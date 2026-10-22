// A test of an app of myzig in a real browser (headless): the page loads
// the app as index.html does, then checks that frames draw with WebGL 2
// and match the CPU renderer's pixels, that nothing draws while idle, and
// that clicking a text (DOM pointer events on the canvas) changes the
// view. The result goes into the element `#result` and the title, as
// "web: ok ..." or "web: FAIL ...", for `--dump-dom`.
//
//   test.html?click=Increment&expect=1
//   test.html?click=Tasks&click=2%20of%203%20left&dy=-44&type=Hi&key=Enter&expect=Hi
//
// Texts are clicked in turn; `dy` moves the last click from the text's middle (CSS pixels), `type` is
// typed into the text area (an input event), then `key` is pressed.
import { start } from "./host.js";

const params = new URLSearchParams(location.search);
const result = document.getElementById("result");
const report = (s) => { result.textContent = s; document.title = s; };
const tick = () => new Promise((r) => requestAnimationFrame(() => r()));

async function settle(host) {
  // Until no frame is asked for a few animation frames in a row.
  for (let quiet = 0, i = 0; quiet < 4 && i < 600; i++) {
    await tick();
    quiet = [...host.windows.values()].some((w) => w.frame) ? 0 : quiet + 1;
  }
}

function compare(host, id) {
  const ex = host.exports;
  const gl = host.frames.get(id);
  if (!gl) throw new Error("no frame drawn");
  const ptr = ex.myzig_web_cpu_pixels(id);
  const size = ex.myzig_web_pixels_size(id);
  const w = size >>> 16, h = size & 0xffff;
  if (w !== gl.width || h !== gl.height) throw new Error(`sizes: WebGL ${gl.width}x${gl.height}, CPU ${w}x${h}`);
  const cpu = new Uint8Array(ex.memory.buffer, ptr, w * h * 4);
  let max = 0, off = 0, colors = new Set();
  for (let i = 0; i < w * h * 4; i += 4) {
    const d = Math.max(Math.abs(cpu[i + 2] - gl.rgba[i]), Math.abs(cpu[i + 1] - gl.rgba[i + 1]), Math.abs(cpu[i] - gl.rgba[i + 2]));
    if (d > max) max = d;
    if (d > 2) off++;
    if (i % 388 === 0) colors.add(gl.rgba[i] | (gl.rgba[i + 1] << 8) | (gl.rgba[i + 2] << 16));
  }
  return { w, h, max, off, colors: colors.size };
}

function find(host, id, s) {
  const ex = host.exports;
  if (!ex.myzig_web_find_text(id, host.put(s))) return null;
  return new Float32Array(ex.memory.buffer, ex.myzig_web_found(), 4).slice();
}

function click(host, id, r) {
  const canvas = host.windows.get(id).canvas;
  const b = canvas.getBoundingClientRect();
  const at = { clientX: b.left + r[0] + r[2] / 2, clientY: b.top + r[1] + r[3] / 2, pointerId: 1, isPrimary: true, bubbles: true, button: 0, detail: 1 };
  canvas.dispatchEvent(new PointerEvent("pointermove", { ...at, buttons: 0 }));
  canvas.dispatchEvent(new PointerEvent("pointerdown", { ...at, buttons: 1 }));
  canvas.dispatchEvent(new PointerEvent("pointerup", { ...at, buttons: 0 }));
}

