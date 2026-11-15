// Writes test inputs plus the page's own answers for them, so tests/EngineTests.swift can check that the Swift
// engine gives the same answers. Run: node tests/engine-fixtures.mjs <dir>   (see scripts/test-engine.sh)
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import vm from "node:vm";

const dir = process.argv[2];
if (!dir) throw new Error("usage: node tests/engine-fixtures.mjs <dir>");
mkdirSync(join(dir, "files"), { recursive: true });

const html = readFileSync(new URL("../web/juice-tracker.html", import.meta.url), "utf8");
const ctx = vm.createContext({ TextEncoder, TextDecoder, console, Blob, Uint8Array, DataView });
vm.runInContext(/<script id="core">([\s\S]*?)<\/script>/.exec(html)[1], ctx);
const g = name => vm.runInContext(name, ctx);
const plain = v => JSON.parse(JSON.stringify(v)); // out of the vm's realm

const enc = new TextEncoder();
const cat = (...parts) => { const n = parts.reduce((a, p) => a + p.length, 0), out = new Uint8Array(n); let o = 0; for (const p of parts) { out.set(p, o); o += p.length; } return out; };
const u32be = n => Uint8Array.of(n >>> 24, (n >> 16) & 255, (n >> 8) & 255, n & 255);
const u32le = n => Uint8Array.of(n & 255, (n >> 8) & 255, (n >> 16) & 255, n >>> 24);
const latin = s => Uint8Array.from(s, c => c.charCodeAt(0) & 255);
const box = (type, ...parts) => { const body = cat(...parts); return cat(u32be(body.length + 8), latin(type), body); };
const audio = n => Uint8Array.from({ length: n }, (_, i) => (i * 37 + 11) & 255);
const utf16le = s => { const o = new Uint8Array(s.length * 2); for (let i = 0; i < s.length; i++) { o[2 * i] = s.charCodeAt(i) & 255; o[2 * i + 1] = s.charCodeAt(i) >> 8; } return o; };
const synch = n => Uint8Array.of((n >> 21) & 127, (n >> 14) & 127, (n >> 7) & 127, n & 127);

const tags = { title: "Lucid Dreams", artist: "Juice WRLD", albumartist: "Juice WRLD", album: "Goodbye & Good Riddance", year: "2018", producer: "Nick Mira", genre: "Hip-Hop/Rap", comment: "Released" };

// ---- text helpers
const titles = ["Lucid Dreams", "Lucid Dreams (Forget Me)", "Lucid Dreams [v2] {snippet}", "All Girls Are The Same (Remix) [feat. G Herbo]",
  "Robbery feat. Someone", "Wishing Well ft. X", "Prod. by Nick Mira", "Café Déjà Vu", "Rich & Blind", "  Spaced   Out  ", "999", "(only brackets)",
  "!!!", "", "Ｆｕｌｌｗｉｄｔｈ Ｔｅｘｔ", "Naïve — Dash – Test", "feat. at start", "Hello, World! (v1) - Remastered", "ÆON flux ß", "Tab\tSeparated"];
const paths = ["Juice WRLD/Lucid Dreams.m4a", "Music/02 - Juice WRLD - Robbery.mp3", "a/b/01. Wishing Well.FLAC", "x/123 Song.mp3", "x/1234 Song.mp3",
  "noext", "dir.with.dots/file", "x/Some - Thing - Else.wav", "x\\back\\slash.mp3", "x/JUICE wrld/song.ogg", "x/.hidden.mp3"];
const text = {
  normalize: titles.map(t => [t, g("normalize")(t)]),
  hasValue: ["N/A", "n/a", "na", "none", "Unknown", "TBA", "--", "???", " x ", "", "null", "0"].map(v => [v, g("hasValue")(v)]),
  yearOf: ["Recorded in 2018.", "1999", "21000", "x2015x", "abc", "May 2, 2019 - 2020"].map(v => [v, g("yearOf")(v)]),
  hasArtist: ["Juice WRLD", "juice-wrld", "JUICEWRLD feat", "Juice World", "x/Juice_WRLD/y"].map(v => [v, g("hasArtist")(v)]),
  extOf: paths.map(p => [p, g("extOf")(p)]),
  stemOf: paths.map(p => [p, g("stemOf")(p)]),
  titleFromFilename: paths.map(p => [p, g("titleFromFilename")(p)]),
  similarity: [["lucid dreams", "lucid dream"], ["", ""], ["a", ""], ["robbery", "robery"], ["abc", "xyz"], ["wishing well", "wishing wells"]]
    .map(([a, b]) => [a, b, g("similarity")(a, b)]),
};

