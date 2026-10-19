// Runs myzig's unit tests compiled for browsers (wasm32-wasi) under Node,
// with the host's WASI (host_wasi.js), the fonts of FONT_DIR at
// /usr/share/fonts, and the page's functions stubbed:
//
//   zig test -target wasm32-wasi --test-no-exec -femit-bin=tests.wasm ...
//   node src/web/test_wasm.mjs tests.wasm FONT_DIR
//
// Exits with the tests' status.
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { Wasi, Exit } from "./host_wasi.js";

const [wasmPath, fontDir] = process.argv.slice(2);
const wasi = new Wasi(["tests"], {});
if (fontDir) for (const f of readdirSync(fontDir)) if (/\.tt[fc]$/i.test(f)) wasi.writeFile("/usr/share/fonts/" + f, new Uint8Array(readFileSync(join(fontDir, f))));
// The page's functions do nothing here (no canvas, no browser).
const myzig = new Proxy({}, { get: (_, name) => (name === "run" ? () => { throw new Error("run in a test"); } : () => 0) });
const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), { wasi_snapshot_preview1: wasi.imports(), myzig });
wasi.memory = instance.exports.memory;
let code = 0;
try {
  instance.exports._start();
} catch (e) {
  if (!(e instanceof Exit)) throw e;
  code = e.code;
}
process.exit(code);
