// The host of an app of myzig in a browser: loads its WebAssembly (built
// for wasm32-wasi), gives it WASI in memory with the fonts it draws text
// with, and a canvas for each window, in the element with the ID "myzig"
// (else the page's body). The browser's pointer, wheel, keys, input
// methods, clipboard, size and device pixel ratio go to the app through
// the functions it exports; it asks for animation frames only when it
// has something to draw. Frames draw with WebGL 2 (host_gl.js), or, where
// there is none, with the pixels the app draws on the CPU.
//
//   <script type="module">
//     import { start } from "./host.js";
//     start({ wasm: "app.wasm", fonts: "fonts/" });
//   </script>

import { Wasi, Exit } from "./host_wasi.js";
import { GL } from "./host_gl.js";

/// Thrown by the app's `run` to end `main` with its stack kept: the
/// browser's events drive the app from then on.
const running = { myzig: "running" };
const cursors = ["default", "pointer", "text", "col-resize", "row-resize"];
const isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
const enc = new TextEncoder();
const dec = new TextDecoder();

/// Starts the app: `wasm` its URL, `fonts` the directory of its fonts,
/// listed in `fonts.json` there (fetched into /usr/share/fonts); `webgl`
/// false draws on the CPU.
export async function start({ wasm = "app.wasm", fonts = "fonts/", container = null, args = ["app"], env = {}, webgl = true } = {}) {
  const host = new Host(container, args, env);
  host.webgl = webgl;
  window.myzigHost = host;
  await host.load(wasm, fonts);
  host.start();
  return host;
}

class Host {
  constructor(container, args, env) {
    this.container = container || document.getElementById("myzig") || document.body;
    this.wasi = new Wasi(args, env);
    this.windows = new Map();
    // Tests read each frame drawn (`capture`), from WebGL or the CPU.
    this.capture = false;
    this.frames = new Map();
    this.dark = matchMedia("(prefers-color-scheme: dark)");
  }

  async load(url, fonts) {
    const list = await fetch(fonts + "fonts.json").then((r) => (r.ok ? r.json() : []), () => []);
    await Promise.all(list.map(async (name) => {
      const r = await fetch(fonts + name);
      if (r.ok) this.wasi.writeFile("/usr/share/fonts/" + name, new Uint8Array(await r.arrayBuffer()));
    }));
    const imports = { wasi_snapshot_preview1: this.wasi.imports(), myzig: this.imports() };
    const source = await fetch(url);
    const { instance } = await (WebAssembly.instantiateStreaming && source.headers.get("content-type") === "application/wasm"
      ? WebAssembly.instantiateStreaming(source, imports)
      : source.arrayBuffer().then((b) => WebAssembly.instantiate(b, imports)));
    this.exports = instance.exports;
    this.wasi.memory = instance.exports.memory;
  }

  start() {
    try {
      this.exports._start();
    } catch (e) {
      if (e === running) return this.listen();
      if (e instanceof Exit) return;
      throw e;
    }
  }

  listen() {
    const appearance = () => this.exports.myzig_web_appearance(this.isDark());
    this.dark.addEventListener("change", appearance);
    new MutationObserver(appearance).observe(document.documentElement, { attributes: true, attributeFilter: ["data-myzig-theme"] });
    // A zoom or a move to another screen changes the device pixel ratio.
    addEventListener("resize", () => { for (const w of this.windows.values()) w.sendSize(); });
  }

  isDark() {
    const t = document.documentElement.dataset.myzigTheme;
    return t ? t === "dark" : this.dark.matches;
  }

  bytes(ptr, len) { return new Uint8Array(this.exports.memory.buffer, ptr, len); }
  str(ptr, len) { return dec.decode(this.bytes(ptr, len).slice()); }

  /// Writes `s` into the app's buffer; its length in bytes.
  put(s) {
    const b = enc.encode(s);
    const ptr = this.exports.myzig_web_buffer(b.length);
    this.bytes(ptr, b.length).set(b);
    return b.length;
  }