// ---- catalog cleaning
const raw = [
  { id: 1, name: "Lucid Dreams", alt_titles: "Lucid Dreams (Forget Me); lucid dreams|Forget Me\nForget me", era: { name: "GB&GR", description: "Goodbye", time_frame: "2018" },
    category: "released", length: "3:59", release_date: "May 2018", credited_artists: ["Juice WRLD", null, ""], producers: "Nick Mira", record_dates: null,
    engineers: "Max Lord", path: "Juice WRLD/Lucid Dreams.mp3", bitrate: 320 },
  { public_id: "abc", name: "", era: "", category: null, track_titles: ["A", "a", "B", 0], notes: ["x", "y"], date_leaked: "2020", leak_type: "Full" },
  { id: 3, name: "Robbery", era: { name: "DRFL" }, category: "released", filePath: "Robbery.mp3", hasDetails: true, alt: null, release: ["2019", "02"] },
  { id: 4, name: "Wishing Well", era: { description: "no name" }, path: "nopath", key: "C#", original_key: "D", info: " spaced ", session_titles: ["S1", "S2"], dates: "x" },
  { id: 3, name: "Robbery (dup id, later)", era: "DRFL", category: "unreleased" },
];
const catalog = {
  raw,
  cleaned: plain(raw.map(r => g("cleanSong")(r))),
  merged: plain(g("mergeSongs")([raw])),
  eras: plain(g("collectEras")(raw)),
};

// ---- tags: files built by the page's own writers and by hand
const files = [];
const addFile = async (name, bytes) => {
  writeFileSync(join(dir, "files", name), bytes);
  const ext = g("extOf")(name);
  files.push({ name, ext, tags: plain(await g("readTags")(new Blob([bytes]), ext)) });
};
const mp3 = g("writeMp3")(cat(Uint8Array.of(0xff, 0xfb), audio(2000)), tags).out;
await addFile("written.mp3", mp3);
const flacOrig = cat(enc.encode("fLaC"), Uint8Array.of(0x80, 0, 0, 34), new Uint8Array(34), audio(2000));
await addFile("written.flac", g("writeFlac")(flacOrig, tags).out);
const ftyp = box("ftyp", enc.encode("M4A "), new Uint8Array(4), enc.encode("M4A mp42isom"));
const moovFor = off => box("moov", box("mvhd", new Uint8Array(100)), box("trak", box("mdia", box("minf", box("stbl", box("stco", new Uint8Array(4), u32be(1), u32be(off)))))));
const m4aOrig = cat(ftyp, moovFor(ftyp.length + moovFor(0).length + 8), box("mdat", audio(2000)));
await addFile("written.m4a", g("writeM4a")(m4aOrig, tags).out);
// ID3v2.3 with UTF-16 text, a producer TXXX, a COMM, then unsynchronised
const frame3 = (id, body) => cat(latin(id), u32be(body.length), Uint8Array.of(0, 0), body);
const v23body = cat(
  frame3("TIT2", cat(Uint8Array.of(1, 0xff, 0xfe), utf16le("Wishing Well\u0000"))),
  frame3("TPE1", cat(Uint8Array.of(0), latin("Juice WRLD"))),
  frame3("TYER", cat(Uint8Array.of(0), latin("2020"))),
  frame3("TXXX", cat(Uint8Array.of(0), latin("PRODUCER\u0000Nick Mira"))),
  frame3("COMM", cat(Uint8Array.of(0), latin("eng"), latin("\u0000A comment"))),
  frame3("TALB", cat(Uint8Array.of(1, 0xfe, 0xff), Uint8Array.from([0, 0x4c, 0, 0x4e, 0, 0x44]))), // "LND" big-endian
  new Uint8Array(20));
