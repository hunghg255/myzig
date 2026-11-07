<a id="native-ui-in-browsers"></a>

# Giao diện native trong trình duyệt

App giao diện native cũng chạy được trong trình duyệt, biên dịch sang WebAssembly cho `wasm32-wasi`. App không cần sửa gì: ví dụ counter build cho trình duyệt nguyên như vậy.

```zig
pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Counter" });
    defer app.destroy();
    var state: Counter = .{};
    _ = try app.newWindow(.{ .title = "Counter", .content = .{ .view = .init(&state, Counter.view) } });
    try app.run();
}
```

- Cửa sổ của app hiện trên các canvas của một trang, vẽ bằng WebGL 2 với cùng shader như trên Linux.
- Trình duyệt không có libc. Thư viện chuẩn của Zig nói chuyện qua WASI, và host của trang trả lời bằng JavaScript (`src/web/host_wasi.js`), với một hệ thống file trong bộ nhớ.
- Backend cho trình duyệt là `src/web/`. `src/myzig.zig` chọn nó cho `.wasi`, như chọn các backend khác cho hệ điều hành của chúng.

<a id="building"></a>

## Build

Với CLI, `myzig build --platform web` build app vào `<out>/web`, một site tĩnh có thể phục vụ từ bất kỳ đâu (xem [CLI](cli.md)). Mặc định là ReleaseSmall, trừ khi `--optimize` chỉ định khác.

```
index.html  host.js  host_gl.js  host_wasi.js   the page and its host
app.wasm                                        the app
fonts/fonts.json  fonts/*.ttf                   the fonts it draws text with
```

`build.zig` của app (như `myzig init` tạo ra) export các hàm mà host gọi bằng `if (target.result.os.tag == .wasi) exe.rdynamic = true;`.

Không dùng CLI thì `addSite` trong `build.zig` của myzig tạo ra cùng site đó từ build của app:

```zig
const std = @import("std");
const myzig_build = @import("myzig");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("myzig", .{});
    const site = myzig_build.web.addSite(b, .{
        .name = "counter",
        .main = b.path("src/main.zig"),
        .myzig = dep.path("src"),
        // .fonts = "fonts",            // thư mục chứa các file .ttf/.ttc để đóng gói kèm
        // .optimize = .ReleaseSmall,   // mặc định
    });
    b.step("web", "Build the app for browsers").dependOn(site.step);
}
```

- Site được cài vào `zig-out/web/<name>`. `install_subdir` đổi chỗ này.
- `site.dir` là thư mục của site trước khi cài, còn `site.wasm` là bước biên dịch.

Trong repository của chính myzig:

```sh
zig build web                    # counter, gallery, gestures vào zig-out/web/<name>
zig build web -Dweb-fonts=DIR    # với các font trong DIR
zig build test-web               # chạy headless trên Node
zig build test-web -Dweb-browser="/path/to/chrome-or-edge" # test thêm wheel/pinch của DOM, headless
```

Phục vụ thư mục này qua HTTP, với WebAssembly có kiểu `application/wasm`, như phần lớn server vẫn làm. `index.html` khởi động app:

```html
<script type="module">
  import { start } from "./host.js";
  start({ wasm: "app.wasm", fonts: "fonts/" });
</script>
```

| Tùy chọn của `start` | |
|---|---|
| `wasm`, `fonts` | app và thư mục font |
| `container` | phần tử chứa các cửa sổ |
| `args`, `env` | dòng lệnh và biến môi trường của app |
| `webgl: false` | vẽ bằng CPU |
| `embed: true` | chạy app như một vị khách trong trang của bạn |

<a id="in-a-page-of-your-own"></a>

### Trong trang của riêng bạn

```js
const host = await start({
  wasm: "/app.wasm",
  fonts: "/fonts/",
  container: document.getElementById("demo"), // trang tự đặt chiều cao cho nó
  args: ["app", "--demo=buttons"],
  embed: true,
});
// Về sau:
host.destroy();
```

