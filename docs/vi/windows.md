<a id="windows"></a>

# Cửa sổ

Một cửa sổ hiển thị một trong hai nội dung: giao diện native mà myzig vẽ (a `ui.View`) hoặc một trang web trong webview của hệ thống. Mọi thứ khác, các tùy chọn, sự kiện, thanh tiêu đề, tờ rơi, đều giống nhau đối với cả hai.

```zig
const win = try app.newWindow(.{
    .title = "Notes",
    .width = 900,
    .height = 600,
    .min_width = 480,
    .min_height = 320,
    .title_bar = .hidden,
    .state = myzig.windowState("main"),
    .content = .{ .view = .init(&state, State.view) },
});
```

`App.newWindow` tạo cửa sổ, hiển thị nó trừ khi `visible` là false và trả về nó. Ứng dụng sẽ giữ nó trong `app.windows` cho đến khi nó đóng; sau đó nó được giải phóng và con trỏ không được sử dụng lại (`on_close` là nơi để quên nó).

Một trang thay vì một lượt xem:

```zig
const assets = [_]myzig.Asset{
    .{ .path = "/index.html", .data = @embedFile("frontend/index.html") },
};

_ = try app.newWindow(.{
    .title = "Hello",
    .content = .{ .page = .{ .url = "/", .assets = &assets } },
});
```

Các tùy chọn của trang là gì (`myzig.PageOptions`: nội dung, thư mục, máy chủ nhà phát triển, lược đồ, nguồn gốc đáng tin cậy, tập lệnh, trình nghe của trang) nằm trong [Trang](pages.md).

<a id="options"></a>

## Tùy chọn

`myzig.WindowOptions`:

