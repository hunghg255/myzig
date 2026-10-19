// Runs the test page (test_browser.js) on a static site of myzig (as
// `zig build web` makes it) in a headless Chromium (Chrome or Edge,
// hidden: no window shows), serving the site and the test page itself,
// and prints the page's verdict and console:
//
//   node src/web/test_browser_run.mjs BROWSER_EXE SITE_DIR "click=Increment&expect=1" [SCALE]
//
// SCALE is the device pixel ratio (1 by default).
//
// QUERY "index" loads the site's own index.html instead and checks the
// app started there (a window, a frame asked for or drawn).
//
// Exits 0 when the page reports "web: ok".
import { createServer } from "node:http";
import { readFile, mkdtemp, rm } from "node:fs/promises";
import { spawn } from "node:child_process";
import { join, extname, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";

const [browser, site, query = "", scale = "1"] = process.argv.slice(2);
const types = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm", ".json": "application/json", ".ttf": "font/ttf" };
const here = dirname(fileURLToPath(import.meta.url));
const testPage = `<!doctype html><html><head><meta charset="utf-8"><title>test</title><style>html,body{margin:0;height:100%}</style></head>
<body><pre id="result" hidden>running</pre><div id="myzig" style="position:absolute;inset:0"></div><script type="module" src="test_browser.js"></script></body></html>`;
const server = createServer(async (req, res) => {
  const path = decodeURIComponent(new URL(req.url, "http://x").pathname);
  try {
    const body = path === "/test.html" ? testPage
      : path === "/test_browser.js" ? await readFile(join(here, "test_browser.js"))
      : await readFile(join(site, path.endsWith("/") ? path + "index.html" : path));
    res.writeHead(200, { "content-type": types[extname(path)] || "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end();
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const index = query === "index";
const url = `http://127.0.0.1:${server.address().port}/` + (index ? "index.html" : `test.html?${query}`);
const check = index
  ? `(() => { const h = window.myzigHost; const w = h && [...h.windows.values()][0];
      return w && (w.gl || w.ctx2d) && w.canvas.width !== 300 ? "web: ok index.html: a window, its canvas " + w.canvas.width + "x" + w.canvas.height + (w.gl ? " (WebGL 2)" : "") : ""; })()`
  : "document.title";

const profile = await mkdtemp(join(tmpdir(), "myzig-web-"));
const proc = spawn(browser, ["--headless=new", `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "--enable-unsafe-swiftshader", "--use-angle=swiftshader", "--window-size=800,600", `--force-device-scale-factor=${scale}`, "--remote-debugging-port=0", "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
const ws = await new Promise((resolve, reject) => {
  let err = "";
  proc.stderr.on("data", (d) => {
    err += d;
    const m = /DevTools listening on (ws:\S+)/.exec(err);
    if (m) resolve(m[1]);
  });
  proc.on("exit", () => reject(new Error("the browser ended: " + err)));
});

let verdict = "web: FAIL no verdict in 120 s";
try {
  const sock = new WebSocket(ws);
  await new Promise((r) => sock.addEventListener("open", r));
  let next = 1;
  const waiting = new Map();
  sock.addEventListener("message", (m) => {
    const msg = JSON.parse(m.data);
    if (msg.id && waiting.has(msg.id)) waiting.get(msg.id)(msg);
    if (msg.method === "Runtime.consoleAPICalled") console.log("console:", msg.params.args.map((a) => a.value ?? a.description).join(" "));
    if (msg.method === "Runtime.exceptionThrown") console.log("exception:", msg.params.exceptionDetails.exception?.description || msg.params.exceptionDetails.text);
  });
  const send = (method, params = {}, sessionId) => new Promise((r) => {
    const id = next++;
    waiting.set(id, r);
    sock.send(JSON.stringify({ id, method, params, sessionId }));
  });
  const { result } = await send("Target.createTarget", { url: "about:blank" });
  const { result: attached } = await send("Target.attachToTarget", { targetId: result.targetId, flatten: true });
  const session = attached.sessionId;
  await send("Runtime.enable", {}, session);
  await send("Page.navigate", { url }, session);
  for (let i = 0; i < 240; i++) {
    await new Promise((r) => setTimeout(r, 500));
    const r = await send("Runtime.evaluate", { expression: check, returnByValue: true }, session);
    const title = r.result?.result?.value || "";
    if (title.startsWith("web:")) {
      verdict = title;
      break;
    }
  }
  await send("Browser.close").catch(() => {});
} finally {
  proc.kill();
  server.close();
  await rm(profile, { recursive: true, force: true }).catch(() => {});
}
console.log(verdict);
process.exit(verdict.startsWith("web: ok") ? 0 : 1);
