# websocket

Một WebSocket client: RFC 6455 viết bằng Zig (`websocket.Conn`). Cho trang web, nó cung cấp một `WebSocket` có API giống trình duyệt, nhưng kết nối do Zig tạo. Vì vậy `WebSocket` của trang:

- gửi được bất kỳ header nào trong handshake mở đầu (`Authorization`, `Cookie`, `Origin`...);
- không bị Content Security Policy của trang ràng buộc;
- giữ tin nhắn của một server gửi nhanh ở phía Zig trong khi trang xử lý chưa kịp.

`wss:` là TLS dùng chứng chỉ của hệ thống. Handshake đi qua `std.http.Client`, rồi các frame dùng lại kết nối của nó.

Package là `plugins/websocket` (module `websocket`). Nó phụ thuộc [mainthread](mainthread.md). Xem [Plugins](../plugins.md) để thêm nó vào app.

<a id="from-pages"></a>

## Từ trang web

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

`WebSocket` của trang có API như trình duyệt, cộng thêm đối số thứ ba chứa `headers`:

- URL là `ws:` và `wss:`. `http:` và `https:` được đổi thành chúng, URL tương đối được tính theo URL của trang.
- Nó có subprotocol (`protocol` khi đã mở), `readyState`, `bufferedAmount` (số byte Zig chưa ghi) và `binaryType`.
- Các event của nó là `open`, `message`, `error` và `close`.
- `send` nhận chuỗi, `ArrayBuffer`, typed array và `Blob`, gửi theo thứ tự. Nó throw khi đang kết nối. Tin nhắn gửi sau khi đóng bị bỏ.
- `close(code, reason)` nhận 1000 hoặc từ 3000 đến 4999, và reason tối đa 123 byte.
- Sau `close`, Zig chờ `close_timeout_ms` để nhận close của server: `wasClean`, kèm code và reason của server. Nếu không, nó bỏ kết nối (1006).
- Zig tự trả lời ping và ghép lại tin nhắn bị phân mảnh.
- Zig đánh lỗi kết nối (1002, 1007, 1009) khi server vi phạm giao thức, gửi UTF-8 không hợp lệ, hoặc gửi tin nhắn lớn hơn `max_message_size`. Trang khi đó nhận `error`, rồi `close` với 1006, và console ghi lý do.
- Zig ngừng đọc khi trang còn hơn `window_bytes` tin nhắn chưa xử lý.
- Kết nối của trang bị bỏ (going away, 1001) khi trang chuyển đi, reload hoặc đóng. Kể cả các kết nối đang chờ trang đọc. `service.deinit` bỏ phần còn lại.
- Không thương lượng extension nào (permessage-deflate).

<a id="options"></a>

### Tùy chọn

`websocket.ServiceOptions`:

| trường | mặc định | |
|---|---|---|
| `allow` | null | `fn (ctx, url, headers: []const websocket.Header) bool`: có thể từ chối một kết nối |
| `allow_ctx` | null | truyền cho `allow` |
| `max_message_size` | 64 MiB | tin nhắn lớn nhất nhận từ server |
| `close_timeout_ms` | 5000 | thời gian kết nối đang đóng chờ close của server |
| `window_bytes` | 1 MiB | lượng tin nhắn trang được phép chưa xử lý trước khi Zig ngừng đọc |

Mỗi kết nối là hai task trên `Io` của app. Một task kết nối và đọc; một task ghi những gì trang gửi. Event của chúng (`myzig-websocket`) đến trang qua main thread ([mainthread](mainthread.md)).

<a id="from-zig"></a>

## Từ Zig

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
- `send(.text or .binary, data)`, `ping(data)`, `close(code, reason)`.
- `fail(code)` đóng ngay, như khi gặp lỗi giao thức.
- Đọc và ghi có thể chạy cùng lúc trên hai thread. Các lần ghi được tuần tự hóa.
- `shutdown()` dừng một `read` đang bị chặn từ thread khác.
- `websocket.frame` là codec cho cả hai đầu. Server trong ví dụ dùng nó ở vai trò server.
- `websocket.Code` đặt tên cho các mã close.

<a id="example-and-tests"></a>

## Ví dụ và test

`example/` chạy một WebSocket server trên 127.0.0.1 và một trang nói chuyện với nó. Server (`example/server.zig`) làm handshake của `std.http.Server`, rồi dùng frame của plugin này. `zig build run` mở ví dụ.

```sh
cd plugins/websocket
zig build test               # Conn and the frames against the in-process server, and the page, hidden
zig build test -Dpage=false  # without the page
zig build check -Dtarget=x86_64-linux-gnu
```

Các test bao gồm:

- ví dụ masking của RFC 6455, mọi cách mã hóa độ dài, frame vi phạm quy tắc, payload của close và accept key;
- echo tin nhắn text và binary (200 KB), header và subprotocol;
- close do server khởi xướng, ping, phân mảnh có ping chen giữa;
- lỗi giao thức, giới hạn tin nhắn, upgrade bị từ chối và `shutdown`;
- API trình duyệt từ đầu đến cuối, trong test của trang.

Trên Windows, test `shutdown` in ra một stack trace từ thư viện chuẩn, và vẫn pass. Bản build debug báo `PIPE_DISCONNECTED` của socket là bất thường.
