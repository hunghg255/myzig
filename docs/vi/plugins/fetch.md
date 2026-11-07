# fetch

Request HTTP và HTTPS do Zig thực hiện (`std.http.Client`). Trang web dùng một `fetch` chuẩn; Zig dùng `fetch.perform`. Request đi ra từ Zig chứ không phải từ webview, nên:

- chúng không bị CORS ràng buộc: server nào cũng trả lời, và mọi header của response đều đọc được trừ `Set-Cookie`;
- chúng đặt được bất kỳ header nào, kể cả `Origin`, `Cookie`, `Referer` và `User-Agent`;
- body được stream tới trang ngay khi Zig đọc, và abort sẽ hủy request ở phía Zig.

Package là `plugins/fetch` (module `fetch`). Nó phụ thuộc [mainthread](mainthread.md). Xem [Plugins](../plugins.md) để thêm nó vào app.

<a id="from-pages"></a>

## Từ trang web

Bind service, đăng ký event của nó và phục vụ client của nó:

```zig
const fetch = @import("fetch");

var service: fetch.Service = try .init(gpa, app.io, .{}); // on the main thread
defer service.deinit();
try app.bind(&service);
try app.registerEvent(fetch.PartEvent);
// ... .content = .{ .page = .{ .url = "/", .assets = &.{ index_html, fetch.asset } } }
```

```js
import { fetch } from "/plugins/fetch.js";

const res = await fetch("https://api.example.com/items", {
  method: "POST",
  headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
  body: JSON.stringify({ name: "Ada" }),
});
console.log(res.status, res.headers.get("content-type"));
const reader = res.body.pipeThrough(new TextDecoderStream()).getReader(); // streams
```

- Nó nhận đối số như `fetch` (một URL, một `Request`, các tùy chọn) và trả về một `Response`.
- Body của request được đọc hết trước khi request bắt đầu.
- `redirect` là `"follow"`, `"manual"` hoặc `"error"`. `"follow"` là mặc định: tối đa 20 lần redirect, đặt `redirected` và `url`. `"manual"` trả về chính response redirect.
- Request thất bại (không kết nối được, lỗi TLS, quá nhiều redirect) reject với một `TypeError` có message nói lý do. Response với status bất kỳ đều resolve.
- Abort `signal` sẽ hủy request, trước hay sau khi response đến. `res.body.cancel()` cũng vậy.
- Zig không đọc nhanh hơn trang. Nó chờ khi trang còn hơn `window_bytes` của body chưa đọc.
- URL không phải `http:` hay `https:` đi qua `fetch` của chính webview.

<a id="options"></a>

### Tùy chọn

| trường | mặc định | |
|---|---|---|
| `allow` | null | `fn (ctx, req: *const http.Request) bool`: xem từng request (URL, method, header) và có thể từ chối; null thì cho phép tất cả |
| `allow_ctx` | null | truyền cho `allow` |
| `window_bytes` | 1 MiB | lượng body trang được phép chưa đọc trước khi Zig chờ |

```zig
fn onlyOurApi(_: ?*anyopaque, req: *const fetch.Request) bool {
    return std.mem.startsWith(u8, req.url, "https://api.example.com/");
}

var service: fetch.Service = try .init(gpa, app.io, .{ .allow = onlyOurApi });
```

Request bị từ chối sẽ reject ở trang (`NotAllowed`).

<a id="how-it-works"></a>

### Cách hoạt động

- Mỗi request chạy trên một task của `Io` của app (`io.concurrent`).
- Head, các chunk của body và phần kết thúc quay về dưới dạng event `myzig-fetch`. Chúng được chuyển sang main thread bằng [mainthread](mainthread.md), rồi tới cửa sổ đã yêu cầu, nếu nó còn mở.
- Trang chuyển đi, reload hoặc đóng sẽ hủy các request của nó, kể cả request đang chờ trang đọc body.
- Việc hủy là của `Io`, nên request đang bị chặn trên mạng dừng ngay.

<a id="from-zig"></a>

## Từ Zig

```zig
var client: std.http.Client = .{ .allocator = gpa, .io = io };
defer client.deinit();
try fetch.perform(&client, arena, .{
    .url = "https://example.com",
    .headers = &.{.{ .name = "accept", .value = "text/html" }},
}, .{
    .ctx = &state,
    .head = State.onHead, // status, status_text, url, redirected, headers
    .chunk = State.onChunk, // the body as it arrives, at most 64 KiB at a time
});
```

| `fetch.Request` | |
|---|---|
| `url` | |
| `method` | GET, HEAD, POST, PUT, DELETE, OPTIONS, PATCH, TRACE, QUERY, viết hoa hay thường đều được |
| `headers`, `body` | |
| `redirect` | `.follow`, `.manual`, `.@"error"` |
| `max_redirects` | 20 |

- `head` và `chunk` của `Sink` nhận `ctx` của nó dưới dạng `*anyopaque`.
- Tên header đến dưới dạng chữ thường.
- `perform` chặn. Chạy nó trên một thread hoặc với `io.concurrent`, và `cancel` của nó sẽ dừng `perform`.

<a id="not-yet"></a>

## Chưa có

- Proxy (`HTTPS_PROXY`): `std.http.Client.initDefaultProxies` có thể đặt proxy cho client của riêng bạn.
- Body của request bị redirect bằng 307 hoặc 308 sẽ lỗi (`RedirectRequiresResend`); 301, 302 và 303 trở thành GET như trên trình duyệt.
- Method ngoài `std.http.Method` (verb tùy chỉnh) bị từ chối.

<a id="example-and-tests"></a>

## Ví dụ và test

`example/` chạy một API nhỏ trên 127.0.0.1 (`example/api.zig`) và một trang fetch từ nó. `zig build run` mở ví dụ.

```sh
cd plugins/fetch
zig build test               # perform against the local API, and the page, hidden
zig build test -Dpage=false  # without the page
zig build check -Dtarget=x86_64-linux-gnu
```

Các test bao gồm:

- header (`Set-Cookie` bị bỏ) và body;
- ba chế độ redirect, và vòng lặp redirect;
- streaming: chunk đầu đến trước khi server gửi chunk thứ hai;
- hủy trong lúc server im lặng;
- body lớn, server không kết nối được và `HEAD`.

Test của trang kiểm tra những điều trên qua webview, kèm abort và backpressure.
