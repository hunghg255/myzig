<a id="getting-started"></a>

# Bắt đầu

myzig giúp xây dựng ứng dụng desktop bằng Zig. Cửa sổ hiển thị giao diện native do myzig tự vẽ, hoặc trang web trong webview hệ thống. Frontend gọi code Zig qua client được sinh tự động. Hướng dẫn này trình bày cách cài công cụ, tạo và chạy ứng dụng, build bản phát hành rồi khám phá các ví dụ.

<a id="install"></a>

## Cài đặt

Bạn cần **Zig 0.17.0** trở lên (`minimum_zig_version` trong `build.zig.zon`). myzig nạp thư viện hệ thống của Linux và Windows khi ứng dụng khởi động, thay vì liên kết lúc build. Vì vậy có thể build cho hai nền tảng này từ máy khác bằng `-Dtarget=...` mà không cần cài thêm thư viện. Ứng dụng macOS liên kết các framework của Apple nên cần macOS SDK khi build.

Ứng dụng cần những gì để chạy:

| | Khi build | Khi chạy |
|---|---|---|
| macOS | macOS SDK (Xcode hoặc Command Line Tools) | Không cần cài thêm |
| Linux | Không cần cài thêm | GTK 3; WebKitGTK (`libwebkit2gtk-4.1` hoặc `-4.0`) khi dùng trang web |
| Windows | Không cần cài thêm | WebView2 Runtime khi dùng trang web (có sẵn trên Windows 11) |
| trình duyệt | không có gì | một trình duyệt có WebGL 2 (xem [Trình duyệt](browsers.md)) |

Nhận myzig và xây dựng công cụ dòng lệnh:

```sh
git clone https://github.com/hunghg255/myzig
cd myzig/cli
zig build -Doptimize=ReleaseSmall    # zig-out/bin/myzig
```

Đặt `cli/zig-out/bin` trên `PATH` của bạn hoặc chạy công cụ từ bản checkout với `zig build run -- <command>` trong `cli/`. `myzig doctor` kiểm tra xem máy có thể xây dựng và chạy các ứng dụng: Zig, SDK và thư viện của nền tảng (macOS SDK; GTK 3 và WebKitGTK; WebView2 Runtime).

myzig trước đây có tên nanoui. Mô-đun, các cờ (`--myzig-*`), runtime của trang (`window.myzig`) và URL scheme (`myzig://`) đã dùng tên mới. Hệ thống build vẫn xuất mô-đun với tên `nanoui` để tương thích với ứng dụng dùng tên cũ.

<a id="create-an-app"></a>

## Tạo một ứng dụng

```sh
myzig init hello                  # native UI (the default template)
myzig init hello --template web   # a web page calling Zig
```

`init` tạo một ứng dụng trong một thư mục mới hoặc trống. Đó là gói Zig có `build.zig.zon` phụ thuộc vào myzig:

```
hello/
  build.zig          the app's build: `zig build run`, `zig build test`
  build.zig.zon      depends on myzig
  myzig.zon          the app, for the CLI: name, identifier, icon, frontend
  src/main.zig       the app
  resources/icon.png its icon (myzig's default one)
  frontend/          the web template's pages (index.html, main.js, style.css)
  .gitignore
```

Chọn nguồn myzig: `--myzig PATH` dùng bản checkout cục bộ và tạo phụ thuộc dạng đường dẫn; `--myzig URL` dùng nguồn mà `zig fetch` có thể tải. Nếu không có hai cờ này, `init` dùng bản checkout trong `MYZIG_ROOT`, nếu có; nếu không thì dùng kho myzig. `--name` đặt tên ứng dụng khác tên thư mục. Sau khi tạo mẫu web, công cụ chạy bước sinh client một lần để ghi client của frontend; dùng `--skip-generate` để hoãn việc đó đến lần chạy `myzig dev` đầu tiên.

<a id="native-ui"></a>

### Giao diện native

`src/main.zig` của mẫu gốc là một bộ đếm:

```zig
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const Counter = struct {
    n: i64 = 0,

    fn view(s: *Counter, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 16 });
        defer ui.end(c);
        ui.textf(c, .{ .size = 56, .weight = .bold }, "{d}", .{s.n});
        if (ui.button(c, "Increment", .{ .variant = .primary, .size = 16 }).clicked) s.n += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Hello" });
    defer app.destroy();
    var state: Counter = .{};
    _ = try app.newWindow(.{
        .title = "Hello",
        .width = 420,
        .height = 300,
        .content = .{ .view = .init(&state, Counter.view) },
    });
    try app.run();
}

test "the button counts" {
    var state: Counter = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, Counter.view), .{});
    defer t.deinit();
    try t.clickText("Increment");
    try std.testing.expectEqual(@as(i64, 1), state.n);
}
```

