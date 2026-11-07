<a id="plugins"></a>

# Plugin

Plugin là một package Zig cho một tính năng mà lõi myzig không có sẵn. App nào không dùng nó thì không bị nặng thêm.

- **Plugin cho trang** gồm hai nửa, như plugin của mygo: một service Zig mà app bind, và một module JavaScript có các hàm gọi tới service đó. App tự phục vụ module này; nó không bao giờ đến từ npm.
- **Plugin cho native UI** chỉ có Zig.

Mỗi plugin chính thức nằm trong `plugins/<name>` của repository myzig. Đó là một package riêng, gồm:

- một `build.zig`;
- một `build.zig.zon` phụ thuộc vào myzig, và vào `mainthread` khi nó làm việc ngoài main thread;
- mã nguồn trong `src/`, một app `example/` và các test của nó.

<a id="official-plugins"></a>

## Plugin chính thức

- [loading](plugins/loading.md): 29 chỉ báo đang tải native, có tạm dừng, giảm chuyển động, tên cho trình đọc màn hình và tùy chọn riêng cho từng mẫu.

- [fetch](plugins/fetch.md): một `fetch` cho trang, request do Zig thực hiện: không có CORS, header nào cũng được, body dạng stream và hủy được; cùng `fetch.perform` từ Zig.
- [websocket](plugins/websocket.md): một `WebSocket` cho trang, kết nối do Zig mở, có header khi handshake; cùng `Conn`, một client RFC 6455 viết bằng Zig.
- [sqlite](plugins/sqlite.md): SQLite từ Zig và từ trang, thư viện của hệ thống được nạp lúc chạy.
- [watch](plugins/watch.md): theo dõi thay đổi của file trong các thư mục gốc mà app chỉ định, từ Zig và từ trang.
- [updater](plugins/updater.md): kiểm tra manifest, tải file thực thi mới có xác minh SHA-256 rồi đặt nó vào chỗ; một service cho banner cập nhật trong trang.
- [terminal](plugins/terminal.md): một view terminal cho native UI, chạy shell trong pseudo-terminal với bộ giả lập của Ghostty, libghostty-vt, được nạp lúc chạy.
- [glass](plugins/glass.md): các pane Liquid Glass và hiệu ứng làm mờ nền cho native UI, mọi renderer đều vẽ được và có bản CPU tương ứng.
- [game](plugins/game.md): vòng lặp game theo bước cố định, camera và gamepad, cho native UI.
- [signals](plugins/signals.md): state toàn cục bằng signal, computed và effect, bản port của alien-signals.
- [mainthread](plugins/mainthread.md): chuyển việc về main thread từ bất kỳ thread nào khác; các plugin khác dựa trên nó.

| plugin | module | trang | native UI | chỉ Zig |
|---|---|:-:|:-:|:-:|
| fetch | `fetch` | có | | `fetch.perform` |
| websocket | `websocket` | có | | `Conn` |
| sqlite | `sqlite` | có | | `Db` |
| watch | `watch` | có | | `Watcher` |
| updater | `updater` | có | | `Updater` |
| terminal | `terminal` | | có | |
| glass | `glass` | | có | |
| game | `game`, `gamepad` | | có | `gamepad` |
| signals | `signals` | | có | có |
| mainthread | `mainthread` | | | có |

<a id="using-a-plugin"></a>

## Dùng một plugin

**updater và mainthread** đi kèm myzig. Package của myzig export chúng, và bản release có sẵn mã nguồn của chúng. App phụ thuộc vào một bản release thì lấy chúng từ đó: `b.dependency("myzig", ...).module("updater")`.

**Các plugin khác** là dependency của package của app. Thêm plugin cạnh myzig trong `build.zig.zon`, dưới dạng đường dẫn vào một bản checkout của myzig:

```zig
.dependencies = .{
    .myzig = .{ .path = "../myzig" },
    .myzig_fetch = .{ .path = "../myzig/plugins/fetch" },
},
```

