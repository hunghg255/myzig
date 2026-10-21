# websocket

Ứng dụng khách WebSocket: RFC 6455 trong Zig (`websocket.Conn`) và đối với các trang `WebSocket` với API của trình duyệt có kết nối Zig tạo ra, sao cho nó:

- gửi bất kỳ tiêu đề nào có bắt tay mở đầu (`Authorization`, `Cookie`, `Origin`...);
- không tuân theo Chính sách bảo mật nội dung của trang;
- lưu giữ các tin nhắn của một máy chủ nhanh trong Zig trong khi trang ở phía sau.

`wss:` là TLS có chứng chỉ của hệ thống: quá trình bắt tay đi qua `std.http.Client`, kết nối mà các khung sẽ sử dụng.

Gói này là `plugins/websocket` (mô-đun `websocket`); nó phụ thuộc vào [mainthread](mainthread.md). Xem [Plugin](../plugins.md) để thêm plugin vào ứng dụng.

<a id="from-pages"></a>

## Sử dụng từ trang web

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

`WebSocket` của trang có API của trình duyệt, cùng với đối số thứ ba với `headers`:

- `ws:` và `wss:` URL (`http:` và `https:` trở thành chúng, các URL tương đối phân giải theo trang), giao thức con (`protocol` khi mở), `readyState`, `bufferedAmount` (byte Zig chưa được ghi), `binaryType` và Các sự kiện `open`, `message`, `error` và `close`.
- `send` nhận các chuỗi, `ArrayBuffer`, mảng đã nhập và `Blob`, được gửi theo thứ tự; nó ném ra trong khi kết nối và các tin nhắn sau khi đóng sẽ bị loại bỏ.
- `close(code, reason)` mất 1000 hoặc 3000 đến 4999 và lý do tối đa là 123 byte. Zig sau đó đợi `close_timeout_ms` để máy chủ đóng (`wasClean`, với mã và lý do của máy chủ) và ngắt kết nối theo cách khác (1006).
- Zig trả lời ping, tập hợp lại các tin nhắn bị phân mảnh và không kết nối được (1002, 1007, 1009) khi máy chủ phá vỡ giao thức, gửi UTF-8 không hợp lệ hoặc tin nhắn qua `max_message_size`. Sau đó, trang sẽ nhận được `error`, sau đó là `close` với 1006 và bảng điều khiển sẽ cho biết lý do.
- Zig không đọc thêm trong khi trang có nhiều hơn `window_bytes` tin nhắn cần xử lý.
- Các kết nối của một trang bị ngắt (biến mất, 1001) khi trang điều hướng, tải lại hoặc đóng, ngay cả những trang đang chờ trang đó đọc; `service.deinit` bỏ phần còn lại.
- Không có tiện ích mở rộng (permessage-deflate) nào được thương lượng.

<a id="options"></a>

### Tùy chọn

`websocket.ServiceOptions`:

| lĩnh vực | mặc định | |
|---|---|---|
| `allow` | null | `fn (ctx, url, headers: []const websocket.Header) bool`: có thể từ chối kết nối |
| `allow_ctx` | null | được chuyển tới `allow` |
| `max_message_size` | 64 MiB | tin nhắn lớn nhất từ máy chủ |
| `close_timeout_ms` | 5000 | bao lâu một kết nối đóng chờ máy chủ đóng |
| `window_bytes` | 1 MiB | tin nhắn mà trang có thể chưa xử lý trước khi Zig ngừng đọc |

Mỗi kết nối là hai tác vụ trên `Io` của ứng dụng: một kết nối và đọc, một ghi nội dung trang gửi. Các sự kiện của họ (`myzig-websocket`) đến trang thông qua luồng chính ([mainthread](mainthread.md)).

<a id="from-zig"></a>

## Sử dụng từ Zig

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
- `send(.text or .binary, data)`, `ping(data)`, `close(code, reason)`, `fail(code)` (đóng ngay lập tức, do lỗi giao thức).
- Đọc và ghi có thể chạy trên hai luồng cùng một lúc (ghi được tuần tự hóa); `shutdown()` dừng `read` bị chặn khỏi một chuỗi khác.
- `websocket.frame` là codec cho cả hai đầu; máy chủ của ví dụ sử dụng nó làm máy chủ. `websocket.Code` đặt tên cho các mã đóng.

<a id="example-and-tests"></a>

## Ví dụ và kiểm thử

`example/` chạy máy chủ WebSocket trên 127.0.0.1 (`example/server.zig`: cái bắt tay của `std.http.Server`, sau đó là khung của plugin này) và một trang nói chuyện với nó; `zig build run` hiển thị nó.

```sh
cd plugins/websocket
zig build test               # Conn and the frames against the in-process server, and the page, hidden
zig build test -Dpage=false  # without the page
zig build check -Dtarget=x86_64-linux-gnu
```

Các kiểm thử bao gồm ví dụ về mặt nạ của RFC 6455, mọi mã hóa độ dài, các khung phá vỡ quy tắc, đóng tải trọng, khóa chấp nhận, tiếng vang của văn bản và tin nhắn nhị phân (200 KB), tiêu đề và giao thức con, đóng do máy chủ khởi tạo, ping, phân mảnh có ping bên trong, lỗi giao thức, giới hạn tin nhắn, từ chối nâng cấp và `shutdown`; kiểm tra trang bao gồm API trình duyệt từ đầu đến cuối. Trên Windows, bài kiểm tra `shutdown` in dấu vết ngăn xếp từ thư viện chuẩn (bản dựng gỡ lỗi báo cáo `PIPE_DISCONNECTED` của ổ cắm là không mong muốn) và vượt qua.
