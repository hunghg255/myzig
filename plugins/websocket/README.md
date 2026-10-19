# websocket

A WebSocket client for myzig apps, after mygo's
[WebSocket plugin](../../../mygo/docs/plugins/websocket.md): RFC 6455 in
Zig (`Conn`), and for pages a `WebSocket` with the browser's API whose
connections Zig makes, so that it:

- sends any header with the opening handshake (`Authorization`, `Cookie`,
  `Origin`…);
- is not subject to the page's Content Security Policy;
- keeps the messages of a fast server in Zig while the page is behind.

`wss:` is TLS with the system's certificates: the handshake goes through
`std.http.Client`, whose connection the frames then use.

## From pages

```zig
const websocket = @import("websocket");

var service: websocket.Service = try .init(gpa, app.io, .{}); // on the main thread
defer service.deinit();
try app.bind(&service);
try app.registerEvent(websocket.PartEvent);
// … .assets = &.{ index_html, websocket.asset }
```

```js
import { WebSocket } from "/plugins/websocket.js";

const ws = new WebSocket("wss://example.com/live", ["v1"], {
  headers: { authorization: `Bearer ${token}` },
});
ws.binaryType = "arraybuffer";
ws.onopen = () => ws.send(JSON.stringify({ subscribe: "prices" }));
ws.onmessage = (e) => console.log(e.data);
ws.onclose = (e) => console.log(e.code, e.reason, e.wasClean);
```

- The browser's API: `ws:`/`wss:` URLs (`http:` and `https:` become them,
  relative ones resolve against the page's), subprotocols (`protocol` once
  open), `readyState`, `send` of strings, `ArrayBuffer`s, typed arrays and
  `Blob`s (in the order sent), `bufferedAmount` (bytes Zig has not written
  yet), `binaryType`, `close(code, reason)` (1000 or 3000–4999, at most 123
  bytes), and `open`, `message`, `error` and `close` events.
- `send` throws while connecting; messages after closing are dropped.
- Zig answers pings, reassembles fragmented messages, and fails the
  connection (1002, 1007, 1009) when the server breaks the protocol, sends
  invalid UTF-8 or a message over `max_message_size` (64 MiB). The page
  then gets `error`, then `close` with 1006, and the console says why.
- After `close()`, Zig waits `close_timeout_ms` (5 s) for the server's
  close (`wasClean`, the server's code and reason), then drops the
  connection (1006).
- Zig reads no further while the page has more than `window_bytes` (1 MiB)
  of messages to handle.
- A connection whose window closed is dropped (going away, 1001) when its
  next event arrives; `service.deinit` drops the rest.
- No extensions (permessage-deflate) are negotiated.
- `Options.allow` sees each connection's URL and headers and may refuse it.

Each connection is two tasks on the app's `Io`: one connects and reads,
one writes what the page sends; their events reach the page through the
main thread (package [`mainthread`](../mainthread)).

## From Zig

```zig
var client: std.http.Client = .{ .allocator = gpa, .io = io };
defer client.deinit();
const c = try websocket.Conn.connect(&client, gpa, "wss://example.com/live", .{
    .protocols = &.{"v1"},
    .headers = &.{.{ .name = "Authorization", .value = "Bearer …" }},
});
defer c.deinit();
try c.send(.text, "hello");
switch (try c.read(gpa)) { // blocks: pings are answered, fragments joined
    .text => |t| …, // gpa's
    .binary => |b| …,
    .close => |cl| …, // the server's code and reason; its close was echoed
}
try c.close(1000, "done"); // then read until .close
```

Reads and writes may run on two threads at once (writes are serialized);
`shutdown()` stops a blocked read from another thread. `frame.zig` is the
codec for either end (the example's server uses it as a server).

## Example and tests

`example/` runs a WebSocket server on 127.0.0.1 (`server.zig`:
std.http.Server's handshake, then this plugin's frames) and a page that
talks to it. `zig build run` shows it.

```sh
zig build test               # Conn and the frames against the in-process server, and the page, hidden
zig build test -Dpage=false  # without the page
zig build check -Dtarget=x86_64-linux-gnu
```

The tests cover RFC 6455's masking example, every length encoding, frames
that break the rules, close payloads, the accept key, echo of text and
binary messages (200 KB), headers and subprotocols, server-initiated
closes, pings, fragmentation with a ping inside, protocol errors, the
message limit, refused upgrades and `shutdown`; the page test covers the
browser API end to end. On Windows, the `shutdown` test prints a stack
trace from std (a debug build reports the socket's PIPE_DISCONNECTED as
unexpected); it passes.
