using System.Text;

namespace JuiceTracker;

/// Rewrites a file's tags and leaves its audio bytes alone. Each writer returns the new file; its verify step re-reads
/// it and throws unless the audio is untouched and every tag reads back, so a bad write is never saved. The page's
/// writers and safety checks, byte for byte.
public static class TagWriter
{
    public static readonly string[] Fields = ["title", "artist", "albumartist", "album", "year", "producer", "genre", "comment"];
    public static readonly Dictionary<string, string> FieldLabels = new()
    {
        ["title"] = "Title", ["artist"] = "Artist", ["albumartist"] = "Album artist", ["album"] = "Album", ["year"] = "Year",
        ["producer"] = "Producers", ["genre"] = "Genre", ["comment"] = "Comment",
    };
    public sealed record Written(byte[] Out, long AudioLength = 0, long Delta = 0, int MoovStart = 0, int OldMoovEnd = 0);
    public static Dictionary<string, string> NoTags => [];

    /// Writes and checks: the new file's bytes, or an error saying why the file was left unchanged.
    public static byte[] Write(byte[] orig, string ext, Dictionary<string, string> desired)
    {
        var want = desired.Where(kv => kv.Value.Length > 0).ToDictionary();
        switch (ext)
        {
            case "mp3": { var r = WriteMp3(orig, want); VerifyMp3(orig, r, want); return r.Out; }
            case "flac": { var r = WriteFlac(orig, want); VerifyFlac(orig, r, want); return r.Out; }
            case "m4a": { var r = WriteM4a(orig, want); VerifyM4a(orig, r, want); return r.Out; }
            default: throw new EngineError("can't be tagged here (only MP3, FLAC and M4A)");
        }
    }

    // byte helpers
    public static byte[] Ascii(string s) => s.Select(c => (byte)c).ToArray();
    public static byte[] Utf8(string s) => Encoding.UTF8.GetBytes(s);
    public static byte[] Utf16le(string s) => Encoding.Unicode.GetBytes(s);
    public static byte[] U32be(long n) => [(byte)(n >> 24 & 255), (byte)(n >> 16 & 255), (byte)(n >> 8 & 255), (byte)(n & 255)];
    public static byte[] U32le(long n) => [(byte)(n & 255), (byte)(n >> 8 & 255), (byte)(n >> 16 & 255), (byte)(n >> 24 & 255)];
    static byte[] Cat(params byte[][] parts) { var o = new byte[parts.Sum(p => p.Length)]; int at = 0; foreach (var p in parts) { p.CopyTo(o, at); at += p.Length; } return o; }
    public static bool SameTail(byte[] a, byte[] b, int count = 512)
    {
        int n = Math.Min(count, Math.Min(a.Length, b.Length));
        return n == 0 || a.AsSpan(a.Length - n).SequenceEqual(b.AsSpan(b.Length - n));
    }
    public static void CheckTags(Dictionary<string, string> read, Dictionary<string, string> desired)
    {
        foreach (var k in Fields)
        {
            if (!desired.TryGetValue(k, out var d) || d.Length == 0) continue;
            var want = k == "year" ? (Engine.YearOf(d) is { Length: > 0 } y ? y : d) : d;
            if (read.GetValueOrDefault(k, "") != want) throw new EngineError($"failed a safety check ({FieldLabels[k].ToLowerInvariant()} didn't read back), so it was left unchanged");
        }
    }

    // MP3 (ID3v2.3 and 2.4)
    public static byte[] Id3Frame(string id, byte[] body, byte ver)
    {
        int n = body.Length;
        byte[] size = ver == 4 ? [(byte)(n >> 21 & 0x7f), (byte)(n >> 14 & 0x7f), (byte)(n >> 7 & 0x7f), (byte)(n & 0x7f)] : U32be(n);
        return Cat(Ascii(id), size, [0, 0], body);
    }
    static byte[] Id3Text(string id, string value, byte ver) => Id3Frame(id, ver == 4 ? Cat([3], Utf8(value)) : Cat([1, 0xff, 0xfe], Utf16le(value)), ver);
    static byte[] Id3Txxx(string desc, string value, byte ver) =>
        Id3Frame("TXXX", ver == 4 ? Cat([3], Utf8(desc), [0], Utf8(value)) : Cat([1, 0xff, 0xfe], Utf16le(desc), [0, 0, 0xff, 0xfe], Utf16le(value)), ver);
    static byte[] Id3Comm(string value, byte ver) =>
        Id3Frame("COMM", ver == 4 ? Cat([3], Ascii("eng"), [0], Utf8(value)) : Cat([1], Ascii("eng"), [0xff, 0xfe, 0, 0, 0xff, 0xfe], Utf16le(value)), ver);
    static (string Desc, string Value)? SplitComm(byte[] body) => body.Length < 5 ? null : TagReader.SplitTxxx([body[0], .. body[4..]]);

