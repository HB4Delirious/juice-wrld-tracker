import AppKit
import AVFoundation
import CoreMedia
import Network
import ScreenCaptureKit
import SwiftUI
import VideoToolbox

// Go live on TikTok (or anywhere that takes RTMP) straight from the app: the stream window's picture and the app's own
// sound are captured (ScreenCaptureKit), encoded on the Mac's media engine (H.264 video, AAC audio) and sent over
// RTMP with the Server URL and Stream Key TikTok gives you. Nothing else on the screen is captured.

struct LiveError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

// MARK: - AMF0 (the little data format RTMP commands are written in)

enum AMF {
    case number(Double), bool(Bool), string(String), object([(String, AMF)]), ecmaArray([(String, AMF)]), null

    func write(_ d: inout Data) {
        switch self {
        case .number(let v): d.append(0x00); d.append(contentsOf: withUnsafeBytes(of: v.bitPattern.bigEndian, Array.init))
        case .bool(let v): d.append(0x01); d.append(v ? 1 : 0)
        case .string(let s): d.append(0x02); AMF.key(s, &d)
        case .object(let pairs): d.append(0x03); AMF.pairs(pairs, &d)
        case .ecmaArray(let pairs):
            d.append(0x08); d.append(contentsOf: withUnsafeBytes(of: UInt32(pairs.count).bigEndian, Array.init)); AMF.pairs(pairs, &d)
        case .null: d.append(0x05)
        }
    }
    private static func key(_ s: String, _ d: inout Data) {
        let u = Array(s.utf8); d.append(contentsOf: withUnsafeBytes(of: UInt16(u.count).bigEndian, Array.init)); d.append(contentsOf: u)
    }
    private static func pairs(_ pairs: [(String, AMF)], _ d: inout Data) {
        for (k, v) in pairs { key(k, &d); v.write(&d) }
        d.append(contentsOf: [0, 0, 9])
    }
    static func encode(_ values: [AMF]) -> Data { var d = Data(); for v in values { v.write(&d) }; return d }

    /// Reads values until the data ends or holds a type this doesn't know.
    static func decode(_ data: Data) -> [AMF] {
        let b = [UInt8](data); var i = 0, out: [AMF] = []
        func u16() -> Int? { guard i + 2 <= b.count else { return nil }; defer { i += 2 }; return Int(b[i]) << 8 | Int(b[i + 1]) }
        func str() -> String? { guard let n = u16(), i + n <= b.count else { return nil }; defer { i += n }; return String(decoding: b[i..<i + n], as: UTF8.self) }
        func pairs() -> [(String, AMF)]? {
            var p: [(String, AMF)] = []
            while i + 3 <= b.count {
                if b[i] == 0, b[i + 1] == 0, b[i + 2] == 9 { i += 3; return p }
                guard let k = str(), let v = value() else { return nil }
                p.append((k, v))
            }
            return nil
        }
        func value() -> AMF? {
            guard i < b.count else { return nil }
            let t = b[i]; i += 1
            switch t {
            case 0x00:
                guard i + 8 <= b.count else { return nil }
                var bits: UInt64 = 0; for k in 0..<8 { bits = bits << 8 | UInt64(b[i + k]) }; i += 8
                return .number(Double(bitPattern: bits))
            case 0x01: guard i < b.count else { return nil }; defer { i += 1 }; return .bool(b[i] != 0)
            case 0x02: return str().map(AMF.string)
            case 0x03: return pairs().map(AMF.object)
            case 0x05, 0x06: return .null
            case 0x08: i += 4; return pairs().map(AMF.ecmaArray)
            default: return nil
            }
        }
        while let v = value() { out.append(v) }
        return out
    }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
    subscript(key: String) -> AMF? {
        switch self { case .object(let p), .ecmaArray(let p): return p.first { $0.0 == key }?.1; default: return nil }
    }
}

// MARK: - RTMP publisher

