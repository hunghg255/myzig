# fetch

HTTP(S) requests for myzig apps, after mygo's
[fetch plugin](../../../mygo/docs/plugins/fetch.md): from Zig with
`fetch.perform`, and from pages with a standard `fetch` whose requests
leave from Zig (`std.http.Client`), so that:

- they are not subject to CORS: any server answers, and every response
  header is readable but `Set-Cookie`;
- they may set any header, `Origin`, `Cookie`, `Referer` and `User-Agent`
  included;
- the body streams to the page as Zig reads it, and aborting cancels the
  request in Zig.

## From pages

```zig
const fetch = @import("fetch");

var service: fetch.Service = try .init(gpa, app.io, .{}); // on the main thread
defer service.deinit();
try app.bind(&service);
try app.registerEvent(fetch.PartEvent);
// … .assets = &.{ index_html, fetch.asset }
```

```js
import { fetch } from "/plugins/fetch.js";

const res = await fetch("https://api.example.com/items", {
  method: "POST",
  headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
  body: JSON.stringify({ name: "Ada" }),
});
const reader = res.body.pipeThrough(new TextDecoderStream()).getReader(); // streams
```

- It takes `fetch`'s arguments (a URL, a `Request`, the options) and
  returns a `Response`. Bodies are read whole before the request starts.
  `redirect: "follow"` (up to 20, setting `redirected` and `url`),
  `"manual"` (the redirect response itself) or `"error"`.
- A failed request (unreachable, TLS, too many redirects) rejects with a
  `TypeError` whose message says why; a response of any status resolves.
- Aborting the `signal` cancels the request before or after its response
  came; so does `res.body.cancel()`.
- Zig reads no faster than the page: it waits while the page has more
  than `window_bytes` (1 MiB) of the body yet to read.
- URLs that are not http or https go to the webview's `fetch`.
- `Options.allow` sees each request (URL, method, headers) and may refuse
  it.

How it works: each request runs on a task of the app's `Io`
(`Io.concurrent`); its head, body chunks and end come back as
`myzig-fetch` events, handed to the main thread (package
[`mainthread`](../mainthread)) and given to the window that asked, if it
is still open; a closed window's requests are canceled. Cancelation is
`Io`'s, so a request blocked on the network stops at once.

## From Zig

```zig
var client: std.http.Client = .{ .allocator = gpa, .io = io };
defer client.deinit();
try fetch.perform(&client, arena, .{ .url = "https://example.com", .headers = &.{.{ .name = "accept", .value = "text/html" }} }, .{
    .ctx = &state,
    .head = State.onHead, // status, status_text, url, redirected, headers
    .chunk = State.onChunk, // the body as it arrives, at most 64 KiB at a time
});
```

`perform` blocks: run it on a thread or with `io.concurrent`, whose
`cancel` stops it.

## Not yet

- Proxies (`HTTPS_PROXY`): `std.http.Client.initDefaultProxies` can set
  them on the service's `client`.
- A request body redirected with 307 or 308 fails (`RedirectRequiresResend`);
  301, 302 and 303 become GETs as in browsers.
- Methods outside `std.http.Method` (custom verbs) are refused.

## Example and tests

`example/` runs a small API on 127.0.0.1 (`api.zig`) and a page that
fetches from it. `zig build run` shows it.

```sh
zig build test               # perform against the local API (started in the test), and the page, hidden
zig build test -Dpage=false  # without the page
zig build check -Dtarget=x86_64-linux-gnu
```

The tests cover headers (Set-Cookie dropped), bodies, the three redirect
modes and redirect loops, streaming (the first chunk arrives before the
server sends the second), cancelation while the server is silent, large
bodies, unreachable servers and HEAD; the page test covers the same through
the webview, with abort and backpressure.
