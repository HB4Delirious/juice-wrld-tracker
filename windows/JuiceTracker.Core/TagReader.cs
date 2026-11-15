using System.Text;

namespace JuiceTracker;

/// Reading tags (ID3, FLAC, MP4, Ogg): the page's readers, byte for byte.
public static class TagReader
{
    /// Reads the text tags of one file. Unreadable files give no tags, never an error.
    public static Dictionary<string, string> Read(string file, string ext)
    {
        try
        {
            using var f = new Reader(file);
            if (ext == "flac") return ReadFlac(f) ?? [];
            if (ext is "ogg" or "opus") return ReadOgg(f);
            if (ext is "m4a" or "m4b" or "alac") return ReadMp4(f) ?? ReadId3v2(f) ?? [];
            var tags = ReadId3v2(f) ?? [];
            if (tags.GetValueOrDefault("title", "").Length == 0 && ext == "mp3")
            {
                var v1 = ReadId3v1(f) ?? [];
                foreach (var (k, v) in tags) v1[k] = v; // ID3v2 wins
                tags = v1;
            }
            return tags;
        }
        catch (IOException) { return []; }
        catch (UnauthorizedAccessException) { return []; }
    }

    /// Random-access reads, like slicing a File in the browser (out-of-range parts come back short).
    public sealed class Reader : IDisposable
    {
        readonly FileStream fs;
        public long Size { get; }
        public Reader(string path) { fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete); Size = fs.Length; }
        public byte[] Bytes(long start, long end)
        {
            long s = Math.Min(start, Size), e = Math.Min(Math.Max(end, s), Size);
            if (e <= s) return [];
            var buf = new byte[e - s];
            fs.Position = s;
            int got = 0;
            while (got < buf.Length) { int n = fs.Read(buf, got, buf.Length - got); if (n <= 0) break; got += n; }
            return got == buf.Length ? buf : buf[..got];
        }
        public void Dispose() => fs.Dispose();
    }

    // byte helpers
    public static string Latin1(ReadOnlySpan<byte> b) { var c = new char[b.Length]; for (int i = 0; i < b.Length; i++) c[i] = (char)b[i]; return new string(c); }
    public static ReadOnlySpan<byte> Sub(byte[] b, int s, int e) { int a = Math.Max(0, Math.Min(s, b.Length)), z = Math.Max(a, Math.Min(e, b.Length)); return b.AsSpan(a, z - a); }
    public static int Synchsafe(byte[] b, int p) => p + 3 < b.Length ? (b[p] & 0x7f) << 21 | (b[p + 1] & 0x7f) << 14 | (b[p + 2] & 0x7f) << 7 | (b[p + 3] & 0x7f) : 0;
    public static long U32(byte[] b, int p) => p >= 0 && p + 3 < b.Length ? (long)b[p] << 24 | (long)b[p + 1] << 16 | (long)b[p + 2] << 8 | b[p + 3] : 0;
    public static long? U32le(byte[] b, int p) => p >= 0 && p + 3 < b.Length ? b[p] | (long)b[p + 1] << 8 | (long)b[p + 2] << 16 | (long)b[p + 3] << 24 : null;
    public static string CleanText(string s) => s.TrimEnd('\0').Replace('\0', '/').Trim();
    // Like the browser's TextDecoder, these drop a leading byte order mark (and replace bad bytes with U+FFFD).
    static readonly UTF8Encoding Utf8Lenient = new(false, false);
    public static string Utf8(ReadOnlySpan<byte> b) => NoBom(Utf8Lenient.GetString(b));
    static string NoBom(string s) => s.StartsWith('﻿') ? s[1..] : s;
    public static string Utf16(ReadOnlySpan<byte> b, bool bigEndian)
    {
        var even = b[..(b.Length & ~1)];
        var s = (bigEndian ? Encoding.BigEndianUnicode : Encoding.Unicode).GetString(even);
        return NoBom(s + (b.Length % 2 == 1 ? "�" : ""));
    }

    // ID3
    public static string DecodeId3Text(ReadOnlySpan<byte> b, byte enc) => enc switch
    {
        0 => CleanText(Latin1(b)),
        3 => CleanText(Utf8(b)),
        2 => CleanText(Utf16(b, true)),
        1 => DecodeUtf16Bom(b),
        _ => "",
    };
    static string DecodeUtf16Bom(ReadOnlySpan<byte> b)
    {
        bool be = b.Length >= 2 && b[0] == 0xfe && b[1] == 0xff;
        bool bom = be || (b.Length >= 2 && b[0] == 0xff && b[1] == 0xfe);
        return CleanText(Utf16(bom ? b[2..] : b, be));
    }
    public static (string Desc, string Value)? SplitTxxx(byte[] body)
    {
        if (body.Length < 2) return null;
        byte enc = body[0]; var rest = body[1..];
        bool wide = enc is 1 or 2;
        int i = 0;
        if (wide) { while (i + 1 < rest.Length && !(rest[i] == 0 && rest[i + 1] == 0)) i += 2; }
        else { while (i < rest.Length && rest[i] != 0) i++; }
        return (DecodeId3Text(Sub(rest, 0, i), enc), DecodeId3Text(Sub(rest, i + (wide ? 2 : 1), rest.Length), enc));
    }
    public sealed record Id3Frame(string Id, byte[] Raw, byte[] Body, byte Special);
    public sealed record Id3(byte Ver, bool Unsynced, bool Damaged, int TagEnd, bool Truncated, List<Id3Frame> Frames);

    public static Id3? ParseId3(byte[] b)
    {
        if (b.Length < 10 || Latin1(b.AsSpan(0, 3)) != "ID3") return null;
        byte ver = b[3], flags = b[5]; int size = Synchsafe(b, 6);
        var data = Sub(b, 10, 10 + size).ToArray();
        if ((flags & 0x80) != 0 && ver < 4) // unsynchronisation: FF 00 means FF
        {
            var output = new List<byte>(data.Length);
            for (int i = 0; i < data.Length; i++) { output.Add(data[i]); if (data[i] == 0xff && i + 1 < data.Length && data[i + 1] == 0) i++; }
            data = output.ToArray();
        }
        int pos = 0;
        if ((flags & 0x40) != 0) pos = ver == 4 ? Synchsafe(data, 0) : (int)U32(data, 0) + 4;
        int idLen = ver == 2 ? 3 : 4, hdr = ver == 2 ? 6 : 10;
        var frames = new List<Id3Frame>(); bool damaged = false;
        while (pos + hdr <= data.Length)
        {
            if (data[pos] == 0) break; // padding
            var id = Latin1(data.AsSpan(pos, idLen));
            if (!id.All(c => c is >= 'A' and <= 'Z' or >= '0' and <= '9')) { damaged = true; break; }
            long fsize = ver == 2 ? data[pos + 3] << 16 | data[pos + 4] << 8 | data[pos + 5]
                : ver == 4 ? Synchsafe(data, pos + 4) : U32(data, pos + 4);
            if (pos + hdr + fsize > data.Length) { damaged = true; break; }
            byte fmt = ver == 2 ? (byte)0 : data[pos + 9];
            frames.Add(new Id3Frame(id, data[pos..(pos + hdr + (int)fsize)], data[(pos + hdr)..(pos + hdr + (int)fsize)],
                                    (byte)(ver == 4 ? fmt & 0x0f : fmt & 0xe0)));
            pos += hdr + (int)fsize;
        }
        return new Id3(ver, (flags & 0x80) != 0, damaged, 10 + size + (ver == 4 && (flags & 0x10) != 0 ? 10 : 0), 10 + size > b.Length, frames);
    }

    public static Dictionary<string, string> TagsFromId3(Id3 p)
    {
        var output = new Dictionary<string, string>();
        var map = p.Ver == 2
            ? new Dictionary<string, string> { ["TT2"] = "title", ["TP1"] = "artist", ["TP2"] = "albumartist", ["TAL"] = "album", ["TYE"] = "year", ["TCO"] = "genre" }
            : new Dictionary<string, string> { ["TIT2"] = "title", ["TPE1"] = "artist", ["TPE2"] = "albumartist", ["TALB"] = "album", ["TYER"] = "year", ["TDRC"] = "year", ["TCON"] = "genre" };
        foreach (var f in p.Frames.Where(f => f.Special == 0 && f.Body.Length >= 2))
        {
            if (map.TryGetValue(f.Id, out var k)) { if (output.GetValueOrDefault(k, "").Length == 0) output[k] = DecodeId3Text(f.Body.AsSpan(1), f.Body[0]); }
            else if (f.Id is "TXXX" or "TXX" && output.GetValueOrDefault("producer", "").Length == 0)
            {
                if (SplitTxxx(f.Body) is { } t && t.Desc.ToUpperInvariant() == "PRODUCER") output["producer"] = t.Value;
            }
            else if (f.Id is "COMM" or "COM" && output.GetValueOrDefault("comment", "").Length == 0)
            {
                // COMM is TXXX-like with a three-letter language after the encoding byte
                if (f.Body.Length >= 5 && SplitTxxx([f.Body[0], .. f.Body[4..]]) is { } t && t.Desc.Length == 0) output["comment"] = t.Value;
            }
        }
        FixYear(output);
        return output;
    }
    static void FixYear(Dictionary<string, string> tags)
    {
        if (tags.TryGetValue("year", out var y) && y.Length > 0 && Engine.YearOf(y) is { Length: > 0 } yy) tags["year"] = yy;
    }
    public static Dictionary<string, string>? ReadId3v2(Reader file)
    {
        var h = file.Bytes(0, 10);
        if (h.Length < 10 || Latin1(h.AsSpan(0, 3)) != "ID3") return null;
        int size = Synchsafe(h, 6), first = 256 * 1024;
        var p = ParseId3(file.Bytes(0, 10 + Math.Min(size, first)));
        // Most files put text tags before the cover art, so the first 256 KB is usually enough. Read the whole tag (up to
        // 4 MB) when the title wasn't there, or when a frame ran past it: then more frames follow the art.
        if (p is not null && size > first && (TagsFromId3(p).GetValueOrDefault("title", "").Length == 0 || p.Damaged))
            p = ParseId3(file.Bytes(0, 10 + Math.Min(size, 4 * 1024 * 1024)));
        return p is null ? null : TagsFromId3(p);
    }
    public static Dictionary<string, string>? ReadId3v1(Reader file)
    {
        if (file.Size < 128) return null;
        var b = file.Bytes(file.Size - 128, file.Size);
        if (b.Length != 128 || Latin1(b.AsSpan(0, 3)) != "TAG") return null;
        return new() { ["title"] = CleanText(Latin1(b.AsSpan(3, 30))), ["artist"] = CleanText(Latin1(b.AsSpan(33, 30))),
                       ["album"] = CleanText(Latin1(b.AsSpan(63, 30))), ["year"] = Engine.YearOf(Latin1(b.AsSpan(93, 4))) };
    }

    // FLAC and Ogg (Vorbis comments)
    static readonly Dictionary<string, string> VorbisKeys = new()
    {
        ["TITLE"] = "title", ["ARTIST"] = "artist", ["ALBUMARTIST"] = "albumartist", ["ALBUM ARTIST"] = "albumartist", ["ALBUM"] = "album",
        ["DATE"] = "year", ["YEAR"] = "year", ["PRODUCER"] = "producer", ["GENRE"] = "genre", ["COMMENT"] = "comment",
    };
    public static Dictionary<string, string> ParseVorbisComments(byte[] b)
    {
        var output = new Dictionary<string, string>();
        int p = 0;
        if (U32le(b, p) is { } vendor)
        {
            p += 4 + (int)vendor;
            if (U32le(b, p) is { } n)
            {
                p += 4;
                for (long i = 0; i < n && p + 4 <= b.Length && U32le(b, p) is { } len; i++) // truncated: keep what was read
                {
                    p += 4;
                    var s = Utf8(Sub(b, p, p + (int)len)); p += (int)len;
                    int eq = s.IndexOf('=');
                    if (eq < 0) continue;
                    if (VorbisKeys.TryGetValue(s[..eq].ToUpperInvariant(), out var key) && output.GetValueOrDefault(key, "").Length == 0)
                        output[key] = s[(eq + 1)..].Trim();
                }
            }
        }
        FixYear(output);
        return output;
    }
    public static Dictionary<string, string>? ReadFlac(Reader file)
    {
        if (Latin1(file.Bytes(0, 4)) != "fLaC") return null;
        long pos = 4;
        for (int n = 0; n < 64; n++)
        {
            var h = file.Bytes(pos, pos + 4);
            if (h.Length < 4) break;
            bool last = (h[0] & 0x80) != 0; int type = h[0] & 0x7f; long len = h[1] << 16 | h[2] << 8 | h[3];
            if (type == 4) return ParseVorbisComments(file.Bytes(pos + 4, pos + 4 + Math.Min(len, 1 << 20)));
            pos += 4 + len;
            if (last) break;
        }
        return [];
    }
    public static Dictionary<string, string> ReadOgg(Reader file)
    {
        var b = file.Bytes(0, 256 * 1024);
        if (Find(b, "OpusTags"u8.ToArray()) is { } i) return ParseVorbisComments(b[(i + 8)..]);
        if (Find(b, [3, .. "vorbis"u8.ToArray()]) is { } j) return ParseVorbisComments(b[(j + 7)..]);
        return [];
    }
    static int? Find(byte[] b, byte[] needle)
    {
        int idx = b.AsSpan().IndexOf(needle);
        return idx >= 0 ? idx : null;
    }

    // MP4 (M4A)
    static readonly Dictionary<string, string> Mp4Keys = new()
    {
        ["©nam"] = "title", ["©ART"] = "artist", ["aART"] = "albumartist", ["©alb"] = "album", ["©day"] = "year", ["©gen"] = "genre", ["©cmt"] = "comment",
    };
    public static void WalkAtoms(byte[] b, int start, int end, Action<string, int, int> cb)
    {
        int p = start;
        while (p + 8 <= end)
        {
            long len = U32(b, p);
            var type = Latin1(Sub(b, p + 4, p + 8));
            if (len < 8 || p + len > end) len = end - p;
            cb(type, p + 8, p + (int)len);
            p += (int)len;
        }
    }
    public static Dictionary<string, string> ParseMoov(byte[] b)
    {
        var output = new Dictionary<string, string>();
        void Walk(int start, int end)
        {
            WalkAtoms(b, start, end, (type, s, e) =>
            {
                if (type is "udta" or "ilst") Walk(s, e);
                else if (type == "meta") Walk(Latin1(Sub(b, s + 4, s + 8)) == "hdlr" ? s : s + 4, e); // usually a full box
                else if (Mp4Keys.TryGetValue(type, out var k))
                {
                    WalkAtoms(b, s, e, (t2, s2, e2) =>
                    {
                        if (t2 == "data" && output.GetValueOrDefault(k, "").Length == 0) output[k] = Utf8(Sub(b, s2 + 8, e2)).Trim();
                    });
                }
                else if (type == "----")
                {
                    string name = "", value = "";
                    WalkAtoms(b, s, e, (t2, s2, e2) =>
                    {
                        if (t2 == "name") name = Utf8(Sub(b, s2 + 4, e2));
                        else if (t2 == "data") value = Utf8(Sub(b, s2 + 8, e2)).Trim();
                    });
                    if (name.ToUpperInvariant() == "PRODUCER" && output.GetValueOrDefault("producer", "").Length == 0) output["producer"] = value;
                }
            });
        }
        Walk(0, b.Length);
        FixYear(output);
        return output;
    }
    public static Dictionary<string, string>? ReadMp4(Reader file)
    {
        long pos = 0;
        for (int n = 0; n < 64 && pos + 8 <= file.Size; n++)
        {
            var h = file.Bytes(pos, pos + 16);
            if (h.Length < 8) break;
            long len = U32(h, 0), hdr = 8;
            var type = Latin1(h.AsSpan(4, 4));
            if (len == 1) { if (h.Length < 16) break; len = U32(h, 8) << 32 | U32(h, 12); hdr = 16; }
            else if (len == 0) len = file.Size - pos;
            if (len < 8) break;
            if (type == "moov") return ParseMoov(file.Bytes(pos + hdr, pos + Math.Min(len, 16 * 1024 * 1024)));
            pos += len;
        }
        return null;
    }
}