/// Sends a live stream to an RTMP server: handshake, connect, publish, then audio and video messages (FLV tags).
final class RTMPPublisher: @unchecked Sendable {
    private let connection: NWConnection
    private let app: String, tcUrl: String, streamName: String
    private let queue = DispatchQueue(label: "rtmp")
    private var inbound = Data(), inChunk = 128, outChunk = 4096
    private var partial: [UInt32: (type: UInt8, length: Int, stream: UInt32, time: UInt32, body: Data)] = [:]
    private var streamId: UInt32 = 0
    private var waiting: (name: String?, txn: Double?, cont: CheckedContinuation<[AMF], Error>)?
    private(set) var pending = 0         // sends not yet handed to the network (a growing number means a slow link)
    private(set) var sentBytes = 0
    var onClose: ((Error?) -> Void)?
    private var closed = false

    /// `server` is the Server URL (rtmp:// or rtmps://host[:port]/app...); `key` the Stream Key.
    init(server: String, key: String) throws {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "rtmp" || scheme == "rtmps", let host = url.host, !host.isEmpty else {
            throw LiveError("The Server URL should start with rtmp:// or rtmps:// (copy it from TikTok LIVE).")
        }
        let port = UInt16(url.port ?? (scheme == "rtmps" ? 443 : 1935))
        app = url.path.split(separator: "/").joined(separator: "/")
        tcUrl = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        streamName = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !streamName.isEmpty else { throw LiveError("Add your Stream Key (copy it from TikTok LIVE).") }
        let params: NWParameters = scheme == "rtmps" ? .tls : .tcp
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    // MARK: Connecting

    func connect() async throws {
        try await open()
        // handshake: C0+C1, read S0+S1+S2, answer with C2 (= S1)
        var c1 = Data(count: 1536)
        c1.withUnsafeMutableBytes { p in for k in 8..<1536 { p[k] = UInt8.random(in: 0...255) } }
        try await write(Data([3]) + c1)
        let s = try await read(1 + 1536 + 1536)
        guard s.first == 3 else { throw LiveError("The server didn't answer like an RTMP server.") }
        try await write(s.subdata(in: 1..<1537))
        queue.async { self.readLoop() }
        send(type: 1, csid: 2, stream: 0, time: 0, body: withUnsafeBytes(of: UInt32(outChunk).bigEndian) { Data($0) })
        outChunkActive = outChunk
        let connected = try await command(["connect", 1, .object([("app", .string(app)), ("type", .string("nonprivate")),
                                            ("flashVer", .string("FMLE/3.0 (compatible; JuiceTracker)")), ("tcUrl", .string(tcUrl))])], txn: 1)
        if let code = connected.dropFirst(3).first?["code"]?.string, code.contains("Rejected") || code.contains("Failed") {
            throw LiveError("The server refused the connection (\(code)).")
        }
        sendCommand(["releaseStream", 2, .null, .string(streamName)])
        sendCommand(["FCPublish", 3, .null, .string(streamName)])
        let created = try await command(["createStream", 4, .null], txn: 4)
        streamId = UInt32(created.dropFirst(3).first?.number ?? 1)
        let status = try await command(["publish", 5, .null, .string(streamName), .string("live")], name: "onStatus", csid: 4, stream: streamId)
        let code = status.dropFirst(3).first?["code"]?.string ?? ""
        guard code == "NetStream.Publish.Start" else {
            throw LiveError(code.isEmpty ? "The server didn't start the stream." : "The server didn't start the stream (\(code)). Check the Stream Key; TikTok's keys change each time you set up a LIVE.")
        }
    }

    private var outChunkActive = 128

    func close() {
        queue.async {
            guard !self.closed else { return }
            if self.streamId != 0 {
                let body = AMF.encode([.string("deleteStream"), .number(6), .null, .number(Double(self.streamId))])
                self.connection.send(content: self.chunk(type: 20, csid: 3, stream: 0, time: 0, body: body), completion: .idempotent)
            }
            self.closed = true
            self.connection.cancel()
        }
    }

    // MARK: Sending media

    /// Stream details for players (TikTok reads the codecs and size from here).
    func sendMetadata(width: Int, height: Int, fps: Double, videoKbps: Double, audioKbps: Double) {
        let meta: [(String, AMF)] = [("width", .number(Double(width))), ("height", .number(Double(height))), ("framerate", .number(fps)),
                                     ("videocodecid", .number(7)), ("videodatarate", .number(videoKbps)), ("audiocodecid", .number(10)),
                                     ("audiodatarate", .number(audioKbps)), ("audiosamplerate", .number(48000)), ("audiosamplesize", .number(16)),
                                     ("stereo", .bool(true)), ("encoder", .string("Juice Tracker"))]
        send(type: 18, csid: 5, stream: streamId, time: 0, body: AMF.encode([.string("@setDataFrame"), .string("onMetaData"), .ecmaArray(meta)]))
    }
    func sendAudio(_ body: Data, ms: UInt32) { send(type: 8, csid: 4, stream: streamId, time: ms, body: body) }
    func sendVideo(_ body: Data, ms: UInt32) { send(type: 9, csid: 6, stream: streamId, time: ms, body: body) }

    // MARK: Chunks

    private func chunk(type: UInt8, csid: UInt8, stream: UInt32, time: UInt32, body: Data) -> Data {
        var out = Data(capacity: body.count + body.count / outChunkActive + 16)
        let ts = min(time, 0xFFFFFF), extended = time >= 0xFFFFFF
        out.append(csid & 0x3F)  // a full (type 0) header
        out.append(contentsOf: [UInt8(ts >> 16 & 0xFF), UInt8(ts >> 8 & 0xFF), UInt8(ts & 0xFF)])
        out.append(contentsOf: [UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF), type])
        out.append(contentsOf: withUnsafeBytes(of: stream.littleEndian, Array.init))
        if extended { out.append(contentsOf: withUnsafeBytes(of: time.bigEndian, Array.init)) }
        let bytes = [UInt8](body); var at = 0
        repeat {
            if at > 0 { out.append(0xC0 | (csid & 0x3F)); if extended { out.append(contentsOf: withUnsafeBytes(of: time.bigEndian, Array.init)) } }
            let n = min(outChunkActive, bytes.count - at)
            out.append(contentsOf: bytes[at..<at + n]); at += n
        } while at < bytes.count
        return out
    }
    private func send(type: UInt8, csid: UInt8, stream: UInt32, time: UInt32, body: Data) {
        queue.async {
            guard !self.closed else { return }
            let data = self.chunk(type: type, csid: csid, stream: stream, time: time, body: body)
            self.pending += 1; self.sentBytes += data.count
            self.connection.send(content: data, completion: .contentProcessed { error in
                self.queue.async { self.pending -= 1 }
                if let error { self.fail(error) }
            })
        }
    }
    private func sendCommand(_ values: [AMF], csid: UInt8 = 3, stream: UInt32 = 0) {
        send(type: 20, csid: csid, stream: stream, time: 0, body: AMF.encode(values))
    }
    /// Sends a command and waits for its answer: a _result/_error with the same transaction number, or a named reply.
    private func command(_ values: [AMF], txn: Double? = nil, name: String? = nil, csid: UInt8 = 3, stream: UInt32 = 0) async throws -> [AMF] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[AMF], Error>) in
            queue.async {
                self.waiting = (name, txn, c)
                self.sendCommand(values, csid: csid, stream: stream)
                self.queue.asyncAfter(deadline: .now() + 12) {
                    if let w = self.waiting, w.txn == txn, w.name == name { self.waiting = nil; w.cont.resume(throwing: LiveError("The server didn't answer in time.")) }
                }
            }
        }
    }

    // MARK: Reading what the server sends

    private func readLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            self.queue.async {
                if let data { self.inbound.append(data); self.parse() }
                if let error { self.fail(error); return }
                if done { self.fail(LiveError("The server closed the connection.")); return }
                if !self.closed { self.readLoop() }
            }
        }
    }
    private func parse() {
        let b = [UInt8](inbound); var i = 0
        while true {
            let start = i
            guard i < b.count else { break }
            let fmt = b[i] >> 6; var csid = UInt32(b[i] & 0x3F); i += 1
            if csid == 0 { guard i < b.count else { i = start; break }; csid = 64 + UInt32(b[i]); i += 1 }
            else if csid == 1 { guard i + 1 < b.count else { i = start; break }; csid = 64 + UInt32(b[i]) + UInt32(b[i + 1]) * 256; i += 2 }
            let headerSize = [11, 7, 3, 0][Int(fmt)]
            guard i + headerSize <= b.count else { i = start; break }
            var m = partial[csid] ?? (0, 0, 0, 0, Data())
            if fmt <= 2 { m.time = UInt32(b[i]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) }
            if fmt <= 1 { m.length = Int(b[i + 3]) << 16 | Int(b[i + 4]) << 8 | Int(b[i + 5]); m.type = b[i + 6] }
            if fmt == 0 { m.stream = UInt32(b[i + 7]) | UInt32(b[i + 8]) << 8 | UInt32(b[i + 9]) << 16 | UInt32(b[i + 10]) << 24 }
            i += headerSize
            if m.time == 0xFFFFFF { guard i + 4 <= b.count else { i = start; break }; i += 4 }
            let n = min(inChunk, m.length - m.body.count)
            guard i + n <= b.count else { i = start; break }
            m.body.append(contentsOf: b[i..<i + n]); i += n
            if m.body.count >= m.length {
                handle(type: m.type, body: m.body)
                m.body = Data()
            }
            partial[csid] = m
        }
        inbound = i > 0 ? Data(b[i...]) : inbound
    }
    private func handle(type: UInt8, body: Data) {
        let b = [UInt8](body)
        switch type {
        case 1 where b.count >= 4: inChunk = Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case 4 where b.count >= 6 && b[1] == 6: // ping: answer with pong
            send(type: 4, csid: 2, stream: 0, time: 0, body: Data([0, 7] + b[2..<6]))
        case 20:
            let values = AMF.decode(body)
            guard let name = values.first?.string, let w = waiting else { return }
            let txn = values.dropFirst().first?.number
            if (w.txn != nil && txn == w.txn && (name == "_result" || name == "_error")) || (w.name != nil && name == w.name) {
                waiting = nil
                if name == "_error" {
                    let why = values.dropFirst(3).first?["description"]?.string ?? values.dropFirst(3).first?["code"]?.string ?? "an error"
                    w.cont.resume(throwing: LiveError("The server answered with \(why)."))
                } else { w.cont.resume(returning: values) }
            }
        default: break
        }
    }
    private func fail(_ error: Error) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        if let w = waiting { waiting = nil; w.cont.resume(throwing: error) }
        onClose?(error)
    }

    // MARK: Network helpers

    private func open() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            final class Once: @unchecked Sendable { var done = false } // only touched on the connection's queue
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if !once.done { once.done = true; c.resume() }
                case .failed(let e): if !once.done { once.done = true; c.resume(throwing: LiveError("Couldn't reach the streaming server: \(e.localizedDescription)")) }
                case .waiting(let e): if !once.done { once.done = true; self.connection.cancel(); c.resume(throwing: LiveError("Couldn't reach the streaming server: \(e.localizedDescription)")) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }
    private func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { e in if let e { c.resume(throwing: e) } else { c.resume() } })
        }
    }
    private func read(_ count: Int) async throws -> Data {
        var got = Data()
        while got.count < count {
            got += try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - got.count) { data, _, done, error in
                    if let error { c.resume(throwing: error) } else if let data, !data.isEmpty { c.resume(returning: data) }
                    else { c.resume(throwing: LiveError(done ? "The server closed the connection." : "Nothing came back from the server.")) }
                }
            }
        }
        return got
    }
}

