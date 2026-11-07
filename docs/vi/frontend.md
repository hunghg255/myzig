<a id="the-frontend"></a>

# Frontend

Frontend của một trang là HTML, CSS và JavaScript, viết tay hoặc build bằng bất kỳ công cụ nào (Vite, esbuild, công cụ riêng của một framework). myzig không đòi hỏi gì ở nó ngoài những thứ myzig phục vụ: các file, và client được sinh ở `/myzig.js`.

Trang này nói về phía frontend của một trang: runtime của trang, cách đưa frontend vào app, dev server, thanh tiêu đề, và inspector. App làm gì với một trang thì xem ở [Trang](pages.md). Gọi Zig thì xem ở [Binding](bindings.md).

<a id="the-page-runtime"></a>

## Runtime của trang

Mọi document trong main frame của trang đều được nạp bridge (`src/bridge.js`) trước khi script của chính nó chạy. Bridge định nghĩa `window.myzig`:

| | |
|---|---|
| `myzig.call(method, ...args)` | gọi `"Service.method"`; trả về promise của kết quả ([Binding](bindings.md)) |
| `myzig.on(event, fn)` | lắng nghe một event; trả về hàm để ngừng lắng nghe |
| `myzig.once(event, fn)` | như trên, nhưng chỉ cho lần kế tiếp |
| `myzig.Channel` | `new myzig.Channel(onmessage?)` tạo một channel để truyền vào method |
| `myzig.onChannel(kind, fn)` | nhận các channel thuộc một loại mà Zig mở ra |
| `myzig.log(...values)` | in `page: ...` ra stderr của app (chuỗi giữ nguyên, phần còn lại dạng JSON) |
| `myzig.window.close()`, `.minimize()`, `.toggleMaximize()`, `.setTitle(title)` | cửa sổ của trang |
| `myzig.platform` | `"macos"`, `"linux"` hoặc `"windows"` |
| `myzig.version` | phiên bản của myzig |

- `window.myzig` đã bị đóng băng và không thay thế được.
- Client được sinh re-export nó (`import { myzig, Channel } from "/myzig.js"`) cùng với các service, event và loại channel của app. Module không cần import gì thêm.
- `myzig.d.ts` khai báo toàn bộ những thứ đó.

Bridge còn:

