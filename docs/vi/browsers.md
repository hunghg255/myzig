<a id="native-ui-in-browsers"></a>

# Giao diện native trong trình duyệt

Một ứng dụng giao diện native cũng chạy trong trình duyệt, được biên dịch thành WebAssembly cho `wasm32-wasi`: cửa sổ của nó hiển thị trên canvas của một trang, được vẽ bằng WebGL 2 bởi cùng một shader như trên Linux. Không có gì thay đổi trong ứng dụng: ví dụ truy cập được xây dựng cho các trình duyệt.

```zig
pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Counter" });
    defer app.destroy();
    var state: Counter = .{};
    _ = try app.newWindow(.{ .title = "Counter", .content = .{ .view = .init(&state, Counter.view) } });
    try app.run();
}
```

Không có libc trong trình duyệt: thư viện chuẩn của Zig nói về WASI, mà máy chủ của trang trả lời bằng JavaScript (`src/web/host_wasi.js`), với hệ thống tệp trong bộ nhớ. Phần phụ trợ của trình duyệt là `src/web/`, được `src/myzig.zig` chọn cho `.wasi` vì những phần khác dành cho hệ thống của họ.

<a id="building"></a>

## Tòa nhà

Với CLI, `myzig build --platform web` xây dựng ứng dụng (ReleaseSmall trừ khi `--optimize` có quy định khác) thành `<out>/web`, một trang web tĩnh để phân phối từ mọi nơi (xem [CLI](cli.md)):

```
index.html  host.js  host_gl.js  host_wasi.js   the page and its host
app.wasm                                        the app
fonts/fonts.json  fonts/*.ttf                   the fonts it draws text with
```

`build.zig` của ứng dụng (như `myzig init` viết nó) xuất các hàm mà máy chủ gọi bằng `if (target.result.os.tag == .wasi) exe.rdynamic = true;`.

Nếu không có CLI, `addSite` của myzig's `build.zig` sẽ tạo cùng một trang web từ bản dựng của ứng dụng:

```zig
const std = @import("std");
const myzig_build = @import("myzig");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("myzig", .{});
    const site = myzig_build.web.addSite(b, .{
        .name = "counter",
        .main = b.path("src/main.zig"),
        .myzig = dep.path("src"),
        // .fonts = "fonts",            // a directory of .ttf/.ttc files to bundle
        // .optimize = .ReleaseSmall,   // the default
    });
    b.step("web", "Build the app for browsers").dependOn(site.step);
}
```

Trang web được cài đặt vào `zig-out/web/<name>` (`install_subdir` thay đổi nó); `site.dir` là thư mục của nó trước khi cài đặt và `site.wasm` là bước biên dịch. Trong kho lưu trữ riêng của myzig:

```sh
zig build web                    # counter and gallery into zig-out/web/<name>
zig build web -Dweb-fonts=DIR    # with the fonts of DIR
zig build test-web               # both, run headless under Node
```

Cung cấp thư mục qua HTTP, với WebAssugging là `application/wasm`, như hầu hết các máy chủ đều làm. `index.html` khởi động ứng dụng:

```html
<script type="module">
  import { start } from "./host.js";
  start({ wasm: "app.wasm", fonts: "fonts/" });
</script>
```

`start` cũng lấy `container` (phần tử mà cửa sổ đi vào), `args` và `env` (dòng lệnh và môi trường của ứng dụng) và `webgl: false` để vẽ trên CPU.

<a id="fonts"></a>

## Phông chữ

Văn bản là TrueType của chính myzig, được rút ra từ các phông chữ trong gói trang web: máy chủ tìm nạp các danh sách `fonts/fonts.json` đó vào hệ thống tệp WASI (`/usr/share/fonts`), nơi cơ sở dữ liệu phông chữ tìm thấy chúng. Chúng đến từ tùy chọn `fonts` (với CLI, thư mục `fonts/` của ứng dụng), khác từ tập đầu tiên được tìm thấy trong các họ `src/web/site.zig` liệt kê trong thư mục phông chữ của hệ thống: Inter, DejaVu Sans hoặc Giải phóng Sans trên Linux, Segoe UI trên Windows, Arial trên macOS. Kiểm tra giấy phép của họ trước khi xuất bản một trang web với họ. Bản dựng không có phông chữ để gói sẽ cảnh báo: văn bản không vẽ được.

<a id="what-works"></a>

## Những gì hoạt động