  imports() {
    const w = (id) => this.windows.get(id);
    return {
      window_open: (id, ptr, len) => {
        const title = this.str(ptr, len);
        this.windows.set(id, new HostWindow(this, id, title));
        if (title) document.title = title;
      },
      window_close: (id) => { w(id)?.remove(); this.windows.delete(id); },
      window_title: (id, ptr, len) => { document.title = this.str(ptr, len); },
      request_frame: (id) => w(id)?.requestFrame(),
      set_cursor: (id, c) => { const win = w(id); if (win) win.canvas.style.cursor = cursors[c] || "default"; },
      text_area: (id, x, y, width, h, focused) => w(id)?.placeTextArea(x, y, width, h, focused),
      set_timeout: (ms, token) => setTimeout(() => this.exports.myzig_web_timer(token), ms),
      clipboard_write: (ptr, len) => {
        const text = this.str(ptr, len);
        this.copied = text;
        navigator.clipboard?.writeText(text)?.catch(() => {});
      },
      open_url: (ptr, len) => !!open(this.str(ptr, len), "_blank", "noopener"),
      message: (ptr, len, buttons) => {
        const text = this.str(ptr, len);
        if (buttons <= 1) { alert(text); return 0; }
        return confirm(text) ? 0 : 1;
      },
      is_dark: () => this.isDark(),
      languages: (ptr, cap) => {
        const b = enc.encode((navigator.languages || [navigator.language || "en-US"]).join(","));
        const n = Math.min(b.length, cap);
        this.bytes(ptr, n).set(b.subarray(0, n));
        return n;
      },
      beep: () => {},
      run: () => { throw running; },
      quit: () => { for (const win of this.windows.values()) win.remove(); this.windows.clear(); },
      gl_init: (id, vs, vsLen, fs, fsLen) => {
        const win = w(id);
        if (!win || !this.webgl) return false;
        const g = GL.create(win.canvas, null, () => this.exports.myzig_web_context_restored(id));
        if (!g || !g.init(this.str(vs, vsLen), this.str(fs, fsLen))) return false;
        win.gl = g;
        return true;
      },
      gl_atlas: (id, ptr, size) => w(id)?.gl?.setAtlas(this.bytes(ptr, size * size), size),
      gl_images: (id, ptr, side, row0, row1) => w(id)?.gl?.setImages(this.bytes(ptr, side * side * 4), side, row0, row1),
      gl_fx: (id, src, len, main, mainLen, plain, plainLen) => w(id)?.gl?.setFx(this.str(src, len), this.str(main, mainLen), this.str(plain, plainLen)),
      gl_effect: (id, index, ptr, len) => w(id)?.gl?.setEffect(index, this.str(ptr, len)),
      gl_draw: (id, ptr, count, width, height, scale, r, g, b, plans, planFloats, x0, y0, x1, y1) => {
        const win = w(id);
        if (!win?.gl) return;
        const plan = planFloats ? new Float32Array(this.exports.memory.buffer, plans, planFloats) : new Float32Array(0);
        win.gl.draw(this.bytes(ptr, count * 96), count, width, height, scale, r, g, b, plan, x1 > x0 ? [x0, y0, x1, y1] : null);
        if (this.capture) this.frames.set(id, win.gl.read());
      },
      blit: (id, ptr, width, height) => w(id)?.blit(this.bytes(ptr, width * height * 4), width, height),
    };
  }
}

/// A window: its canvas, filling the container, and the text area out of
/// sight where keys and input methods type.
class HostWindow {
  constructor(host, id, title) {
    this.host = host;
    this.id = id;
    this.ex = host.exports;
    const c = host.container;
    if (c === document.body) Object.assign(document.documentElement.style, { height: "100%" });
    if (getComputedStyle(c).position === "static") c.style.position = "relative";
    if (c === document.body) Object.assign(c.style, { margin: "0", height: "100%", overflow: "hidden" });
    const root = (this.root = document.createElement("div"));
    root.className = "myzig-window";
    Object.assign(root.style, { position: "absolute", inset: "0", overflow: "hidden" });
    const canvas = (this.canvas = document.createElement("canvas"));
    canvas.setAttribute("aria-label", title);
    Object.assign(canvas.style, { display: "block", width: "100%", height: "100%", touchAction: "none", outline: "none" });
    const ta = (this.ta = document.createElement("textarea"));
    ta.setAttribute("autocapitalize", "off");
    ta.setAttribute("autocomplete", "off");
    ta.setAttribute("spellcheck", "false");
    ta.setAttribute("aria-hidden", "true");
    Object.assign(ta.style, { position: "absolute", left: "0", top: "0", width: "1px", height: "1em", padding: "0", border: "0", margin: "0", opacity: "0", resize: "none", overflow: "hidden", whiteSpace: "pre", caretColor: "transparent", background: "transparent", color: "transparent", pointerEvents: "none" });
    root.append(canvas, ta);
    c.append(root);
    this.gl = null;
    this.frame = 0;
    this.clicks = { at: 0, x: 0, y: 0, n: 0 };
    this.listen();
    this.observer = new ResizeObserver(() => this.sendSize());
    this.observer.observe(canvas);
    queueMicrotask(() => ta.focus({ preventScroll: true }));
  }

  remove() {
    this.observer.disconnect();
    if (this.frame) cancelAnimationFrame(this.frame);
    this.root.remove();
  }

  sendSize() {
    const r = this.canvas.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return;
    const dpr = devicePixelRatio || 1;
    // The app sizes the drawing buffer the same way: round(points × scale).
    if (!this.gl) {
      this.canvas.width = Math.max(1, Math.round(r.width * dpr));
      this.canvas.height = Math.max(1, Math.round(r.height * dpr));
    }
    this.ex.myzig_web_resize(this.id, r.width, r.height, dpr);
  }