// Exercise the host's actual WheelEvent listener, not just the WASM exports.
async function gestures(host, id) {
  const canvas = host.windows.get(id).canvas;
  const bounds = canvas.getBoundingClientRect();
  const wheel = async (options, taken = true) => {
    const event = new WheelEvent("wheel", {
      clientX: bounds.left + 30, clientY: bounds.top + 30,
      bubbles: true, cancelable: true, ...options,
    });
    canvas.dispatchEvent(event);
    if (event.defaultPrevented !== taken) throw new Error("incorrect wheel preventDefault");
    await settle(host);
  };
  const text = (s) => { if (!find(host, id, s)) throw new Error("no text " + s); };
  text("Scale 1.00");
  await wheel({ deltaY: -Math.log(2) * 100, ctrlKey: true });
  text("Scale 2.00");
  await wheel({ deltaY: Math.log(2) * 100, ctrlKey: true });
  text("Scale 1.00");
  await wheel({ deltaX: 12, deltaY: 8 });
  text("Pan 20");
  await wheel({ deltaX: 2, deltaY: -1, deltaMode: WheelEvent.DOM_DELTA_LINE });
  text("Pan 60");
  await wheel({ deltaX: 1, deltaMode: WheelEvent.DOM_DELTA_PAGE });
  text(`Pan ${60 + canvas.clientWidth}`);
  // Ctrl with line deltas stays scrolling, rather than zooming.
  await wheel({ deltaY: 1, deltaMode: WheelEvent.DOM_DELTA_LINE, ctrlKey: true });
  text(`Pan ${100 + canvas.clientWidth}`);
  text("Scale 1.00");
  // Events outside the handler leave the browser's default behavior alone.
  const outside = { clientX: bounds.right - 1, clientY: bounds.bottom - 1 };
  await wheel({ deltaY: 20, ...outside }, false);
  await wheel({ deltaY: -20, ctrlKey: true, ...outside }, false);
  text("Scale 1.00");
  text(`Pan ${100 + canvas.clientWidth}`);
}

// `theme=dark` (or light) is the page's choice of appearance.
if (params.get("theme")) document.documentElement.dataset.myzigTheme = params.get("theme");
try {
  const host = await start({ wasm: "app.wasm", fonts: "fonts/", webgl: params.get("webgl") !== "0" });
  host.capture = true;
  await settle(host);
  const id = [...host.windows.keys()][0];
  if (id === undefined) throw new Error("no window");
  const webgl = host.exports.myzig_web_uses_webgl(id);
  const first = compare(host, id);
  if (first.colors < 3) throw new Error(`a frame of ${first.colors} colors`);
  // The corner is the theme's background: dark or light as asked.
  const corner = host.frames.get(id).rgba[0];
  if (params.get("theme") === "dark" ? corner > 64 : corner < 192) throw new Error("the background is " + corner);
  const drawn = host.frames.get(id);
  for (let i = 0; i < 10; i++) await tick();
  if (host.frames.get(id) !== drawn) throw new Error("frames while idle");
  if (params.has("gestures")) await gestures(host, id);
  let after = null;
  const clicks = params.getAll("click");
  const what = clicks.join(", ");
  if (clicks.length) {
    for (const [i, t] of clicks.entries()) {
      const r = find(host, id, t);
      if (!r) throw new Error("no text " + t);
      if (i === clicks.length - 1) r[1] += Number(params.get("dy") || 0);
      click(host, id, r);
      await settle(host);
    }
    const ta = host.windows.get(id).ta;
    if (params.get("type")) {
      ta.value = params.get("type");
      ta.dispatchEvent(new InputEvent("input", { data: ta.value, inputType: "insertText" }));
      await settle(host);
    }
    if (params.get("key")) {
      for (const t of ["keydown", "keyup"]) ta.dispatchEvent(new KeyboardEvent(t, { key: params.get("key"), bubbles: true }));
      await settle(host);
    }
    const want = params.get("expect");
    if (want && !find(host, id, want)) throw new Error(`no text ${want} after clicking ${what}`);
    after = compare(host, id);
  }
  const bad = [first, after].filter((c) => c && c.off > c.w * c.h * 0.001);
  const line = `${webgl ? "WebGL 2" : "CPU"} ${first.w}x${first.h}: max diff ${first.max}, ${first.off} px > 2` + (after ? `; after the click: max diff ${after.max}, ${after.off} px > 2` : "");
  if (!webgl && params.get("webgl") !== "0") throw new Error("no WebGL 2 (" + line + ")");
  if (bad.length) throw new Error("WebGL and CPU pixels differ: " + line);
  report("web: ok " + line);
} catch (e) {
  report("web: FAIL " + (e && e.stack ? e.stack : e));
}