extension AMF: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
}

// MARK: - Encoders

/// H.264 on the Mac's media engine: no B-frames (so decode order is display order), a keyframe every 2 seconds.
final class LiveVideoEncoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private var sentConfig = false
    /// (FLV video tag body, presentation time)
    var onFrame: ((Data, CMTime) -> Void)?

    init(width: Int, height: Int, bitrate: Int, fps: Int) throws {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { throw LiveError("This Mac couldn't start the video encoder (\(status)).") }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [bitrate / 8 * 3 / 2, 1] as CFArray, // bytes per second, over 1 second
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
        ]
        for (k, v) in props { VTSessionSetProperty(s, key: k, value: v as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }
    deinit { if let session { VTCompressionSessionInvalidate(session) } }

    func encode(_ image: CVImageBuffer, at time: CMTime) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: time, duration: .invalid, frameProperties: nil,
                                        infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.output(sample)
        }
    }

    private func output(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if key && !sentConfig, let format = CMSampleBufferGetFormatDescription(sample), let record = Self.avcC(format) {
            sentConfig = true
            onFrame?(Data([0x17, 0, 0, 0, 0]) + record, pts) // the decoder setup (SPS/PPS) goes first
        }
        guard sentConfig, let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var bytes = Data(count: CMBlockBufferGetDataLength(block))
        bytes.withUnsafeMutableBytes { p in _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: p.count, destination: p.baseAddress!) }
        onFrame?(Data([key ? 0x17 : 0x27, 1, 0, 0, 0]) + bytes, pts) // NAL units, already length-prefixed (AVCC)
    }

    /// The AVCDecoderConfigurationRecord from the encoder's SPS and PPS.
    private static func avcC(_ format: CMFormatDescription) -> Data? {
        func set(_ k: Int) -> Data? {
            var ptr: UnsafePointer<UInt8>?; var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: k, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                                                                       parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr else { return nil }
            return Data(bytes: ptr, count: size)
        }
        guard let sps = set(0), let pps = set(1), sps.count >= 4 else { return nil }
        var d = Data([1, sps[1], sps[2], sps[3], 0xFF, 0xE1])
        d.append(contentsOf: [UInt8(sps.count >> 8), UInt8(sps.count & 0xFF)]); d.append(sps)
        d.append(contentsOf: [1, UInt8(pps.count >> 8), UInt8(pps.count & 0xFF)]); d.append(pps)
        return d
    }
}

