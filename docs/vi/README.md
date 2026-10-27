<a id="myzig-documentation"></a>

# Tài liệu myzig

myzig giúp xây dựng ứng dụng desktop bằng Zig. Mỗi cửa sổ hiển thị một trong hai loại giao diện; một ứng dụng có thể dùng cả hai:

- **Trang web**, chạy trong webview của hệ điều hành (WKWebView trên macOS, WebKitGTK trên Linux, WebView2 trên Windows), không cần đóng gói thêm trình duyệt. Frontend dùng HTML, CSS và JavaScript với công cụ build tùy chọn. myzig sinh JavaScript client và khai báo TypeScript từ các kiểu Zig ngay khi biên dịch để frontend gọi code Zig.
- **Giao diện native**, do myzig tự vẽ và được viết hoàn toàn bằng Zig với `myzig.ui`. Không cần HTML, JavaScript hay khởi động webview, nên cửa sổ mở ngay và dùng ít bộ nhớ. Backend dùng Metal trên macOS, Direct3D 11 trên Windows, OpenGL trên Linux và WebGL 2 trên trình duyệt; khi không có GPU, bộ kết xuất CPU của myzig tạo ra cùng kết quả pixel.

Cả hai loại cửa sổ dùng chung tùy chọn, sự kiện, menu và API desktop. Ứng dụng là một chương trình Zig duy nhất với binary nhỏ hơn một megabyte. Giao diện native cũng chạy trên trình duyệt khi build cho `wasm32-wasi`.

Cửa sổ hiển thị trang web, với frontend gọi dịch vụ Zig:

```zig
const Greeter = struct {
    pub const myzig_params = .{ .greet = .{"name"} };

    /// Returns a greeting.
    pub fn greet(_: *Greeter, call: *myzig.Call, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(call.arena, "Hello, {s}!", .{name});
    }
};

const assets = [_]myzig.Asset{
    .{ .path = "/index.html", .data = @embedFile("frontend/index.html") },
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Hello" });
    defer app.destroy();
    var greeter: Greeter = .{};
    try app.bind(&greeter);
    _ = try app.newWindow(.{ .title = "Hello", .content = .{ .page = .{ .url = "/", .assets = &assets } } });
    try app.run();
}
```

```js
import { Greeter } from "/myzig.js"; // generated, served by the app

document.body.textContent = await Greeter.greet("Ada");
```

Một cửa sổ có giao diện native, có view là hàm Zig của trạng thái ứng dụng:

```zig
const Counter = struct {
    n: i64 = 0,

    fn view(s: *Counter, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 16 });
        defer ui.end(c);
        ui.textf(c, .{ .size = 56, .weight = .bold }, "{d}", .{s.n});
        if (ui.button(c, "Increment", .{ .variant = .primary }).clicked) s.n += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Counter" });
    defer app.destroy();
    var state: Counter = .{};
    _ = try app.newWindow(.{ .title = "Counter", .content = .{ .view = .init(&state, Counter.view) } });
    try app.run();
}
```

<a id="guides"></a>

## Hướng dẫn

Bắt đầu ở đây:

