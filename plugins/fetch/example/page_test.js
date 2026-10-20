(async () => {
  const expect = (ok, what) => { if (!ok) throw new Error(what); };
  const { fetch } = await import("/plugins/fetch.js");
  const base = await myzig.call("Demo.base");

  // After the reload below: the request the last document left waiting
  // for it to read was canceled with it.
  if (sessionStorage.getItem("reloaded")) {
    const after = await myzig.call("Demo.requests");
    expect(after === 0, "requests left by the last document: " + after);
    return true;
  }

  const hello = await fetch(base + "/hello", { headers: { origin: "https://example.com" } });
  expect(hello.ok && hello.status === 200 && hello.statusText === "OK", "status " + hello.status);
  expect(hello.headers.get("x-test") === "1" && !hello.headers.has("set-cookie"), "headers");
  expect((await hello.text()) === "hello", "body");

  const echo = await fetch(base + "/echo", { method: "PUT", headers: { "x-custom": "abc" }, body: "the body" });
  expect((await echo.text()) === "PUT\nabc\nthe body", "echo");

  const redirected = await fetch(base + "/redirect");
  expect(redirected.redirected && redirected.url.endsWith("/hello"), "redirect " + redirected.url);
  const manual = await fetch(base + "/redirect", { redirect: "manual" });
  expect(manual.status === 302 && manual.headers.get("location") === "/hello", "manual");

  // Streams: "one" arrives while the server holds "two".
  const res = await fetch(base + "/stream");
  const reader = res.body.getReader();
  const first = await reader.read();
  expect(new TextDecoder().decode(first.value) === "one", "first chunk");
  await myzig.call("Demo.openGate");
  let rest = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    rest += new TextDecoder().decode(value);
  }
  expect(rest === "two", "rest " + rest);

  // A large body, read whole while Zig waits for the page.
  const big = await fetch(base + "/big");
  expect((await big.arrayBuffer()).byteLength === 3 << 20, "big");

  // Aborted after the response came: reading rejects with the reason.
  const ctrl = new AbortController();
  const aborted = await fetch(base + "/big", { signal: ctrl.signal });
  const r2 = aborted.body.getReader();
  await r2.read();
  ctrl.abort(new Error("stop"));
  let err = "";
  try { for (;;) { if ((await r2.read()).done) break; } } catch (e) { err = String(e); }
  expect(err.includes("stop"), "abort " + err);

  err = "";
  try { await fetch("http://127.0.0.1:1/"); } catch (e) { err = e instanceof TypeError ? "TypeError " + e.message : String(e); }
  expect(err.startsWith("TypeError fetch failed"), "unreachable " + err);

  // A body of 3 MiB left unread as the page reloads: past its window of
  // unread bytes, the request waits for the page.
  const left = await fetch(base + "/big");
  expect(left.ok, "big");
  const before = await myzig.call("Demo.requests");
  expect(before === 1, "requests before the reload: " + before);
  sessionStorage.setItem("reloaded", "1");
  location.reload();
  return false;
})().then((done) => {
  if (!done) return;
  myzig.log("ok");
  myzig.window.close();
}, (e) => {
  myzig.log("FAIL", String(e));
  myzig.window.close();
});