/// AAC-LC, 48 kHz stereo, 128 kbps. Time comes from the number of samples encoded, so audio never runs ahead or
/// leaves gaps (silence fills in when the app is quiet).
final class LiveAudioEncoder: @unchecked Sendable {
    static let rate = 48000.0
    static let sequenceHeader = Data([0xAF, 0x00, 0x11, 0x90]) // AudioSpecificConfig: AAC-LC, 48 kHz, 2 channels
    private let output: AVAudioFormat
    private let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    private let converter: AVAudioConverter
    private(set) var samples: Int64 = 0      // encoded so far
    private var packets: Int64 = 0
    private let queue = DispatchQueue(label: "live.aac") // captured sound and filler silence arrive on different threads
    /// (FLV audio tag body, milliseconds since the start)
    var onPacket: ((Data, UInt32) -> Void)?

    init() throws {
        var d = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
                                            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let out = AVAudioFormat(streamDescription: &d), let c = AVAudioConverter(from: input, to: out) else { throw LiveError("This Mac couldn't start the audio encoder.") }
        c.bitRate = 128_000
        output = out; converter = c
    }

    /// Captured sound (any float format ScreenCaptureKit gives; converted to 48 kHz stereo here).
    func encode(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              let inFormat = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr else { return }
        if inFormat == input { queue.async { self.push(pcm) } }
        else if let fit = AVAudioConverter(from: inFormat, to: input), let out = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames * 2) {
            var given = false
            fit.convert(to: out, error: nil) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true; status.pointee = .haveData; return pcm
            }
            queue.async { self.push(out) }
        }
    }
    /// Silence, so the stream keeps a steady audio track when nothing plays.
    func silence(frames: Int) {
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames) // buffers start zeroed
        queue.async { self.push(pcm) }
    }
    /// Plain 48 kHz stereo float samples (the self-test's tone).
    func encodePCM(_ pcm: AVAudioPCMBuffer) { queue.async { self.push(pcm) } }

    private func push(_ pcm: AVAudioPCMBuffer) {
        samples += Int64(pcm.frameLength)
        var given = false
        while true {
            let out = AVAudioCompressedBuffer(format: output, packetCapacity: 8, maximumPacketSize: max(converter.maximumOutputPacketSize, 1536))
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, s in
                if given { s.pointee = .noDataNow; return nil }
                given = true; s.pointee = .haveData; return pcm
            }
            guard status != .error, out.packetCount > 0, let descriptions = out.packetDescriptions else { break }
            for k in 0..<Int(out.packetCount) {
                let d = descriptions[k]
                let bytes = Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize))
                onPacket?(Data([0xAF, 1]) + bytes, UInt32(Double(packets) * 1024 / Self.rate * 1000))
                packets += 1
            }
        }
    }
}

