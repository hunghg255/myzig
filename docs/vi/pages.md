<a id="pages"></a>

# Trang web

Một cửa sổ có thể hiển thị một trang web thay vì giao diện native. Trang chạy trong webview của hệ điều hành, không phải trong trình duyệt đi kèm:

| | macOS | Linux | Windows |
|---|---|---|---|
| động cơ | WKWebView | WebKitGTK (`libwebkit2gtk-4.1`, nếu không thì `4.0`, được nạp `dlopen`) | WebView2 (Microsoft Edge WebView2 Runtime) |
| frontend của ứng dụng | `myzig://localhost/` | `myzig://localhost/` | `http://myzig.localhost/` |
| thanh tra web | Thanh tra web | Thanh tra của WebKit | Edge DevCông cụ |

Không có gì được liên kết: WebKitGTK được tải khi trang đầu tiên mở ra (một ứng dụng có cửa sổ chỉ hiển thị giao diện native không bao giờ tải nó) và WebView2 được tìm thấy theo cách `WebView2Loader.dll` tìm thấy nó (một phiên bản cố định được đặt tên bởi `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER`, nếu không thì các kênh đã cài đặt, phiên bản ổn định nhất trước tiên). Máy Linux không có WebKitGTK ghi nhật ký mà các trang cần.

Trang này bao gồm nội dung của trang và ứng dụng có thể làm gì với trang đó. Phía frontend (thời gian chạy trang, máy chủ nhà phát triển, thanh tiêu đề) nằm trong [Giao diện người dùng](frontend.md) và gọi Zig từ trang trong [Bindings](bindings.md).

<a id="a-window-with-a-page"></a>

## Một cửa sổ có một trang

```zig
const std = @import("std");
const myzig = @import("myzig");

const assets = [_]myzig.Asset{
    .{ .path = "/index.html", .data = @embedFile("frontend/index.html") },
    .{ .path = "/main.js", .data = @embedFile("frontend/main.js") },
    .{ .path = "/style.css", .data = @embedFile("frontend/style.css") },
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Hello" });
    defer app.destroy();
    _ = try app.newWindow(.{
        .title = "Hello",
        .width = 720,
        .height = 560,
        .content = .{ .page = .{ .url = "/", .assets = &assets } },
    });
    try app.run();
}
```

`WindowOptions.content` là một liên minh: `.view` cho giao diện native, `.page` cho một trang, với `myzig.PageOptions` của nó. Bản thân các tùy chọn cửa sổ (kích thước, thanh tiêu đề, sự kiện) đều giống nhau cho cả hai: xem [Cửa sổ](windows.md).

<a id="how-the-frontend-is-served"></a>

## Giao diện người dùng được phục vụ như thế nào

Một người họ hàng `url` (`"/"`, `"/settings"`) giải quyết theo sơ đồ riêng của ứng dụng, `myzig://localhost/` (trên Windows `http://myzig.localhost/`, vì WebView2 coi `*.localhost` là nguồn gốc an toàn; ứng dụng trả lời tất cả như nhau). URL tuyệt đối (`https://example.com`, `http://localhost:5173`) tải như hiện tại.

Ứng dụng trả lời từng yêu cầu `myzig://localhost/<path>` từ:

1. `/myzig.js`: client được tạo từ các sự kiện và dịch vụ bị ràng buộc của ứng dụng ([Bindings](bindings.md)).
2. `assets_dir`, khi được đặt: một thư mục trên đĩa, chẳng hạn như frontend được xây dựng hoặc một giao diện đang được xử lý. Các đường dẫn có `..`, `.`, dấu gạch chéo ngược hoặc ổ đĩa bị từ chối, do đó không có gì bên ngoài thư mục được đọc.
3. `assets`: các tệp được nhúng trong tệp nhị phân, danh sách `myzig.Asset` (`path`, `data` và `mime` tùy chọn).

`/` là `/index.html`. Đường dẫn không có tiện ích mở rộng không có tệp (tuyến phía client chẳng hạn như `/settings/profile`) nhận được `/index.html`, do đó bộ định tuyến của ứng dụng một trang sẽ hoạt động. Loại nội dung đến từ tiện ích mở rộng (`.html`, `.js`, `.mjs`, `.css`, `.json`, `.svg`, `.png`, `.jpg`, `.woff2`, `.wasm`; khác `application/octet-stream`) trừ khi nội dung đặt tên cho nó `mime` và mọi câu trả lời đều ghi `Cache-Control: no-cache`. Bất cứ điều gì khác là 404.

