namespace JuiceTracker;

// Cover art: whether a file has a picture, and adding the song's picture to one that has none (the Mac app's
// TagReader.hasArt and TagWriter.addArt).

public static partial class Engine { }

public static class CoverArt
{
    /// Whether a file already has cover art (an ID3 picture, an MP4 "covr" item, or a FLAC PICTURE block).
    public static bool HasArt(byte[] b, string ext)
    {
        switch (ext)
        {
            case "flac":
                try { return TagWriter.ParseFlacBlocks(b).Blocks.Any(x => x.Type == 6); } catch (EngineError) { return false; }
            case "m4a" or "m4b" or "alac":
                List<TagWriter.Atom> top;
                try { top = TagWriter.ReadAtoms(b, 0, b.Length); } catch (EngineError) { return false; }
                if (top.FirstOrDefault(a => a.Type == "moov") is not { } moov) return false;
                bool found = false;
                void Walk(int s, int e) => TagReader.WalkAtoms(b, s, e, (type, s2, e2) =>
                {
                    if (type == "covr") found = true;
                    else if (type is "udta" or "ilst") Walk(s2, e2);
                    else if (type == "meta") Walk(TagReader.Latin1(TagReader.Sub(b, s2 + 4, s2 + 8)) == "hdlr" ? s2 : s2 + 4, e2);
                });
                Walk(moov.Start + moov.Hdr, moov.End);
                return found;
            default:
                return TagReader.ParseId3(b)?.Frames.Any(f => f.Id is "APIC" or "PIC") ?? false;
        }
    }

    /// The same for a file on disk, reading only the tag (an MP3's ID3 tag, an M4A's moov box, a FLAC's header).
    public static bool HasArt(string file, string ext)
    {
        try
        {
            using var f = new TagReader.Reader(file);
            switch (ext)
            {
                case "flac":
                    if (TagReader.Latin1(f.Bytes(0, 4)) != "fLaC") return false;
                    long pos = 4;
                    for (int n = 0; n < 64; n++)
                    {
                        var h = f.Bytes(pos, pos + 4);
                        if (h.Length < 4) break;
                        if ((h[0] & 0x7f) == 6) return true;
                        pos += 4 + (h[1] << 16 | h[2] << 8 | h[3]);
                        if ((h[0] & 0x80) != 0) break;
                    }
                    return false;
                case "m4a" or "m4b" or "alac":
                    return HasArt(f.Bytes(0, Math.Min(f.Size, 64L * 1024 * 1024)), ext); // shortcut: songs with the moov after 64 MB of audio aren't checked
                default:
                    var hd = f.Bytes(0, 10);
                    if (hd.Length < 10 || TagReader.Latin1(hd.AsSpan(0, 3)) != "ID3") return false;
                    return HasArt(f.Bytes(0, 10 + Math.Min(TagReader.Synchsafe(hd, 6), 64 * 1024 * 1024)), ext); // the whole tag, even with big art
            }
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    /// Adds a front cover (JPEG) to a file that has none, leaving its tags and audio as they are. Runs the same safety
    /// check as a tag write, and checks the picture reads back.
    public static byte[] AddArt(byte[] orig, string ext, byte[] jpeg, int width, int height)
    {
        if (HasArt(orig, ext)) throw new EngineError("already has cover art");
        var none = new Dictionary<string, string>();
        TagWriter.Written r;
        switch (ext)
        {
            case "mp3": r = TagWriter.WriteMp3(orig, none, jpeg); TagWriter.VerifyMp3(orig, r, none); break;
            case "flac": r = TagWriter.WriteFlac(orig, none, (jpeg, width, height)); TagWriter.VerifyFlac(orig, r, none); break;
            case "m4a": r = TagWriter.WriteM4a(orig, none, jpeg); TagWriter.VerifyM4a(orig, r, none); break;
            default: throw new EngineError("can't get cover art here (only MP3, FLAC and M4A)");
        }
        if (!HasArt(r.Out, ext)) throw new EngineError("failed a safety check (the picture didn't read back), so it was left unchanged");
        return r.Out;
    }
}
