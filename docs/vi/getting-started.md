<a id="getting-started"></a>

# Bắt đầu

myzig dùng để làm app desktop bằng Zig. Một cửa sổ hiện một trong hai thứ:

- native UI do myzig tự vẽ, viết hoàn toàn bằng Zig;
- một trang web trong webview của hệ thống, có frontend gọi code Zig của bạn qua một client được sinh tự động.

Trang này cài công cụ, tạo một app, chạy nó và build bản phát hành. Sau đó điểm qua các ví dụ.

<a id="install"></a>

## Cài đặt

Bạn cần **Zig 0.17.0** trở lên (`minimum_zig_version` trong `build.zig.zon`).

- myzig nạp những gì Linux và Windows có sẵn khi app khởi động, thay vì link chúng. Nhờ vậy app cho hai nền tảng này build được từ bất kỳ máy nào (`-Dtarget=...`), không cần gì thêm.
- App macOS link các framework của Apple, nên phải build ở nơi có macOS SDK.

App cần gì để chạy:

| | để build | để chạy |
|---|---|---|
| macOS | macOS SDK (Xcode hoặc Command Line Tools) | không cần gì |
| Linux | không cần gì | GTK 3; WebKitGTK (`libwebkit2gtk-4.1` hoặc `-4.0`) cho trang web |
| Windows | không cần gì | WebView2 Runtime cho trang web (Windows 11 có sẵn) |
| trình duyệt | không cần gì | một trình duyệt có WebGL 2 (xem [Trình duyệt](browsers.md)) |

Lấy myzig về, rồi build công cụ dòng lệnh:

```sh
git clone https://github.com/hunghg255/myzig
cd myzig/cli
zig build -Doptimize=ReleaseSmall    # zig-out/bin/myzig
```

Thêm `cli/zig-out/bin` vào `PATH`. Hoặc chạy công cụ ngay trong bản checkout bằng `zig build run -- <command>` trong `cli/`.

`myzig doctor` kiểm tra máy có build và chạy được app không: Zig, cùng SDK và thư viện của nền tảng (macOS SDK; GTK 3 và WebKitGTK; WebView2 Runtime).

<details>
<summary>myzig trước đây tên là nanoui</summary>

Module, các flag (`--myzig-*`), runtime của trang (`window.myzig`) và URL scheme (`myzig://`) đều mang tên mới. Build vẫn xuất module dưới tên `nanoui`, cho các app còn import tên cũ.

</details>

<a id="create-an-app"></a>

## Tạo app

```sh
myzig init hello                  # native UI (template mặc định)
myzig init hello --template web   # một trang web gọi Zig
```

`init` tạo app trong một thư mục mới hoặc thư mục rỗng. App là một package Zig, có `build.zig.zon` phụ thuộc vào myzig:

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

| Tùy chọn | |
|---|---|
| `--myzig PATH` | một bản checkout, trở thành dependency dạng path |
| `--myzig URL` | thứ mà `zig fetch` sẽ tải về |
| không có cả hai | bản checkout mà `MYZIG_ROOT` chỉ tới, nếu không thì repository myzig |
| `--name` | tên app khác với tên thư mục |
| `--skip-generate` | bỏ qua lần build đầu của template web; lần `myzig dev` đầu tiên sẽ làm việc đó |

Template web được build một lần ngay sau khi tạo, để ghi client được sinh cho frontend.

<a id="native-ui"></a>

### Native UI

`src/main.zig` của template native là một bộ đếm:

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

- View là một hàm của state của app, chạy ở mọi frame.
- Widget trả lời chuyện đã xảy ra với nó ở frame trước (`.clicked`). Khi điều đó làm đổi state, frame được build lại trước khi vẽ.
- Test chạy cùng view đó trong một `ui.Tester`, không cần cửa sổ.

Xem [Native UI](ui/README.md).

<a id="a-web-page"></a>

### Trang web

Template web bind một service và hiện `frontend/` trong một cửa sổ:

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

- `assets` là `frontend/myzig_assets.zig`, do CLI ghi ra. Nó chứa các file của frontend, được nhúng vào app và phục vụ tại `myzig://localhost/`.
- `/myzig.js` là client sinh ra từ các service đã bind, có kiểu trong `frontend/myzig.d.ts`.

Xem [Trang web](pages.md) và [Binding](bindings.md).

<a id="develop"></a>

## Phát triển

```sh
cd hello
myzig dev            # build, chạy, rồi build lại và khởi động lại khi file đổi
zig build run        # hoặc chỉ dùng Zig
zig build test       # các test của app
```

`myzig dev`:

- theo dõi file của app qua hệ thống; không có gì chạy polling;
- ghi lại client của template web khi các service đổi;
- nếu `myzig.zon` có `dev_command` và `dev_url`, chạy một dev server (Vite, ...) trước, rồi trỏ app tới đó qua `MYZIG_DEV_URL`;
- chuyển các tham số sau `--` cho app.

Xem [CLI](cli.md) và [Cấu hình](configuration.md).

<a id="check-an-app-without-a-window"></a>

## Kiểm tra app không cần cửa sổ

App nhận các flag để chạy ẩn. Test và agent dùng chúng thay vì hiện cửa sổ:

```sh
zig-out/bin/hello --myzig-snapshot=shot.png                 # vẽ cửa sổ native UI đầu tiên ra PNG
zig-out/bin/hello --myzig-snapshot=shot.png --myzig-script="click:Increment" --myzig-dark
zig-out/bin/hello --myzig-snapshot=shot.png --myzig-wait=1  # chạy vòng lặp một giây trước
zig-out/bin/hello --myzig-eval='myzig.call("Greeter.greet","Ada").then(v => { myzig.log(v); myzig.window.close() })'
zig-out/bin/hello --myzig-generate=frontend                 # ghi myzig.js và myzig.d.ts, rồi thoát
zig-out/bin/hello --myzig-hidden                            # chạy, không bao giờ hiện cửa sổ
```

`--myzig-eval` chạy một script trong mỗi trang khi DOM của trang đã sẵn sàng. Trang báo về bằng `myzig.log()`, và kết thúc lần chạy bằng `myzig.window.close()`. Snapshot, script và `ui.Tester` có trong [Test](ui/testing.md).

<a id="build-the-release"></a>

## Build bản phát hành

```sh
myzig build                        # nền tảng và kiến trúc hiện tại
myzig build --platform windows     # từ bất kỳ máy nào
myzig build --platform linux --arch aarch64
myzig build --platform web         # một site tĩnh (chỉ native UI)
```

`build` biên dịch một binary `ReleaseSmall` đã strip; `--optimize fast` hoặc `safe` cho các chế độ khác. Nó đóng gói binary vào `dist/<platform>-<arch>`:

| Nền tảng | Gói |
|---|---|
| macOS | một `.app` và một `.dmg` |
| Windows | một `.exe` kèm icon và thông tin phiên bản, một `.zip`, và một bộ cài nếu có NSIS |
| Linux | một thư mục, một `.tar.gz` và một `.deb` |

App bộ đếm nặng khoảng 0,7 MB. Xem [Phân phối](distribution.md).

<a id="the-examples"></a>

## Các ví dụ

Các ví dụ của repository được build bằng `zig build` từ thư mục gốc, ra `zig-out/bin`. Mỗi ví dụ chạy bằng `zig build run-<name>`:

| ví dụ | nội dung |
|---|---|
| `counter` | app native UI nhỏ nhất: view là một hàm của state |
| `gallery` | dạo qua bộ công cụ native UI: layout, chữ, mọi widget, overlay, vẽ, chuyển động, kéo thả |
| `hello` | một trang web gọi Zig: service đã bind, event có kiểu, client được sinh |
| `todo` | một app web nhỏ nhưng đầy đủ: service và event có kiểu, lưu trữ, dialog, menu, các cửa sổ đồng bộ với nhau |
| `native` | desktop từ một trang web: thanh menu, icon khay hệ thống, dialog, thông báo, clipboard |
| `pages` | test cho trang web: scheme, channel, event, quyền, tải xuống, eval, tìm kiếm, PDF, cookie, độ tin cậy |
| `documents` | trình soạn ghi chú trên `myzig.Documents`: menu File, mỗi ghi chú một cửa sổ, tự lưu, khôi phục |
| `notes` | ghi chú soạn bằng rich text, có thanh công cụ, liên kết và phím tắt Markdown |
| `markdown-chat` | câu trả lời stream về dưới dạng Markdown |
| `code-editor` | trình soạn code, trình xem diff và text area |
| `text-buffer` | 100 000 dòng trong một rope, chỉ layout phần đang hiện |
| `text-input` | một ô nhập chữ dựng từ các thành phần cơ bản của text input |
| `clipboard` | một mô hình dữ liệu được sao chép và kéo dưới dạng text, HTML và JSON |
| `drag-drop` | kéo trong và giữa các cửa sổ, ra các app khác, thả file vào |
| `chart-streaming` | dạng sóng cuộn liên tục 15 000 mẫu, thêm 1 000 mẫu mỗi giây |
| `confetti` | các demo của canvas-confetti trong native UI |
| `piano` | một cây đàn piano tổng hợp, chơi bằng `myzig.audio` |
| `timeline` | nhiều tween trên một đầu phát (`ui.motion.timeline`) |
| `blackhole` | một hố đen dựng bằng ray tracing trong một shader chỉ viết một lần |
| `chat-glow` | một khung chat phát sáng, với shader cho quả cầu, vòng tròn và ánh lấp lánh |
| `wind` | một tấm chữ bị shader gió khuấy động |
| `effort-slider` | slider "galaxy brain", với shader và chuyển động |
| `mayoi` | một game nhỏ vẽ bằng một shader duy nhất |
| `loading` | 29 chỉ báo đang tải native của loading.dev, có điều khiển kích thước, màu, easing, đầu nét và tạm dừng |
| `farm` | một game nông trại trên plugin game: `cd examples/farm && zig build run` |

Các plugin có ví dụ riêng (`plugins/<name>/example`).

Các bước khác của build ở thư mục gốc:

```sh
zig build test                    # test đơn vị và test widget
zig build test -Dportable=true    # như trên, với phần chữ và renderer CPU của myzig
zig build test-pages              # chạy ẩn các trang web: hello gọi Zig, và examples/pages
zig build web                     # counter và gallery cho trình duyệt, trong zig-out/web/<name>
zig build test-web                # chạy chúng headless dưới Node
zig build gen                     # ghi client được sinh của ví dụ hello
zig build lines                   # mọi file tối đa 600 dòng
```

<a id="next-steps"></a>

## Bước tiếp theo

- [Ứng dụng](app.md): vòng đời, chạy một instance duy nhất, deep link, thông báo.
- [Cửa sổ](windows.md): tùy chọn, event, thanh tiêu đề, flyout.
- [Menu, khay hệ thống và phím tắt toàn cục](menus.md).
- [Native UI](ui/README.md) hoặc [Trang web](pages.md), tùy cửa sổ của bạn hiện gì.