await addFile("v23.mp3", cat(latin("ID3"), Uint8Array.of(3, 0, 0), synch(v23body.length), v23body, audio(500)));
const unsyncBody = cat(frame3("TIT2", cat(Uint8Array.of(0), Uint8Array.of(0x41, 0xff, 0x00, 0x42))), new Uint8Array(10));
await addFile("unsync.mp3", cat(latin("ID3"), Uint8Array.of(3, 0, 0x80), synch(unsyncBody.length), unsyncBody, audio(100)));
// ID3v2.2 (three-letter frames)
const frame2 = (id, body) => cat(latin(id), Uint8Array.of((body.length >> 16) & 255, (body.length >> 8) & 255, body.length & 255), body);
const v22body = cat(frame2("TT2", cat(Uint8Array.of(0), latin("Old Format"))), frame2("TP1", cat(Uint8Array.of(0), latin("Juice WRLD"))), frame2("TYE", cat(Uint8Array.of(0), latin("2017"))));
await addFile("v22.mp3", cat(latin("ID3"), Uint8Array.of(2, 0, 0), synch(v22body.length), v22body, audio(100)));
// ID3v2.4 UTF-8, with a frame flagged as compressed (skipped)
const frame4 = (id, body, f = 0) => cat(latin(id), synch(body.length), Uint8Array.of(0, f), body);
const v24body = cat(frame4("TIT2", cat(Uint8Array.of(3), enc.encode("Ünïcode Tïtle"))), frame4("TPE1", cat(Uint8Array.of(3), enc.encode("Juice WRLD")), 0x08),
  frame4("TDRC", cat(Uint8Array.of(3), enc.encode("2019-05-02"))), frame4("TCON", cat(Uint8Array.of(3), enc.encode("﻿Rap\u0000Hip-Hop"))));
await addFile("v24.mp3", cat(latin("ID3"), Uint8Array.of(4, 0, 0), synch(v24body.length), v24body, audio(100)));
// ID3v1 only, and an empty v2 title next to a v1 tag
const v1 = (title) => cat(latin("TAG"), latin(title.padEnd(30, "\u0000")), latin("Juice WRLD".padEnd(30, "\u0000")), latin("Album".padEnd(30, " ")), latin("2016"), new Uint8Array(31));
await addFile("v1only.mp3", cat(audio(300), v1("Version One")));
const emptyTitle = cat(frame3("TIT2", Uint8Array.of(0, 0)), frame3("TPE1", cat(Uint8Array.of(0), latin("V2 Artist"))));
await addFile("v2empty-v1.mp3", cat(latin("ID3"), Uint8Array.of(3, 0, 0), synch(emptyTitle.length), emptyTitle, audio(300), v1("From V1")));
// a WAV with an ID3 chunk at the front, an AAC with nothing, and garbage
const wavTag = frame3("TIT2", cat(Uint8Array.of(0), latin("Wave Title")));
await addFile("tagged.wav", cat(latin("ID3"), Uint8Array.of(3, 0, 0), synch(wavTag.length), wavTag, audio(50)));
await addFile("plain.aac", audio(300));
await addFile("short.mp3", Uint8Array.of(0x49, 0x44));
// Vorbis comments: FLAC by hand (with a picture block first) and Ogg / Opus
const vorbis = (...kv) => cat(u32le(6), latin("vendor"), u32le(kv.length), ...kv.map(s => { const b = enc.encode(s); return cat(u32le(b.length), b); }));
const vc = vorbis("TITLE=Hand Flac", "artist=Juice WRLD", "ALBUM ARTIST=Juice WRLD", "DATE=2018-01-01", "Producer=DT", "NOEQUALS", "TITLE=second title ignored");
await addFile("hand.flac", cat(enc.encode("fLaC"), Uint8Array.of(0, 0, 0, 34), new Uint8Array(34), Uint8Array.of(6, 0, 0, 4), new Uint8Array(4),
  Uint8Array.of(0x84, (vc.length >> 16) & 255, (vc.length >> 8) & 255, vc.length & 255), vc, audio(100)));
await addFile("truncated.flac", cat(enc.encode("fLaC"), Uint8Array.of(0x84, 0, 0, 200), vorbis("TITLE=Cut Short", "ARTIST=x").subarray(0, 30)));
await addFile("song.ogg", cat(latin("OggS"), new Uint8Array(30), Uint8Array.of(3), latin("vorbis"), vorbis("TITLE=Ogg Song", "GENRE=Rap"), audio(100)));
await addFile("song.opus", cat(latin("OggS"), new Uint8Array(30), latin("OpusTags"), vorbis("TITLE=Opus Song", "COMMENT= hi "), audio(100)));
// M4A by hand: QuickTime-style meta (no version bytes), a freeform producer, a 64-bit mdat before moov
const data = s => box("data", Uint8Array.of(0, 0, 0, 1, 0, 0, 0, 0), enc.encode(s));
const ilst = box("ilst", box("©nam", data("Hand M4A")), box("©day", data("2021-07-09")),
  box("----", box("mean", new Uint8Array(4), latin("com.apple.iTunes")), box("name", new Uint8Array(4), latin("PRODUCER")), data("Taz Taylor")));