`embed: true` chạy app như một vị khách trong một trang có vòng đời riêng, giống các demo trên site này:

- Trang giữ tiêu đề của nó, và giữ bàn phím cho tới khi người dùng bấm vào app.
- Chạm vẫn scroll được trang.
- Lăn chuột trên app thì scroll trang, trừ khi có thứ gì trong app scroll.
- `start` resolve ra host. `destroy()` của host gỡ app khi trang không cần nữa: các cửa sổ, WebGL context của chúng, timer và listener của app.

<a id="fonts"></a>

## Font

Chữ được vẽ bằng bộ đọc TrueType của chính myzig, từ các font mà site đóng gói kèm.

- Host tải các font mà `fonts/fonts.json` liệt kê vào hệ thống file WASI (`/usr/share/fonts`), nơi cơ sở dữ liệu font tìm thấy chúng.
- Font lấy từ tùy chọn `fonts`. Với CLI, đó là thư mục `fonts/` của app.
- Nếu không có, chúng lấy từ thư mục font của hệ thống: bộ đầu tiên tìm thấy trong các họ font mà `src/web/site.zig` liệt kê. Đó là Inter, DejaVu Sans hoặc Liberation Sans trên Linux, Segoe UI trên Windows, Arial trên macOS.
- Hãy kiểm tra giấy phép của chúng trước khi đăng site.
- Build không có font nào để đóng gói sẽ cảnh báo: chữ sẽ không được vẽ.

<a id="what-works"></a>

## Những gì chạy được

- **Vẽ.**
  - Frame vẽ bằng WebGL 2 theo device pixel ratio, ở animation frame kế tiếp của trình duyệt sau khi có gì đó thay đổi. Frame vẽ lại liên tục khi có animation; lúc rảnh thì không có gì chạy.
  - Hiệu ứng backdrop, layer làm mờ và [shader](ui/shaders.md) vẽ giống như trên desktop.
  - Không có WebGL 2 thì renderer CPU vẽ các frame, hiển thị qua một canvas 2D.
  - WebGL context bị mất sẽ vẽ lại khi trình duyệt khôi phục nó.
- **Cửa sổ.**
  - Mỗi cửa sổ là một canvas lấp đầy phần tử có ID `myzig`, nếu không có thì lấp đầy body. Cửa sổ mở sau che các cửa sổ trước.
  - Trang quyết định kích thước cửa sổ, nên các tùy chọn kích thước, vị trí và thanh tiêu đề không có tác dụng.
  - Tiêu đề của cửa sổ hiện sau cùng là tiêu đề của trang.
- **Input.**
  - Con trỏ kèm số lần bấm, bánh xe chuột và touchpad, và phím (theo `KeyboardEvent.key`).
  - Bộ gõ soạn chữ trong một text area giấu khỏi tầm nhìn, đặt ngay tại con trỏ soạn thảo.
  - Trên Mac, ⌘ đóng vai Control cho các phím tắt của view, vì view coi trình duyệt như đang chạy trên một hệ không phải macOS.
  - Phím tắt của menu vẫn hoạt động, dù không có thanh menu nào hiện ra.
- **Clipboard.** Chữ copy đi vào clipboard của trình duyệt (`navigator.clipboard`), và paste thì lấy từ clipboard của hệ thống. Đọc clipboard từ code trả về thứ app copy sau cùng: trình duyệt chỉ đưa clipboard cho thao tác paste.
- **Giao diện sáng tối.** Dark mode theo `prefers-color-scheme` của trình duyệt và đổi theo nó. Trang có thể tự chọn bằng `data-myzig-theme="dark"` hoặc `"light"` trên phần tử gốc.
- **Desktop.**
  - `myzig.shell.openUrl` mở một tab.
  - `myzig.dialog.message` hỏi bằng `alert` và `confirm`.
  - `myzig.system.locale` và `languages` là `navigator.languages`.
  - Các thư mục của app (`myzig.path`) nằm trong hệ thống file WASI, tồn tại theo vòng đời của trang: `/home`, `/tmp`, và thư mục riêng của app dưới `/home/.local/share`.
  - Timer là timer của trình duyệt.
