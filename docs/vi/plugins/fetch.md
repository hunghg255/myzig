# fetch

Các yêu cầu HTTP và HTTPS được thực hiện bởi Zig (`std.http.Client`), đối với các trang thông qua `fetch` tiêu chuẩn và từ Zig với `fetch.perform`. Bởi vì các yêu cầu xuất phát từ Zig thay vì từ webview:

- chúng không phải tuân theo CORS: mọi câu trả lời của máy chủ và mọi tiêu đề phản hồi đều có thể đọc được ngoại trừ `Set-Cookie`;
- họ có thể đặt bất kỳ tiêu đề nào, bao gồm `Origin`, `Cookie`, `Referer` và `User-Agent`;
- nội dung truyền đến trang khi Zig đọc nó và việc hủy bỏ sẽ hủy yêu cầu trong Zig.

Gói này là `plugins/fetch` (mô-đun `fetch`); nó phụ thuộc vào [mainthread](mainthread.md). Xem [Plugin](../plugins.md) để thêm plugin vào ứng dụng.

<a id="from-pages"></a>

## Sử dụng từ trang web

Liên kết dịch vụ, đăng ký sự kiện và phục vụ khách hàng của nó:

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

- Nó lấy các đối số của `fetch` (URL, `Request`, các tùy chọn) và trả về `Response`. Nội dung yêu cầu được đọc toàn bộ trước khi yêu cầu bắt đầu.
- `redirect`: `"follow"` (mặc định, tối đa 20 chuyển hướng, cài đặt `redirected` và `url`), `"manual"` (chính phản hồi chuyển hướng) hoặc `"error"`.
- Yêu cầu không thành công (không thể truy cập, TLS, quá nhiều chuyển hướng) sẽ từ chối với `TypeError` có thông báo cho biết lý do; một phản hồi của bất kỳ trạng thái nào sẽ được giải quyết.
- Việc hủy bỏ `signal` sẽ hủy yêu cầu trước hoặc sau khi có phản hồi; `res.body.cancel()` cũng vậy.
- Zig đọc không nhanh hơn trang: nó đợi trong khi trang có nhiều hơn `window_bytes` nội dung chưa đọc.
- Các URL không phải là `http:` hoặc `https:` sẽ chuyển đến `fetch` của chính webview.

<a id="options"></a>

### Tùy chọn

| lĩnh vực | mặc định | |
|---|---|---|
| `allow` | null | `fn (ctx, req: *const http.Request) bool`: xem từng yêu cầu (URL, phương thức, tiêu đề) và có thể từ chối yêu cầu đó; null cho phép tất cả |
| `allow_ctx` | null | được chuyển tới `allow` |
| `window_bytes` | 1 MiB | bao nhiêu nội dung trang có thể chưa được đọc trước khi Zig chờ |

```zig
fn onlyOurApi(_: ?*anyopaque, req: *const fetch.Request) bool {
    return std.mem.startsWith(u8, req.url, "https://api.example.com/");
}

var service: fetch.Service = try .init(gpa, app.io, .{ .allow = onlyOurApi });
```

Yêu cầu bị từ chối sẽ bị từ chối trong trang (`NotAllowed`).

<a id="how-it-works"></a>

### Cách hoạt động

Mỗi yêu cầu chạy trên một nhiệm vụ của `Io` (`io.concurrent`) của ứng dụng. Phần đầu, phần thân và phần cuối của nó quay trở lại dưới dạng sự kiện `myzig-fetch`, được giao cho luồng chính với [mainthread](mainthread.md) và được đưa đến cửa sổ hỏi xem nó có còn mở không. Một trang điều hướng, tải lại hoặc đóng sẽ hủy các yêu cầu của nó, thậm chí một trang đang chờ nó đọc nội dung. Việc hủy là của `Io`, do đó yêu cầu bị chặn trên mạng sẽ dừng ngay lập tức.

<a id="from-zig"></a>

## Sử dụng từ Zig

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

`fetch.Request` có `url`, `method` (GET, HEAD, POST, PUT, DELETE, OPTIONS, PATCH, TRACE, QUERY, trong mọi trường hợp), `headers`, `body`, `redirect` (`.follow`, `.manual`, `.@"error"`) và `max_redirects` (20). `Sink` của `head` và `chunk` lấy `ctx` của nó là `*anyopaque`; tên tiêu đề có chữ thường. Khối `perform`: chạy nó trên một luồng hoặc với `io.concurrent`, có `cancel` dừng nó.

<a id="not-yet"></a>

## Chưa hỗ trợ

- Proxy (`HTTPS_PROXY`): `std.http.Client.initDefaultProxies` có thể đặt chúng trên client của riêng bạn.
- Nội dung yêu cầu được chuyển hướng với 307 hoặc 308 không thành công (`RedirectRequiresResend`); 301, 302 và 303 trở thành GET như trong trình duyệt.
- Các phương thức bên ngoài `std.http.Method` (động từ tùy chỉnh) đều bị từ chối.

<a id="example-and-tests"></a>

## Ví dụ và kiểm thử

`example/` chạy một API nhỏ trên 127.0.0.1 (`example/api.zig`) và một trang tìm nạp từ đó; `zig build run` hiển thị nó.

```sh
cd plugins/fetch
zig build test               # perform against the local API, and the page, hidden
zig build test -Dpage=false  # without the page
zig build check -Dtarget=x86_64-linux-gnu
```

Các kiểm thử bao gồm các tiêu đề (`Set-Cookie` bị rớt), nội dung, ba chế độ chuyển hướng và vòng lặp chuyển hướng, phát trực tuyến (đoạn đầu tiên đến trước khi máy chủ gửi đoạn thứ hai), hủy trong khi máy chủ im lặng, nội dung lớn, máy chủ không thể truy cập và `HEAD`; kiểm tra trang cũng thực hiện tương tự thông qua webview, với tính năng hủy bỏ và áp suất ngược.