const mdat64 = cat(u32be(1), latin("mdat"), u32be(0), u32be(16 + 100), audio(100));
await addFile("hand.m4a", cat(ftyp, mdat64, box("moov", box("udta", box("meta", box("hdlr", new Uint8Array(20)), ilst)))));
await addFile("nomoov.m4a", cat(ftyp, box("mdat", audio(100))));

// ---- matching
const songs = [
  { id: "1", name: "Lucid Dreams", alt: ["Forget Me"], filePath: "" }, { id: "2", name: "Lucid Dreams", alt: [], filePath: "" },
  { id: "3", name: "Robbery", alt: [], filePath: "Sessions/robbery_final_v2.mp3" }, { id: "4", name: "Wishing Well", alt: [], filePath: "" },
  { id: "5", name: "Righteous", alt: ["Righteous (Remix)"], filePath: "" }, { id: "6", name: "Bandit", alt: [], filePath: "" },
].map(s => g("cleanSong")(s));
const lib = ["Juice WRLD/Lucid Dreams.mp3", "Juice WRLD/Forget Me.m4a", "Juice WRLD/robbery_final_v2.mp3", "Juice WRLD/Wishing Wel.flac",
  "Juice WRLD/Righteous.mp3", "Juice WRLD/Bandit.mp3", "Juice WRLD/Unknown Thing.mp3", "Juice WRLD/Manual Pick.mp3", "Juice WRLD/Rightous.mp3"]
  .map(p => { const title = g("titleFromFilename")(p); return { path: p, title, key: g("normalize")(title), stem: g("stemOf")(p) }; });
const overrides = { "Juice WRLD/Manual Pick.mp3": "6", "Juice WRLD/Bandit.mp3": "none" };
const { owned, unmatched } = g("matchLibrary")(songs, lib, overrides);
const matching = {
  catalog: plain(songs), files: lib.map(f => ({ path: f.path, title: f.title, key: f.key, stem: f.stem })), overrides,
  owned: Object.fromEntries([...owned].map(([i, fs]) => [i, fs.map(f => f.path)])), unmatched: unmatched.map(f => f.path),
  how: Object.fromEntries(lib.filter(f => f.matchedBy).map(f => [f.path, f.matchedBy])),
};

// ---- what the screens show (stage 2): functions from the page's main script, run on a stand-in state
const main = /<script>([\s\S]*?)<\/script>\s*<\/body>/.exec(html)?.[1] ?? html.slice(html.lastIndexOf("<script>") + 8);
const grab = name => { // the source of one top-level function or const in the main script
  const fn = main.indexOf(`\nfunction ${name}(`), cn = main.indexOf(`\nconst ${name} =`);
  if (cn >= 0 && (fn < 0 || cn < fn)) return main.slice(cn, main.indexOf(";\n", cn) + 1);
  if (fn < 0) throw new Error(`no ${name} in the page`);
  let i = main.indexOf("{", fn), depth = 0;
  for (; i < main.length; i++) { if (main[i] === "{") depth++; else if (main[i] === "}" && --depth === 0) break; }
  return main.slice(fn, i + 1);
};
vm.runInContext(["NO_ERA", "MONTHS", "capital", "eraName", "timeKey", "eraStats", "yearsIn", "splitStudios"].map(grab).join("\n"), ctx);
const credits = ["Nick Mira & Dre Moon, Taz Taylor", "Juice WRLD (feat. Lil Uzi Vert)", "DT; Purps / Max Lord + Charlie Handsome and Joey",
  "Ft. Someone", "A, a, B, N/A, x, ??", "Rex Kudo(prod by Pharrell)", "", "Brandon Finessin ft. Nick"];
const studioTexts = ["Studio A; Studio B / studio a", "Means Street Studios\nLA | NYC", "N/A", ""];
const dateTexts = ["Recorded\nAugust 2, 2015.", "May 2018", "2019-05-02", "2019-13-02", "Sept. 3rd, 2017 and Jan 1 2018", "2017-2019", "2015 to 2025", "nothing",
  "December 22nd, 2017 - May 23rd, 2018", "Feb. 2020"];