    public static Written WriteMp3(byte[] orig, Dictionary<string, string> d, byte[]? art = null)
    {
        var p = TagReader.ParseId3(orig);
        if (p is not null)
        {
            if (p.Ver != 3 && p.Ver != 4) throw new EngineError("uses an older ID3 tag version that can't be edited here");
            if (p.Unsynced) throw new EngineError("uses an ID3 option that can't be edited here");
            if (p.Damaged || p.Truncated) throw new EngineError("has a damaged ID3 tag");
        }
        byte ver = p?.Ver ?? 3;
        var drop = new HashSet<string>();
        if (d.ContainsKey("title")) drop.Add("TIT2");
        if (d.ContainsKey("artist")) drop.Add("TPE1");
        if (d.ContainsKey("albumartist")) drop.Add("TPE2");
        if (d.ContainsKey("album")) drop.Add("TALB");
        if (d.ContainsKey("year")) { drop.Add("TYER"); drop.Add("TDRC"); }
        if (d.ContainsKey("genre")) drop.Add("TCON");
        var kept = new List<byte>();
        foreach (var f in p?.Frames ?? [])
        {
            if (drop.Contains(f.Id)) continue;
            if (d.ContainsKey("producer") && f.Id == "TXXX" && (TagReader.SplitTxxx(f.Body)?.Desc ?? "").ToUpperInvariant() == "PRODUCER") continue;
            if (d.ContainsKey("comment") && f.Id == "COMM" && (SplitComm(f.Body)?.Desc ?? "").Length == 0) continue;
            kept.AddRange(f.Raw);
        }
        var added = new List<byte>();
        if (d.TryGetValue("title", out var v)) added.AddRange(Id3Text("TIT2", v, ver));
        if (d.TryGetValue("artist", out v)) added.AddRange(Id3Text("TPE1", v, ver));
        if (d.TryGetValue("albumartist", out v)) added.AddRange(Id3Text("TPE2", v, ver));
        if (d.TryGetValue("album", out v)) added.AddRange(Id3Text("TALB", v, ver));
        if (d.TryGetValue("year", out v)) added.AddRange(Id3Text(ver == 4 ? "TDRC" : "TYER", v, ver));
        if (d.TryGetValue("producer", out v)) added.AddRange(Id3Txxx("PRODUCER", v, ver));
        if (d.TryGetValue("genre", out v)) added.AddRange(Id3Text("TCON", v, ver));
        if (d.TryGetValue("comment", out v)) added.AddRange(Id3Comm(v, ver));
        if (art is not null) added.AddRange(Id3Frame("APIC", Cat([0], Ascii("image/jpeg"), [0, 3, 0], art), ver)); // front cover, no description
        var frames = Cat(kept.ToArray(), added.ToArray());
        int size = frames.Length + 2048;
        byte[] header = [0x49, 0x44, 0x33, ver, 0, 0, (byte)(size >> 21 & 0x7f), (byte)(size >> 14 & 0x7f), (byte)(size >> 7 & 0x7f), (byte)(size & 0x7f)];
        int start = Math.Min(p?.TagEnd ?? 0, orig.Length);
        var audio = orig[start..];
        if (audio.Length == 0) throw new EngineError("has no audio after its tag");
        return new Written(Cat(header, frames, new byte[2048], audio), audio.Length);
    }
    public static void VerifyMp3(byte[] orig, Written r, Dictionary<string, string> d)
    {
        var p = TagReader.ParseId3(r.Out);
        if (p is null || p.Damaged || p.Truncated) throw new EngineError("failed a safety check (new tag unreadable), so it was left unchanged");
        if (r.Out.Length - p.TagEnd != r.AudioLength || !SameTail(orig, r.Out)) throw new EngineError("failed a safety check (audio mismatch), so it was left unchanged");
        CheckTags(TagReader.TagsFromId3(p), d);
    }

