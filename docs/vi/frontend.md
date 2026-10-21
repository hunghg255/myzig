<a id="the-frontend"></a>

# Giao diện người dùng

Giao diện người dùng của trang là HTML, CSS và JavaScript, được viết bằng tay hoặc được xây dựng bằng bất kỳ công cụ nào (Vite, esbuild, của riêng một khung). myzig không yêu cầu gì ngoài những gì nó phục vụ: các tệp và client được tạo tại `/myzig.js`. Trang này nói về frontend của trang: thời gian chạy trang, cách frontend truy cập vào ứng dụng, máy chủ nhà phát triển, thanh tiêu đề và trình kiểm tra. Những gì ứng dụng thực hiện với một trang nằm trong [Trang](pages.md) và gọi Zig trong [Bindings](bindings.md).

<a id="the-page-runtime"></a>

## Thời gian chạy trang

Mọi tài liệu trong khung chính của trang đều nhận được cầu nối (`src/bridge.js`) trước khi chạy tập lệnh của chính nó. Nó định nghĩa `window.myzig`:

| | |
|---|---|
| `myzig.call(method, ...args)` | gọi `"Service.method"`; lời hứa về kết quả ([Bindings](bindings.md)) |
| `myzig.on(event, fn)` | lắng nghe một sự kiện; trả về một hàm dừng nghe |
| `myzig.once(event, fn)` | tương tự, chỉ dành cho cái tiếp theo |
| `myzig.Channel` | `new myzig.Channel(onmessage?)` tạo một kênh để truyền tới một phương thức |
| `myzig.onChannel(kind, fn)` | mở các kênh thuộc loại Zig |
| `myzig.log(...values)` | in `page: ...` vào stderr của ứng dụng (các chuỗi như hiện tại, phần còn lại là JSON) |
| `myzig.window.close()`, `.minimize()`, `.toggleMaximize()`, `.setTitle(title)` | cửa sổ của trang |
| `myzig.platform` | `"macos"`, `"linux"` hoặc `"windows"` |
| `myzig.version` | Phiên bản của myzig |

`window.myzig` bị đóng băng và không thể thay thế được. Ứng dụng khách được tạo sẽ xuất lại nó (`import { myzig, Channel } from "/myzig.js"`) bên cạnh các dịch vụ, sự kiện và loại kênh của ứng dụng, vì vậy mô-đun không cần gì khác. `myzig.d.ts` tuyên bố tất cả.