const derived = {
  splitNames: credits.map(t => [t, plain(g("splitNames")(t))]),
  splitStudios: studioTexts.map(t => [t, plain(g("splitStudios")(t))]),
  yearsIn: dateTexts.map(t => [t, [...g("yearsIn")(t)]]),
  recordMonth: dateTexts.map(t => [t, g("recordMonth")(t)]),
  timeKey: dateTexts.map(t => [t, g("timeKey")(t)]),
  datesIn: dateTexts.map(t => [t, plain(g("datesIn")(t))]),
  capital: ["released", "recording_session", "unsurfaced", ""].map(t => [t, g("capital")(t)]),
};
const eraSongs = [
  { id: "1", name: "A", era: "GB&GR", recordDates: "May 2017" }, { id: "2", name: "B", era: "", recordDates: "2016" },
  { id: "3", name: "C", era: "DRFL", release: "March 8, 2019" }, { id: "4", name: "D", era: "Zeta", recordDates: "" },
  { id: "5", name: "E", era: "Alpha", recordDates: "" }, { id: "6", name: "F", era: "GB&GR", recordDates: "January 2016" },
  { id: "7", name: "G", era: "WOD", recordDates: "2018" }, { id: "8", name: "H", era: "N/A" },
].map(r => g("cleanSong")(r));
const eraInfo = { "GB&GR": { id: 5, description: "Goodbye", timeFrame: "December 22nd, 2017 - May 23rd, 2018" }, WOD: { id: 3, description: "", timeFrame: "" },
  DRFL: { id: 2, description: "Race", timeFrame: "N/A" } };
vm.runInContext("var state = {}", ctx);
const st = g("state");
st.catalog = eraSongs; st.owned = new Map([[0, []], [2, []], [7, []]]); st.eras = eraInfo;
const eras = { catalog: plain(eraSongs), owned: [0, 2, 7], info: eraInfo,
  stats: plain(g("eraStats")().map(e => ({ name: e.name, have: e.have, total: e.total, timeFrame: e.info.timeFrame || "", description: e.info.description || "" }))) };

// ---- export helpers (stage 3)
vm.runInContext(["csvText", "fileUrl"].map(grab).join("\n"), ctx);
const exportCases = {
  uri: ["Juice WRLD/Lucid Dreams (v2).mp3", "a&b=c?d#e", "Café déjà/ü 100%", "~!*'()-_.", "space here+plus"].map(t => [t, encodeURIComponent(t)]),
  fileUrl: [{ filePath: "" }, { filePath: "Sessions/robbery_final v2.wav" }].map(x => [x.filePath, g("fileUrl")(x)]),
  csv: g("csvText")([["id", "name", "note"], ["1", 'He said "hi"', "line\nbreak, comma"], ["2", "", "Ünïcode"]]).replace(/^\ufeff/, ""),
  csvBom: g("csvText")([["x"]]).startsWith("\ufeff"), // kept apart: Foundation's JSON reader drops a leading U+FEFF
};