- **Chạy headless** (`--myzig-snapshot`, `--myzig-generate`) hoạt động như trên desktop, dưới một runtime WASI.

<a id="what-does-not"></a>

## Những gì không chạy

Những thứ sau không có gì trong trình duyệt để thay thế. Chúng trả về `error.Unsupported`, không trả về gì, hoặc không làm gì:

- cửa sổ chứa trang web (nội dung `.page`);
- tray, thông báo, hộp thoại chọn file, secret;
- theo dõi file descriptor và process;
- phát âm thanh;
- kéo thả ra ngoài cửa sổ.

Chế độ single instance luôn coi app là bản đầu tiên. Công nghệ hỗ trợ tiếp cận chưa thấy được nội dung: tất cả những gì nó đọc được là một canvas.

<a id="testing"></a>

## Test

- `zig build test-web` chạy counter, gallery và gestures trên Node (`src/web/test_node.mjs`).
  - WASI và font của host là thật; các hàm của trang là bản giả. Không có WebGL: frame được vẽ bằng CPU.
  - Nó kiểm tra một frame được vẽ, lúc rảnh không vẽ gì, và bấm vào một đoạn chữ thì hiện đoạn khác.
  - Ví dụ gestures còn kiểm tra pinch và pan ngang/dọc.
- Thêm `-Dweb-browser="/path/to/chrome-or-edge"` vào lệnh trên để chạy các kiểm tra Node cùng test `WheelEvent` thật của DOM trong một trình duyệt headless. Chúng kiểm tra delta theo pixel/dòng/trang, Ctrl-pinch, Ctrl-scroll theo dòng, và việc giữ nguyên hành vi mặc định của trình duyệt bên ngoài handler của view.
- `src/web/test_browser_run.mjs BROWSER SITE_DIR "click=Increment&expect=1"` phục vụ một site và chạy `test_browser.js` trong Chromium headless (Chrome hoặc Edge, ẩn).
  - Frame vẽ bằng WebGL 2 và khớp pixel với renderer CPU.
  - Lúc rảnh không vẽ gì.
  - Event con trỏ của DOM trên canvas làm view thay đổi.
  - `index` nạp trang của chính site và kiểm tra app đã khởi động ở đó.
- `src/web/test_wasm.mjs` chạy unit test của myzig, biên dịch cho wasm32-wasi (`zig test -target wasm32-wasi --test-no-exec`), trên Node.

<a id="under-the-hood"></a>

## Bên trong

`main` tạo app và các cửa sổ, rồi `App.run` giao app cho trình duyệt. Nó kết thúc `main` nhưng giữ lại stack.

- Từ đó, event của trình duyệt điều khiển app qua các hàm app export (`src/web/exports.zig`): `myzig_web_pointer`, `myzig_web_key`, `myzig_web_text`, `myzig_web_resize`, `myzig_web_animation_frame`, `myzig_web_timer`, ...
- Mỗi event chạy một frame nếu nó làm thay đổi gì đó. Nó báo cho host biết view có nhận event hay không, để chỉ khi đó mới chặn hành vi mặc định của trình duyệt.
- App gọi trang qua các hàm import từ module `"myzig"` (`src/web/js.zig`): mở cửa sổ, xin animation frame, con trỏ chuột, vị trí con trỏ soạn thảo cho bộ gõ, timer, clipboard, URL, hộp thoại message, giao diện sáng tối và ngôn ngữ.
- Chữ đi qua một buffer dùng chung trong bộ nhớ WebAssembly.

[Trang về rendering](architecture-rendering.md) trong tài liệu kiến trúc mô tả các renderer.