- **Vẽ.** Các khung vẽ bằng WebGL 2 ở tỷ lệ pixel của thiết bị, trong frame động tiếp theo của trình duyệt sau khi có thứ gì đó thay đổi, một lần nữa trong khi có thứ gì đó hoạt hình; nhàn rỗi, không có gì chạy. Hiệu ứng phông nền, lớp mờ và [shaders](ui/shaders.md) vẽ như trên màn hình nền. Trong trường hợp trình duyệt không có WebGL 2, các khung được bộ kết xuất CPU vẽ và hiển thị qua khung vẽ 2D. Ngữ cảnh WebGL bị mất sẽ xuất hiện lại sau khi trình duyệt khôi phục nó.
- **Windows.** Mỗi cửa sổ là một khung vẽ trong phần tử có ID `myzig`, nếu không thì phần nội dung sẽ điền vào phần đó; một cửa sổ mở sau sẽ che những cửa sổ trước đó. Trang đặt kích thước của cửa sổ, do đó, các tùy chọn kích thước, vị trí và thanh tiêu đề không có tác dụng gì và tiêu đề của cửa sổ hiển thị cuối cùng là của trang.
- **Đầu vào**: con trỏ có số lần nhấp chuột được đếm, bánh xe và bàn di chuột, các phím (bởi `KeyboardEvent.key`) và các phương thức nhập, tạo thành một vùng văn bản khuất tầm nhìn của dấu mũ. Trên máy Mac, ⌘ là Kiểm soát các phím tắt của view, sử dụng trình duyệt cho hệ thống không phải macOS. Trình tăng tốc của menu hoạt động, mặc dù không có thanh menu nào hiển thị.
- **Bảng nhớ tạm**: văn bản đã sao chép sẽ chuyển vào bảng nhớ tạm của trình duyệt (`navigator.clipboard`) và việc dán sẽ mang lại bảng nhớ tạm của hệ thống. Việc đọc bảng tạm từ mã sẽ trả về những gì ứng dụng đã sao chép lần cuối, vì trình duyệt chỉ chuyển bảng tạm của nó thành một tệp dán.
- **Giao diện**: chế độ tối tuân theo `prefers-color-scheme` của trình duyệt và thay đổi theo đó. Một trang tự chọn giao diện với `data-myzig-theme="dark"` hoặc `"light"` trên phần tử gốc của nó.
- **Màn hình nền**: `myzig.shell.openUrl` mở một tab; `myzig.dialog.message` hỏi với `alert` và `confirm`; `myzig.system.locale` và `languages` là `navigator.languages`; các thư mục của ứng dụng (`myzig.path`) nằm trong hệ thống tệp WASI, trong thời gian tồn tại của trang: `/home`, `/tmp` và thuộc sở hữu của ứng dụng theo `/home/.local/share`. Bộ hẹn giờ là của trình duyệt.
- **Headless chạy** (`--myzig-snapshot`, `--myzig-generate`) hoạt động như trên máy tính để bàn, trong thời gian chạy WASI.

<a id="what-does-not"></a>

## Cái gì không

Windows của các trang web (nội dung `.page`), các khay, thông báo, hộp thoại tệp, bí mật, xem mô tả và quy trình tệp, đầu ra âm thanh cũng như kéo và thả ra khỏi cửa sổ không có gì đại diện cho chúng trong trình duyệt: chúng trả về `error.Unsupported`, không trả lại gì hoặc không làm gì cả. Một trường hợp duy nhất luôn là trường hợp đầu tiên. Công nghệ hỗ trợ chưa nhìn thấy nội dung: tất cả những gì nó đọc là một khung vẽ.

<a id="testing"></a>

## Kiểm tra

- `zig build test-web` chạy bộ đếm và thư viện trong Nút (`src/web/test_node.mjs`), với WASI và phông chữ của máy chủ cũng như các chức năng của trang được giữ nguyên (không có WebGL: khung được vẽ trên CPU): khung vẽ, không vẽ gì khi không hoạt động và nhấp vào văn bản sẽ hiển thị khung khác.
- `src/web/test_browser_run.mjs BROWSER SITE_DIR "click=Increment&expect=1"` phục vụ một trang web và chạy `test_browser.js` trong headless Chrome (Chrome hoặc Edge, ẩn): các khung vẽ bằng WebGL 2 và khớp với các pixel của bộ kết xuất CPU, không có gì vẽ khi không hoạt động và các sự kiện con trỏ DOM trên khung vẽ sẽ thay đổi view. `index` tải trang riêng của trang web và kiểm tra xem ứng dụng đã bắt đầu ở đó chưa.
- `src/web/test_wasm.mjs` chạy các bài kiểm tra đơn vị của myzig được biên dịch cho wasm32-wasi (`zig test -target wasm32-wasi --test-no-exec`) trong Node.

<a id="under-the-hood"></a>

## Dưới mui xe

`main` tạo ứng dụng và các cửa sổ của nó, và `App.run` chuyển ứng dụng đó cho trình duyệt: nó kết thúc `main` với ngăn xếp được giữ nguyên và từ đó trở đi, các sự kiện của trình duyệt sẽ điều khiển ứng dụng thông qua các chức năng mà nó xuất (`src/web/exports.zig`: `myzig_web_pointer`, `myzig_web_key`, `myzig_web_text`, `myzig_web_resize`, `myzig_web_animation_frame`, `myzig_web_timer`, ...). Mỗi sự kiện sẽ chạy một khung khi nó thay đổi thứ gì đó và cho máy chủ biết liệu view có chấp nhận nó hay không, do đó khi đó chế độ mặc định của trình duyệt chỉ bị ngăn chặn. Ứng dụng gọi trang thông qua các chức năng mà nó nhập từ mô-đun `"myzig"` (`src/web/js.zig`): mở cửa sổ, yêu cầu khung hoạt ảnh, con trỏ, vị trí dấu mũ cho phương thức nhập, bộ hẹn giờ, bảng tạm, URL, thông báo, giao diện và ngôn ngữ. Văn bản đi qua bộ đệm dùng chung trong bộ nhớ WebAssembly. [Trang kết xuất](architecture-rendering.md) của hướng dẫn kiến ​​trúc có bộ kết xuất.