Các plugin phụ thuộc vào myzig ở hai cấp thư mục phía trên (`../..`), nên app và plugin dùng chung một myzig. Sau đó đưa module của plugin cho app trong `build.zig`, như `examples/farm` làm với plugin game:

```zig
const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize }).module("myzig");
const fetch = b.dependency("myzig_fetch", .{ .target = target, .optimize = optimize }).module("fetch");
const root = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "myzig", .module = myzig },
        .{ .name = "fetch", .module = fetch },
    },
});
```

Truyền cùng `target` và `optimize` cho cả hai dependency. Khi đó Zig build một myzig duy nhất cho cả app và plugin.

<a id="plugins-for-pages"></a>

### Plugin cho trang

```zig
const std = @import("std");
const myzig = @import("myzig");
const fetch = @import("fetch");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const app = try myzig.App.create(init, .{ .name = "Feeds" });
    defer app.destroy();

    var service: fetch.Service = try .init(gpa, app.io, .{});
    defer service.deinit();
    try app.bind(&service);
    try app.registerEvent(fetch.PartEvent);

    const index: myzig.Asset = .{ .path = "/index.html", .data = @embedFile("index.html") };
    _ = try app.newWindow(.{ .title = "Feeds", .content = .{ .page = .{ .url = "/", .assets = &.{ index, fetch.asset } } } });
    try app.run();
}
```

```js
import { fetch } from "/plugins/fetch.js";

const res = await fetch("https://api.example.com/me", { headers: { authorization: `Bearer ${token}` } });
```

- **Nửa Zig** là một service. Khởi tạo nó trên main thread, bind nó, và đăng ký event mà kết quả của nó gửi về.
- **Nửa JavaScript** là một `Asset` do plugin export. Thêm nó vào asset của trang: `fetch.asset` được phục vụ tại `/plugins/fetch.js`.
- Mỗi service có `Options`, chẳng hạn hàm `allow` quyết định trang được gửi request, mở kết nối hay theo dõi những gì. Trang của từng plugin liệt kê các tùy chọn này.

<a id="plugins-for-native-ui"></a>

### Plugin cho native UI

Chúng là các hàm dùng trong view, giống widget của chính myzig:

```zig
const glass = @import("glass");

fn view(s: *State, c: *ui.Context) void {
    // ... the content ...
    _ = glass.pane(c, .{ .radius = 16 }, .{ .padding = .all(12) });
    ui.text(c, "On glass", .{});
    c.end();
}
```

<a id="building-and-testing-a-plugin"></a>

## Build và test một plugin

Package của plugin nào cũng có các bước như nhau:

```sh
cd plugins/fetch
zig build test                              # its tests; pages' tests run the example hidden
zig build test -Dpage=false                 # plugins for pages: without the page (no webview)
zig build test-page                         # plugins for pages: the example's page alone, hidden
zig build check -Dtarget=x86_64-linux-gnu   # compile the tests for another platform without running them
zig build run                               # the example, in a window
zig build test -Dtest-filter=redirect       # only the tests whose names contain this
```

Test trang chạy example với `--myzig-eval`, cửa sổ của nó được giữ ẩn. Test đạt khi trang log ra `ok` (`page: ok`).

<a id="writing-a-plugin"></a>

## Viết một plugin

Plugin là một package Zig giống các plugin chính thức. Với trang, nó gồm:

- **Một service**: một struct có các method public mà trang gọi, bind bằng `app.bind`. Xem [Bindings](bindings.md).
  - `myzig_name` đặt tên cho nó phía trang; nếu không có thì dùng tên type.
  - `myzig_params` đặt tên tham số cho từng method trong client được sinh ra.
  - Method nhận `*myzig.Call` biết cửa sổ nào đã gọi (`call.window`) và có một arena cho kết quả (`call.arena`).
