// Runs an app of myzig built for browsers (wasm32-wasi) headless under
// Node: the host's WASI (host_wasi.js) with fonts, the page's functions
// stubbed (no WebGL: frames are drawn on the CPU and kept here), then
// checks a frame draws and clicking a text changes the view.
//
//   node src/web/test_node.mjs app.wasm FONT_DIR "Increment" "1"
//
// clicks the text "Increment" (after the first frame) and expects the
// text "1" to show; prints "web: ok" and exits 0 when it does.
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { deflateSync } from "node:zlib";
import { writeFileSync } from "node:fs";
import { Wasi, Exit } from "./host_wasi.js";

const [wasmPath, fontDir, click = "", expect = ""] = process.argv.slice(2);
const fail = (what) => { console.error("web: FAIL " + what); process.exit(1); };

const wasi = new Wasi(["app"], {});
if (fontDir) for (const f of readdirSync(fontDir)) if (/\.tt[fc]$/i.test(f)) wasi.writeFile("/usr/share/fonts/" + f, new Uint8Array(readFileSync(join(fontDir, f))));

const running = {};
const frames = [];
let ex, windows = [], wantFrame = new Set(), timers = [];
const str = (p, n) => new TextDecoder().decode(new Uint8Array(ex.memory.buffer, p, n).slice());
const myzig = {
  window_open: (id) => windows.push(id),
  window_close: (id) => { windows = windows.filter((w) => w !== id); },
  window_title: () => {},
  request_frame: (id) => wantFrame.add(id),
  set_cursor: () => {},
  text_area: () => {},
  set_timeout: (ms, token) => timers.push(token),
  clipboard_write: () => {},
  open_url: () => false,
  message: () => 0,
  is_dark: () => false,
  languages: () => 0,
  beep: () => {},
  run: () => { throw running; },
  quit: () => {},
  gl_init: () => false,
  gl_atlas: () => {},
  gl_images: () => {},
  gl_draw: () => {},
  gl_fx: () => {},
  gl_effect: () => {},
  blit: (id, ptr, w, h) => frames.push({ id, w, h, px: new Uint8Array(ex.memory.buffer, ptr, w * h * 4).slice() }),
};
const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), { wasi_snapshot_preview1: wasi.imports(), myzig });
ex = instance.exports;
wasi.memory = ex.memory;
try {
  ex._start();
  fail("main returned without running");
} catch (e) {
  if (e instanceof Exit) fail("exited " + e.code);
  if (e !== running) throw e;
}
if (windows.length !== 1) fail("windows: " + windows.length);
const id = windows[0];

function animate() {
  // The animation frames the app asks for, until it asks for none.
  for (let i = 0; i < 120 && wantFrame.size; i++) {
    const ids = [...wantFrame];
    wantFrame.clear();
    for (const w of ids) ex.myzig_web_animation_frame(w);
  }
}
const put = (s) => {
  const b = new TextEncoder().encode(s);
  new Uint8Array(ex.memory.buffer, ex.myzig_web_buffer(b.length), b.length).set(b);
  return b.length;
};
const find = (s) => {
  if (!ex.myzig_web_find_text(id, put(s))) return null;
  return [...new Float32Array(ex.memory.buffer, ex.myzig_web_found(), 4)];
};

ex.myzig_web_resize(id, 480, 320, 2);
animate();
if (frames.length === 0) fail("no frame drawn");
const f = frames[frames.length - 1];
if (f.w !== 960 || f.h !== 640) fail(`frame ${f.w}x${f.h}`);
// Not one color: text and buttons drew.
const colors = new Set();
for (let i = 0; i < f.px.length; i += 4 * 97) colors.add(f.px[i] | (f.px[i + 1] << 8) | (f.px[i + 2] << 16));
if (colors.size < 3) fail("a frame of " + colors.size + " colors");

const idle = frames.length;
animate();
if (frames.length !== idle) fail("frames while idle");

if (click) {
  const r = find(click) || fail("no text " + click);
  const x = r[0] + r[2] / 2, y = r[1] + r[3] / 2;
  ex.myzig_web_pointer(id, 0, x, y, 0, 0, 0);
  ex.myzig_web_pointer(id, 1, x, y, 0, 1, 0);
  ex.myzig_web_pointer(id, 2, x, y, 0, 0, 0);
  animate();
  if (expect && !find(expect)) fail("no text " + expect + " after clicking " + click);
}
if (find("Pinch demo")) {
  if (!ex.myzig_web_pinch(id, 30, 30, 2, 0)) fail("pinch not taken");
  if (!find("Scale 4.00")) fail("pinch did not scale");
  if (!ex.myzig_web_scroll(id, 30, 30, 12, 8, true, 0)) fail("pan not taken");
  if (!find("Pan 20")) fail("scroll lost its deltas");
  if (ex.myzig_web_pinch(id, 470, 310, 2, 0)) fail("pinch outside handler taken");
  if (ex.myzig_web_pinch(id, 30, 30, 0, 0)) fail("invalid pinch taken");
}
if (process.env.MYZIG_WEB_PNG) writePng(process.env.MYZIG_WEB_PNG, frames[frames.length - 1]);
console.log(`web: ok (${frames.length} frames, ${colors.size}+ colors)`);

/// The frame as a PNG (BGRA to RGB), to look at.
function writePng(path, { w, h, px }) {
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const i = (y * w + x) * 4, o = y * (w * 3 + 1) + 1 + x * 3;
    raw[o] = px[i + 2]; raw[o + 1] = px[i + 1]; raw[o + 2] = px[i];
  }
  const crc = (b) => { let c = ~0; for (const v of b) { c ^= v; for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1)); } return ~c >>> 0; };
  const chunk = (t, d) => { const b = Buffer.concat([Buffer.from(t), d]); const out = Buffer.alloc(d.length + 12); out.writeUInt32BE(d.length); b.copy(out, 4); out.writeUInt32BE(crc(b), d.length + 8); return out; };
  const head = Buffer.alloc(13); head.writeUInt32BE(w); head.writeUInt32BE(h, 4); head[8] = 8; head[9] = 2;
  writeFileSync(path, Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", head), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]));
}