// MARK: - Capture

/// The stream window's picture and the app's sound, from ScreenCaptureKit (needs Screen Recording permission).
@available(macOS 13, *)
final class LiveCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "live.video"), audioQueue = DispatchQueue(label: "live.audio")
    var onVideo: ((CVImageBuffer, CMTime) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onStop: ((Error) -> Void)?

    func start(windowNumber: Int, width: Int, height: Int) async throws {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch {
            throw LiveError("Juice Tracker needs Screen Recording permission to stream its window: System Settings > Privacy & Security > Screen & System Audio Recording, turn on Juice Tracker, then try again.")
        }
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(windowNumber) }) else {
            throw LiveError("Couldn't find the stream window to capture.")
        }
        let config = SCStreamConfiguration()
        config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false
        config.queueDepth = 6
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false // the music is this app's own sound
        config.sampleRate = 48000; config.channelCount = 2
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await s.startCapture()
        stream = s
    }
    func stop() { let s = stream; stream = nil; Task { try? await s?.stopCapture() } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }
        switch type {
        case .screen:
            guard let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let image = CMSampleBufferGetImageBuffer(sample) else { return }
            onVideo?(image, CMSampleBufferGetPresentationTimeStamp(sample))
        case .audio: onAudio?(sample)
        default: break
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }
}

