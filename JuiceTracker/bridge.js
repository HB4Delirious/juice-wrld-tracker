// Injected by the Mac app before juice-tracker.html runs.
// Recreates the parts of Chrome's File System Access API the tracker uses (showDirectoryPicker,
// folder/file handles, createWritable) on top of NativeBridge.swift, so tag editing works in the app.
// In a normal browser this file isn't loaded and the page behaves exactly as before.
(() => {
  const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.jwNative;
  if (!native) return;
  // Lets the page leave room for the window buttons, which sit over it in the app.
  document.documentElement.classList.add("jw-app");

  const call = async (op, args = {}) => {
    try {
      return await native.postMessage({ op, ...args });
    } catch (e) {
      const msg = String((e && e.message) || e);
      const m = /^(\w+Error): ?([\s\S]*)$/.exec(msg);
      throw new DOMException(m ? m[2] : msg, m ? m[1] : "UnknownError");
    }
  };
  // Whole songs (10+ MB) pass through here when tags are written. The browser's own decoders do the work off the
  // page's main thread; a JavaScript loop over every byte froze the window for a moment on each file.
  const fromB64Loop = s => {
    const bin = atob(s || "");
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  };
  const toB64Loop = bytes => {
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s);
  };
  const fromB64 = async s => {
    if (!s || s.length < 65536) return fromB64Loop(s); // small reads: the loop is quicker than a round trip
    try { return new Uint8Array(await (await fetch(`data:application/octet-stream;base64,${s}`)).arrayBuffer()); }
    catch (e) { return fromB64Loop(s); }
  };
  const toB64 = bytes => {
    if (bytes.length < 49152) return Promise.resolve(toB64Loop(bytes));
    return new Promise(resolve => {
      const reader = new FileReader();
      reader.onload = () => { const url = String(reader.result); resolve(url.slice(url.indexOf(",") + 1)); };
      reader.onerror = () => resolve(toB64Loop(bytes));
      reader.readAsDataURL(new Blob([bytes]));
    });
  };
  const join = (dir, name) => (dir.endsWith("/") ? dir + name : `${dir}/${name}`);

  /** A lazy File: bytes are only read when arrayBuffer() is called, so scanning reads just the tag headers. */
  class NativeFile {
    constructor(path, name, start, end, mtime = Date.now()) {
      this._path = path; this._s = start; this._e = end;
      this.name = name; this.size = end - start; this.type = ""; this.lastModified = mtime;
    }
    slice(a = 0, b = this.size) {
      const n = this.size, clamp = x => (x < 0 ? Math.max(n + x, 0) : Math.min(x, n));
      const s = clamp(a), e = Math.max(clamp(b), s);
      return new NativeFile(this._path, this.name, this._s + s, this._s + e, this.lastModified);
    }
    async arrayBuffer() {
      if (!this.size) return new ArrayBuffer(0);
      return (await fromB64(await call("read", { path: this._path, start: this._s, end: this._e }))).buffer;
    }
    async text() { return new TextDecoder().decode(await this.arrayBuffer()); }
  }

  const granted = async () => "granted";

  class NativeFileHandle {
    constructor(path, name) { this.kind = "file"; this.name = name; this._path = path; }
    async getFile() {
      const st = await call("stat", { path: this._path });
      return new NativeFile(this._path, this.name, 0, st.size, st.mtime);
    }
    async createWritable() {
      const chunks = [], path = this._path;
      return {
        async write(data) {
          if (data && data.type === "write") data = data.data;
          if (typeof data === "string") data = new TextEncoder().encode(data);
          else if (data instanceof ArrayBuffer) data = new Uint8Array(data);
          else if (ArrayBuffer.isView(data)) data = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
          else if (data && typeof data.arrayBuffer === "function") data = new Uint8Array(await data.arrayBuffer());
          chunks.push(data);
        },
        async close() {
          let n = 0;
          for (const c of chunks) n += c.length;
          const all = new Uint8Array(n);
          let o = 0;
          for (const c of chunks) { all.set(c, o); o += c.length; }
          await call("write", { path, data: await toB64(all) });
        },
        async abort() { chunks.length = 0; },
      };
    }
    async isSameEntry(other) { return Boolean(other) && other._path === this._path; }
  }
  NativeFileHandle.prototype.queryPermission = granted;
  NativeFileHandle.prototype.requestPermission = granted;

  class NativeDirectoryHandle {
    constructor(path, name) { this.kind = "directory"; this.name = name; this._path = path; }
    async *entries() {
      const list = await call("list", { path: this._path });
      for (const e of list) {
        const p = join(this._path, e.name);
        yield [e.name, e.kind === "directory" ? new NativeDirectoryHandle(p, e.name) : new NativeFileHandle(p, e.name)];
      }
    }
    async *values() { for await (const [, h] of this.entries()) yield h; }
    async *keys() { for await (const [n] of this.entries()) yield n; }
    [Symbol.asyncIterator]() { return this.entries(); }
    async getDirectoryHandle(name, opts = {}) {
      const p = join(this._path, name), st = await call("exists", { path: p });
      if (st.exists && st.kind === "directory") return new NativeDirectoryHandle(p, name);
      if (st.exists) throw new DOMException(`${name} is a file, not a folder.`, "TypeMismatchError");
      if (!opts.create) throw new DOMException(`${name} wasn't found.`, "NotFoundError");
      await call("mkdir", { path: p });
      return new NativeDirectoryHandle(p, name);
    }
    async getFileHandle(name, opts = {}) {
      const p = join(this._path, name), st = await call("exists", { path: p });
      if (st.exists && st.kind === "file") return new NativeFileHandle(p, name);
      if (st.exists) throw new DOMException(`${name} is a folder, not a file.`, "TypeMismatchError");
      if (!opts.create) throw new DOMException(`${name} wasn't found.`, "NotFoundError");
      await call("write", { path: p, data: "" });
      return new NativeFileHandle(p, name);
    }
    async resolve(other) {
      const a = this._path.replace(/\/+$/, ""), b = other && other._path;
      if (!b) return null;
      if (b === a) return [];
      return b.startsWith(`${a}/`) ? b.slice(a.length + 1).split("/") : null;
    }
    async isSameEntry(other) { return Boolean(other) && other._path === this._path; }
  }
  NativeDirectoryHandle.prototype.queryPermission = granted;
  NativeDirectoryHandle.prototype.requestPermission = granted;

  window.showDirectoryPicker = async (opts = {}) => {
    const r = await call("pickFolder", { id: String(opts.id || "") });
    return new NativeDirectoryHandle(r.path, r.name);
  };

  // Saves a juicewrldapi.com song file straight into the music folder: resolves { path, size } or { path, existed }.
  window.jwDownload = (url, path) => call("download", { url, path });

  // Moves a file (inside a picked folder) to the Trash. Used by duplicate cleanup.
  window.jwTrash = path => call("trash", { path });

  // Plex (set up in Settings): { action: "refresh" | "status" | "playlist", title, paths }.
  window.jwPlex = cmd => call("plex", cmd);

  // Ambient background music: { items: [{ path, title }], play: true | false }.
  window.jwAmbient = cmd => call("ambient", cmd);

  // File health check: { ok, seconds } for an audio file; and showing a file in Finder.
  window.jwProbe = path => call("probe", { path });
  window.jwReveal = path => call("reveal", { path });
  // { kind, size, mtime } for a path; the drive status times it.
  window.jwStat = path => call("stat", { path });

  // A handle for a file path from an earlier scan, with no disk access (the native side still checks every use).
  window.jwFileHandle = (path, name) => new NativeFileHandle(path, name);

  // The folder picked last time for this picker id, or null. Lets the page rescan it at launch.
  window.jwRestoreFolder = async id => {
    const r = await call("restoreFolder", { id: String(id || "") });
    return r ? new NativeDirectoryHandle(r.path, r.name) : null;
  };

  // Clipboard writes from a file:// page can be refused by WebKit, so route them through the app.
  const writeText = text => call("copy", { text: String(text) }).then(() => undefined);
  try {
    if (navigator.clipboard) navigator.clipboard.writeText = writeText;
    else Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
  } catch (e) { /* keep the browser's own clipboard */ }

  window.jwNativeApp = true;
})();
