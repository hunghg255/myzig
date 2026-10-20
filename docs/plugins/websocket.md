# websocket

A WebSocket client: RFC 6455 in Zig (`websocket.Conn`), and for pages a
`WebSocket` with the browser's API whose connections Zig makes, so that it:

- sends any header with the opening handshake (`Authorization`, `Cookie`,
  `Origin`...);
- is not subject to the page's Content Security Policy;
- keeps the messages of a fast server in Zig while the page is behind.

`wss:` is TLS with the system's certificates: the handshake goes through
`std.http.Client`, whose connection the frames then use.

The package is `plugins/websocket` (module `websocket`); it depends on
[mainthread](mainthread.md). See [Plugins](../plugins.md) for adding it to
an app.

## From pages

```zig
const websocket = @import("websocket");

var service: websocket.Service = try .init(gpa, app.io, .{}); // on the main thread
defer service.deinit();
try app.bind(&service);
try app.registerEvent(websocket.PartEvent);
// ... .assets = &.{ index_html, websocket.asset }
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

The page's `WebSocket` has the browser's API, plus a third argument with
`headers`:

- `ws:` and `wss:` URLs (`http:` and `https:` become them, relative ones
  resolve against the page's), subprotocols (`protocol` once open),
  `readyState`, `bufferedAmount` (bytes Zig has not written yet),
  `binaryType`, and `open`, `message`, `error` and `close` events.
- `send` takes strings, `ArrayBuffer`s, typed arrays and `Blob`s, sent in
  order; it throws while connecting, and messages after closing are
  dropped.
- `close(code, reason)` takes 1000 or 3000 to 4999 and a reason of at most
  123 bytes. Zig then waits `close_timeout_ms` for the server's close
  (`wasClean`, with the server's code and reason), and drops the connection
  otherwise (1006).
- Zig answers pings, reassembles fragmented messages, and fails the
  connection (1002, 1007, 1009) when the server breaks the protocol, sends
  invalid UTF-8 or a message over `max_message_size`. The page then gets
  `error`, then `close` with 1006, and the console says why.
- Zig reads no further while the page has more than `window_bytes` of
  messages to handle.
- A page's connections are dropped (going away, 1001) when the page
  navigates, reloads or closes, even those waiting for it to read;
  `service.deinit` drops the rest.
- No extensions (permessage-deflate) are negotiated.

### Options

`websocket.ServiceOptions`:

| field | default | |
|---|---|---|
| `allow` | null | `fn (ctx, url, headers: []const websocket.Header) bool`: may refuse a connection |
| `allow_ctx` | null | passed to `allow` |
| `max_message_size` | 64 MiB | the largest message from a server |
| `close_timeout_ms` | 5000 | how long a closing connection waits for the server's close |
| `window_bytes` | 1 MiB | messages the page may have unhandled before Zig stops reading |

Each connection is two tasks on the app's `Io`: one connects and reads, one
writes what the page sends. Their events (`myzig-websocket`) reach the page
through the main thread ([mainthread](mainthread.md)).

## From Zig

```zig
var client: std.http.Client = .{ .allocator = gpa, .io = io };
defer client.deinit();
const c = try websocket.Conn.connect(&client, gpa, "wss://example.com/live", .{
    .protocols = &.{"v1"},
    .headers = &.{.{ .name = "Authorization", .value = "Bearer ..." }},
});
defer c.deinit();
try c.send(.text, "hello");
switch (try c.read(gpa)) { // blocks: pings are answered, fragments joined
    .text => |t| std.log.info("{s}", .{t}), // allocated with gpa
    .binary => |b| gpa.free(b),
    .close => |cl| std.log.info("closed {d}", .{cl.code}), // the server's close, echoed
}
try c.close(1000, "done"); // then read until .close
```

- `Options`: `protocols`, `headers`, `max_message_size` (64 MiB).
- `send(.text or .binary, data)`, `ping(data)`, `close(code, reason)`,
  `fail(code)` (closes at once, as for a protocol error).
- Reads and writes may run on two threads at once (writes are serialized);
  `shutdown()` stops a blocked `read` from another thread.
- `websocket.frame` is the codec for either end; the example's server uses
  it as a server. `websocket.Code` names the close codes.

## Example and tests

`example/` runs a WebSocket server on 127.0.0.1 (`example/server.zig`:
`std.http.Server`'s handshake, then this plugin's frames) and a page that
talks to it; `zig build run` shows it.

```sh
cd plugins/websocket
zig build test               # Conn and the frames against the in-process server, and the page, hidden
zig build test -Dpage=false  # without the page
zig build check -Dtarget=x86_64-linux-gnu
```

The tests cover RFC 6455's masking example, every length encoding, frames
that break the rules, close payloads, the accept key, echo of text and
binary messages (200 KB), headers and subprotocols, server-initiated
closes, pings, fragmentation with a ping inside, protocol errors, the
message limit, refused upgrades and `shutdown`; the page test covers the
browser API end to end. On Windows the `shutdown` test prints a stack trace
from the standard library (a debug build reports the socket's
`PIPE_DISCONNECTED` as unexpected), and passes.