    // FLAC (Vorbis comments)
    public sealed record FlacBlock(byte Type, byte[] Body);
    public static (List<FlacBlock> Blocks, int AudioStart) ParseFlacBlocks(byte[] b)
    {
        if (b.Length < 8 || TagReader.Latin1(b.AsSpan(0, 4)) != "fLaC") throw new EngineError("isn't a valid FLAC file");
        int pos = 4; var blocks = new List<FlacBlock>();
        while (true)
        {
            if (pos + 4 > b.Length || blocks.Count > 512) throw new EngineError("has a damaged FLAC header");
            byte h = b[pos], type = (byte)(h & 0x7f); int len = b[pos + 1] << 16 | b[pos + 2] << 8 | b[pos + 3];
            if (type == 127 || pos + 4 + len > b.Length) throw new EngineError("has a damaged FLAC header");
            blocks.Add(new FlacBlock(type, b[(pos + 4)..(pos + 4 + len)]));
            pos += 4 + len;
            if ((h & 0x80) != 0) break;
        }
        if (blocks[0].Type != 0) throw new EngineError("has a damaged FLAC header");
        return (blocks, pos);
    }
    static (byte[] Vendor, List<string> Comments) ParseVorbisStrict(byte[] b)
    {
        var fail = new EngineError("has a damaged tag block");
        if (b.Length < 8 || TagReader.U32le(b, 0) is not { } vlen || 8 + vlen > b.Length) throw fail;
        var vendor = b[4..(4 + (int)vlen)];
        int p = 4 + (int)vlen;
        if (TagReader.U32le(b, p) is not { } n) throw fail;
        p += 4;
        var comments = new List<string>();
        for (long i = 0; i < n; i++)
        {
            if (p + 4 > b.Length || TagReader.U32le(b, p) is not { } len) throw fail;
            p += 4;
            if (p + len > b.Length) throw fail;
            comments.Add(TagReader.Utf8(b.AsSpan(p, (int)len))); p += (int)len;
        }
        return (vendor, comments);
    }
    static readonly Dictionary<string, string[]> VorbisReadKeys = new()
    {
        ["title"] = ["TITLE"], ["artist"] = ["ARTIST"], ["albumartist"] = ["ALBUMARTIST", "ALBUM ARTIST"], ["album"] = ["ALBUM"],
        ["year"] = ["DATE", "YEAR"], ["producer"] = ["PRODUCER"], ["genre"] = ["GENRE"], ["comment"] = ["COMMENT"],
    };
    static readonly Dictionary<string, string> VorbisWriteKey = new()
    {
        ["title"] = "TITLE", ["artist"] = "ARTIST", ["albumartist"] = "ALBUMARTIST", ["album"] = "ALBUM", ["year"] = "DATE",
        ["producer"] = "PRODUCER", ["genre"] = "GENRE", ["comment"] = "COMMENT",
    };