View là một chức năng của trạng thái ứng dụng, chạy cho mọi frame. Một widget trả lời những gì đã xảy ra với nó trong khung trước đó (`.clicked`); khi điều đó thay đổi trạng thái, khung sẽ được tạo lại trước khi được vẽ. Kiểm thử chạy cùng một view trong `ui.Tester`, không có cửa sổ. Xem [Giao diện native](ui/README.md).

<a id="a-web-page"></a>

### Một trang web

Mẫu web liên kết một dịch vụ và hiển thị `frontend/` trong một cửa sổ:

```zig
const std = @import("std");
const myzig = @import("myzig");
const assets = @import("assets");

const Greeter = struct {
    pub const myzig_params = .{ .greet = .{"name"} };

    /// Returns a greeting.
    pub fn greet(_: *Greeter, call: *myzig.Call, name: []const u8) ![]const u8 {
        const who = std.mem.trim(u8, name, " ");
        return std.fmt.allocPrint(call.arena, "Hello, {s}!", .{if (who.len == 0) "stranger" else who});
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Hello" });
    defer app.destroy();
    var greeter: Greeter = .{};
    try app.bind(&greeter);
    // `myzig dev` points the window at the dev server, when there is one.
    const url = init.environ_map.get("MYZIG_DEV_URL") orelse "/";
    _ = try app.newWindow(.{
        .title = "Hello",
        .width = 720,
        .height = 520,
        .content = .{ .page = .{ .url = url, .assets = &assets.files } },
    });
    try app.run();
}
```

```js
// frontend/main.js
import { Greeter } from "/myzig.js";

document.getElementById("greeting").textContent = await Greeter.greet("Ada");
```

`assets` là `frontend/myzig_assets.zig`, CLI ghi: các tệp của frontend được nhúng vào ứng dụng và được phân phát tại `myzig://localhost/`. `/myzig.js` là client được tạo từ các dịch vụ liên kết, được nhập bởi `frontend/myzig.d.ts`. Xem [Trang](pages.md) và [Bindings](bindings.md).

<a id="develop"></a>

## Phát triển

```sh
cd hello
myzig dev            # build, run, and rebuild and restart as files change
zig build run        # or with Zig alone
zig build test       # the app's tests
```

`myzig dev` xem các tệp của ứng dụng thông qua hệ thống (không có polling ý kiến nào), viết lại client của mẫu web khi dịch vụ thay đổi và, với `dev_command` và `dev_url` trong `myzig.zon`, trước tiên hãy chạy máy chủ nhà phát triển (Vite, ...) và trỏ ứng dụng tới nó thông qua `MYZIG_DEV_URL`. Các đối số sau `--` sẽ chuyển đến ứng dụng. Xem [CLI](cli.md) và [Cấu hình](configuration.md).

<a id="check-an-app-without-a-window"></a>

## Kiểm tra ứng dụng không có cửa sổ

Các ứng dụng lấy cờ chạy ẩn, các kiểm thử và tác nhân sử dụng thay vì hiển thị cửa sổ:

```sh
zig-out/bin/hello --myzig-snapshot=shot.png                 # draw the first native UI window to a PNG
zig-out/bin/hello --myzig-snapshot=shot.png --myzig-script="click:Increment" --myzig-dark
zig-out/bin/hello --myzig-snapshot=shot.png --myzig-wait=1  # run the loop for a second first
zig-out/bin/hello --myzig-eval='myzig.call("Greeter.greet","Ada").then(v => { myzig.log(v); myzig.window.close() })'
zig-out/bin/hello --myzig-generate=frontend                 # write myzig.js and myzig.d.ts, and exit
zig-out/bin/hello --myzig-hidden                            # run, never showing a window
```

`--myzig-eval` chạy tập lệnh trên mỗi trang sau khi DOM của nó sẵn sàng; trang báo cáo với `myzig.log()` và kết thúc quá trình chạy với `myzig.window.close()`. Ảnh chụp nhanh, tập lệnh và Trình kiểm tra nằm trong [Thử nghiệm](ui/testing.md).

<a id="build-the-release"></a>

## Xây dựng bản phát hành

```sh
myzig build                        # this platform and architecture
myzig build --platform windows     # from any machine
myzig build --platform linux --arch aarch64
myzig build --platform web         # a static site (native UI only)
```