// MARK: - Going live

/// When the stream's first picture was taken; every picture's time is counted from it. Read on the encoder's thread.
final class LiveClock: @unchecked Sendable {
    private let lock = NSLock()
    private var start = CMTime.invalid
    func mark(_ t: CMTime) { lock.lock(); if !start.isValid { start = t }; lock.unlock() }
    func ms(_ t: CMTime) -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return start.isValid ? UInt32(max(0, CMTimeGetSeconds(CMTimeSubtract(t, start)) * 1000)) : 0
    }
}

/// The live session: the stream window → capture → encoders → RTMP. Lives on the main thread; the media work runs on
/// the capture and encoder queues.
@MainActor final class GoLive: ObservableObject {
    static let shared = GoLive()
    enum State: Equatable { case off, connecting, live(since: Date), failed(String) }
    @Published private(set) var state: State = .off
    @Published private(set) var portrait = true
    @Published private(set) var kbps = 0

    static let serverKey = "liveServerURL", keychainAccount = "live-stream-key"
    static var server: String { UserDefaults.standard.string(forKey: serverKey) ?? "" }
    static var hasKey: Bool { UserDefaults.standard.bool(forKey: "keychain.\(keychainAccount).saved") }

    private var publisher: RTMPPublisher?
    private var video: LiveVideoEncoder?
    private var audio: LiveAudioEncoder?
    private var capture: AnyObject?
    private var silenceTimer: Timer?, rateTimer: Timer?
    private var lastAudio = Date()
    private var lastBytes = 0

    var isOn: Bool { if case .off = state { return false }; if case .failed = state { return false }; return true }