Biến môi trường `MYZIG_ASSETS_DIR` ghi đè `assets_dir` và `MYZIG_DEV_URL` ghi đè `dev_url`, thay vào đó tải đường dẫn của frontend từ máy chủ nhà phát triển ([Giao diện người dùng](frontend.md#dev-servers)).

<a id="page-options"></a>

## Tùy chọn trang

| lĩnh vực | mặc định | |
|---|---|---|
| `url` | `"/"` | trang nào tải đầu tiên |
| `assets` | không có | các tập tin được phục vụ tại `myzig://localhost/` |
| `assets_dir` | null | một thư mục được cung cấp trước `assets` |
| `dev_url` | null | một máy chủ nhà phát triển được tải cho các đường dẫn của frontend và được tin cậy |
| `trusted_origins` | không có | nguồn gốc bên cạnh nguồn gốc của ứng dụng có thể gọi các dịch vụ bị ràng buộc ([trust](#trust)) |
| `schemes` | không có | các chương trình mà ứng dụng phân phát, ngoài `myzig://` ([sơ đồ](#schemes-of-the-app)) |
| `user_scripts` | không có | tập lệnh mọi tài liệu chạy, sau cây cầu |
| `zoom` | 1 | hệ số thu phóng của trang |
| `user_agent` | null | tác nhân người dùng, thay vì động cơ |
| `user_agent_suffix` | "" | được thêm vào tác nhân người dùng sau một khoảng trắng thay vì thay thế nó, chẳng hạn như `"MyApp/1.2"`: vào động cơ hoặc vào `user_agent`; `setUserAgent` giữ nó (một cái trống sẽ khôi phục động cơ, hậu tố và tất cả); không gian xung quanh nó được cắt tỉa. `"Version/17.0 Safari/605.1.15"` làm cho view web đơn giản trông giống Safari đối với các trang web phục vụ các trang cũ hơn |
| `safari_tab_focus` | false | rời Tab sang các trường văn bản và thành phần có tabindex, giống như Safari thực hiện khi điều hướng bàn phím của hệ thống tắt (macOS); theo mặc định, Tab sẽ tiếp cận các liên kết, nút, hộp kiểm và cả phần chọn, như trong Chrome, Edge và WebKitGTK |
| `inspectable` | true | liệu trình kiểm tra web có thể mở hay không (nhấp chuột phải > Kiểm tra phần tử) |
| `on_event` | null | nghe các sự kiện của trang và trả lời các câu hỏi của trang đó ([events](#page-events)) |

<a id="the-page"></a>

## Trang

Cửa sổ hiển thị một trang có trang đó trong `window.page`, `?*Page` (null cho cửa sổ giao diện native). Cửa sổ có các phím tắt cho hầu hết các ứng dụng cần:

```zig
win.loadUrl("/settings");          // load a URL, or a path of the frontend
win.eval("document.body.classList.add('ready')");   // run a script, without waiting
win.evalResult("document.title", cb);               // evaluate, and get the value
```

và trang này có phần còn lại, giống nhau trên mọi nền tảng:

| phương pháp | |
|---|---|
| `load(url_or_path)` | tải một URL hoặc đường dẫn của frontend (trên máy chủ nhà phát triển trong khi có) |
| `loadHtml(html, base_url)` | tải một tài liệu từ một chuỗi; `base_url` (hoặc `about:blank`) là nguồn gốc của nó |
| `loadFile(path)` | tải một đường dẫn tuyệt đối của đĩa; các tập tin trong thư mục của nó cũng có thể tải |
| `reload()`, `stop()` | |
| `goBack()`, `goForward()`, `canGoBack()`, `canGoForward()` | lịch sử của trang |
| `isLoading()` | |
| `currentUrl(gpa)` (cũng là `url`), `title(gpa)` | bản sao sở hữu |
| `addUserScript(script)` → id, `removeUserScript(id)` | tập lệnh tài liệu sau này chạy |
| `setZoom(factor)`, `zoom()` | |
| `setUserAgent(ua)`, `userAgent(gpa)` | |
| `openDevTools()` | mở trình kiểm tra web khi `inspectable` |
| `eval(js)`, `evalResult(js, cb)` | [đánh giá kịch bản](#evaluating-scripts) |
| `findInPage(text, opts, cb)`, `stopFind()` | [tìm văn bản](#finding-text) |
| `print()`, `printToPdf(opts, cb)` | [in](#printing) |
| `listCookies`, `setCookie`, `deleteCookie`, `clearCookies` | [cookie](#cookies) |

Các phương thức trang chạy trên luồng chính, nơi các phương thức và trình nghe bị ràng buộc đã chạy.

`myzig.page.UserScript` có `source` và `at_document_end`: false (mặc định) chạy nó trước các tập lệnh riêng của tài liệu, true khi DOM của nó đã sẵn sàng. Các tập lệnh chạy trong khung chính, sau cầu nối, vì vậy chúng có thể sử dụng `window.myzig`.

<a id="evaluating-scripts"></a>

## Đánh giá kịch bản

`eval` chạy một tập lệnh và quên nó. `evalResult` đánh giá một biểu thức, chờ đợi nó khi đó là một lời hứa và chuyển giá trị của nó cho `myzig.EvalCallback` dưới dạng JSON hoặc thông báo lỗi:

```zig
fn gotTitle(_: ?*anyopaque, r: myzig.EvalResult) void {
    switch (r) {
        .ok => |json| std.log.info("title: {s}", .{json}), // "\"Hello\""
        .err => |msg| std.log.err("eval: {s}", .{msg}),
    }
}

win.evalResult("document.title", .{ .ctx = null, .func = gotTitle });
win.evalResult("fetch('/data.json').then((r) => r.json())", .{ .ctx = null, .func = gotTitle });
```

Giá trị là `JSON.stringify` của kết quả (`null` cho `undefined`) và cả hai chuỗi chỉ tồn tại khi lệnh gọi lại chạy. Lỗi được đưa ra hoặc lời hứa bị từ chối có dạng `.err`. Đánh giá vẫn đang chờ khi trang điều hướng hoặc đóng không thành công với "trang được điều hướng" hoặc "trang đã đóng", vì vậy mỗi lệnh gọi lại đều được gọi một lần. Kết quả mang một mã thông báo mà chỉ cầu nối của trang này mới biết, vì vậy tập lệnh của trang không thể trả lời cho nó.

<a id="page-events"></a>

## Sự kiện trang

`on_event` lấy `myzig.PageListener`, được tạo bằng `.of(&state, func)` trong đó `func` là `fn (state: *State, window: *myzig.Window, event: myzig.PageEvent) void`. Một số sự kiện đặt ra một câu hỏi và người nghe sẽ trả lời tại chỗ:

```zig
fn onPage(s: *State, win: *myzig.Window, e: myzig.PageEvent) void {
    switch (e) {
        .title_changed => |t| win.setTitle(t),
        .will_navigate => |nav| {
            // Keep the page on the app's own frontend.
            if (!std.mem.startsWith(u8, nav.url, "myzig:")) nav.cancel = true;
        },
        .new_window => |req| {
            req.handled = true;
            s.openPopup(req.url);
        },
        .permission => |req| req.allow = s.allowsMedia(req.origin),
        .download_started => |d| if (!s.wantsDownloads) {
            d.cancel = true;
        },
        else => {},
    }
}

_ = try app.newWindow(.{ .content = .{ .page = .{ .url = "/", .assets = &assets, .on_event = .of(&state, onPage) } } });
```

| sự kiện | tải trọng | |
|---|---|---|
| `will_navigate` | `*Navigate`: `url`, `user_initiated`, `cancel` | quá trình điều hướng của khung chính sắp bắt đầu |
| `load_started` | URL | |
| `committed` | URL | tài liệu đã thay đổi (sau khi chuyển hướng) |
| `load_finished` | URL | |
| `load_failed` | `LoadError`: `url`, `code`, `description` | |
| `title_changed` | tiêu đề | |
| `dom_ready` | | cây cầu đã có trong trang và DOM của nó đã sẵn sàng |
| `new_window` | `*NewWindow`: `url`, `handled` | `window.open`, `target=_blank` |
| `permission` | `*PermissionRequest`: `kinds`, `origin`, `allow` | máy ảnh, micrô, định vị địa lý, thông báo |
| `download_started` | `*DownloadStart`: `url`, `suggested_name`, `path`, `cancel` | |
| `download_progress` | `DownloadProgress`: `url`, `received`, `total` (0 khi không xác định) | |
| `download_done` | `DownloadDone`: `url`, `path`, `err` (null khi thành công) | |

Các loại nằm trong `myzig.page` (`myzig.page.Navigate`, ...). Chuỗi tồn tại trong khi người nghe chạy.

Điều gì xảy ra mà không có câu trả lời:

- **Cửa sổ mới.** Trừ khi người nghe đặt các URL `handled`, `http` và `https` mở trong trình duyệt của hệ thống; những người khác bị bỏ rơi. Bản thân trang này không bao giờ mở cửa sổ webview thứ hai.
- **Quyền.** `allow` bắt đầu nếu trang yêu cầu là [đáng tin cậy](#trust): các trang của chính ứng dụng nhận được máy ảnh, micrô, vị trí và thông báo (hệ thống vẫn có thể hỏi người dùng) còn các trang khác thì không. `kinds` liệt kê những gì được yêu cầu cùng nhau, dưới dạng máy ảnh và micrô của cuộc gọi.
- **Tải xuống.** Tệp tải xuống sẽ chuyển đến thư mục Tải xuống của người dùng, dưới tên được đề xuất (chỉ phần cuối cùng: không bao giờ là thư mục), được đánh số là `name (2).ext` khi có tệp. Người nghe có thể đặt `path` ở nơi khác (chuỗi được sao chép khi sự kiện trả về) hoặc `cancel` nó.

<a id="schemes-of-the-app"></a>

## Đề án của ứng dụng

Ngoài `myzig://`, ứng dụng có thể cung cấp các lược đồ riêng cho dữ liệu không phải là tệp của frontend cũng như lệnh gọi: hình ảnh được tạo nhanh chóng, tệp người dùng đã chọn, luồng.

```zig
fn serveMedia(_: ?*anyopaque, req: *myzig.SchemeRequest) void {
    if (std.mem.eql(u8, req.path, "/hello.json"))
        return req.respond(200, &.{.{ .name = "Content-Type", .value = "application/json" }}, "{\"hello\":\"scheme\"}");
    req.respond(404, &.{}, "Not Found");
}

.content = .{ .page = .{
    .url = "/",
    .assets = &assets,
    .schemes = &.{.{ .name = "media", .handler = .{ .ctx = null, .func = serveMedia } }},
} },
```

Trang tải `media://localhost/hello.json`, trên Windows là `http://media.localhost/hello.json`; một trang có thể chọn biểu mẫu với `myzig.platform`:

```js
const media = (path) =>
  myzig.platform === "windows" ? "http://media.localhost" + path : "media://localhost" + path;
const data = await (await fetch(media("/hello.json"))).json();
```

`myzig.SchemeRequest` có `method`, `url` (luôn ở dạng `<scheme>://localhost/...`), `path` không có truy vấn và `body`. Nó được trả lời một lần, trên luồng chính, bây giờ hoặc sau này:

- `req.respond(status, headers, body)` trả lời toàn bộ;
- `req.begin(status, headers)`, sau đó `req.write(bytes)` thường xuyên nếu cần, sau đó `req.finish()` trả lời theo từng phần. Trình xử lý có thể giữ lại yêu cầu và hoàn thành nó ở lượt vòng lặp sau (từ bộ đếm thời gian hoặc sau khi quá trình được trả lời); nó được giải phóng khi hoàn thành.

`req.addHeader(name, value)` thêm tiêu đề trước `begin` và `req.header(name)` đọc một bộ cho đến nay. Khi một trang đáng tin cậy có nguồn gốc khác hỏi (một trang trên máy chủ nhà phát triển đang tìm nạp `media://`), câu trả lời sẽ cho phép trang đó với các tiêu đề CORS và các yêu cầu preflight `OPTIONS` sẽ được trả lời cho ứng dụng.

<a id="trust"></a>

## Tin tưởng

Các dịch vụ bị ràng buộc là mã riêng của ứng dụng, vì vậy chỉ những trang mà ứng dụng tin cậy mới có thể gọi chúng. Cuộc gọi từ bất kỳ trang nào khác không thành công với `Untrusted`. Đáng tin cậy là:

- các kế hoạch của ứng dụng (`myzig://` và `PageOptions.schemes`, ở một trong hai dạng trên Windows) và `blob:` URL có nguồn gốc đáng tin cậy;
- trang `file:` và `about:`;
- máy chủ nhà phát triển (`dev_url` hoặc `MYZIG_DEV_URL`), theo nguồn gốc của nó;
- các danh sách nguồn gốc `trusted_origins`, chẳng hạn như `"https://example.com"` (so sánh không phân biệt chữ hoa chữ thường, bỏ qua dấu `/`, bao gồm lược đồ và cổng) hoặc `"*"` cho mỗi trang.

Độ tin cậy được kiểm tra đối với tài liệu hiển thị khi cuộc gọi đến, do đó, một trang được điều hướng đến một trang khác sẽ mất nó. Quy tắc tương tự cấp [quyền](#page-events) theo mặc định.

<a id="finding-text"></a>

## Tìm văn bản

```zig
fn found(_: ?*anyopaque, r: ?myzig.page.FindResult) void {
    const res = r orelse return; // the page could not search
    std.log.info("{d} of {d}", .{ res.active, res.matches });
}

page.findInPage("needle", .{}, .{ .ctx = null, .func = found });
page.findInPage("needle", .{ .find_next = true }, .{ .ctx = null, .func = found }); // the next match
page.stopFind();
```

`myzig.page.FindOptions` có `match_case`, `backward` và `find_next` (chuyển từ kết quả khớp hiện tại của cùng một văn bản). Cây cầu tìm thấy các kết quả trùng khớp trong văn bản hiển thị của trang trên mọi nền tảng, đánh dấu chúng (với API đánh dấu tùy chỉnh CSS nơi công cụ có nó, nếu không thì lựa chọn), cuộn trang hiện tại vào view và báo cáo số lượng có và số nào hiện tại, từ 1.

<a id="printing"></a>

## In ấn

`page.print()` mở hộp thoại in của hệ thống (`window.print()`). `page.printToPdf(opts, cb)` tạo một trang PDF mà không có hộp thoại:

```zig
fn gotPdf(_: ?*anyopaque, pdf: ?[]const u8, err: ?[]const u8) void {
    const bytes = pdf orelse return std.log.err("pdf: {s}", .{err.?});
    _ = bytes; // write it somewhere: it lives while the callback runs
}

page.printToPdf(.{ .landscape = true, .background = true }, .{ .ctx = null, .func = gotPdf });
```

`myzig.page.PdfOptions` được tính bằng inch: `width` và `height` (Chữ cái Hoa Kỳ theo mặc định), `landscape`, bốn lề (0,4 inch) và `background`. WebKitGTK và WebView2 theo dõi họ; trên macOS (`createPDF`, macOS 11 trở lên), tệp PDF có kích thước riêng của trang.

<a id="cookies"></a>

## Cookie

Cookie của các trang của ứng dụng (cửa hàng mặc định của webview, được chia sẻ bởi các cửa sổ của ứng dụng) có thể được đọc và thay đổi từ Zig, không đồng bộ:

```zig
page.setCookie(.{ .name = "session", .value = token, .domain = "example.com", .secure = true }, .{ .ctx = null, .func = done });
page.listCookies("https://example.com/", .{ .ctx = null, .func = listed }); // null: every cookie
page.deleteCookie("session", "example.com", "/", .{ .ctx = null, .func = done });
page.clearCookies(.{ .ctx = null, .func = done });
```

`myzig.page.Cookie` có `name`, `value`, `domain` (`.example.com` cho cả tên miền phụ của nó), `path` (`/`), `expires` (giây kể từ năm 1970; null cho cookie phiên), `secure`, `http_only` và `same_site` (`.lax`, `.strict`, `.none`). `listCookies` gọi `CookiesCallback` với các cookie mà một yêu cầu tới URL sẽ gửi (hoặc tất cả chúng) và những cookie khác gọi `DoneCallback` với null hoặc có lỗi.

<a id="testing-pages"></a>

## Trang thử nghiệm

Các trang được kiểm tra ẩn thông qua webview và cầu nối thực. Chạy một ứng dụng với `--myzig-eval=JS` và mỗi trang sẽ đánh giá `JS` sau khi DOM của nó sẵn sàng, không có cửa sổ trên màn hình; trang báo cáo với `myzig.log(...)`, in `page: ...` tới thiết bị xuất chuẩn của ứng dụng và kết thúc quá trình chạy với `myzig.window.close()` (ứng dụng thoát với cửa sổ cuối cùng của nó). `--myzig-hidden` ẩn các cửa sổ đối với trang tự kiểm tra.

```sh
zig-out/bin/hello --myzig-eval='myzig.call("Greeter.greet","Ada").then(v=>{myzig.log(v);myzig.window.close()})'
zig build test-pages   # hello's calls and events, and examples/pages
```

`examples/pages` là kiểm thử mọi thứ trên trang này: trang gọi các dịch vụ, tìm nạp sơ đồ của ứng dụng (toàn bộ, từng phần, POST, 404), đọc `assets_dir` và tuyến client, truyền qua các kênh theo cả hai cách, yêu cầu quyền, mở cửa sổ và tải xuống tệp; sau đó Zig đánh giá tập lệnh, tìm văn bản, in sang PDF, đặt và xóa cookie, thêm tập lệnh người dùng và tải tài liệu không đáng tin cậy có lệnh gọi không thành công. Nó in `page: ok`.