| lĩnh vực | mặc định | nó làm gì |
|---|---|---|
| `title` | `""` | văn bản của thanh tiêu đề |
| `width`, `height` | 800, 600 | kích thước của nội dung tính bằng điểm |
| `min_width`, `min_height` | 200, 150 | cái nhỏ nhất mà người dùng có thể làm được |
| `resizable` | true | người dùng có thể thay đổi kích thước nó |
| `x`, `y` | null | góc trên bên trái của nó cách với góc trên bên trái của màn hình chính; căn giữa khi null |
| `visible` | true | hiển thị cùng một lúc; nếu không hãy gọi `show` |
| `always_on_top` | false | phía trên cửa sổ của các ứng dụng khác |
| `skip_taskbar` | false | ra khỏi thanh tác vụ và trình chuyển đổi ứng dụng (Linux, Windows) |
| `title_bar` | `.default` | `.default`, `.hidden` hoặc `.frameless` ([bên dưới](#title-bars)) |
| `title_bar_height` | 0 | chiều cao của thanh tiêu đề ẩn hoặc dải kéo của cửa sổ không khung; 0 là của hệ thống (32 trên Windows, 28 ở nơi khác) |
| `theme` | null | Màu của giao diện native, cố định (`ui.Theme.light`, `ui.Theme.dark_theme`, một trong các màu của ứng dụng); hệ thống sáng hay tối khi null |
| `material` | `.none` | những gì hiển thị qua nền ([Vật liệu](#materials)) |
| `state` | null | nhớ khung bên dưới một phím ([bên dưới](#remember-where-windows-were)) |
| `on_close` | null | được gọi khi cửa sổ đóng lại, trước khi nó được giải phóng |
| `on_close_request` | null | hỏi liệu cửa sổ có đóng khi người dùng đóng nó không |
| `on_event` | null | tập trung, di chuyển, thay đổi kích thước, thu nhỏ, phóng to |
| `on_drop` | null | các tập tin được thả trên cửa sổ từ trình quản lý tập tin |
| `content` | (bắt buộc) | `.{ .view = ... }` hoặc `.{ .page = ... }` |

Flyout cũng là một cửa sổ, được tạo bởi `App.newFlyout` ([Flyouts](#flyouts)).

<a id="show-windows-without-flashing"></a>

## Hiển thị cửa sổ không nhấp nháy

Một cửa sổ hiển thị trước khi nội dung của nó sẵn sàng sẽ nhấp nháy trống. Tạo nó bằng `.visible = false` và hiển thị nó khi nó sẵn sàng:

```zig
const win = try app.newWindow(.{ .title = "Report", .visible = false, .content = content });
// ... load what it shows ...
win.show();
```

`--myzig-hidden` (và các cờ headless khác) giữ mọi cửa sổ ẩn bất kể ứng dụng yêu cầu: các bài kiểm tra và ảnh chụp nhanh không bao giờ đưa bất cứ thứ gì lên màn hình.

<a id="size-position-and-state"></a>

## Kích thước, vị trí và trạng thái

| phương pháp | nó làm gì |
|---|---|
| `show()`, `hide()`, `isVisible()` | hiển thị hoặc ẩn cửa sổ |
| `focus()`, `isFocused()` | đưa cửa sổ và ứng dụng lên phía trước; nó có bàn phím không |
| `close()` | đóng nó ngay lập tức mà không cần hỏi `on_close_request` |
| `requestClose()` | đóng nó lại như người dùng sẽ làm và hỏi `on_close_request` |
| `setTitle(title)` | văn bản của thanh tiêu đề |
| `frame()` | `Window.Frame`: `x`, `y`, `width`, `height` tại các điểm trên màn hình, từ trên cùng bên trái của màn hình chính |
| `contentSize()` | chiều rộng và chiều cao `[2]f64` của nội dung, không có thanh tiêu đề |
| `setSize(w, h)` | thay đổi kích thước nội dung, giữ phía trên bên trái |
| `setPosition(x, y)` | di chuyển phía trên bên trái |
| `center()` | tập trung nó vào màn hình của nó |
| `setMinSize(w, h)` | kích thước nội dung nhỏ nhất |
| `setResizable(on)`, `setAlwaysOnTop(on)` | như các tùy chọn |
| `minimize()`, `isMinimized()` | vào Dock hoặc thanh tác vụ |
| `zoom()`, `isMaximized()` | tối đa hóa nó hoặc khôi phục nó |
| `setFullScreen(on)`, `isFullScreen()` | toàn màn hình (Không gian riêng trên macOS) |
| `setMaterial(m)` | tài liệu đằng sau nội dung; false ở nơi không có |
| `redraw()` | rút lại giao diện native ở lần làm mới tiếp theo, vì trạng thái đã thay đổi bên ngoài các sự kiện của nó |

Từ một trang, `myzig.window.close()`, `minimize()`, `toggleMaximize()` và `setTitle(title)` thực hiện tương tự cho cửa sổ riêng của trang đó.

<a id="remember-where-windows-were"></a>

## Hãy nhớ cửa sổ ở đâu

```zig
_ = try app.newWindow(.{
    .title = "Notes",
    .state = myzig.windowState("main"),
    .content = content,
});
```

Với khóa `state`, một cửa sổ sẽ mở ra trong đó cửa sổ cuối cùng có khóa đó là: vị trí, kích thước của nó và liệu nó có được ghi đè tối đa hay không `x`, `y`, `width` và `height`. Các trạng thái được lưu giữ trong `window-state.txt` trong thư mục dữ liệu của ứng dụng, mỗi dòng trên một phím, được đọc khi cửa sổ đầu tiên có phím mở ra và được ghi khi cửa sổ đó đóng lại. Trạng thái không còn vừa (màn hình chưa cắm, kích thước dưới 50 điểm) sẽ bị bỏ qua. Cung cấp cho mỗi loại cửa sổ khóa riêng (`"main"`, `"preferences"`, `"note"`). Các ứng dụng không nhớ cửa sổ sẽ không liên kết cửa hàng.

<a id="closing"></a>

## Đóng cửa

```zig
const State = struct {
    dirty: bool = false,
    window: ?*myzig.Window = null,

    fn mayClose(s: *State, win: *myzig.Window) bool {
        _ = win;
        if (!s.dirty) return true;
        const r = myzig.dialog.message(.{
            .title = "Close without saving?",
            .buttons = &.{ "Close", "Cancel" },
        });
        return r.button == 0;
    }

    fn closed(ctx: *anyopaque, win: *myzig.Window) void {
        _ = win;
        const s: *State = @ptrCast(@alignCast(ctx));
        s.window = null;
    }
};

_ = try app.newWindow(.{
    .on_close_request = .of(&state, State.mayClose),
    .on_close = .{ .ctx = &state, .func = State.closed },
    .content = content,
});
```

`on_close_request` (a `myzig.CloseRequest`) được hỏi khi người dùng đóng cửa sổ: nút đóng của nó, Alt+F4, Đóng của Dock hoặc thanh tác vụ, mục Đóng cửa sổ của macOS, `requestClose`. Sai giữ cho nó mở. `close` không hỏi. `on_close` chạy khi cửa sổ hoạt động, trước khi nó được giải phóng, bất kể nó đóng theo cách nào. [Tài liệu](documents.md) yêu cầu bạn, lưu hoặc hủy các thay đổi của từng tài liệu.

<a id="events"></a>

## Sự kiện

```zig
fn onWindow(s: *State, win: *myzig.Window, e: myzig.WindowEvent) void {
    _ = win;
    switch (e) {
        .focus => s.active = true,
        .blur => s.active = false,
        .resized => |size| s.width = size.width,
        .moved => |p| std.log.info("at {d}, {d}", .{ p.x, p.y }),
        .minimized, .maximized, .restored => {},
    }
}

_ = try app.newWindow(.{ .on_event = .of(&state, State.onWindow), .content = content });
```

`myzig.WindowEvent` là sự kết hợp của `focus`, `blur`, `moved` (trên cùng bên trái, theo điểm màn hình), `resized` (kích thước nội dung), `minimized`, `maximized` và `restored` (trở lại từ một trong hai). Các sự kiện xảy ra trên luồng chính, một lần cho mỗi thay đổi: hệ thống lặp lại kích thước và kích hoạt mà không thay đổi gì và myzig loại bỏ chúng.

<a id="title-bars"></a>

## Thanh tiêu đề

`title_bar` là một trong:

- **`.default`**: thanh tiêu đề của hệ thống phía trên nội dung.
- **`.hidden`**: nội dung lấp đầy cửa sổ, dưới các điều khiển cửa sổ của hệ thống: đèn giao thông của macOS, nút chú thích của Windows 11 ở góc trên cùng bên phải (với bố cục chụp nhanh ở mức tối đa), thanh tiêu đề của GTK với các nút tiêu đề. Khoảng trống ở trên cùng `title_bar_height` sẽ di chuyển cửa sổ, giống như thanh tiêu đề và nhấp đúp vào đó sẽ phóng to cửa sổ. Trên Windows, các nút chú thích sáng hoặc tối tùy theo chủ đề của giao diện native (`theme` của cửa sổ hoặc chủ đề mà view áp dụng), không phải của hệ thống.
- **`.frameless`**: không có thanh tiêu đề và không có điều khiển. Nội dung sẽ vẽ tất cả nội dung đó và di chuyển cửa sổ khỏi vùng kéo của nó. Cửa sổ vẫn thay đổi kích thước so với các cạnh và giữ nguyên bóng.

Trong giao diện native, một lần nhấn trong dải kéo sẽ di chuyển cửa sổ trừ khi nó chạm vào hộp tương tác (nút, tab, trường): những thao tác đó sẽ chiếm lấy nó. View có thanh công cụ cao hơn thanh tiêu đề sẽ đặt `c.title_bar_height` theo chiều cao của thanh công cụ và dải theo sau nó. Để tránh sự kiểm soát của hệ thống, hãy hỏi cửa sổ xem chúng chiếm bao nhiêu chỗ:

```zig
fn view(s: *State, c: *ui.Context) void {
    const area = s.window.titleBar(); // myzig.TitleBarArea
    const bar = ui.div(c).row().itemsCenter().wFull().h(@floatCast(@max(area.height, 40)))
        .pl(@floatCast(area.left + 8)).pr(@floatCast(area.right + 8));
    defer bar.end();
    ui.text(c, "Notes", .{ .weight = .semibold });
}
```

`myzig.TitleBarArea` có `height` các nút điều khiển và chiều rộng mà chúng bao phủ trên `left` (đèn giao thông của macOS) và trên các nút chú thích `right` (Windows'). Nó trống đối với các cửa sổ không bị ẩn, ở chế độ toàn màn hình và trên Linux, nơi thanh tiêu đề của GTK nằm phía trên nội dung.

Một cửa sổ không khung sẽ di chuyển từ thanh tiêu đề của chính nó: gọi `startDrag()` bằng cách nhấn vào nó. Trên Windows 11, một cửa sổ không khung vẽ nút phóng to của riêng nó gọi `setSnapButton(rect)` với hình chữ nhật của nút trong nội dung, để khi di chuột vào nó sẽ hiển thị bố cục đính kèm; null xóa nó.

Các trang đánh dấu các vùng kéo của chúng trong CSS: các phần tử được tạo kiểu `--app-region: drag` di chuyển cửa sổ (một cú nhấp đúp sẽ phóng to nó) và `--app-region: no-drag` loại bỏ những gì bên trong một cửa sổ, chẳng hạn như các nút:

```css
header { --app-region: drag; height: 38px; }
header button { --app-region: no-drag; }
```

<a id="materials"></a>

## Vật liệu

```zig
_ = try app.newWindow(.{ .material = .sidebar, .title_bar = .hidden, .content = content });
```

`myzig.Material` là nội dung hiển thị qua nền của cửa sổ nơi hệ thống có tài liệu và nội dung hiển thị rõ ràng:

| vật chất | macOS (sống động) | Windows 11 |
|---|---|---|
| `.none` | không có | không có |
| `.sidebar` | thanh bên | Mica |
| `.under_window` | dưới nội dung của cửa sổ | Mica Alt (theo thẻ) |
| `.popover` | một cửa sổ bật lên hoặc HUD | Acrylic |

`setMaterial` thay đổi nó sau và trả về false khi hệ thống không có (Linux, Windows 10, trình duyệt).

<a id="flyouts"></a>

## Tờ rơi

Flyout là một bảng điều khiển không viền không có nút trên thanh tác vụ, được đặt bên cạnh một hình chữ nhật: hộp của cửa sổ chính, một điểm trên màn hình hoặc biểu tượng khay. Các ứng dụng trên thanh menu, bộ chọn và danh sách gợi ý là những trang trình bày.

```zig
const panel = try app.newFlyout(.{
    .tray = tray,                // or .parent = win with .anchor in its content
    .width = 320,
    .height = 420,
    .dismiss = .hide,
    .hidden = true,
    .content = .{ .view = .init(&state, State.panel) },
});
// The tray icon's click toggles it:
fn trayClicked(s: *State, t: *myzig.Tray) void {
    _ = t;
    if (s.panel.isVisible()) s.panel.hide() else s.panel.show();
}
```

`myzig.FlyoutOptions`:

| lĩnh vực | mặc định | nó làm gì |
|---|---|---|
| `parent` | null | cửa sổ có nội dung `anchor`; tờ rơi vẫn ở phía trên nó |
| `tray` | null | neo hộp thả xuống vào biểu tượng khay: bên dưới thanh menu macOS, phía trên thanh tác vụ ở dưới cùng; tập trung vào khu vực làm việc nơi hệ thống không cho biết các biểu tượng ở đâu (Linux) |
| `anchor` | trống rỗng | `myzig.flyout.Rect` tính theo điểm: trong nội dung của phụ huynh hoặc trên màn hình không có phụ huynh |
| `placement` | `.bottom_start` | cạnh và căn chỉnh: `bottom`, `top`, `right`, `left`, mỗi `_start`, căn giữa hoặc `_end` |
| `gap` | 0 | điểm giữa neo và flyout |
| `width`, `height` | 200, 200 | kích thước của nó |
| `focusable` | true | lấy bàn phím như hiển thị và bị loại bỏ khi một cửa sổ khác lấy nó; nếu không nó sẽ không bao giờ sử dụng bàn phím (chú giải công cụ, gợi ý) và giữ nguyên cho đến khi đóng |
| `dismiss` | `.close` | tác dụng của flyout bị loại bỏ: `.close` (khi người dùng đóng nó) hoặc `.hide` (để hiển thị lại) |
| `hidden` | false | đã tạo ẩn: `show` hiển thị nó, đặt lại |
| `popover` | false | trên macOS, cửa sổ bật lên của hệ thống (`NSPopover`): vật liệu của nó, các góc tròn và một mũi tên chỉ vào giữa mỏ neo; ở phía `placement` hoặc phía đối diện (phần còn lại của vị trí và `gap` không áp dụng); cần `parent` hoặc `tray`. Một chuyến bay thường xuyên ở nơi khác |
| `material` | `.none` | vật liệu mờ, mờ đằng sau nội dung, dưới dạng ([Vật liệu](#materials)); một cửa sổ bật lên có cái riêng của nó |
| `corner_radius` | 0 | làm tròn các góc trên macOS, theo điểm: vật liệu và nội dung được cắt theo chúng và bóng theo sau chúng. Windows 11 vòng bay khi nó làm tròn các menu của nó; Linux thì không |
| `theme` | null | như một cửa sổ |
| `content` | (bắt buộc) | một lượt xem hoặc một trang |

Flyout có thể lấy tiêu điểm sẽ bị loại bỏ khi một cửa sổ khác sử dụng bàn phím (một cú nhấp chuột vào nơi khác, ứng dụng đã tắt) và trên Escape; thao tác nhấn vào biểu tượng trên khay của chính nó sẽ được để lại cho lần nhấp vào biểu tượng, thao tác này sẽ chuyển đổi biểu tượng đó thay vì đóng biểu tượng để nhấp để mở lại (macOS, Windows). Nó được đặt như các menu: trên mỗi trục, nó lật sang phía bên kia của mỏ neo hoặc đầu kia của nó, nơi nó không vừa và trục bị lật sẽ trượt trở lại khu vực làm việc, sau đó thu nhỏ lại.

Nội dung của hộp thả xuống bật lên không có nền tảng trên tài liệu. Với `focusable` nó sẽ đóng khi người dùng nhấp vào nơi khác (yêu cầu `on_close_request`) và từ biểu tượng khay, nó sẽ kích hoạt ứng dụng và làm nổi bật biểu tượng khi nó hiển thị. Cửa sổ của nó là cửa sổ bật lên khi nó hiển thị.

Khi mỏ neo di chuyển (mốc gốc đã di chuyển, biểu tượng trên khay cũng vậy), `placeFlyout()` đặt nó lại; `setAnchor(rect)` cho nó một mỏ neo khác; `setSize` thay đổi kích thước tại chỗ; `isFlyout()` thông báo các hộp thả xuống từ các cửa sổ khác.

<a id="attention-and-progress"></a>

## Chú ý và tiến bộ

- `flash(true)` yêu cầu sự chú ý cho đến khi cửa sổ được tập trung: nó bật lại biểu tượng Dock (macOS), nhấp nháy nút thanh tác vụ (Windows) hoặc đánh dấu cửa sổ là khẩn cấp (Linux); `flash(false)` dừng lại.
- `setProgress(.{ .state = .normal, .value = 0.4 })` hiển thị tiến trình của một nhiệm vụ (`myzig.Progress`: `state` là `.none`, `.normal`, `.indeterminate`, `.paused` hoặc `.failed`, `value` từ 0 đến 1) trên nút thanh tác vụ (Windows) hoặc mục nhập trình khởi chạy (Linux gắn với Unity API). Nó trả về false trong đó không có gì hiển thị (macOS, trong đó `app.setBadge` là của Dock).

<a id="documents"></a>

## Tài liệu

- `setDocumentEdited(true)` đánh dấu tài liệu của cửa sổ là có các thay đổi chưa được lưu: một dấu chấm trong nút đóng của macOS, `*` trước tiêu đề trên Windows và Linux. `isDocumentEdited()` đọc nó.
- `setRepresentedFile(path)` đặt tên cho tệp mà cửa sổ hiển thị: trên macOS biểu tượng của nó trên thanh tiêu đề mà người dùng có thể kéo và ⌘-nhấp vào các thư mục của nó; không có gì ở nơi khác.

[Tài liệu](documents.md) thực hiện cả hai chức năng này cho cửa sổ tài liệu.

<a id="files-dropped-on-a-window"></a>

## Các tập tin bị rơi trên một cửa sổ

```zig
fn dropped(s: *State, win: *myzig.Window, paths: []const []const u8) void {
    _ = win;
    for (paths) |p| s.open(p);
}

_ = try app.newWindow(.{ .on_drop = .of(&state, State.dropped), .content = content });
```

`on_drop` lấy đường dẫn của tệp bị xóa khỏi Finder, Explorer hoặc trình quản lý tệp. Kéo trong giao diện native và kéo ra khỏi ứng dụng khác, nằm trong [Truyền dữ liệu](data-transfer.md) và [Kéo và thả](ui/drag-and-drop.md).

<a id="pages-in-windows"></a>

## Các trang trong cửa sổ

Cửa sổ hiển thị một trang cũng chạy các tập lệnh trong đó và tải các URL khác:

- `loadUrl(url)` tải một URL khác.
- `eval(js)` chạy tập lệnh mà không phải đợi tập lệnh đó.
- `evalResult(js, cb)` đánh giá một biểu thức và chuyển giá trị của nó dưới dạng JSON hoặc lỗi của nó tới `myzig.EvalCallback`.
- `sendOwned(msg)` xếp hàng tin nhắn được mã hóa cho trang, từ bất kỳ chuỗi nào; sự kiện đã gõ làm điều đó cho bạn.

Bản thân trang này là `win.page` (null cho giao diện native), với tính năng tìm kiếm, in, cookie và phần còn lại: xem [Trang](pages.md).

<a id="platforms"></a>

## Nền tảng

| | macOS | Linux | Windows | trình duyệt |
|---|---|---|---|---|
| các cửa sổ | NSWindow | GtkWindow | Win32 | canvas của trang, một cửa sổ |
| giao diện native được vẽ bằng | Metal | OpenGL, hoặc CPU | Direct3D 11, hoặc CPU | WebGL 2 |
| trang | WKWebView | WebKitGTK | WebView2 | không |
| thanh tiêu đề ẩn | nội dung đèn giao thông | thanh tiêu đề GTK | nút chú thích trên nội dung, bố cục chụp nhanh | không |
| vật liệu | sự sống động | không | Mica, Mica Alt, Acrylic (Windows 11) | không |
| tờ rơi | vâng | có (tấm thả khay ở giữa) | vâng | không |
| tiến bộ | không (huy hiệu của Dock) | Trình khởi chạy đoàn kết | thanh tác vụ | không |
| tập tin đại diện | vâng | không | không | không |

Trong trình duyệt, cửa sổ đầu tiên của giao diện native sẽ lấp đầy trang; kích thước, vị trí và trạng thái của cửa sổ không làm gì ở đó ([Trình duyệt](browsers.md)).
