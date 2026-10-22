<a id="plugins"></a>

# Plugin

Plugin [loading](plugins/loading.md) cung cấp 29 chỉ báo native, hỗ trợ tạm
dừng, giảm chuyển động, accessibility và cấu hình riêng từng mẫu.

Plugin là một gói Zig bổ sung thêm một tính năng cốt lõi của myzig, do đó các ứng dụng không sử dụng nó sẽ không phát triển. Plugin cho các trang có hai nửa, giống như mygo: dịch vụ Zig mà ứng dụng liên kết và mô-đun JavaScript (được ứng dụng phân phối, không bao giờ được tìm nạp từ npm) có chức năng gọi nó. Chỉ có các plugin dành cho giao diện native là Zig.

Mọi plugin chính thức đều tồn tại trong `plugins/<name>` của kho lưu trữ myzig, một gói riêng có `build.zig`, `build.zig.zon` (tùy thuộc vào myzig và trên `mainthread` khi nó hoạt động với luồng chính), nguồn của nó trong `src/`, ứng dụng `example/` và các kiểm thử của nó.

<a id="official-plugins"></a>

## Plugin chính thức

- [fetch](plugins/fetch.md): một `fetch` cho các trang có yêu cầu Zig thực hiện, không có CORS, bất kỳ tiêu đề, nội dung được truyền trực tuyến và sự hủy bỏ nào; và `fetch.perform` từ Zig.
- [websocket](plugins/websocket.md): a `WebSocket` cho các trang có kết nối Zig tạo ra, với các tiêu đề khi bắt tay; và `Conn`, client RFC 6455 trong Zig.
- [sqlite](plugins/sqlite.md): SQLite từ Zig và từ các trang, với thư viện của hệ thống được tải trong thời gian chạy.
- [watch](plugins/watch.md): thay đổi các tập tin, trong thư mục gốc tên ứng dụng, từ Zig và từ các trang.
- [updater](plugins/updater.md): kiểm tra một bảng kê khai, tải xuống tệp thực thi mới để xác minh SHA-256 của nó và đặt nó vào vị trí; một dịch vụ cho một biểu ngữ cập nhật trong một trang.
- [terminal](plugins/terminal.md): view terminal cho giao diện native, chạy shell trong terminal giả với trình mô phỏng Ghostty, libghostty-vt, được tải trong thời gian chạy.
- [glass](plugins/glass.md): Kính lỏng và hiệu ứng làm mờ phông nền cho giao diện native, được vẽ bởi mọi bộ kết xuất có CPU đôi.
- [game](plugins/game.md): vòng lặp trò chơi theo các bước cố định, máy ảnh và tay cầm chơi game cho giao diện native.
- [mainthread](plugins/mainthread.md): công việc được giao cho luồng chính từ bất kỳ ai khác; các plugin khác được xây dựng trên đó.

| phần bổ trợ | mô-đun | trang | native UI | Zig chỉ |
|---|---|:-:|:-:|:-:|
| lấy | `fetch` | vâng | | `fetch.perform` |
| ổ cắm web | `websocket` | vâng | | `Conn` |
| sqlite | `sqlite` | vâng | | `Db` |
| xem | `watch` | vâng | | `Watcher` |
| người cập nhật | `updater` | vâng | | `Updater` |
| terminal | `terminal` | | vâng | |
| kính | `glass` | | vâng | |
| trò chơi | `game`, `gamepad` | | vâng | `gamepad` |
| chủ đề chính | `mainthread` | | | vâng |

<a id="using-a-plugin"></a>

## Sử dụng một plugin

Plugin là phần phụ thuộc của gói ứng dụng. Thêm nó bên cạnh myzig trong `build.zig.zon`, như một đường dẫn đến bản checkout myzig (các plugin phụ thuộc vào myzig hai thư mục trở lên, `../..`, vì vậy ứng dụng và plugin chia sẻ một myzig):

```zig
.dependencies = .{
    .myzig = .{ .path = "../myzig" },
    .myzig_fetch = .{ .path = "../myzig/plugins/fetch" },
},
```

và cung cấp mô-đun của nó cho ứng dụng trong `build.zig`, như `examples/farm` thực hiện với plugin trò chơi:

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

Chuyển cùng `target` và `optimize` cho cả hai phần phụ thuộc: Zig sau đó xây dựng một myzig cho ứng dụng và plugin.

<a id="plugins-for-pages"></a>

### Plugin cho trang

Một nửa Zig là một dịch vụ: khởi tạo nó trên luồng chính, liên kết nó và đăng ký sự kiện mà kết quả của nó trả về. Một nửa JavaScript là một `Asset` xuất plugin (`fetch.asset` được cung cấp tại `/plugins/fetch.js`): thêm nó vào nội dung của trang.

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

Mỗi dịch vụ có `Options`, chẳng hạn như chức năng `allow` quyết định những yêu cầu, kết nối hoặc trang theo dõi nào có thể thực hiện; trang của mỗi plugin liệt kê chúng.

<a id="plugins-for-native-ui"></a>

### Plugin cho giao diện native

Chúng là các chức năng của view, vì các widget riêng của myzig là:

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

## Xây dựng và thử nghiệm plugin

Mọi gói plugin đều có các bước giống nhau:

```sh
cd plugins/fetch
zig build test                              # its tests; pages' tests run the example hidden
zig build test -Dpage=false                 # plugins for pages: without the page (no webview)
zig build test-page                         # plugins for pages: the example's page alone, hidden
zig build check -Dtarget=x86_64-linux-gnu   # compile the tests for another platform without running them
zig build run                               # the example, in a window
zig build test -Dtest-filter=redirect       # only the tests whose names contain this
```

Kiểm tra trang chạy ví dụ với `--myzig-eval`, giúp ẩn cửa sổ của nó và vượt qua khi trang ghi nhật ký `ok` (`page: ok`).

<a id="writing-a-plugin"></a>

## Viết một plugin

Plugin là gói Zig giống như gói chính thức. Đối với các trang, các phần của nó là:

- **Một dịch vụ**: một cấu trúc có các trang phương thức công khai gọi, được liên kết với `app.bind`. `myzig_name` đặt tên cho các trang (nếu không thì là tên loại của nó), `myzig_params` đặt tên tham số của từng phương thức cho client được tạo và các phương thức nhận `*myzig.Call` tìm hiểu cửa sổ nào có tên (`call.window`) và nhận được một arena cho kết quả của chúng (`call.arena`). Xem [Ràng buộc](bindings.md).
- **Một sự kiện** cho những gì sẽ quay lại sau: `myzig.Event("myzig-<name>", Payload)`, được gửi tới một cửa sổ với `Event.emit(window, payload)` hoặc tới tất cả các cửa sổ có `Event.broadcast(app, payload)`. Ứng dụng đăng ký nó với `app.registerEvent`.
- **Mô-đun JavaScript**, được nhúng với `@embedFile` và được xuất dưới dạng `Asset` trong `/plugins/<name>.js`. Nó gọi dịch vụ bằng `myzig.call("Name.method", ...)` và lắng nghe bằng `myzig.on("myzig-<name>", ...)` (thời gian chạy trang, `window.myzig`; xem [Giao diện người dùng](frontend.md)).

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

Các quy tắc mà các plugin chính thức tuân theo và của bạn cũng vậy:

- **Các phương thức giới hạn chạy trên luồng chính.** Công việc chặn (mạng, tệp, truy vấn dài) chạy theo tác vụ của `Io` (`io.concurrent`) hoặc một chuỗi của ứng dụng và chuyển kết quả của nó cho luồng chính với [`mainthread.post`](plugins/mainthread.md); chỉ ở đó nó mới có thể phát ra các sự kiện hoặc chạm vào cửa sổ. Kiểm tra xem cửa sổ vẫn mở trước khi phát ra (`app.windows`) và thả công việc của các cửa sổ đã đóng.
- **Công việc được lưu giữ cho một trang sẽ đi cùng với nó.** Một dịch vụ có `pub fn myzig_pageGone(s: *Service, window: *myzig.Window, page: *anyopaque) void` sẽ biết khi tài liệu của một trang không còn nữa (nó được điều hướng, tải lại hoặc đóng): nó sẽ loại bỏ những gì nó đã lưu giữ cho trang đó mà nó biết bởi `call.page`. Một trang tải lại sẽ không bao giờ gọi lại tác phẩm đó cũng như không đọc nội dung xuất hiện, do đó, một luồng đang chờ `ack` của nó sẽ chờ mãi mãi. Các trang không bao giờ gọi phương thức `myzig_*`.
- **Back Pressure.** Các luồng chờ trong khi trang có nhiều hơn một cửa sổ byte chưa đọc (trang xác nhận những gì nó đọc, `ack`), do đó, nguồn nhanh không bao giờ chồng chất lên trang.
- **Đặt tên các trang, không bao giờ đặt đường dẫn.** Tên tệp trong thư mục dữ liệu của ứng dụng (sqlite), gốc ứng dụng có tên (xem): một trang không thể tiếp cận xa hơn mức ứng dụng cho phép.
- **Thư viện gốc được tải, không được liên kết**, với `std.DynLib` hoặc trình tải của nền tảng và được kiểm tra (sqlite thử thư viện của hệ thống; terminal kiểm tra SHA-256 về những gì nó tải xuống và bố cục của các cấu trúc mà nó chuyển qua). Không có `@cImport`, không có tệp C.
- **Không có polling nào** và các bài kiểm tra không bao giờ chờ đợi theo thời gian trên đồng hồ treo tường: họ chờ đợi sự kiện mà họ mong đợi hoặc nâng cao đồng hồ của `ui.Tester`.
- **Tối đa 600 dòng một tệp**, như mọi nơi trong myzig.

<a id="not-yet"></a>

## Chưa hỗ trợ

Các plugin của mygo được đăng ký với `mygo.Use`, plugin này sẽ cài đặt các dịch vụ và tập lệnh của họ cùng một lúc và một nửa JavaScript của chúng là các gói npm. myzig không có: ứng dụng liên kết dịch vụ của plugin và thêm nội dung của plugin đó, đồng thời CLI chưa đưa thư viện gốc của plugin vào ứng dụng (plugin đầu cuối tải chúng xuống bộ nhớ đệm của người dùng hoặc tìm chúng bên cạnh tệp thực thi).