Cây cầu này cũng cho ứng dụng biết khi nào DOM sẵn sàng (`dom_ready`, sau đó các sự kiện được tổ chức sẽ đến), tìm văn bản cho `Page.findInPage`, giải quyết các tập lệnh của `evalResult` và di chuyển các cửa sổ không khung theo [vùng kéo](#title-bars) của chúng.

Các trang của ứng dụng có thể cho biết họ đang sử dụng nền tảng nào và có điểm gì khác biệt: sơ đồ của ứng dụng là `myzig://localhost/` trên macOS và Linux và `http://myzig.localhost/` trên Windows ([Trang](pages.md#schemes-of-the-app)). URL tương đối hoạt động ở mọi nơi và đơn giản nhất.

<a id="a-frontend-of-plain-files"></a>

## Giao diện người dùng của các tập tin đơn giản

Giao diện người dùng nhỏ nhất là các tệp được nhúng trong hệ nhị phân, như `examples/hello` thực hiện:

```zig
const assets = [_]myzig.Asset{
    .{ .path = "/index.html", .data = @embedFile("frontend/index.html") },
    .{ .path = "/main.js", .data = @embedFile("frontend/main.js") },
    .{ .path = "/style.css", .data = @embedFile("frontend/style.css") },
};

_ = try app.newWindow(.{ .title = "Hello", .content = .{ .page = .{ .url = "/", .assets = &assets } } });
```

```html
<script type="module" src="/main.js"></script>
```

```js
import { Greeter } from "/myzig.js";
```

Ứng dụng này tự phục vụ `/myzig.js` nên nó không phải là tài sản. Quá trình nhập mô-đun của trình duyệt, `fetch`, công nhân và WebAssembly đều hoạt động chống lại sơ đồ của ứng dụng, vốn là một nguồn gốc an toàn.

<a id="a-built-frontend"></a>

## Một frontend được xây dựng

Một ứng dụng được tạo bằng `myzig init --template web` ([Bắt đầu](getting-started.md)) nhúng toàn bộ thư mục: `build.zig` của nó nhập một mô-đun, `assets`, từ `<frontend>/myzig_assets.zig`, liệt kê mọi tệp của thư mục có `@embedFile` và ứng dụng chuyển `&assets.files`:

```zig
const assets = @import("assets");

// `myzig dev` points the window at the dev server, when there is one.
const url = init.environ_map.get("MYZIG_DEV_URL") orelse "/";
_ = try app.newWindow(.{
    .title = "My App",
    .content = .{ .page = .{ .url = url, .assets = &assets.files } },
});
```

CLI ghi `myzig_assets.zig` bất cứ khi nào tệp thay đổi (`myzig generate`, `dev` và `build`), vì vậy, việc thêm tệp vào frontend không cần Zig. Nó loại bỏ chính mô-đun, client được tạo, tệp dấu chấm và `node_modules`.

Với công cụ xây dựng, `myzig.zon` của ứng dụng cho biết nguồn của frontend ở đâu, nơi xây dựng nó và cách chạy cả hai:

```zig
.{
    .name = "My App",
    .frontend = "frontend",            // the sources (the client is written here)
    .frontend_dist = "frontend/dist",  // what build.zig embeds (-Dfrontend=...)
    .dev_url = "http://localhost:5173",
    .dev_command = "bun run dev",
    .build_command = "bun run build",
}
```

`myzig build` chạy `build_command` trước, sau đó nhúng `frontend_dist`. Các trường được mô tả trong [Cấu hình](configuration.md).

Các ứng dụng một trang có định tuyến phía client hoạt động như cũ: một đường dẫn không có phần mở rộng và không có tệp (`/settings/profile`) được trả lời bằng `/index.html`. Sử dụng đường dẫn tuyệt đối cho nội dung (`/assets/app.js`) hoặc cơ sở của gói `/`.

<a id="dev-servers"></a>

## Máy chủ nhà phát triển

Trong khi bạn làm việc ở frontend, máy chủ nhà phát triển sẽ tải lại nó khi bạn chỉnh sửa. Một trang có máy chủ nhà phát triển tải các đường dẫn của frontend từ trang đó: `"/"` là gốc của máy chủ và `"/settings"` `/settings` của nó, trong khi các URL tuyệt đối vẫn tải như cũ. Máy chủ dev đến từ:

- biến môi trường `MYZIG_DEV_URL`, mà `myzig dev` đặt từ `dev_url` sau khi khởi động `dev_command` và chờ máy chủ trả lời;
- khác `PageOptions.dev_url`.

Nguồn gốc của máy chủ nhà phát triển là [đáng tin cậy](pages.md#trust), vì vậy các trang của nó gọi các dịch vụ bị ràng buộc như cách làm của chính ứng dụng. Các mô-đun của nó cũng nhập client dưới dạng `/myzig.js`: `myzig dev` ghi nó vào `frontend`, nơi máy chủ phục vụ nó. Với máy chủ nhà phát triển, `myzig dev` để lại các tệp của frontend cho nó, đồng thời chỉ xây dựng lại và khởi động lại ứng dụng khi Zig thay đổi ([CLI](cli.md)).

Nếu không có máy chủ, `MYZIG_ASSETS_DIR` (hoặc `PageOptions.assets_dir`) sẽ phục vụ một thư mục của ổ đĩa trước nội dung được nhúng, do đó, việc tải lại trang sẽ chọn các tệp đã chỉnh sửa mà không cần xây dựng lại ứng dụng.

<a id="title-bars"></a>

## Thanh tiêu đề

Một cửa sổ có `.title_bar = .hidden` cho phép trang lấp đầy cửa sổ, dưới các điều khiển cửa sổ của hệ thống; một cái có `.title_bar = .frameless` không có thanh tiêu đề và không có điều khiển nào cả ([Cửa sổ](windows.md)). Dù bằng cách nào, trang sẽ vẽ thanh tiêu đề của riêng mình và cho biết phần nào của nó di chuyển cửa sổ với thuộc tính tùy chỉnh CSS `--app-region`:

```css
header { --app-region: drag; height: 38px; padding-left: 80px; /* clear of macOS's traffic lights */ }
header button, header input { --app-region: no-drag; }
```

Việc nhấn nút chính trên một phần tử có tổ tiên gần nhất (hoặc chính nó) với `--app-region` cho biết `drag` sẽ di chuyển cửa sổ và nhấp đúp sẽ phóng to nó như thanh tiêu đề; `no-drag` giữ các điều khiển bên trong vùng kéo có thể nhấp được. Thuộc tính tùy chỉnh kế thừa, do đó, một quy tắc sẽ bao trùm toàn bộ thanh.

Các nút riêng của cửa sổ không khung gọi thời gian chạy:

```html
<button onclick="myzig.window.minimize()">–</button>
<button onclick="myzig.window.toggleMaximize()">□</button>
<button onclick="myzig.window.close()">×</button>
```

`myzig.window.setTitle(title)` đặt tiêu đề của cửa sổ (những gì Dock, thanh tác vụ và bộ chuyển đổi cửa sổ hiển thị) và `<title>` của tài liệu cũng vậy thông qua sự kiện `title_changed` khi ứng dụng lắng nghe nó.

<a id="appearance"></a>

## Ngoại hình

Các lượt xem web tuân theo giao diện sáng hoặc tối của hệ thống: khai báo `color-scheme: light dark` và sử dụng `prefers-color-scheme` truy vấn phương tiện, đồng thời trang sẽ thay đổi theo hệ thống. Ứng dụng có thể đọc nó bằng `myzig.isDark()` và màu nhấn bằng `myzig.accentColor()` ([System](system.md)) và chuyển chúng trong một sự kiện.

<a id="links-and-new-windows"></a>

## Liên kết và cửa sổ mới

`window.open` và các liên kết với `target="_blank"` tiếp cận ứng dụng dưới dạng sự kiện trang `new_window`. Trừ khi người nghe xử lý nó, các URL `http` và `https` sẽ mở trong trình duyệt của hệ thống, đây là điều mà hầu hết các ứng dụng đều muốn có đối với các liên kết bên ngoài. Thay vào đó, người nghe có thể mở một cửa sổ riêng hoặc hủy điều hướng của chính trang đó bằng `will_navigate` ([Trang](pages.md#page-events)).

<a id="scripts-of-the-app"></a>

## Kịch bản của ứng dụng

`PageOptions.user_scripts` và `Page.addUserScript` thêm tập lệnh mỗi tài liệu chạy, sau cầu nối và trước tập lệnh riêng của tài liệu (hoặc khi DOM của nó đã sẵn sàng, với `at_document_end`): dành cho các kiểu được đưa vào một trang từ xa hoặc toàn cầu mà frontend mong đợi.

<a id="the-web-inspector"></a>

## Thanh tra web

Các trang có thể được kiểm tra trừ khi `PageOptions.inspectable` là false: nhấp chuột phải > Kiểm tra phần tử sẽ mở trình kiểm tra của công cụ (Trình kiểm tra web trên macOS, WebKit trên Linux, Edge DevTools trên Windows) và `page.openDevTools()` mở nó từ Zig. Trên macOS đi qua API riêng tư của WebKit, API này có thể biến mất. Tắt nó trong các bản phát hành không nên có nó.

`console.log` đến gặp thanh tra; `myzig.log` đi tới stderr của ứng dụng, nơi các bài kiểm tra sẽ đọc nó.

<a id="testing-the-frontend"></a>

## Kiểm tra frontend

Chạy ứng dụng với `--myzig-eval=JS`: mỗi trang đánh giá `JS` sau khi DOM của nó sẵn sàng, không có cửa sổ trên màn hình và quá trình chạy kết thúc khi trang gọi `myzig.window.close()`.

```sh
zig-out/bin/hello --myzig-eval='import("/myzig.js").then(async ({ Greeter }) => { myzig.log(await Greeter.greet("Ada")); myzig.window.close() })'
```

`zig build test-pages` chạy `examples/hello` theo cách này và `examples/pages` với `--myzig-hidden`, mỗi lần kiểm tra `page: ok` trong stderr ([Trang](pages.md#testing-pages)).