`build` biên dịch một nhị phân `ReleaseSmall` bị lược bỏ (`--optimize fast` hoặc `safe` cho các loại khác) và đóng gói nó trong `dist/<platform>-<arch>`: `.app` và `.dmg` trên macOS, `.exe` với các tài nguyên biểu tượng và phiên bản của nó và `.zip` (và một trình cài đặt, với NSIS) cho Windows, một thư mục, `.tar.gz` và `.deb` cho Linux. Một bộ đếm có dung lượng khoảng 0,7 MB. Xem [Phân phối](distribution.md).

<a id="the-examples"></a>

## Các ví dụ

Các ví dụ của kho lưu trữ được xây dựng với `zig build` từ gốc của nó, thành `zig-out/bin` và mỗi ví dụ chạy với `zig build run-<name>`:

| ví dụ | nó thể hiện điều gì |
|---|---|
| `counter` | ứng dụng giao diện native nhỏ nhất: view là một chức năng của trạng thái |
| `gallery` | tham quan bộ công cụ giao diện native: bố cục, văn bản, mọi widget, lớp phủ, bản vẽ, chuyển động, kéo và thả |
| `hello` | một trang web gọi Zig: các dịch vụ bị ràng buộc, các sự kiện đã nhập, client được tạo |
| `todo` | một ứng dụng web nhỏ hoàn chỉnh: các dịch vụ và sự kiện đã nhập, tính bền vững, hộp thoại, menu, cửa sổ được đồng bộ hóa |
| `native` | màn hình nền từ một trang: thanh menu, biểu tượng khay, hộp thoại, thông báo, bảng nhớ tạm |
| `pages` | kiểm tra các trang: lược đồ, kênh, sự kiện, quyền, lượt tải xuống, đánh giá, tìm, PDF, cookie, tin cậy |
| `documents` | trình chỉnh sửa ghi chú trên `myzig.Documents`: menu Tệp, cửa sổ cho mỗi ghi chú, tự động lưu, khôi phục |
| `notes` | ghi chú được chỉnh sửa dưới dạng văn bản có định dạng, với thanh công cụ, liên kết và phím tắt Markdown |
| `markdown-chat` | trả lời trực tuyến dưới dạng Markdown |
| `code-editor` | trình soạn thảo mã, trình xem khác biệt và vùng văn bản |
| `text-buffer` | 100 000 sợi dây chỉ được bày ra trước mắt |
| `text-input` | một trường văn bản được xây dựng từ các kiểu nhập văn bản nguyên thủy |
| `clipboard` | một mô hình dữ liệu được sao chép và kéo dưới dạng văn bản, HTML và JSON |
| `drag-drop` | kéo trong và giữa các cửa sổ, ra các ứng dụng khác, thả các tập tin vào |
| `chart-streaming` | dạng sóng cuộn của 15 000 mẫu, 1 000 mẫu mới mỗi giây |
| `confetti` | bản demo của canvas-confetti trong giao diện native |
| `piano` | một cây đàn piano tổng hợp được chơi bằng `myzig.audio` |
| `timeline` | vài thanh thiếu niên trên một đầu phát (`ui.motion.timeline`) |
| `blackhole` | một tia lỗ đen được vạch ra trong một shader được viết một lần |
| `chat-glow` | một cuộc trò chuyện rực sáng, với các bóng đổ cho quả cầu, chiếc nhẫn và ánh sáng lung linh |
| `wind` | một khung ký tự được khuấy bởi trình tạo bóng gió |
| `effort-slider` | thanh trượt "bộ não thiên hà", với các bóng đổ và chuyển động |
| `mayoi` | một trò chơi nhỏ được vẽ dưới dạng một shader |
| `farm` | trò chơi nông trại trên plugin trò chơi: `cd examples/farm && zig build run` |

Các plugin đều có ví dụ riêng (`plugins/<name>/example`).

Các bước khác của quá trình xây dựng gốc:

```sh
zig build test                    # unit and widget tests
zig build test -Dportable=true    # the same with myzig's own text and CPU renderer
zig build test-pages              # pages run hidden: hello calling Zig, and examples/pages
zig build web                     # counter and gallery for browsers, in zig-out/web/<name>
zig build test-web                # those run headless under Node
zig build gen                     # write the hello example's generated client
zig build lines                   # every file at most 600 lines
```

<a id="next-steps"></a>

## Các bước tiếp theo

- [Ứng dụng](app.md): vòng đời của ứng dụng, một phiên bản duy nhất, liên kết sâu, thông báo.
- [Cửa sổ](windows.md): tùy chọn, sự kiện, thanh tiêu đề, bảng thả xuống.
- [Menu, khay và phím tắt chung](menus.md).
- [Giao diện native](ui/README.md) hoặc [Trang](pages.md), tùy theo cửa sổ của bạn hiển thị.
