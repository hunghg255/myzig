// The page's half of the pages test: calls, the app's schemes, channels
// both ways, permissions, a window it opens and a download. Zig does the
// other half (main.zig) once this one calls Test.zigChecks().
const expect = (ok, what) => {
  if (!ok) throw new Error(what);
};
const app = (path) => (myzig.platform === "windows" ? "http://app.localhost" + path : "app://localhost" + path);

const run = async () => {
  // The inactive memory policy is installed when dom-ready reaches Zig.
  if (document.readyState !== "complete") {
    await new Promise((resolve) => window.addEventListener("load", resolve, { once: true }));
  }
  expect((await myzig.call("Test.ping")) === "pong", "ping");
  const memoryPolicy = await myzig.call("Test.memoryPolicy");
  expect(memoryPolicy === null || memoryPolicy === true, "inactive memory target restore");
  expect((await myzig.call("Test.ping")) === "pong", "IPC after memory target restore");
  const memoryMode = await myzig.call("Test.memoryMode");
  if (memoryMode === "ipc") return (await import("./ipc.js")).run();
  if (memoryMode) return (await import("./memory.js")).run(memoryMode);

  // WKScriptMessage handlers exist in subframes too. An opaque-origin
  // iframe must not borrow the main document's permission to call Zig.
  if (myzig.platform === "macos") {
    const frame = document.createElement("iframe");
    frame.sandbox = "allow-scripts";
    await new Promise((resolve) => {
      const received = (e) => {
        if (e.source !== frame.contentWindow || e.data !== "frame-probe-sent") return;
        window.removeEventListener("message", received);
        resolve();
      };
      window.addEventListener("message", received);
      frame.srcdoc = `<script>try{window.webkit.messageHandlers.myzig.postMessage(JSON.stringify({t:"call",id:9001,m:"Test.iframeProbe",a:[]}));}finally{parent.postMessage("frame-probe-sent","*");}<\/script>`;
      document.body.append(frame);
    });
    expect((await myzig.call("Test.iframeCalls")) === 0, "iframe invoked a bound service");
    await myzig.call("Test.iframeProbe");
    expect((await myzig.call("Test.iframeCalls")) === 1, "main-frame IPC was blocked");
    frame.remove();
  }

  // The app's scheme: status, headers, a body answered later, errors.
  const r = await fetch(app("/data.json"));
  expect(r.status === 200 && r.headers.get("x-test") === "1", "scheme status " + r.status);
  expect((await r.json()).hello === "scheme", "scheme body");
  expect((await (await fetch(app("/later"))).text()) === "part1part2", "later");
  expect((await fetch(app("/missing"))).status === 404, "404");
  const posted = await fetch(app("/echo"), { method: "POST", body: "sent" });
  expect((await posted.text()) === "POST sent", "post");
  // The frontend from disk, and client-side routes.
  expect((await (await fetch("/fromdisk.txt")).text()) === "from disk", "assets_dir");
  expect((await (await fetch("/disk%20name.txt")).text()) === "disk space", "encoded disk asset");
  expect((await (await fetch("/embedded%20name.txt")).text()) === "embedded space", "encoded embedded asset");
  expect((await (await fetch("/caf%C3%A9.txt")).text()) === "unicode", "unicode asset");
  expect((await (await fetch("/a/route")).text()).includes("<title>Pages</title>"), "route");

  // Zig sends through a channel the page made, then closes it.
  const numbers = new myzig.Channel();
  myzig.call("Test.count", 5, numbers);
  const got = [];
  for await (const n of numbers) got.push(n);
  expect(JSON.stringify(got) === "[0,1,2,3,4]", "count " + JSON.stringify(got));

  // The page sends to Zig.
  const up = new myzig.Channel();
  await myzig.call("Test.upload", up);
  for (const v of ["a", "b", "c"]) await up.send(v);
  up.close();
  expect((await myzig.call("Test.uploaded")) === "a,b,c", "upload");

  // Backpressure: Zig fills the window, waits for the page to take the
  // values, then says it drained.
  const flood = new myzig.Channel();
  const sent = await myzig.call("Test.flood", flood);
  expect(sent > 1, "flood sent " + sent);
  let taken = 0;
  let last = null;
  for await (const v of flood) {
    taken++;
    last = v;
  }
  expect(taken === sent + 1 && last === "drained", "flood taken " + taken + " last " + String(last).slice(0, 10));

  // A channel Zig opened.
  const logs = await new Promise((resolve) => myzig.onChannel("logs", resolve));
  const lines = [];
  for await (const l of logs) lines.push(l.text);
  expect(lines.join("|") === "hello|world", "logs " + lines.join("|"));

  // Permissions go to the app, which grants notifications.
  if (typeof Notification !== "undefined") {
    await myzig.call("Test.permissionWas", Notification.permission);
    const p = await Notification.requestPermission();
    expect(p === "granted", "notification permission " + p);
  }

  // A window the page opens goes to the app's listener.
  window.open("https://example.org/opened");

  // A download, which Zig saves where it chose and tells of.
  const downloaded = new Promise((resolve) => myzig.once("downloaded", resolve));
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob(["downloaded bytes"], { type: "text/plain" }));
  a.download = "notes.txt";
  document.body.append(a);
  a.click();
  const d = await downloaded;
  expect(d.ok, "download " + JSON.stringify(d));

  await myzig.call("Test.zigChecks");
};

run().catch((e) => {
  myzig.log("FAIL", String(e && e.message ? e.message : e));
  myzig.window.close();
});