// ---- writing tags (stage 4): the page's writers on many inputs; Swift must give the same bytes or the same error
const b64 = u => Buffer.from(u).toString("base64");
const WRITERS = { mp3: ["writeMp3", "verifyMp3"], flac: ["writeFlac", "verifyFlac"], m4a: ["writeM4a", "verifyM4a"] };
const writes = [];
const tryWrite = (name, ext, input, desired) => {
  const [w, v] = WRITERS[ext];
  const c = { name, ext, input: b64(input), desired };
  try {
    const res = g(w)(input, desired);
    c.out = b64(res.out);
    try { g(v)(input, res, desired); c.verify = null; } catch (e) { c.verify = e.message; }
  } catch (e) { c.error = e.message; }
  writes.push(c);
};
const full = { ...tags, comment: "Released. Recorded March 2018." };
const uni = { title: "Ünïcode — “quotes” & 999 🦋", artist: "Juice WRLD, Lil Uzi Vert", year: "Recorded 2019-05-02", producer: "Nick Mira, DT" };
const mp3Plain = cat(Uint8Array.of(0xff, 0xfb), audio(3000));
tryWrite("mp3 untagged, all fields", "mp3", mp3Plain, full);
tryWrite("mp3 untagged, unicode", "mp3", mp3Plain, uni);
const mp3v3 = g("writeMp3")(mp3Plain, full).out;
tryWrite("mp3 v2.3 retag title and producer", "mp3", mp3v3, { title: "Lucid Dreams (Forget Me)", producer: "Nick Mira, DT" });
tryWrite("mp3 v2.3 retag comment only", "mp3", mp3v3, { comment: "New comment" });
const v23 = readFileSync(join(dir, "files", "v23.mp3"));
tryWrite("mp3 hand v2.3 with TXXX and COMM", "mp3", new Uint8Array(v23), { producer: "Taz Taylor", comment: "c", genre: "Rap" });
const v24 = readFileSync(join(dir, "files", "v24.mp3"));
tryWrite("mp3 v2.4 keeps a compressed frame", "mp3", new Uint8Array(v24), { title: "New", year: "2021" });
tryWrite("mp3 v2.2 refused", "mp3", new Uint8Array(readFileSync(join(dir, "files", "v22.mp3"))), { title: "x" });
tryWrite("mp3 unsynchronised refused", "mp3", new Uint8Array(readFileSync(join(dir, "files", "unsync.mp3"))), { title: "x" });
const damaged = cat(latin("ID3"), Uint8Array.of(3, 0, 0), synch(30), latin("tit2"), new Uint8Array(26), audio(100));
tryWrite("mp3 damaged tag refused", "mp3", damaged, { title: "x" });
tryWrite("mp3 tag with no audio refused", "mp3", cat(latin("ID3"), Uint8Array.of(3, 0, 0), synch(20), new Uint8Array(20)), { title: "x" });
tryWrite("flac no comments", "flac", flacOrig, full);
tryWrite("flac unicode", "flac", flacOrig, uni);
const flacTagged = g("writeFlac")(flacOrig, full).out;
tryWrite("flac retag", "flac", flacTagged, { title: "Retitled", album: "LND" });
tryWrite("flac hand with picture first", "flac", new Uint8Array(readFileSync(join(dir, "files", "hand.flac"))), { genre: "Hip-Hop/Rap", year: "2018" });
tryWrite("flac damaged refused", "flac", cat(enc.encode("fLaC"), Uint8Array.of(0x80, 0, 0, 200), new Uint8Array(10)), { title: "x" });
tryWrite("flac not flac refused", "flac", audio(100), { title: "x" });
tryWrite("m4a moov before audio", "m4a", m4aOrig, full);
tryWrite("m4a unicode", "m4a", m4aOrig, uni);
const m4aTagged = g("writeM4a")(m4aOrig, full).out;
tryWrite("m4a retag shrinks moov", "m4a", m4aTagged, { title: "T", producer: "P" });
const co64For = off => box("moov", box("mvhd", new Uint8Array(100)), box("trak", box("mdia", box("minf", box("stbl",
  box("co64", new Uint8Array(4), u32be(2), u32be(0), u32be(off), u32be(0), u32be(off + 50)))))));
tryWrite("m4a 64-bit offsets", "m4a", cat(ftyp, co64For(ftyp.length + co64For(0).length + 8), box("mdat", audio(2000))), { title: "Wide" });
tryWrite("m4a moov after audio", "m4a", cat(ftyp, box("mdat", audio(500)), moovFor(ftyp.length + 8)), { album: "After" });
tryWrite("m4a no stco fails the check", "m4a", new Uint8Array(readFileSync(join(dir, "files", "hand.m4a"))), { title: "x" });
tryWrite("m4a no moov refused", "m4a", new Uint8Array(readFileSync(join(dir, "files", "nomoov.m4a"))), { title: "x" });
tryWrite("m4a fragmented refused", "m4a", cat(ftyp, moovFor(0), box("moof", new Uint8Array(8)), box("mdat", audio(50))), { title: "x" });