- **Một event** cho những gì trả về sau: `myzig.Event("myzig-<name>", Payload)`. Gửi tới một cửa sổ bằng `Event.emit(window, payload)`, hoặc tới mọi cửa sổ bằng `Event.broadcast(app, payload)`. App đăng ký nó bằng `app.registerEvent`.
- **Module JavaScript**, nhúng bằng `@embedFile` và export dưới dạng `Asset` tại `/plugins/<name>.js`. Nó gọi service bằng `myzig.call("Name.method", ...)` và lắng nghe bằng `myzig.on("myzig-<name>", ...)`. Đây là runtime của trang, `window.myzig`; xem [Frontend](frontend.md).

```zig
//! A counter for pages: `bump()`, and the new count sent to every window.
const myzig = @import("myzig");

pub const CountEvent = myzig.Event("myzig-counter", struct { n: u64 });
pub const asset: myzig.Asset = .{ .path = "/plugins/counter.js", .data = @embedFile("js/counter.js") };

pub const Service = struct {
    pub const myzig_name = "Counter";
    app: *myzig.App,
    n: u64 = 0,

    pub fn bump(s: *Service) u64 {
        s.n += 1;
        CountEvent.broadcast(s.app, .{ .n = s.n });
        return s.n;
    }
};
```

```js
// js/counter.js
export const bump = () => myzig.call("Counter.bump");
export const onCount = (f) => myzig.on("myzig-counter", f);
```

Các quy tắc mà plugin chính thức tuân theo, và plugin của bạn cũng nên vậy:

- **Method được bind chạy trên main thread.**
  - Việc bị chặn (mạng, file, một truy vấn lâu) chạy trên một task của `Io` của app (`io.concurrent`) hoặc một thread.
  - Nó chuyển kết quả về main thread bằng [`mainthread.post`](plugins/mainthread.md). Chỉ ở đó nó mới được emit event hay đụng tới cửa sổ.
  - Kiểm tra cửa sổ còn mở trước khi emit (`app.windows`). Bỏ việc của những cửa sổ đã đóng.
- **Việc giữ cho một trang thì đi cùng trang đó.**
  - Service có `pub fn myzig_pageGone(s: *Service, window: *myzig.Window, page: *anyopaque) void` được báo khi document của một trang không còn: trang đã điều hướng, reload hoặc đóng.
  - Nó giải phóng những gì đã giữ cho trang đó, nhận ra trang qua `call.page`.
  - Trang đã reload sẽ không gọi lại việc đó nữa, cũng không đọc những gì gửi tới. Một stream đang chờ `ack` của nó sẽ chờ mãi.
  - Trang không bao giờ gọi các method `myzig_*`.
- **Backpressure.** Stream dừng chờ khi số byte trang chưa đọc vượt quá một window (khung luồng dữ liệu). Trang xác nhận phần đã đọc (`ack`), nên nguồn dữ liệu nhanh không bao giờ dồn ứ trong trang.
- **Trang chỉ gọi tên, không bao giờ dùng đường dẫn**: tên file trong thư mục dữ liệu của app (sqlite), các thư mục gốc app đã chỉ định (watch). Trang không với tới được ngoài phạm vi app cho phép.
- **Thư viện native được nạp, không link**, bằng `std.DynLib` hoặc loader của nền tảng, và có kiểm tra. sqlite thử thư viện của hệ thống. terminal kiểm tra SHA-256 của những gì nó tải về và layout của các struct nó truyền đi. Không `@cImport`, không file C.
- **Không gì polling**, và test không bao giờ chờ theo thời gian thực. Test chờ event mà nó mong đợi, hoặc cho đồng hồ của `ui.Tester` chạy tới.
- **Mỗi file tối đa 600 dòng**, như mọi nơi trong myzig.

<a id="not-yet"></a>

## Chưa có

- Plugin của mygo được đăng ký bằng `mygo.Use`, cài service và script của nó cùng lúc. myzig không có lời gọi như vậy: app tự bind service của plugin và tự thêm asset của nó.
- Nửa JavaScript của mygo là package npm; của myzig thì không.
- CLI chưa đưa thư viện native của plugin vào app. Plugin terminal tải chúng về cache của người dùng, hoặc tìm chúng cạnh file thực thi.
