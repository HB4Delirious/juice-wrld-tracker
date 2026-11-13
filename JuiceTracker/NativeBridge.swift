import AppKit
import WebKit

/// Gives the page the file access Chrome's File System Access API would: bridge.js builds
/// showDirectoryPicker() and folder/file handles on top of these messages.
/// Only folders the user picked in an open panel (and anything inside them) can be read or written.
final class NativeBridge: NSObject, WKScriptMessageHandlerWithReply {
    private struct BridgeError: Error { let message: String }
    private var roots: [String] = [] // touched on the main thread only

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "TypeError: Bad request")
            return
        }
        switch op {
        case "pickFolder":
            pickFolder(id: body["id"] as? String ?? "", reply: replyHandler)
            return
        case "restoreFolder":
            replyHandler(restoreFolder(id: body["id"] as? String ?? ""), nil)
            return
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body["text"] as? String ?? "", forType: .string)
            replyHandler(true, nil)
            return
        default:
            break
        }
        guard let path = body["path"] as? String, let url = allowedURL(path) else {
            replyHandler(nil, "NotAllowedError: That location isn't inside a folder you chose.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Any?
            let failure: String?
            do {
                result = try Self.perform(op, url: url, body: body)
                failure = nil
            } catch let e as BridgeError {
                result = nil; failure = e.message
            } catch {
                result = nil; failure = "UnknownError: \(error.localizedDescription)"
            }
            DispatchQueue.main.async { replyHandler(result, failure) }
        }
    }

    // MARK: Folder picking

    private func pickFolder(id: String, reply: @escaping (Any?, String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        let key = "lastFolder.\(id)"
        if let last = UserDefaults.standard.string(forKey: key) {
            panel.directoryURL = URL(fileURLWithPath: last).deletingLastPathComponent()
        }
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else {
                reply(nil, "AbortError: The user aborted a request.")
                return
            }
            let path = url.standardizedFileURL.path
            if !(self?.roots.contains(path) ?? true) { self?.roots.append(path) }
            UserDefaults.standard.set(path, forKey: key)
            reply(["path": path, "name": url.lastPathComponent], nil)
        }
    }

    /// Re-grants the folder last picked for this id, so the music folder survives relaunches.
    /// Only ever a folder the user chose in an open panel before; nil if it's gone (e.g. an unmounted drive).
    private func restoreFolder(id: String) -> [String: String]? {
        guard let path = UserDefaults.standard.string(forKey: "lastFolder.\(id)") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        if !roots.contains(path) { roots.append(path) }
        return ["path": path, "name": URL(fileURLWithPath: path).lastPathComponent]
    }

    private func allowedURL(_ path: String) -> URL? {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        for root in roots where p == root || p.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    // MARK: File operations (run off the main thread)

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    private static func kind(of url: URL) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        return isDir.boolValue ? "directory" : "file"
    }

    private static func perform(_ op: String, url: URL, body: [String: Any]) throws -> Any {
        let fm = FileManager.default
        switch op {
        case "list":
            guard kind(of: url) == "directory" else { throw BridgeError(message: "NotFoundError: Folder not found.") }
            let names = try fm.contentsOfDirectory(atPath: url.path)
            return names.compactMap { name -> [String: String]? in
                guard let k = kind(of: url.appendingPathComponent(name)) else { return nil }
                return ["name": name, "kind": k]
            }
        case "stat", "exists":
            guard let k = kind(of: url) else {
                if op == "exists" { return ["exists": false] }
                throw BridgeError(message: "NotFoundError: File not found.")
            }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            return ["exists": true, "kind": k, "size": size]
        case "read":
            guard let start = int(body["start"]), let end = int(body["end"]), start >= 0, end >= start else {
                throw BridgeError(message: "TypeError: Bad range.")
            }
            guard let handle = FileHandle(forReadingAtPath: url.path) else {
                throw BridgeError(message: "NotFoundError: File not found.")
            }
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            let data = try handle.read(upToCount: end - start) ?? Data()
            return data.base64EncodedString()
        case "write":
            guard let b64 = body["data"] as? String, let data = Data(base64Encoded: b64) else {
                throw BridgeError(message: "TypeError: Bad data.")
            }
            try data.write(to: url, options: .atomic)
            return true
        case "mkdir":
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        default:
            throw BridgeError(message: "TypeError: Unknown operation \(op).")
        }
    }
}
