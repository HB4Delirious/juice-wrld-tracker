// Tests for the pure logic in web/juice-tracker.html (the <script id="core"> block).
// Run: node --test tests/
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const html = readFileSync(new URL("../web/juice-tracker.html", import.meta.url), "utf8");
const core = /<script id="core">([\s\S]*?)<\/script>/.exec(html);
assert.ok(core, 'web/juice-tracker.html has no <script id="core"> block');
const ctx = vm.createContext({ TextEncoder, TextDecoder, console });
vm.runInContext(core[1], ctx);
// Top-level const/function names live in the context's global scope.
const g = name => vm.runInContext(name, ctx);
const { normalize, stemOf, matchLibrary, deriveTemplate, backupFile, FIELDS } = Object.fromEntries(
  ["normalize", "stemOf", "matchLibrary", "deriveTemplate", "backupFile", "FIELDS"].map(n => [n, g(n)]));

const enc = new TextEncoder();
const cat = (...parts) => { const n = parts.reduce((a, p) => a + p.length, 0), out = new Uint8Array(n); let o = 0; for (const p of parts) { out.set(p, o); o += p.length; } return out; };
const u32be = n => Uint8Array.of(n >>> 24, (n >> 16) & 255, (n >> 8) & 255, n & 255);
const box = (type, ...parts) => { const body = cat(...parts); return cat(u32be(body.length + 8), enc.encode(type), body); };
const sameBytes = (a, b, msg) => assert.ok(Buffer.from(a).equals(Buffer.from(b)), msg || "bytes differ"); // works across vm contexts
const audio = n => Uint8Array.from({ length: n }, (_, i) => (i * 37 + 11) & 255);

const tags = { title: "Lucid Dreams", artist: "Juice WRLD", albumartist: "Juice WRLD", album: "Goodbye & Good Riddance", year: "2018", producer: "Nick Mira", genre: "Hip-Hop/Rap", comment: "Released" };
const retag = { ...tags, title: "Lucid Dreams (Forget Me)", producer: "Nick Mira, DT" };

/** Writes, runs the app's own safety check, and returns the new file. */
function writeAndVerify(ext, orig, desired) {
  const [write, verify] = g("WRITERS_FOR_TESTS")[ext];
  const res = write(orig, desired);
  verify(orig, res, desired); // throws if audio bytes, layout or tags don't check out
  return res.out;
}
vm.runInContext("var WRITERS_FOR_TESTS = { mp3: [writeMp3, verifyMp3], flac: [writeFlac, verifyFlac], m4a: [writeM4a, verifyM4a] };", ctx);

test("titles match exactly, ignoring bracketed extras, by near misses, and not at all", () => {
  const catalog = [
    { id: 1, name: "Lucid Dreams", alt: ["Forget Me"] },
    { id: 2, name: "Robbery", alt: [] },
    { id: 3, name: "All Girls Are The Same", alt: [] },
  ];
  const file = (title, path = `Juice WRLD/${title}.mp3`) => ({ path, title, key: normalize(title), stem: stemOf(path) });
  const files = [file("Robbery"), file("Lucid Dreams (feat. Someone)"), file("Forget Me"), file("All Girls Are The Sam"), file("Some Other Song")];
  const { owned, unmatched } = matchLibrary(catalog, files, {});
  assert.deepEqual(files.map(f => [...f.songs]), [[1], [0], [0], [2], []]);
  assert.equal(files[3].fuzzy, true, "a near miss is flagged as fuzzy");
  assert.equal(files[0].fuzzy, false);
  assert.deepEqual([...owned.keys()].sort(), [0, 1, 2]);
  assert.deepEqual([...unmatched].map(f => f.title), ["Some Other Song"]);
  // A manual match wins, and "none" un-matches.
  matchLibrary(catalog, files, { [files[4].path]: 3, [files[0].path]: "none" }); // overrides store the catalog id; id 3 is position 2
  assert.deepEqual([...files[4].songs], [2]);
  assert.deepEqual([...files[0].songs], []);
});

