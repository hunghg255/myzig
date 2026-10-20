(async () => {
  const expect = (ok, what) => { if (!ok) throw new Error(what); };
  const { WebSocket } = await import("/plugins/websocket.js");
  const base = await myzig.call("Demo.base");
  const next = (ws, type) => new Promise((resolve) => ws.addEventListener(type, resolve, { once: true }));

  // After the reload below: the last document's connections closed with
  // it; this one's own (index.html keeps one) may be open already.
  if (sessionStorage.getItem("reloaded")) {
    const after = await myzig.call("Demo.connections");
    expect(after <= 1, "connections left by the last document: " + after);
    return true;
  }

  // Headers and subprotocols on the handshake; the server closes.
  const hello = new WebSocket(base.replace("ws:", "http:") + "/hello", ["v2", "v1"], { headers: { "x-token": "abc" } });
  const got = [];
  hello.onmessage = (e) => got.push(e.data);
  await next(hello, "open");
  expect(hello.protocol === "v2" && hello.readyState === WebSocket.OPEN, "protocol " + hello.protocol);
  const closed = await next(hello, "close");
  expect(got.join("|") === "token: abc|protocol: v2", "messages " + got.join("|"));
  expect(closed.code === 4000 && closed.reason === "bye" && closed.wasClean, "server close " + closed.code);

  // Echo: text, then binary in order, then a clean close of ours.
  const echo = new WebSocket(base + "/echo");
  echo.binaryType = "arraybuffer";
  let threw = false;
  try { echo.send("too early"); } catch (e) { threw = e.name === "InvalidStateError"; }
  expect(threw, "send while connecting");
  await next(echo, "open");
  const messages = [];
  echo.onmessage = (e) => messages.push(e.data);
  echo.send("one");
  echo.send(new Uint8Array([1, 2, 255]));
  echo.send(new Blob(["three"]));
  expect(echo.bufferedAmount > 0, "buffered");
  while (messages.length < 3) await next(echo, "message");
  expect(messages[0] === "one", "text");
  expect(messages[1] instanceof ArrayBuffer && new Uint8Array(messages[1])[2] === 255, "binary");
  expect(new TextDecoder().decode(messages[2]) === "three", "blob in order");
  let bad = "";
  try { echo.close(1001); } catch (e) { bad = e.name; }
  expect(bad === "InvalidAccessError", "close code check " + bad);
  echo.close(1000, "done");
  const c = await next(echo, "close");
  expect(c.code === 1000 && c.reason === "done" && c.wasClean, "our close " + c.code + " " + c.reason);
  expect(echo.bufferedAmount === 0, "drained " + echo.bufferedAmount);

  // A server that breaks the protocol: error, then 1006.
  const broken = new WebSocket(base + "/bad");
  let errored = false;
  broken.onerror = () => (errored = true);
  const b = await next(broken, "close");
  expect(errored && b.code === 1006 && !b.wasClean, "protocol error " + b.code);

  // A refused upgrade.
  const refused = new WebSocket(base + "/nope");
  const r = await next(refused, "close");
  expect(r.code === 1006 && !r.wasClean, "refused");

  // A connection left open as the page reloads, with the one index.html
  // keeps.
  const left = new WebSocket(base + "/echo");
  await next(left, "open");
  const before = await myzig.call("Demo.connections");
  expect(before === 2, "connections before the reload: " + before);
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