  requestFrame() {
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      this.ex.myzig_web_animation_frame(this.id);
    });
  }

  placeTextArea(x, y, w, h, focused) {
    Object.assign(this.ta.style, { left: x + "px", top: y + "px", height: Math.max(h, 1) + "px", fontSize: Math.max(h * 0.8, 1) + "px" });
    this.focused = focused;
  }

  blit(bgra, width, height) {
    const c = this.canvas;
    if (c.width !== width) c.width = width;
    if (c.height !== height) c.height = height;
    this.ctx2d ||= c.getContext("2d");
    if (!this.image || this.image.width !== width || this.image.height !== height) this.image = new ImageData(width, height);
    const out = this.image.data;
    for (let i = 0; i < out.length; i += 4) {
      out[i] = bgra[i + 2];
      out[i + 1] = bgra[i + 1];
      out[i + 2] = bgra[i];
      out[i + 3] = 255;
    }
    this.ctx2d.putImageData(this.image, 0, 0);
    if (this.host.capture) this.host.frames.set(this.id, { width, height, rgba: new Uint8Array(out) });
  }

  mods(e) {
    return (e.shiftKey ? 1 : 0) | (e.ctrlKey || (isMac && e.metaKey) ? 2 : 0) | (e.altKey ? 4 : 0);
  }

  point(e) {
    const r = this.canvas.getBoundingClientRect();
    return [e.clientX - r.left, e.clientY - r.top];
  }

  /// Clicks in a row, as the system counts them.
  count(e, x, y) {
    if (e.detail > 0) return e.detail;
    const c = this.clicks, now = performance.now();
    c.n = now - c.at < 500 && Math.abs(x - c.x) < 4 && Math.abs(y - c.y) < 4 ? c.n + 1 : 1;
    Object.assign(c, { at: now, x, y });
    return c.n;
  }

  text(kind, s) {
    this.ex.myzig_web_text(this.id, kind, this.host.put(s));
  }

  listen() {
    const c = this.canvas, ta = this.ta, id = this.id, ex = this.ex;
    c.addEventListener("pointermove", (e) => {
      const [x, y] = this.point(e);
      ex.myzig_web_pointer(id, 0, x, y, 0, 0, this.mods(e));
    });
    c.addEventListener("pointerdown", (e) => {
      const [x, y] = this.point(e);
      if (e.button === 0) c.setPointerCapture(e.pointerId);
      if (ex.myzig_web_pointer(id, 1, x, y, e.button, this.count(e, x, y), this.mods(e))) e.preventDefault();
      ta.focus({ preventScroll: true });
    });
    c.addEventListener("pointerup", (e) => {
      const [x, y] = this.point(e);
      if (ex.myzig_web_pointer(id, 2, x, y, e.button, 0, this.mods(e))) e.preventDefault();
    });
    c.addEventListener("pointerleave", (e) => ex.myzig_web_pointer(id, 3, 0, 0, 0, 0, this.mods(e)));
    c.addEventListener("contextmenu", (e) => e.preventDefault());
    c.addEventListener("wheel", (e) => {
      const [x, y] = this.point(e);
      // Lines and pages in pixels, about as desktops scroll them.
      const dy = e.deltaY * (e.deltaMode === 1 ? 40 : e.deltaMode === 2 ? c.clientHeight : 1);
      if (ex.myzig_web_wheel(id, x, y, dy, this.mods(e))) e.preventDefault();
    }, { passive: false });
    ta.addEventListener("keydown", (e) => {
      if (e.isComposing || e.keyCode === 229) return;
      if (ex.myzig_web_key(id, false, this.host.put(e.key + " " + (e.code || "")), this.mods(e), e.repeat)) e.preventDefault();
    });
    ta.addEventListener("keyup", (e) => {
      if (e.isComposing) return;
      if (ex.myzig_web_key(id, true, this.host.put(e.key + " " + (e.code || "")), this.mods(e), false)) e.preventDefault();
    });
    ta.addEventListener("input", (e) => {
      if (e.isComposing) return;
      const s = ta.value;
      ta.value = "";
      if (s) this.text(0, s);
    });
    ta.addEventListener("compositionupdate", (e) => this.text(1, e.data || ""));
    ta.addEventListener("compositionend", (e) => {
      ta.value = "";
      this.text(2, e.data || "");
    });
    ta.addEventListener("paste", (e) => {
      e.preventDefault();
      const s = e.clipboardData?.getData("text/plain") || "";
      if (s) this.text(3, s);
    });
    ta.addEventListener("focus", () => ex.myzig_web_focus(id, true));
    ta.addEventListener("blur", () => ex.myzig_web_focus(id, false));
  }
}
