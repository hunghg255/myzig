<a id="pages"></a>

# Trang web

Cửa sổ có thể hiện một trang web thay cho native UI. Trang chạy trong webview của hệ điều hành, không phải trong một trình duyệt đóng gói kèm:

| | macOS | Linux | Windows |
|---|---|---|---|
| engine | WKWebView | WebKitGTK (`libwebkit2gtk-4.1`, nếu không có thì `4.0`, nạp bằng `dlopen`) | WebView2 (Microsoft Edge WebView2 Runtime) |
| frontend của app | `myzig://localhost/` | `myzig://localhost/` | `http://myzig.localhost/` |
| công cụ kiểm tra web | Web Inspector | inspector của WebKit | Edge DevTools |

Trang này nói về trang web là gì và app làm được gì với nó. Phía frontend (runtime của trang, dev server, thanh tiêu đề) nằm ở [Frontend](frontend.md). Gọi Zig từ trang web nằm ở [Binding](bindings.md).

**Không link gì cả.**

- WebKitGTK được nạp khi trang web đầu tiên mở. App có cửa sổ chỉ hiện native UI thì không bao giờ nạp nó.
- Máy Linux không có WebKitGTK sẽ ghi log rằng trang web cần nó.
- WebView2 được tìm theo cách `WebView2Loader.dll` tìm: bản cố định do `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER` chỉ tới, nếu không thì các kênh đã cài, kênh ổn định nhất trước.
- Nó nhận `WEBVIEW2_USER_DATA_FOLDER` giống như loader. Thư mục tương đối được tính từ thư mục của file thực thi.

<details>
<summary>Bộ nhớ WebView2 khi cửa sổ bị ẩn</summary>

Sau khi tài liệu tải xong, trang web xin mức bộ nhớ thấp của WebView2 trong lúc:

- cửa sổ chứa nó bị ẩn hoặc thu nhỏ, hoặc
- nó là trang nhúng bị cắt khỏi vùng native UI.

Khi hiện lại hoặc khôi phục, nó xin mức bình thường.

- JavaScript, timer, IPC và kết nối mạng vẫn chạy. Trang không bị tạm dừng hay tải lại.
- Đây là cố gắng giảm bộ nhớ thường trú, không phải giới hạn bộ nhớ.
- Runtime cũ không có API này giữ mức bộ nhớ bình thường.

Xem [tài liệu về memory usage target](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2_19) của Microsoft. Các tiến trình của WebView2 là gì, và một cửa sổ trang web tốn bao nhiêu so với mygo và Electron, có ở [Benchmark](benchmarks.md).

Cửa sổ trang web chính còn tắt việc render của controller khi cửa sổ bị ẩn hoặc thu nhỏ, và bật lại khi hiện.

- JavaScript và IPC vẫn chạy.
- Trình duyệt có thể làm chậm timer và animation ở nền. Không bảo đảm nhịp timer khi bị ẩn.
- Webview nhúng giữ nguyên độ hiển thị của controller theo layout.