    public static Written WriteFlac(byte[] orig, Dictionary<string, string> d, (byte[] Jpeg, int Width, int Height)? art = null)
    {
        var (blocks, audioStart) = ParseFlacBlocks(orig);
        int ci = blocks.FindIndex(x => x.Type == 4);
        var vendor = Utf8("Juice WRLD collection tracker"); var comments = new List<string>();
        if (ci >= 0) (vendor, comments) = ParseVorbisStrict(blocks[ci].Body);
        var drop = new HashSet<string>();
        foreach (var k in Fields) if (d.ContainsKey(k)) foreach (var x in VorbisReadKeys[k]) drop.Add(x);
        comments = comments.Where(c => !drop.Contains((c.IndexOf('=') is var eq and >= 0 ? c[..eq] : c).ToUpperInvariant())).ToList();
        foreach (var k in Fields) if (d.TryGetValue(k, out var v)) comments.Add($"{VorbisWriteKey[k]}={v}");
        var body = new List<byte>(); body.AddRange(U32le(vendor.Length)); body.AddRange(vendor); body.AddRange(U32le(comments.Count));
        foreach (var c in comments) { var e = Utf8(c); body.AddRange(U32le(e.Length)); body.AddRange(e); }
        var output = blocks.Where(x => x.Type != 4).ToList();
        int insertAt = 1;
        if (ci >= 0) insertAt = Math.Max(1, blocks.Take(ci).Count(x => x.Type != 4));
        output.Insert(Math.Min(insertAt, output.Count), new FlacBlock(4, body.ToArray()));
        if (art is { } a) // a front cover PICTURE block, right after the comments
        {
            var mime = Ascii("image/jpeg");
            var pic = Cat(U32be(3), U32be(mime.Length), mime, U32be(0), U32be(a.Width), U32be(a.Height), U32be(24), U32be(0), U32be(a.Jpeg.Length), a.Jpeg);
            output.Insert(Math.Min(insertAt + 1, output.Count), new FlacBlock(6, pic));
        }
        if (!output.Any(x => x.Type == 1)) output.Add(new FlacBlock(1, new byte[1024]));
        var pieces = new List<byte>(Ascii("fLaC"));
        for (int i = 0; i < output.Count; i++)
        {
            var bl = output[i]; int len = bl.Body.Length;
            if (len >= 1 << 24) throw new EngineError("has a tag block that's too large to edit");
            pieces.AddRange([(byte)((i == output.Count - 1 ? 0x80 : 0) | bl.Type), (byte)(len >> 16 & 255), (byte)(len >> 8 & 255), (byte)(len & 255)]);
            pieces.AddRange(bl.Body);
        }
        var audio = orig[audioStart..];
        if (audio.Length == 0) throw new EngineError("has no audio after its header");
        return new Written(Cat(pieces.ToArray(), audio), audio.Length);
    }
    public static void VerifyFlac(byte[] orig, Written r, Dictionary<string, string> d)
    {
        (List<FlacBlock> Blocks, int AudioStart) parsed;
        try { parsed = ParseFlacBlocks(r.Out); } catch (EngineError) { throw new EngineError("failed a safety check (new header unreadable), so it was left unchanged"); }
        if (r.Out.Length - parsed.AudioStart != r.AudioLength || !SameTail(orig, r.Out)) throw new EngineError("failed a safety check (audio mismatch), so it was left unchanged");
        var c = parsed.Blocks.FirstOrDefault(x => x.Type == 4);
        CheckTags(c is null ? [] : TagReader.ParseVorbisComments(c.Body), d);
    }

    // M4A (the iTunes tag list in moov/udta/meta/ilst)
    public sealed record Atom(string Type, int Start, int Hdr, int End);
    /// The boxes between start and end, strictly. A few stray trailing bytes (QuickTime's terminator) are ignored.
    public static List<Atom> ReadAtoms(byte[] b, int start, int end)
    {
        var output = new List<Atom>(); int p = start;
        while (p + 8 <= end)
        {
            long size = TagReader.U32(b, p); int hdr = 8;
            var type = TagReader.Latin1(b.AsSpan(p + 4, 4));
            if (size == 1)
            {
                if (p + 16 > end) throw new EngineError("has a damaged MP4 header");
                size = TagReader.U32(b, p + 8) * 4294967296L + TagReader.U32(b, p + 12); hdr = 16;
            }
            else if (size == 0) size = end - p;
            if (size < hdr || p + size > end) throw new EngineError("has a damaged MP4 header");
            output.Add(new Atom(type, p, hdr, p + (int)size));
            p += (int)size;
        }
        return output;
    }
    static byte[] Mp4Box(string type, params byte[][] parts)
    {
        var body = Cat(parts); long n = body.Length + 8L;
        if (n > 0xffffffffL) throw new EngineError("has a tag block that's too large to edit");
        return Cat(U32be(n), Ascii(type), body);
    }
    static readonly byte[] Mp4TextFlags = [0, 0, 0, 1, 0, 0, 0, 0];
    static readonly (string Field, string Key)[] Mp4Keys =
        [("title", "©nam"), ("artist", "©ART"), ("albumartist", "aART"), ("album", "©alb"), ("year", "©day"), ("genre", "©gen"), ("comment", "©cmt")];
    static string FreeformName(byte[] b, Atom item)
    {
        foreach (var c in ReadAtoms(b, item.Start + item.Hdr, item.End)) if (c.Type == "name") return TagReader.Utf8(TagReader.Sub(b, c.Start + c.Hdr + 4, c.End));
        return "";
    }
    static readonly HashSet<string> Mp4Containers = ["moov", "trak", "mdia", "minf", "stbl"];
    /// Every chunk offset table (stco or co64) in the boxes between s and e: where its entries start, how many, how wide.
    static List<(int P, long N, bool Wide)> StcoTables(byte[] b, int s, int e)
    {
        var output = new List<(int, long, bool)>();
        foreach (var a in ReadAtoms(b, s, e))
        {
            if (Mp4Containers.Contains(a.Type)) output.AddRange(StcoTables(b, a.Start + a.Hdr, a.End));
            else if (a.Type is "stco" or "co64")
            {
                int p = a.Start + a.Hdr; bool wide = a.Type == "co64";
                if (p + 8 > a.End) throw new EngineError("has a damaged MP4 header");
                long n = TagReader.U32(b, p + 4);
                if (p + 8 + n * (wide ? 8 : 4) > a.End) throw new EngineError("has a damaged MP4 header");
                output.Add((p + 8, n, wide));
            }
        }
        return output;
    }
    static long U64(byte[] b, int p) => TagReader.U32(b, p) * 4294967296L + TagReader.U32(b, p + 4);
    static List<long> ChunkOffsets(byte[] b, int s, int e) =>
        StcoTables(b, s, e).SelectMany(t => Enumerable.Range(0, (int)t.N).Select(k => t.Wide ? U64(b, t.P + k * 8) : TagReader.U32(b, t.P + k * 4))).ToList();