// ---- where missing songs are saved (stage 4c): the page's layout rule on a few libraries
vm.runInContext(["safeName", "mostCommon", "computeLayout", "saveFolder", "saveFileName", "snapshotCsv"].map(grab).join("\n"), ctx);
const layoutSongs = [
  { id: "1", name: "Lucid Dreams", era: "GB&GR" }, { id: "2", name: "Armed & Dangerous", era: "GB&GR" }, { id: "3", name: "Robbery", era: "DRFL", filePath: "x/Robbery (OG).mp3" },
  { id: "4", name: "Hear Me Calling", era: "DRFL" }, { id: "5", name: "Righteous", era: "LND" }, { id: "6", name: "Wishing Well", era: "LND" },
  { id: "7", name: "Bandit", era: "" }, { id: "8", name: "What? / Why: <odd> name...", era: "WOD: Part *2*" }, { id: "9", name: "Lucid Dreams", era: "Snippets" },
  { id: "10", name: "Conversations", era: "LND" },
].map(r => g("cleanSong")(r));
const libraries = {
  eraFolders: ["Music/Juice WRLD/GB&GR/Lucid Dreams.mp3", "Music/Juice WRLD/GB&GR/Armed & Dangerous.mp3", "Music/Juice WRLD/Death Race for Love/Robbery.mp3",
    "Music/Juice WRLD/LND/Righteous.mp3", "Music/Other/Righteous (dup).mp3"],
  flat: ["Tunes/All Juice/Robbery.mp3", "Tunes/All Juice/Righteous.mp3", "Tunes/All Juice/Bandit.mp3", "Tunes/Elsewhere/Wishing Well.mp3"],
  empty: [],
  mixed: ["Lib/Lucid Dreams.mp3", "Lib/a/Hear Me Calln.mp3", "Lib/b/Conversations.mp3", "Lib/b/Wishing Well.mp3", "Lib/DRFL/Robbery.mp3"],
};
const layouts = Object.entries(libraries).map(([name, paths]) => {
  const lib = paths.map((p, n) => { const title = g("titleFromFilename")(p);
    return { path: p, title, key: g("normalize")(title), stem: g("stemOf")(p), ext: g("extOf")(p), size: 1000 + n, tags: n % 2 ? { title, artist: "Juice WRLD", year: "2018" } : {} }; });
  st.catalog = layoutSongs; st.library = lib;
  st.owned = g("matchLibrary")(layoutSongs, lib, {}).owned;
  g("computeLayout")();
  return { name, files: lib.map(f => ({ path: f.path, title: f.title, key: f.key, stem: f.stem, tags: f.tags, size: f.size })),
    snapshot: g("snapshotCsv")().replace(/^\ufeff/, ""),
    folders: layoutSongs.map(s => g("saveFolder")(s)), fileNames: layoutSongs.map(s => g("saveFileName")(s)) };
});

// ---- the tag fixer, duplicates and file health (stage 4d): the page's functions with stand-ins for its controls
vm.runInContext(`var __fx = { fields: [], blanks: false, genre: "" };
function selectedFields() { return __fx.fields; }
function $(id) { return { checked: __fx.blanks, value: __fx.genre }; }
const fixGenre = () => __fx.genre.trim() || DEFAULT_GENRE;
var health = { probed: new Map() };`, ctx);
vm.runInContext(["fixFor", "buildPlan", "duplicateGroups", "healthIssues", "fmtTime", "formatSize"].map(grab).join("\n"), ctx);
const toolSongs = [
  { id: "1", name: "Lucid Dreams", era: { name: "GB&GR" }, category: "released", release_date: "May 4, 2018", record_dates: "Recorded\nMarch 2017.", producers: "Nick Mira", length: "3:59", path: "GB&GR/Lucid Dreams.flac", bitrate: "Original Files\n1411kbps (.flac)" },
  { id: "2", name: "Lucid Dreams", era: { name: "Snippets" }, category: "unsurfaced", length: "1:10" },
  { id: "3", name: "Robbery", era: { name: "DRFL" }, category: "recording_session", record_dates: "Recorded: December 2018", credited_artists: "Lil Yachty", length: "4:00", path: "DRFL/Robbery.mp3", bitrate: "320kbps (.mp3)" },
  { id: "4", name: "Wishing Well", era: { name: "LND" }, category: "released", release_date: "2020", length: "3:14", path: "LND/Wishing Well.mp3", bitrate: "320 kbps (.mp3)" },
  { id: "5", name: "Righteous", era: "", category: "unknown", artists: "Juice WRLD", producers: "Nick Mira & Charlie Handsome", length: "0:30" },
].map(r => g("cleanSong")(r));
const toolLib = [
  ["M/Lucid Dreams.mp3", { title: "Lucid Dreams", artist: "Juice WRLD" }, 4000000],
  ["M/Robbery.mp3", { title: "Robbery", artist: "Juice WRLD", album: "DRFL", year: "2019" }, 2500000],
  ["M/Robbery copy.mp3", { title: "Robbery" }, 9600000],
  ["M/Wishing Well.ogg", { title: "Wishing Well" }, 5000000],
  ["M/Wishing Well.mp3", {}, 200000],
  ["M/Righteous.m4a", { title: "Righteous", genre: "Rap" }, 3000000],
  ["M/Righteous (Remix).m4a", { title: "Righteous (Remix)" }, 3100000],
  ["M/Unknown Song.mp3", { title: "Unknown Song" }, 3000000],
  ["M/Unknown Song (2).mp3", { title: "Unknown Song" }, 3200000],
  ["M/Lucid Dreams.flac", { title: "Lucid Dreams" }, 30000000],
].map(([p, tags, size]) => { const title = tags.title || g("titleFromFilename")(p);
  return { path: p, ext: g("extOf")(p), tags, title, key: g("normalize")(title), stem: g("stemOf")(p), fromTags: Boolean(tags.title), size }; });