- báo cho app khi DOM sẵn sàng (`dom_ready`, sau đó các event đang giữ mới được gửi tới);
- tìm chữ cho `Page.findInPage`;
- hoàn tất các script của `evalResult`;
- di chuyển cửa sổ không viền qua các [vùng kéo](#title-bars).

Scheme của app khác nhau theo nền tảng: `myzig://localhost/` trên macOS và Linux, `http://myzig.localhost/` trên Windows ([Trang](pages.md#schemes-of-the-app)). Trang có thể biết mình đang chạy trên nền tảng nào, cho những chỗ khác nhau. URL tương đối chạy được ở mọi nơi và đơn giản nhất.

<a id="a-frontend-of-plain-files"></a>

## Frontend chỉ gồm file tĩnh

Frontend nhỏ nhất là các file nhúng vào binary, như `examples/hello`:

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

- App tự phục vụ `/myzig.js`, nên nó không phải là asset.
- Scheme của app là một origin an toàn. Module import, `fetch`, worker và WebAssembly của trình duyệt đều chạy được trên đó.

<a id="a-built-frontend"></a>

## Frontend có bước build

App tạo bằng `myzig init --template web` ([Bắt đầu](getting-started.md)) nhúng cả một thư mục:

```zig
const assets = @import("assets");

// `myzig dev` trỏ cửa sổ tới dev server, nếu có.
const url = init.environ_map.get("MYZIG_DEV_URL") orelse "/";
_ = try app.newWindow(.{
    .title = "My App",
    .content = .{ .page = .{ .url = url, .assets = &assets.files } },
});
```

- `build.zig` của nó import một module, `assets`, từ `<frontend>/myzig_assets.zig`. Module này liệt kê mọi file trong thư mục bằng `@embedFile`.
- App truyền vào `&assets.files`.
- CLI viết lại `myzig_assets.zig` mỗi khi file thay đổi (`myzig generate`, `dev` và `build`). Thêm file vào frontend không cần đụng tới Zig.
- Nó bỏ qua chính module này, client được sinh, file bắt đầu bằng dấu chấm và `node_modules`.

Khi dùng công cụ build, `myzig.zon` của app cho biết mã nguồn frontend ở đâu, bản build ra đâu, và cách chạy cả hai:

```zig
.{
    .name = "My App",
    .frontend = "frontend",            // mã nguồn (client được viết vào đây)
    .frontend_dist = "frontend/dist",  // thứ build.zig nhúng vào (-Dfrontend=...)
    .dev_url = "http://localhost:5173",
    .dev_command = "bun run dev",
    .build_command = "bun run build",
}
```

`myzig build` chạy `build_command` trước, rồi nhúng `frontend_dist`. Các trường được mô tả ở [Cấu hình](configuration.md).

App một trang có routing phía client chạy được ngay:

- Đường dẫn không có phần mở rộng và không phải file (`/settings/profile`) được trả lời bằng `/index.html`.
- Dùng đường dẫn tuyệt đối cho asset (`/assets/app.js`), hoặc đặt base của bundler là `/`.

<a id="dev-servers"></a>

## Dev server

Khi bạn làm frontend, dev server tự reload mỗi khi bạn sửa. Trang có dev server nạp các đường dẫn của frontend từ server đó:

- `"/"` là gốc của server, và `"/settings"` là `/settings` của nó.
- URL tuyệt đối vẫn nạp như bình thường.

Dev server được lấy từ, theo thứ tự ưu tiên:

1. biến môi trường `MYZIG_DEV_URL`. `myzig dev` đặt nó từ `dev_url` sau khi chạy `dev_command` và chờ server trả lời;
2. `PageOptions.dev_url`.

Cách nó hoạt động:

- Origin của dev server được [tin cậy](pages.md#trust). Trang của nó gọi các service đã bind giống như trang của chính app.
- Module của nó cũng import client qua `/myzig.js`. `myzig dev` viết file này vào `frontend`, nơi server phục vụ nó.
- Khi có dev server, `myzig dev` để server lo các file frontend. Nó chỉ build lại và khởi động lại app khi Zig thay đổi ([CLI](cli.md)).

Khi không có server, `MYZIG_ASSETS_DIR` (hoặc `PageOptions.assets_dir`) phục vụ một thư mục trên đĩa, ưu tiên hơn asset đã nhúng. Khi đó reload trang là thấy file đã sửa mà không cần build lại app.

<a id="title-bars"></a>

## Thanh tiêu đề

| `title_bar` | |
|---|---|
| `.hidden` | trang phủ kín cửa sổ, nằm dưới các nút điều khiển cửa sổ của hệ thống |
| `.frameless` | không có thanh tiêu đề và không có nút điều khiển nào ([Cửa sổ](windows.md)) |

Trong cả hai trường hợp, trang tự vẽ thanh tiêu đề. Thuộc tính CSS tùy biến `--app-region` cho biết phần nào kéo được cửa sổ:

```css
header { --app-region: drag; height: 38px; padding-left: 80px; /* chừa chỗ cho các nút đèn giao thông của macOS */ }
header button, header input { --app-region: no-drag; }
```

- Bấm nút chính sẽ kéo cửa sổ khi phần tử đó, hoặc phần tử cha gần nhất có `--app-region`, ghi `drag`.
- Bấm đúp ở đó sẽ phóng to cửa sổ, như thanh tiêu đề thật.
- `no-drag` giữ cho các control trong vùng kéo vẫn bấm được.
- Thuộc tính tùy biến được kế thừa, nên một quy tắc là đủ cho cả thanh.

Các nút riêng của cửa sổ không viền gọi runtime:

```html
<button onclick="myzig.window.minimize()">–</button>
<button onclick="myzig.window.toggleMaximize()">□</button>
<button onclick="myzig.window.close()">×</button>
```

`myzig.window.setTitle(title)` đặt tiêu đề cửa sổ: thứ mà Dock, taskbar và trình chuyển cửa sổ hiển thị. `<title>` của document cũng làm vậy, qua event `title_changed`, khi app lắng nghe event này.

<a id="appearance"></a>

## Giao diện sáng/tối

Webview theo giao diện sáng hoặc tối của hệ thống. Khai báo `color-scheme: light dark` và dùng media query `prefers-color-scheme`, trang sẽ đổi theo hệ thống.

App đọc được giao diện bằng `myzig.isDark()` và màu accent bằng `myzig.accentColor()` ([Hệ thống](system.md)). App có thể gửi chúng sang trang qua một event.

<a id="links-and-new-windows"></a>

## Liên kết và cửa sổ mới

`window.open` và liên kết có `target="_blank"` tới app dưới dạng event `new_window` của trang.

- Nếu không có listener xử lý, URL `http` và `https` mở trong trình duyệt của hệ thống. Phần lớn app muốn vậy với liên kết ngoài.
- Listener có thể mở một cửa sổ riêng thay vào đó.
- `will_navigate` có thể hủy việc điều hướng của chính trang ([Trang](pages.md#page-events)).

<a id="scripts-of-the-app"></a>

## Script của app

`PageOptions.user_scripts` và `Page.addUserScript` thêm script mà mọi document đều chạy:

- sau bridge và trước script của chính document;
- hoặc khi DOM sẵn sàng, với `at_document_end`.

Dùng chúng để chèn style vào một trang từ xa, hoặc tạo biến toàn cục mà frontend cần.

<a id="the-web-inspector"></a>

## Web inspector

Trang có thể inspect được, trừ khi `PageOptions.inspectable` là false.

- Chuột phải > Inspect Element mở inspector của engine: Web Inspector trên macOS, inspector của WebKit trên Linux, Edge DevTools trên Windows.
- `page.openDevTools()` mở nó từ Zig. Trên macOS việc này đi qua một API riêng của WebKit, có thể bị gỡ bỏ.
- Hãy tắt nó trong các bản release không nên có.
- `console.log` ghi vào inspector. `myzig.log` ghi ra stderr của app, nơi test đọc.

<a id="testing-the-frontend"></a>

## Test frontend

```sh
zig-out/bin/hello --myzig-eval='import("/myzig.js").then(async ({ Greeter }) => { myzig.log(await Greeter.greet("Ada")); myzig.window.close() })'
```

Chạy app với `--myzig-eval=JS`. Mỗi trang chạy `JS` khi DOM sẵn sàng, không có cửa sổ nào trên màn hình. Lần chạy kết thúc khi trang gọi `myzig.window.close()`.

`zig build test-pages` chạy `examples/hello` theo cách này, và `examples/pages` với `--myzig-hidden`. Mỗi lần chạy kiểm tra có `page: ok` trong stderr ([Trang](pages.md#testing-pages)).