test("MP3: writes tags, keeps the audio bytes, and re-tags an already tagged file", () => {
  const sound = audio(4000);
  const once = writeAndVerify("mp3", cat(Uint8Array.of(0xff, 0xfb), sound), tags);
  const twice = writeAndVerify("mp3", once, retag);
  sameBytes(twice.subarray(twice.length - sound.length), sound, "audio bytes unchanged");
  const read = g("tagsFromId3")(g("parseId3")(twice));
  for (const k of FIELDS) assert.equal(read[k], retag[k], k);
});

test("FLAC: writes tags, keeps the audio bytes, and re-tags an already tagged file", () => {
  const sound = audio(4000);
  const streaminfo = cat(Uint8Array.of(0x80, 0, 0, 34), new Uint8Array(34)); // last metadata block, STREAMINFO
  const once = writeAndVerify("flac", cat(enc.encode("fLaC"), streaminfo, sound), tags);
  const twice = writeAndVerify("flac", once, retag);
  sameBytes(twice.subarray(twice.length - sound.length), sound, "audio bytes unchanged");
});

test("M4A: writes tags before the audio and shifts the audio offsets to match", () => {
  const sound = audio(4000);
  const ftyp = box("ftyp", enc.encode("M4A "), new Uint8Array(4), enc.encode("M4A mp42isom"));
  const moovFor = offset => box("moov", box("mvhd", new Uint8Array(100)),
    box("trak", box("mdia", box("minf", box("stbl", box("stco", new Uint8Array(4), u32be(1), u32be(offset)))))));
  const moovLen = moovFor(0).length;
  const orig = cat(ftyp, moovFor(ftyp.length + moovLen + 8), box("mdat", sound));
  const once = writeAndVerify("m4a", orig, tags); // verify also checks every chunk offset moved by the size change
  const twice = writeAndVerify("m4a", once, retag);
  sameBytes(twice.subarray(twice.length - sound.length), sound, "audio bytes unchanged");
});

test("the song-link setting only accepts web addresses", () => {
  assert.throws(() => deriveTemplate("javascript:alert(1)//{id}", []));
  assert.throws(() => deriveTemplate("htps://juicewrldapi.com/player?song={id}", []));
  assert.equal(deriveTemplate("https://juicewrldapi.com/player?song={id}", []), "https://juicewrldapi.com/player?song={id}");
  assert.equal(deriveTemplate("https://juicewrldapi.com/player?song=96383", [{ id: 96383, name: "Lucid Dreams" }]), "https://juicewrldapi.com/player?song={id}");
});

test("a backup left empty by a failed attempt is written again, and a good one is kept", async () => {
  // Minimal in-memory folder handle, like the File System Access API (and bridge.js) provide.
  const dir = (entries = new Map()) => ({
    entries,
    async getDirectoryHandle(name, { create } = {}) {
      if (!entries.has(name)) { if (!create) throw new Error("NotFound"); entries.set(name, dir()); }
      return entries.get(name);
    },
    async getFileHandle(name, { create } = {}) {
      if (!entries.has(name)) { if (!create) throw new Error("NotFound"); entries.set(name, { data: new Uint8Array(0) }); }
      const node = entries.get(name);
      return {
        getFile: async () => ({ size: node.data.length }),
        createWritable: async () => { let buf; return { write: async d => { buf = d; }, close: async () => { node.data = buf; } }; },
      };
    },
  });
  const root = dir(), original = audio(5000);
  const album = await root.getDirectoryHandle("Juice WRLD", { create: true });
  await album.getFileHandle("Lucid Dreams.mp3", { create: true }); // empty file from an attempt that failed mid-write
  await backupFile(root, "Music/Juice WRLD/Lucid Dreams.mp3", original);
  assert.equal(album.entries.get("Lucid Dreams.mp3").data.length, original.length, "the empty backup was replaced");
  await backupFile(root, "Music/Juice WRLD/Lucid Dreams.mp3", audio(10)); // a later edit must not replace the first good backup
  assert.equal(album.entries.get("Lucid Dreams.mp3").data.length, original.length, "the first good backup was kept");
});