Xem [tài liệu về controller visibility](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2controller#get_isvisible) của Microsoft.

Lần chạy headless (`--myzig-hidden` và các flag kéo theo nó) dùng một profile WebView2 tạm. Lần chạy thường vẫn dùng `%LOCALAPPDATA%\<app name>\WebView2`.

</details>

<a id="a-window-with-a-page"></a>

## Cửa sổ có trang web

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

`WindowOptions.content` là một union: `.view` cho native UI, `.page` cho trang web cùng `myzig.PageOptions` của nó. Bản thân các tùy chọn cửa sổ (kích thước, thanh tiêu đề, event) giống nhau cho cả hai: xem [Cửa sổ](windows.md).

<a id="how-the-frontend-is-served"></a>

## Frontend được phục vụ thế nào

- `url` tương đối (`"/"`, `"/settings"`) được tính theo scheme riêng của app, `myzig://localhost/`.
- Trên Windows đó là `http://myzig.localhost/`, vì WebView2 coi `*.localhost` là origin an toàn. App vẫn trả lời nó như thường.
- URL tuyệt đối (`https://example.com`, `http://localhost:5173`) được tải nguyên như vậy.

App trả lời mỗi request tới `myzig://localhost/<path>` từ:

1. `/myzig.js`: client sinh ra từ các service và event đã bind của app ([Binding](bindings.md)).
2. `assets_dir`, nếu được đặt: một thư mục trên đĩa, như frontend đã build hoặc đang làm. Đường dẫn có `..`, `.`, dấu gạch ngược hoặc ổ đĩa bị từ chối, nên không có gì ngoài thư mục bị đọc.
3. `assets`: các file nhúng trong binary, một danh sách `myzig.Asset` (`path`, `data`, và `mime` tùy chọn).

**Cách trả lời.**

- `/` là `/index.html`.
- Đường dẫn không có phần mở rộng và không phải file thì nhận `/index.html`. Đường dẫn như vậy là route phía client, ví dụ `/settings/profile`, nên router của single-page app hoạt động được.
- Content type lấy theo phần mở rộng, trừ khi asset ghi rõ `mime`: `.html`, `.js`, `.mjs`, `.css`, `.json`, `.svg`, `.png`, `.jpg`, `.woff2`, `.wasm`; còn lại là `application/octet-stream`.
- Mọi câu trả lời đều có `Cache-Control: no-cache`.
- Mọi thứ khác là 404.

Biến môi trường `MYZIG_ASSETS_DIR` ghi đè `assets_dir`. `MYZIG_DEV_URL` ghi đè `dev_url`, thứ khiến các đường dẫn của frontend được tải từ một dev server ([Frontend](frontend.md#dev-servers)).

<a id="page-options"></a>

## Tùy chọn của trang

| trường | mặc định | |
|---|---|---|
| `url` | `"/"` | thứ trang tải đầu tiên |
| `assets` | không có | các file phục vụ tại `myzig://localhost/` |
| `assets_dir` | null | thư mục được phục vụ trước `assets` |
| `dev_url` | null | dev server dùng cho các đường dẫn của frontend, và được tin cậy |
| `trusted_origins` | không có | các origin ngoài origin của app được gọi service đã bind ([tin cậy](#trust)) |
| `schemes` | không có | các scheme app phục vụ, ngoài `myzig://` ([scheme](#schemes-of-the-app)) |
| `user_scripts` | không có | script mà mọi tài liệu chạy, sau bridge |
| `zoom` | 1 | hệ số zoom của trang |
| `user_agent` | null | user agent, thay cho của engine |
| `user_agent_suffix` | "" | nối vào sau user agent, cách một dấu cách, ví dụ `"MyApp/1.2"` (bên dưới) |
| `safari_tab_focus` | false | Tab chỉ tới ô nhập chữ và phần tử có tabindex (bên dưới) |
| `inspectable` | true | có cho mở công cụ kiểm tra web không (chuột phải > Inspect Element) |
| `on_event` | null | nghe event của trang và trả lời câu hỏi của nó ([event](#page-events)) |

`user_agent_suffix`:

- Nó được nối thêm chứ không thay thế: vào user agent của engine, hoặc vào `user_agent`.
- `setUserAgent` giữ nó lại. Đặt rỗng thì khôi phục user agent của engine, bỏ luôn hậu tố.
- Dấu cách hai bên bị cắt bỏ.
- `"Version/17.0 Safari/605.1.15"` làm một webview trơn trông như Safari với những site phục vụ nó trang cũ hơn.

`safari_tab_focus` chỉ để Tab tới ô nhập chữ và phần tử có tabindex, như Safari khi điều hướng bằng bàn phím của hệ thống đang tắt (macOS). Mặc định Tab còn tới cả liên kết, nút, checkbox và select, như trong Chrome, Edge và WebKitGTK.

<a id="the-page"></a>

## Đối tượng trang

Cửa sổ hiện trang web giữ nó trong `window.page`, một `?*Page`. Với cửa sổ native UI thì nó là null. Cửa sổ có các lối tắt cho việc hầu hết app cần:

```zig
win.loadUrl("/settings");          // tải một URL, hoặc một đường dẫn của frontend
win.eval("document.body.classList.add('ready')");   // chạy một script, không chờ
win.evalResult("document.title", cb);               // tính giá trị, và nhận kết quả
```

Bản thân trang có phần còn lại, như nhau trên mọi nền tảng:

| method | |
|---|---|
| `load(url_or_path)` | tải một URL, hoặc một đường dẫn của frontend (trên dev server khi có) |
| `loadHtml(html, base_url)` | tải tài liệu từ một chuỗi; `base_url` (hoặc `about:blank`) là origin của nó |
| `loadFile(path)` | tải một đường dẫn tuyệt đối trên đĩa; các file trong thư mục của nó cũng tải được |
| `reload()`, `stop()` | |
| `goBack()`, `goForward()`, `canGoBack()`, `canGoForward()` | lịch sử của trang |
| `isLoading()` | |
| `processId()` | tiến trình chạy trang: tiến trình web content trên macOS, tiến trình trình duyệt trên Windows; null trên Linux và khi không biết |
| `currentUrl(gpa)` (cả `url`), `title(gpa)` | bản sao thuộc về bên gọi |
| `addUserScript(script)` → id, `removeUserScript(id)` | script mà các tài liệu sau sẽ chạy |
| `setZoom(factor)`, `zoom()` | |
| `setUserAgent(ua)`, `userAgent(gpa)` | |
| `openDevTools()` | mở công cụ kiểm tra web, khi `inspectable` |
| `eval(js)`, `evalResult(js, cb)` | [chạy script](#evaluating-scripts) |
| `findInPage(text, opts, cb)`, `stopFind()` | [tìm chữ](#finding-text) |
| `print()`, `printToPdf(opts, cb)` | [in](#printing) |
| `listCookies`, `setCookie`, `deleteCookie`, `clearCookies` | [cookie](#cookies) |

Các method của trang chạy trên main thread, nơi các method đã bind và listener vốn chạy.

`myzig.page.UserScript` có `source` và `at_document_end`:

- `at_document_end` là false (mặc định) thì chạy trước các script của chính tài liệu; true thì chạy khi DOM đã sẵn sàng.
- Script chạy trong frame chính, sau bridge, nên dùng được `window.myzig`.
- Với `all_frames`, script còn chạy trong mọi iframe, nơi không có bridge.

<a id="evaluating-scripts"></a>

## Chạy script

`eval` chạy một script rồi bỏ qua kết quả. `evalResult` tính một biểu thức và chờ nó nếu là promise. Nó đưa giá trị cho một `myzig.EvalCallback` dưới dạng JSON, hoặc thông báo lỗi:

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

- Giá trị là `JSON.stringify` của kết quả; `undefined` cho ra `null`.
- Cả hai chuỗi chỉ sống trong lúc callback chạy.
- Lỗi bị throw, hoặc promise bị reject, đến dưới dạng `.err`.
- Các lần tính còn đang chờ khi trang chuyển hướng hoặc đóng sẽ thất bại với "the page navigated" hoặc "the page closed". Nhờ vậy mọi callback đều được gọi đúng một lần.
- Kết quả mang một token chỉ bridge của trang này biết. Nên script của trang không thể trả lời thay.

<a id="page-events"></a>

## Event của trang

`on_event` nhận một `myzig.PageListener`, tạo bằng `.of(&state, func)`. `func` là `fn (state: *State, window: *myzig.Window, event: myzig.PageEvent) void`. Một số event đặt câu hỏi, và listener trả lời ngay tại chỗ:

```zig
fn onPage(s: *State, win: *myzig.Window, e: myzig.PageEvent) void {
    switch (e) {
        .title_changed => |t| win.setTitle(t),
        .will_navigate => |nav| {
            // Giữ trang ở frontend của chính app.
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

| event | dữ liệu | |
|---|---|---|
| `will_navigate` | `*Navigate`: `url`, `user_initiated`, `cancel` | frame chính sắp bắt đầu chuyển trang |
| `load_started` | URL | |
| `committed` | URL | tài liệu đã đổi (sau các redirect) |
| `load_finished` | URL | |
| `load_failed` | `LoadError`: `url`, `code`, `description` | |
| `title_changed` | tiêu đề | |
| `dom_ready` | | bridge đã vào trang và DOM đã sẵn sàng |
| `new_window` | `*NewWindow`: `url`, `user_gesture`, `handled` | `window.open`, `target=_blank` |
| `permission` | `*PermissionRequest`: `kinds`, `origin`, `allow` | camera, micro, vị trí, thông báo |
| `download_started` | `*DownloadStart`: `url`, `suggested_name`, `path`, `cancel` | |
| `download_progress` | `DownloadProgress`: `url`, `received`, `total` (0 khi không biết) | |
| `download_done` | `DownloadDone`: `url`, `path`, `err` (null khi thành công) | |

Các kiểu nằm trong `myzig.page` (`myzig.page.Navigate`, ...). Các chuỗi sống trong lúc listener chạy.

Chuyện gì xảy ra khi không trả lời:

- **Cửa sổ mới.** Trừ khi listener đặt `handled`, URL `http` và `https` mở trong trình duyệt của hệ thống; các URL khác bị bỏ. Bản thân trang không bao giờ mở cửa sổ webview thứ hai.
- **Quyền.** `allow` ban đầu là trang đang xin có được [tin cậy](#trust) hay không.
  - Trang của chính app được dùng camera, micro, vị trí và thông báo. Hệ thống vẫn có thể hỏi người dùng. Các trang khác thì không.
  - `kinds` liệt kê những gì được xin cùng lúc, như camera và micro của một cuộc gọi.
  - Trang của một server http thường không phải secure context, nên không xin được gì. Ngoại lệ là origin có trong `secure_origins` của app (WebView2).
  - WebView2 lưu câu trả lời trong profile: origin đã bị từ chối một lần sẽ không được hỏi lại.
- **Tải xuống.** File tải về vào thư mục Downloads của người dùng, theo tên được gợi ý.
  - Chỉ dùng phần cuối của tên: không bao giờ là một thư mục.
  - Nếu đã có file trùng tên, nó được đánh số kiểu `name (2).ext`.
  - Listener có thể đặt `path` sang chỗ khác (chuỗi được sao chép khi event trả về), hoặc `cancel` nó.

<a id="schemes-of-the-app"></a>

## Scheme của app

Ngoài `myzig://`, app có thể phục vụ các scheme của riêng mình. Chúng dành cho dữ liệu không phải file của frontend cũng không phải lời gọi: ảnh tạo ngay lúc chạy, file người dùng đã chọn, stream.

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

Trang tải `media://localhost/hello.json`, trên Windows là `http://media.localhost/hello.json`. Trang có thể chọn dạng nào dựa vào `myzig.platform`:

```js
const media = (path) =>
  myzig.platform === "windows" ? "http://media.localhost" + path : "media://localhost" + path;
const data = await (await fetch(media("/hello.json"))).json();
```

Một `myzig.SchemeRequest` có:

- `method`;
- `url`, luôn ở dạng `<scheme>://localhost/...`;
- `path`, không có phần query;
- `body`.

Nó được trả lời một lần, trên main thread, ngay hoặc sau đó:

- `req.respond(status, headers, body)` trả lời trọn vẹn.
- `req.begin(status, headers)`, rồi `req.write(bytes)` bao nhiêu lần cũng được, rồi `req.finish()` trả lời theo từng phần.
- Handler có thể giữ request và kết thúc nó ở một vòng lặp sau: từ một timer, hoặc khi một tiến trình trả lời. Request được giải phóng khi kết thúc.

`req.addHeader(name, value)` thêm header trước `begin`, và `req.header(name)` đọc một header đã đặt.

Một trang đáng tin ở origin khác có thể gửi request, ví dụ trang trên dev server fetch `media://`. Khi đó câu trả lời cho phép nó bằng header CORS, và các request preflight `OPTIONS` được trả lời thay cho app.

<a id="trust"></a>

## Tin cậy

Service đã bind là code của chính app, nên chỉ những trang app tin cậy mới được gọi. Lời gọi từ mọi trang khác thất bại với `Untrusted`. Được tin cậy gồm:

- các scheme của app (`myzig://` và `PageOptions.schemes`, ở cả hai dạng trên Windows), và URL `blob:` của các origin được tin cậy;
- trang `file:` và `about:`;
- dev server (`dev_url`, hoặc `MYZIG_DEV_URL`), theo origin của nó;
- các origin có trong `trusted_origins`, như `"https://example.com"`, hoặc `"*"` cho mọi trang. Chúng được so không phân biệt hoa thường, bỏ qua `/` ở cuối, tính cả scheme và port.

Độ tin cậy được kiểm tra theo tài liệu đang hiện lúc lời gọi tới. Nên trang đã chuyển sang site khác sẽ mất nó. Cùng quy tắc này cấp [quyền](#page-events) mặc định.

<a id="finding-text"></a>

## Tìm chữ

```zig
fn found(_: ?*anyopaque, r: ?myzig.page.FindResult) void {
    const res = r orelse return; // trang không tìm được
    std.log.info("{d} of {d}", .{ res.active, res.matches });
}

page.findInPage("needle", .{}, .{ .ctx = null, .func = found });
page.findInPage("needle", .{ .find_next = true }, .{ .ctx = null, .func = found }); // kết quả kế tiếp
page.stopFind();
```

`myzig.page.FindOptions` có `match_case`, `backward` và `find_next`. `find_next` đi tiếp từ kết quả hiện tại của cùng đoạn chữ.

Bridge làm giống nhau trên mọi nền tảng:

- tìm các kết quả trong phần chữ đang hiện của trang;
- tô sáng chúng, bằng CSS Custom Highlight API nếu engine có, nếu không thì bằng vùng chọn;
- scroll để kết quả hiện tại vào tầm nhìn;
- báo về có bao nhiêu kết quả, và kết quả nào đang được chọn, đếm từ 1.

<a id="printing"></a>

## In

`page.print()` mở hộp thoại in của hệ thống (`window.print()`). `page.printToPdf(opts, cb)` tạo PDF của trang mà không cần hộp thoại:

```zig
fn gotPdf(_: ?*anyopaque, pdf: ?[]const u8, err: ?[]const u8) void {
    const bytes = pdf orelse return std.log.err("pdf: {s}", .{err.?});
    _ = bytes; // ghi nó ra đâu đó: nó chỉ sống trong lúc callback chạy
}

page.printToPdf(.{ .landscape = true, .background = true }, .{ .ctx = null, .func = gotPdf });
```

`myzig.page.PdfOptions` tính bằng inch:

| trường | mặc định |
|---|---|
| `width`, `height` | US Letter |
| `landscape` | |
| bốn lề | 0,4 inch |
| `background` | |

WebKitGTK và WebView2 tuân theo chúng. Trên macOS (`createPDF`, macOS 11 trở lên), PDF có đúng kích thước của trang.

<a id="cookies"></a>

## Cookie

Cookie của các trang trong app đọc và sửa được từ Zig, theo kiểu bất đồng bộ. Chúng nằm trong kho mặc định của webview, dùng chung cho các cửa sổ:

```zig
page.setCookie(.{ .name = "session", .value = token, .domain = "example.com", .secure = true }, .{ .ctx = null, .func = done });
page.listCookies("https://example.com/", .{ .ctx = null, .func = listed }); // null: mọi cookie
page.deleteCookie("session", "example.com", "/", .{ .ctx = null, .func = done });
page.clearCookies(.{ .ctx = null, .func = done });
```

| `myzig.page.Cookie` | |
|---|---|
| `name`, `value` | |
| `domain` | `.example.com` để áp dụng cho cả subdomain |
| `path` | `/` |
| `expires` | số giây từ năm 1970; null cho cookie phiên |
| `secure`, `http_only` | |
| `same_site` | `.lax`, `.strict`, `.none` |

- `listCookies` gọi một `CookiesCallback` với các cookie mà một request tới URL đó sẽ gửi, hoặc tất cả.
- Các hàm khác gọi một `DoneCallback` với null hoặc một lỗi.

<a id="testing-pages"></a>

## Test trang web

Trang web được test ở chế độ ẩn, qua webview và bridge thật.

- Chạy app với `--myzig-eval=JS`, mỗi trang sẽ tính `JS` khi DOM đã sẵn sàng. Không có cửa sổ nào hiện lên màn hình.
- Trang báo về bằng `myzig.log(...)`, in `page: ...` ra stderr của app.
- Nó kết thúc lần chạy bằng `myzig.window.close()`. App thoát khi cửa sổ cuối cùng đóng.
- `--myzig-hidden` giữ cửa sổ ẩn cho trang tự test chính nó.

```sh
zig-out/bin/hello --myzig-eval='myzig.call("Greeter.greet","Ada").then(v=>{myzig.log(v);myzig.window.close()})'
zig build test-pages   # các lời gọi và event của hello, và examples/pages
```

`examples/pages` test mọi thứ trên trang này. Nó in ra `page: ok`. Đầu tiên, trang:

- gọi các service;
- fetch scheme của app: trọn vẹn, từng phần, POST, 404;
- đọc `assets_dir` và một route phía client;
- stream qua channel theo cả hai chiều;
- xin một quyền, mở một cửa sổ và tải xuống một file.

Sau đó Zig chạy script, tìm chữ, in ra PDF, đặt và xóa cookie, và thêm một user script. Cuối cùng, nó tải một tài liệu không được tin cậy, và lời gọi của tài liệu đó thất bại.

`zig build test-page-ipc -Doptimize=ReleaseSmall -j1` kiểm tra các payload echo theo batch, gồm ASCII, Unicode và 64 KiB, qua webview ẩn thật.

`zig build build-pages -Doptimize=ReleaseSmall -j1` cài `zig-out/bin/pages` (`pages.exe` trên Windows) để đo từ bên ngoài. `MYZIG_MEMORY_PROBE=ipc` chọn bài đo IPC khi chạy nó headless.

<details>
<summary>Bài đo bộ nhớ WebView2</summary>

Trên Windows, `zig build test-page-memory -Doptimize=ReleaseSmall -j1` chạy lần lượt bốn bài đo WebView2 ẩn: Normal, restore, restore, Normal.

- Mỗi bài tải lại một lần, rồi kiểm tra mười chu kỳ memory target.
- Các mục kiểm tra: getter memory target và controller visibility của runtime, timer, fetch, state DOM/JS và IPC.
- Request khôi phục đến sau một timer chờ hai giây không có IPC hay fetch. Việc làm chậm ở nền có thể kéo dài thời gian chờ đó.
- Log, gồm từng mẫu đo thời gian, được lưu ở `zig-out/memory-probe/`. Các lần chạy không được cache.
- Nó đo việc IPC hồi phục trong một cửa sổ ẩn. Nó không đo độ trễ vẽ lại khi hiện, hay lượng bộ nhớ dùng khi cửa sổ đang hiện.
- Runtime cũ không hỗ trợ sẽ báo bỏ qua. Bước này chỉ có trên Windows.

</details>