- [Tổng quan về kiến trúc](architecture.md#architecture-at-a-glance): bản đồ trực quan của các lớp, bộ điều hợp nền tảng và hai đường dẫn giao diện người dùng, cùng với sơ đồ IPC trang và hiển thị gốc.
- [Bắt đầu](getting-started.md): Zig 0.17, CLI, `myzig init`, xây dựng và vận hành, mọi ví dụ.

Ứng dụng và máy tính để bàn:

- [Ứng dụng](app.md): tạo và chạy ứng dụng, các tùy chọn và trình xử lý, luồng, thoát và tín hiệu, phiên bản đơn, liên kết sâu, thông báo, trạng thái mạng, bắt đầu khi đăng nhập.
- [Cửa sổ](windows.md): mọi tùy chọn, phương thức và sự kiện của cửa sổ, trạng thái được ghi nhớ, đóng, thanh tiêu đề và cửa sổ không khung, vật liệu, hộp thả xuống, tiến trình, tệp được thả trên cửa sổ.
- [Menu, khay và phím tắt chung](menus.md): mẫu menu, vai trò, phím tắt, thanh menu trên mỗi nền tảng, biểu tượng khay, phím nóng chung.
- [Hệ thống xung quanh ứng dụng](system.md): hộp thoại, shell, thư mục của ứng dụng, giao diện, ngôn ngữ, tài liệu gần đây, mở khi đăng nhập, URL scheme và loại tệp, luôn cập nhật, bí mật, xem tệp và mô tả.
- [Tài liệu](documents.md): ứng dụng dựa trên tài liệu với `myzig.Documents`: một cửa sổ cho mỗi tài liệu, lưu, tự động lưu, khôi phục, menu Tệp.
- [Âm thanh](audio.md): âm thanh, luồng và trình phát, trộn, đầu ra của hệ thống.
- [Clipboard và dữ liệu kéo](data-transfer.md): bảng tạm, dữ liệu kéo đã nhập, kéo ra khỏi cửa sổ.

Các trang web:

- [Trang](pages.md): tùy chọn trang, sơ đồ `myzig://`, sơ đồ riêng của ứng dụng, eval, sự kiện trang, quyền, tải xuống, tin cậy, tìm, PDF, cookie, kiểm tra trang headless.
- [Ràng buộc](bindings.md): dịch vụ bị ràng buộc, `myzig.Call`, lỗi, sự kiện đã nhập, kênh, client được tạo và ánh xạ loại của nó.
- [Giao diện người dùng](frontend.md): thời gian chạy `window.myzig`, frontend được xây dựng, máy chủ nhà phát triển, vùng có thể kéo, tập lệnh người dùng, trình kiểm tra web.

Native UI:

- [Giao diện native](ui/README.md): hướng dẫn về `myzig.ui`, với chỉ mục các trang: view, bố cục, kiểu dáng, văn bản, mọi nhóm widget, lớp phủ, cấu trúc, danh sách, chuyển động, biến đổi, vẽ, biểu đồ, Markdown, vùng văn bản, trình soạn thảo mã, văn bản đa dạng thức, shader, khả năng truy cập, từ phải sang trái, trình kiểm tra, kiểm tra, kết xuất và hiệu suất.
- [Giao diện native trong trình duyệt](browsers.md): mục tiêu `wasm32-wasi`, trang web tĩnh, những gì hoạt động trong trình duyệt.

Mọi thứ khác:

- [Ngôn ngữ](i18n.md): danh mục tin nhắn, số nhiều, số và ngày, từ phải sang trái, chuỗi riêng của myzig, các trang đã dịch.
- [Plugin](plugins.md): sử dụng và ghi các plugin cũng như các plugin chính thức: [fetch](plugins/fetch.md), [websocket](plugins/websocket.md), [sqlite](plugins/sqlite.md), [watch](plugins/watch.md), [updater](plugins/updater.md), [terminal](plugins/terminal.md), [glass](plugins/glass.md), [game](plugins/game.md), [signals](plugins/signals.md) và [mainthread](plugins/mainthread.md).
- [myzig CLI](cli.md): `init`, `dev`, `build`, `generate`, `icon`, `keygen`, `doctor`, `version` và cờ `--myzig-*` của ứng dụng.
- [Cấu hình](configuration.md): mọi trường của `myzig.zon`.
- [Xây dựng và phân phối](distribution.md): những gì `myzig build` tạo ra trên mỗi nền tảng (`.app` và `.dmg`, `.exe`, `.zip` và trình cài đặt NSIS, `.tar.gz` và `.deb`), ký kết, xây dựng chéo.
- [Cập nhật](updates.md): các bản cập nhật đã ký với `myzig keygen`, `myzig build` và `--upload` (GitHub, S3), dành cho plugin trình cập nhật.
- [Benchmark](benchmarks.md): bộ nhớ của một cửa sổ trang web so với mygo và Electron, các tiến trình của WebView2 là gì, các cờ Chromium giúp dùng ít bộ nhớ hơn.

Cách thức hoạt động của myzig dành cho cộng tác viên:

- [Kiến trúc](architecture.md): các lớp, chọn nền tảng tại thời điểm biên dịch, phân luồng, code native không có C.
- [IPC và sinh TypeScript](architecture-ipc.md): giao thức dây giữa các trang và Zig, hộp thư đi, kênh, sơ đồ, `tsgen`.
- [Đang kết xuất giao diện native](architecture-rendering.md): một khung, các phiên bản, năm bộ kết xuất và bản đối chiếu CPU, văn bản và tập bản đồ, các bề mặt.
- [Kiểm thử, kích thước nhị phân và thêm tính năng](architecture-testing.md): mọi bước kiểm thử, thùng chứa Linux và Wine, leo đồi và danh sách kiểm tra cho tính năng mới.

Các quy tắc để thay đổi myzig, bằng tay hoặc thông qua agent, có trong [AGENTS.md](../../AGENTS.md).

<a id="this-documentation-as-a-site"></a>

## Đọc tài liệu trên website

Các trang Markdown cũng tạo thành website [VitePress](https://vitepress.dev), có sidebar, tìm kiếm và giao diện tối. Sau khi cài Node:

```sh
cd docs
npm install
npm run dev       # serves the site at http://localhost:5173, live
npm run build     # writes it to docs/.vitepress/dist, failing on any dead link
npm run preview   # serves what build wrote
```

`docs/.vitepress/config.mts` giữ phần điều hướng và thanh bên: một trang mới sẽ có vị trí ở đó. Các trang vẫn giữ nguyên Markdown, đọc tương tự trên GitHub; các liên kết ngoài `docs/` (đến `AGENTS.md`, nguồn, ghi chú điểm chuẩn) trở thành liên kết đến kho lưu trữ trên trang web.

Website mặc định dùng tiếng Anh tại đường dẫn gốc; bản tiếng Việt nằm dưới `/vi/`. Dùng menu ngôn ngữ để chuyển giữa hai bản của cùng một trang. Khi đọc trên GitHub, xem [bản tiếng Anh](../README.md). Tên API, lệnh và ví dụ code được giữ nguyên giữa hai ngôn ngữ.