    public static Written WriteM4a(byte[] orig, Dictionary<string, string> d, byte[]? art = null)
    {
        var top = ReadAtoms(orig, 0, orig.Length);
        if (top.FirstOrDefault()?.Type != "ftyp") throw new EngineError("isn't a valid M4A file");
        if (top.Any(a => a.Type == "moof")) throw new EngineError("is a fragmented MP4, which can't be edited here");
        var moovs = top.Where(a => a.Type == "moov").ToList();
        if (moovs.Count != 1) throw new EngineError("has a damaged MP4 header");
        if (!top.Any(a => a.Type == "mdat")) throw new EngineError("has no audio after its header");
        var moov = moovs[0];
        byte[] Raw(Atom a) => orig[a.Start..a.End];

        var kids = ReadAtoms(orig, moov.Start + moov.Hdr, moov.End);
        var udta = kids.FirstOrDefault(a => a.Type == "udta");
        var udtaKids = udta is null ? [] : ReadAtoms(orig, udta.Start + udta.Hdr, udta.End);
        var meta = udtaKids.FirstOrDefault(a => a.Type == "meta");
        if (meta is null && kids.Any(a => a.Type == "meta")) throw new EngineError("uses an MP4 tag layout that can't be edited here");
        var metaKids = new List<Atom>(); byte[] metaPrefix = [0, 0, 0, 0];
        if (meta is not null)
        {
            int s = meta.Start + meta.Hdr, cs = TagReader.Latin1(TagReader.Sub(orig, s + 4, s + 8)) == "hdlr" ? s : s + 4;
            metaPrefix = orig[s..cs];
            metaKids = ReadAtoms(orig, cs, meta.End);
        }
        var ilst = metaKids.FirstOrDefault(a => a.Type == "ilst");
        var drop = new HashSet<string>();
        foreach (var (k, key) in Mp4Keys) if (d.ContainsKey(k)) drop.Add(key);
        if (d.ContainsKey("genre")) drop.Add("gnre");
        var items = ilst is null ? [] : ReadAtoms(orig, ilst.Start + ilst.Hdr, ilst.End);
        var kept = new List<byte>();
        foreach (var it in items)
        {
            if (drop.Contains(it.Type)) continue;
            if (d.ContainsKey("producer") && it.Type == "----" && FreeformName(orig, it).ToUpperInvariant() == "PRODUCER") continue;
            kept.AddRange(Raw(it));
        }
        var added = new List<byte>();
        foreach (var (k, key) in Mp4Keys) if (d.TryGetValue(k, out var v)) added.AddRange(Mp4Box(key, Mp4Box("data", Mp4TextFlags, Utf8(v))));
        if (d.TryGetValue("producer", out var pv))
            added.AddRange(Mp4Box("----", Mp4Box("mean", [0, 0, 0, 0], Ascii("com.apple.iTunes")), Mp4Box("name", [0, 0, 0, 0], Utf8("PRODUCER")), Mp4Box("data", Mp4TextFlags, Utf8(pv))));
        if (art is not null) added.AddRange(Mp4Box("covr", Mp4Box("data", [0, 0, 0, 13, 0, 0, 0, 0], art))); // 13: JPEG
        var newIlst = Mp4Box("ilst", kept.ToArray(), added.ToArray());
        var hdlr = metaKids.FirstOrDefault(a => a.Type == "hdlr");
        var hdlrBytes = hdlr is not null ? Raw(hdlr) : Mp4Box("hdlr", new byte[8], Ascii("mdirappl"), new byte[9]);
        var newMeta = Mp4Box("meta", metaPrefix, hdlrBytes, newIlst, metaKids.Where(a => a.Type is not "hdlr" and not "ilst").SelectMany(Raw).ToArray());
        var udtaParts = udtaKids.SelectMany(a => meta is not null && a.Start == meta.Start ? newMeta : Raw(a)).ToList();
        if (meta is null) udtaParts.AddRange(newMeta);
        var newUdta = Mp4Box("udta", udtaParts.ToArray());
        var moovParts = kids.SelectMany(a => udta is not null && a.Start == udta.Start ? newUdta : Raw(a)).ToList();
        if (udta is null) moovParts.AddRange(newUdta);
        var newMoov = Mp4Box("moov", moovParts.ToArray());

        long delta = newMoov.Length - (moov.End - moov.Start);
        if (delta != 0)
        {
            foreach (var t in StcoTables(newMoov, 0, newMoov.Length))
                for (int k = 0; k < t.N; k++)
                {
                    if (t.Wide)
                    {
                        int at = t.P + k * 8; long v = U64(newMoov, at);
                        if (v > moov.Start) { long nv = v + delta; for (int i = 0; i < 8; i++) newMoov[at + i] = (byte)(nv >> (56 - 8 * i) & 255); }
                    }
                    else
                    {
                        int at = t.P + k * 4; long v = TagReader.U32(newMoov, at);
                        if (v > moov.Start)
                        {
                            long nv = v + delta;
                            if (nv > 0xffffffffL || nv < 0) throw new EngineError("would need 64-bit audio offsets, which can't be edited here");
                            U32be(nv).CopyTo(newMoov, at);
                        }
                    }
                }
        }
        return new Written(Cat(orig[..moov.Start], newMoov, orig[moov.End..]), 0, delta, moov.Start, moov.End);
    }
    public static void VerifyM4a(byte[] orig, Written r, Dictionary<string, string> d)
    {
        EngineError Fail(string why) => new($"failed a safety check ({why}), so it was left unchanged");
        Atom? moov;
        try { moov = ReadAtoms(r.Out, 0, r.Out.Length).FirstOrDefault(a => a.Type == "moov"); } catch (EngineError) { moov = null; }
        if (moov is null) throw Fail("new header unreadable");
        if (moov.Start != r.MoovStart || r.Out.Length != orig.Length + r.Delta || moov.End - moov.Start != r.OldMoovEnd - r.MoovStart + r.Delta) throw Fail("layout changed");
        static bool SameRange(byte[] a, int ast, byte[] b, int bst, int n) => ast + n <= a.Length && bst + n <= b.Length && a.AsSpan(ast, n).SequenceEqual(b.AsSpan(bst, n));
        if (!SameRange(orig, 0, r.Out, 0, r.MoovStart) || !SameRange(orig, r.OldMoovEnd, r.Out, moov.End, orig.Length - r.OldMoovEnd)) throw Fail("audio mismatch");
        List<long> before, after;
        try { before = ChunkOffsets(orig, r.MoovStart, r.OldMoovEnd); after = ChunkOffsets(r.Out, moov.Start, moov.End); }
        catch (EngineError) { throw Fail("audio offsets unreadable"); }
        if (before.Count == 0 || before.Count != after.Count || before.Zip(after).Any(x => x.Second != (x.First > r.MoovStart ? x.First + r.Delta : x.First))) throw Fail("audio offsets");
        CheckTags(TagReader.ParseMoov(r.Out[(moov.Start + moov.Hdr)..moov.End]), d);
    }
}