const toolOverrides = { "M/Lucid Dreams.flac": "1" };
st.catalog = toolSongs; st.library = toolLib;
const tm = g("matchLibrary")(toolSongs, toolLib, toolOverrides);
st.owned = tm.owned; st.unmatched = tm.unmatched;
const fx = g("__fx");
const plans = [[["title", "artist", "albumartist", "album", "year", "producer"], false, ""], [["title", "genre", "comment"], true, "Rap"], [["artist", "year", "comment", "producer"], false, " Emo "]]
  .map(([fields, blanks, genre]) => { fx.fields = fields; fx.blanks = blanks; fx.genre = genre; const p = g("buildPlan")();
    return { fields, blanks, genre: genre.trim() || "Hip-Hop/Rap", same: p.same, skipped: p.skipped.map(x => [x.f.path, x.reason]),
      changes: p.changes.map(it => ({ path: it.f.path, song: g("state").catalog.indexOf(it.song), changes: it.changes.map(c => [c.k, c.from, c.to]) })) }; });
const dupGroups = g("duplicateGroups")().map(gr => ({ song: gr.i, title: gr.title, files: gr.files.map(f => f.path), extra: gr.extra,
  exact: g("isExactDuplicate")(gr), keep: g("bestCopy")(gr.files).path }));
const hp = g("health").probed;
hp.set("M/Robbery.mp3", { ok: true, seconds: 100, size: 2500000 }); hp.set("M/Righteous.m4a", { ok: true, seconds: 3.4, size: 3000000 });
hp.set("M/Unknown Song.mp3", { ok: false, seconds: 0, size: 3000000 }); hp.set("M/Lucid Dreams.mp3", { ok: true, seconds: 239.6, size: 0 });
const healthOut = g("healthIssues")().map(x => [x.f.path, x.group, x.text]);
const tools = { songs: plain(toolSongs), lib: toolLib, overrides: toolOverrides, plans, dupGroups, probes: Object.fromEntries(hp), health: healthOut,
  planned: toolSongs.map(so => plain(g("plannedTags")(so, "Hip-Hop/Rap"))),
  sizes: [0, 999, 1500, 307199, 1e6, 12345678, 2.5e9].map(n => [n, g("formatSize")(n)]), times: [0, 3.4, 59.4, 59.6, 61, 239.6].map(n => [n, g("fmtTime")(n)]),
  kbps: [["Original Files\n2117kbps (.wav)\n320kpbs (.mp3)", "mp3"], ["2117kbps (.wav)\n320kbps (.mp3)", ""], ["nothing", "mp3"]].map(([t, e]) => [t, e, g("siteKbps")(t, e)]),
  lengths: ["4:26", "1:02:03", " 3:05 ", "3:5", "abc", ""].map(t => [t, g("lengthSeconds")(t)]),
  keys: ["Lucid Dreams (Forget Me)", "Café—Déjà  Vu!!", "  ", "ÆON"].map(t => [t, g("cmdkKey")(t)]) };

writeFileSync(join(dir, "fixtures.json"), JSON.stringify({ text, catalog, files, matching, derived, eras, exportCases, writes, layouts, layoutSongs: plain(layoutSongs), tools }, null, 1));
console.log(`wrote ${files.length} tag files and fixtures to ${dir}`);