test("ID3 tags are found whether the title comes before or after big cover art", async () => {
  const id3Frame = g("id3Frame"), id3Text = g("id3Text"), readTags = g("readTags");
  const art = id3Frame("APIC", new Uint8Array(300 * 1024).fill(7), 3); // bigger than the 256 KB first read
  const mp3 = (...frames) => {
    const body = cat(...frames, new Uint8Array(64)), n = body.length;
    return cat(Uint8Array.of(0x49, 0x44, 0x33, 3, 0, 0, (n >> 21) & 127, (n >> 14) & 127, (n >> 7) & 127, n & 127), body, audio(2000));
  };
  const titleAfterArt = await readTags(new Blob([mp3(art, id3Text("TIT2", "After The Art", 3))]), "mp3");
  assert.equal(titleAfterArt.title, "After The Art");
  const titleFirst = await readTags(new Blob([mp3(id3Text("TIT2", "Before The Art", 3), art)]), "mp3");
  assert.equal(titleFirst.title, "Before The Art");
});

test("duplicate cleanup keeps the best copy and never treats a different version as a copy", () => {
  const extraCopies = g("extraCopies"), isExactDuplicate = g("isExactDuplicate");
  const file = (path, ext, size, title = "Lucid Dreams") => ({ path, ext, size, title, handle: { _path: `/m/${path}` } });
  const flac = file("a/Lucid Dreams.flac", "flac", 30e6), bigMp3 = file("b/Lucid Dreams.mp3", "mp3", 9e6), smallMp3 = file("c/lucid dreams.mp3", "mp3", 4e6);
  const group = { files: [smallMp3, flac, bigMp3] };
  assert.ok(isExactDuplicate(group));
  assert.deepEqual([...extraCopies([group])].map(f => f.path).sort(), [bigMp3.path, smallMp3.path], "the FLAC is kept");
  // A file listed under two songs is removed once, and a file kept in any group is never removed.
  assert.deepEqual([...extraCopies([group, { files: [bigMp3, file("d/x.mp3", "mp3", 1e6)] }])].map(f => f.path).sort(),
    ["c/lucid dreams.mp3", "d/x.mp3"]);
  assert.ok(!isExactDuplicate({ files: [flac, file("e/Lucid Dreams (v2).mp3", "mp3", 5e6, "Lucid Dreams (v2)")] }), "a v2 is not a copy");
});

test("recording months and song lengths are read from the catalog's text", () => {
  const recordMonth = g("recordMonth"), lengthSeconds = g("lengthSeconds");
  assert.equal(recordMonth("Recorded\nAugust 2, 2015."), 2015 * 12 + 7);
  assert.equal(recordMonth("Recorded\r\nOctober 25, 2015.\nFile Exported\nNovember 12, 2015."), 2015 * 12 + 9, "the first date wins");
  assert.equal(recordMonth("Sept. 2018"), 2018 * 12 + 8);
  assert.equal(recordMonth("2019-03-14"), 2019 * 12 + 2);
  assert.equal(recordMonth("2018"), null, "a year alone has no month");
  assert.equal(recordMonth(""), null);
  assert.equal(lengthSeconds("4:26"), 266);
  assert.equal(lengthSeconds("1:02:03"), 3723);
  assert.equal(lengthSeconds("N/A"), null);
});

test("dates, the site's bitrates, and snapshot CSV files are read correctly", () => {
  const datesIn = g("datesIn"), siteKbps = g("siteKbps"), parseCsv = g("parseCsv"), csvLike = rows => [...rows].map(r => [...r]);
  assert.deepEqual([...datesIn("Recorded\nJune 13, 2017.\nUzi's Vocals\nMay 16th, 2018.")].map(x => ({ ...x })),
    [{ y: 2017, m: 5, d: 13 }, { y: 2018, m: 4, d: 16 }]);
  assert.equal(datesIn("2018").length, 0);
  assert.equal(siteKbps("Original Files\n2117kbps (.wav)\n320kpbs (.mp3)", "mp3"), 320, "typo 'kpbs' still counts");
  assert.equal(siteKbps("Original File\n192kbps (.mp3)", "flac"), 0);
  assert.equal(siteKbps("", "mp3"), 0);
  const rows = parseCsv('﻿"path","song_ids"\r\n"a, b.mp3","1 2"\r\n"say ""hi""\nthere","3"');
  assert.deepEqual(csvLike(rows), [["path", "song_ids"], ["a, b.mp3", "1 2"], ['say "hi"\nthere', "3"]]);
});