    func start(portrait: Bool) {
        guard !isOn else { return }
        guard #available(macOS 13, *) else { state = .failed("Going live needs macOS 13 or later."); return }
        guard !Self.server.isEmpty, Self.hasKey, let key = Keychain.read(Self.keychainAccount) else {
            state = .failed("Add the Server URL and Stream Key from TikTok LIVE in Settings > Live first."); return
        }
        self.portrait = portrait
        state = .connecting
        StreamWindows.show(portrait: portrait)
        let width = portrait ? 1080 : 1920, height = portrait ? 1920 : 1080
        let server = Self.server
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000) // let the window draw before it's captured
            do {
                guard let window = StreamWindows.window(portrait: portrait) else { throw LiveError("The stream window didn't open.") }
                let publisher = try RTMPPublisher(server: server, key: key)
                try await publisher.connect()
                publisher.sendMetadata(width: width, height: height, fps: 30, videoKbps: 4500, audioKbps: 128)
                publisher.sendAudio(LiveAudioEncoder.sequenceHeader, ms: 0)
                let video = try LiveVideoEncoder(width: width, height: height, bitrate: 4_500_000, fps: 30)
                let audio = try LiveAudioEncoder()
                self.publisher = publisher; self.video = video; self.audio = audio
                let clock = LiveClock()
                var waitForKey = false // only touched on the encoder's thread
                video.onFrame = { body, pts in
                    let key = body.first == 0x17
                    // a slow connection: drop pictures until the next keyframe rather than fall behind
                    if publisher.pending > 90 { waitForKey = true }
                    if waitForKey { guard key else { return }; waitForKey = false }
                    publisher.sendVideo(body, ms: clock.ms(pts))
                }
                audio.onPacket = { body, ms in publisher.sendAudio(body, ms: ms) }
                publisher.onClose = { error in
                    Task { @MainActor in self.end(error.map { "The stream stopped: \($0.localizedDescription)" }) }
                }
                let capture = LiveCapture()
                capture.onVideo = { image, pts in
                    clock.mark(pts)
                    video.encode(image, at: pts)
                }
                capture.onAudio = { sample in
                    audio.encode(sample)
                    Task { @MainActor in self.lastAudio = Date() }
                }
                capture.onStop = { error in Task { @MainActor in self.end("Capture stopped: \(error.localizedDescription)") } }
                try await capture.start(windowNumber: window.windowNumber, width: width, height: height)
                self.capture = capture
                self.state = .live(since: Date())
                self.lastAudio = Date()
                // keep the audio track going when nothing plays
                self.silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        guard Date().timeIntervalSince(self.lastAudio) > 0.25 else { return }
                        self.audio?.silence(frames: 4800)
                    }
                }
                self.rateTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        guard let p = self.publisher else { return }
                        self.kbps = (p.sentBytes - self.lastBytes) * 8 / 2000; self.lastBytes = p.sentBytes
                    }
                }
            } catch {
                end(error.localizedDescription)
            }
        }
    }

    func stop() { end(nil) }

    private func end(_ problem: String?) {
        silenceTimer?.invalidate(); silenceTimer = nil; rateTimer?.invalidate(); rateTimer = nil
        if #available(macOS 13, *) { (capture as? LiveCapture)?.stop() }
        capture = nil
        publisher?.onClose = nil; publisher?.close(); publisher = nil
        video = nil; audio = nil; kbps = 0; lastBytes = 0
        state = problem.map(State.failed) ?? .off
    }
}

// MARK: - Self-test (CI): a made-up picture and tone through the encoders and the RTMP sender

enum GoLiveSelfTest {
    /// `JuiceTracker --rtmp-selftest <server> <key>`: six seconds of a moving picture and a tone, then exit 0 (or 1).
    static func run(server: String, key: String) -> Never {
        let done = DispatchSemaphore(value: 0)
        var failure: String?
        Task.detached {
            do {
                let publisher = try RTMPPublisher(server: server, key: key)
                try await publisher.connect()
                let width = 1080, height = 1920
                publisher.sendMetadata(width: width, height: height, fps: 30, videoKbps: 2500, audioKbps: 128)
                publisher.sendAudio(LiveAudioEncoder.sequenceHeader, ms: 0)
                let video = try LiveVideoEncoder(width: width, height: height, bitrate: 2_500_000, fps: 30)
                let audio = try LiveAudioEncoder()
                video.onFrame = { body, pts in publisher.sendVideo(body, ms: UInt32(CMTimeGetSeconds(pts) * 1000)) }
                audio.onPacket = { body, ms in publisher.sendAudio(body, ms: ms) }
                var pool: CVPixelBufferPool?
                CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                   kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                                   kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool)
                guard let pool else { throw LiveError("no pixel buffers") }
                let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
                for frame in 0..<180 {
                    var buffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                    guard let buffer else { continue }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    for plane in 0..<2 { // a brightness that sweeps over time
                        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
                        memset(base, plane == 0 ? Int32(16 + frame % 200) : 128, bytes)
                    }
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    video.encode(buffer, at: CMTime(value: CMTimeValue(frame), timescale: 30))
                    // 1/30 s of a 440 Hz tone
                    let pcm = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 1600)!; pcm.frameLength = 1600
                    for c in 0..<2 { for k in 0..<1600 { pcm.floatChannelData![c][k] = 0.2 * sinf(Float(frame * 1600 + k) * 2 * .pi * 440 / 48000) } }
                    audio.encodePCM(pcm)
                    try await Task.sleep(nanoseconds: 33_000_000)
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                publisher.close()
                try await Task.sleep(nanoseconds: 500_000_000)
                print("rtmp self-test: sent \(publisher.sentBytes) bytes")
            } catch { failure = error.localizedDescription }
            done.signal()
        }
        done.wait()
        if let failure { print("rtmp self-test failed: \(failure)"); exit(1) }
        exit(0)
    }
}
