<a id="windows"></a>

# Cửa sổ

Một cửa sổ hiện giao diện native do myzig vẽ (một `ui.View`), hoặc một trang web trong webview của hệ thống. Tùy chọn, event, thanh tiêu đề và flyout đều giống nhau cho cả hai.

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

- `App.newWindow` tạo cửa sổ, hiện nó nếu `visible` không phải false, và trả về nó.
- App giữ cửa sổ trong `app.windows` cho tới khi nó đóng. Sau đó cửa sổ được giải phóng, và không được dùng lại con trỏ đó nữa. `on_close` là chỗ để quên nó đi.

Một trang web thay cho view:

```zig
const assets = [_]myzig.Asset{
    .{ .path = "/index.html", .data = @embedFile("frontend/index.html") },
};

_ = try app.newWindow(.{
    .title = "Hello",
    .content = .{ .page = .{ .url = "/", .assets = &assets } },
});
```

Tùy chọn của trang nằm ở [Trang web](pages.md): `myzig.PageOptions` có asset, một thư mục, dev server, scheme, origin tin cậy, script và listener của trang.

<a id="options"></a>

## Tùy chọn

`myzig.WindowOptions`:

| Trường | Mặc định | Tác dụng |
|---|---|---|
| `title` | `""` | chữ trên thanh tiêu đề |
| `width`, `height` | 800, 600 | kích thước nội dung, tính bằng điểm |
| `min_width`, `min_height` | 200, 150 | kích thước nhỏ nhất người dùng thu được |
| `resizable` | true | người dùng đổi được kích thước |
| `x`, `y` | null | góc trên bên trái, tính bằng điểm màn hình từ góc trên bên trái của màn hình chính; null thì đặt giữa |
| `visible` | true | hiện ngay; nếu không thì gọi `show` |
| `always_on_top` | false | nằm trên cửa sổ của các app khác |
| `skip_taskbar` | false | không có trên taskbar và trong trình chuyển app (Linux, Windows) |
| `title_bar` | `.default` | `.default`, `.hidden` hoặc `.frameless` ([bên dưới](#title-bars)) |
| `hide_window_buttons` | false | với `.hidden`, view tự vẽ các nút điều khiển; `titleBar()` không chừa chỗ; trình duyệt bỏ qua |
| `title_bar_height` | 0 | chiều cao của thanh tiêu đề ẩn, hoặc của dải kéo trên cửa sổ frameless; 0 là của hệ thống (32 trên Windows, 28 ở nơi khác) |
| `theme` | null | màu cố định cho giao diện native (`ui.Theme.light`, `ui.Theme.dark_theme`, hoặc một theme của app); null thì theo sáng hoặc tối của hệ thống |
| `material` | `.none` | thứ hiện xuyên qua nền ([Material](#materials)) |
| `state` | null | nhớ khung cửa sổ theo một key ([bên dưới](#remember-where-windows-were)) |
| `on_close` | null | được gọi khi cửa sổ đóng, trước khi được giải phóng |
| `on_close_request` | null | được hỏi có cho đóng không khi người dùng đóng cửa sổ |
| `on_event` | null | focus, di chuyển, đổi kích thước, thu nhỏ, phóng to |
| `on_drop` | null | file từ trình quản lý file thả lên cửa sổ |
| `content` | (bắt buộc) | `.{ .view = ... }` hoặc `.{ .page = ... }` |

Flyout cũng là một cửa sổ, tạo bằng `App.newFlyout` ([Flyout](#flyouts)).

<a id="draw-the-window-controls"></a>

## Tự vẽ nút điều khiển cửa sổ

```zig
const maximize = ui.div(c).size(46, 32).maximizeButton();
if (maximize.clicked()) s.window.zoom();
ui.text(c, "□", .{});
maximize.end();
```

Với `.title_bar = .hidden`, đặt `.hide_window_buttons = true` để tự vẽ các nút thu nhỏ, phóng to và đóng trong view.

- Khi đó `win.titleBar()` báo không chừa chỗ nào.
- Các chế độ thanh tiêu đề khác bỏ qua tùy chọn này. Bản build cho trình duyệt bỏ qua phần trang trí cửa sổ.
- Gọi `minimize()`, `zoom()` và `requestClose()` cho các thao tác còn lại. `requestClose()` tôn trọng callback hỏi đóng của app.

**Snap Layouts.** Trên Windows 11, rê chuột lên `maximizeButton()` hợp lệ và đang hiện đầu tiên sẽ mở Snap Layouts. Ở nơi khác, đánh dấu này không làm gì.

- Nút bị cắt hoàn toàn hoặc trong suốt, và nút bị xoay hoặc bị nghiêng, bị bỏ qua.
- Vùng nhận chuột của nó đi theo chuyển động và layout, và bị cắt theo vùng nhìn thấy. Nó bị xóa khi không còn nút hợp lệ nào.
- Việc tự đặt vị trí chỉ chạy khi thanh tiêu đề ẩn và `hide_window_buttons = true`. Nếu không, nó để yên các vùng Snap do app tự quản lý.
- `setSnapButton` cấp thấp hơn vẫn dùng được cho app tự quản lý vùng nhận chuột.

<a id="show-windows-without-flashing"></a>

## Hiện cửa sổ không bị nháy

Cửa sổ hiện trước khi nội dung sẵn sàng sẽ nháy trống. Tạo nó với `.visible = false` và hiện khi đã sẵn sàng:

```zig
const win = try app.newWindow(.{ .title = "Report", .visible = false, .content = content });
// ... nạp những gì nó hiển thị ...
win.show();
```

`--myzig-hidden` và các cờ headless khác giữ mọi cửa sổ ở trạng thái ẩn, bất kể app yêu cầu gì. Test và snapshot không bao giờ đưa gì lên màn hình.

<a id="size-position-and-state"></a>

## Kích thước, vị trí và trạng thái

| Method | Tác dụng |
|---|---|
| `show()`, `hide()`, `isVisible()` | hiện hoặc ẩn cửa sổ |
| `focus()`, `isFocused()` | đưa cửa sổ và app lên trước; cửa sổ có đang giữ bàn phím không |
| `close()` | đóng ngay, không hỏi `on_close_request` |
| `requestClose()` | đóng như người dùng đóng, có hỏi `on_close_request` |
| `setTitle(title)` | chữ trên thanh tiêu đề |
| `frame()` | `Window.Frame`: `x`, `y`, `width`, `height` tính bằng điểm màn hình, từ góc trên bên trái của màn hình chính |
| `contentSize()` | chiều rộng và chiều cao của nội dung dạng `[2]f64`, không tính thanh tiêu đề |
| `setSize(w, h)` | đổi kích thước nội dung, giữ nguyên góc trên bên trái |
| `setPosition(x, y)` | dời góc trên bên trái |
| `center()` | đặt cửa sổ giữa màn hình của nó |
| `setMinSize(w, h)` | kích thước nội dung nhỏ nhất |
| `setResizable(on)`, `setAlwaysOnTop(on)` | như các tùy chọn cùng tên |
| `minimize()`, `isMinimized()` | thu xuống Dock hoặc taskbar |
| `zoom()`, `isMaximized()` | phóng to, hoặc trả về kích thước cũ |
| `setFullScreen(on)`, `isFullScreen()` | toàn màn hình (một Space riêng trên macOS) |
| `setMaterial(m)` | material phía sau nội dung; false ở nơi không có |
| `redraw()` | vẽ lại giao diện native ở lần làm tươi kế tiếp, khi state đổi ngoài các event của nó |

Từ trang web, `myzig.window.close()`, `minimize()`, `toggleMaximize()` và `setTitle(title)` làm điều tương tự cho cửa sổ của chính trang đó.

<a id="remember-where-windows-were"></a>

## Nhớ vị trí cửa sổ

```zig
_ = try app.newWindow(.{
    .title = "Notes",
    .state = myzig.windowState("main"),
    .content = content,
});
```

Với một key `state`, cửa sổ mở ra ở chỗ cửa sổ cuối cùng có key đó từng nằm.

- Vị trí, kích thước và việc có đang phóng to hay không sẽ ghi đè `x`, `y`, `width` và `height`.
- Các trạng thái được lưu trong `window-state.txt` ở thư mục dữ liệu của app, mỗi key một dòng.
- File được đọc khi cửa sổ đầu tiên có key mở ra, và được ghi khi một cửa sổ như vậy đóng.
- Trạng thái không còn vừa thì bị bỏ qua: màn hình đã rút ra, kích thước dưới 50 điểm.
- Mỗi loại cửa sổ dùng một key riêng: `"main"`, `"preferences"`, `"note"`.
- App không nhớ cửa sổ nào thì không link phần lưu trữ này.

<a id="closing"></a>

## Đóng cửa sổ

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

- `on_close_request` (một `myzig.CloseRequest`) được hỏi khi người dùng đóng cửa sổ: nút đóng, Alt+F4, Close trên Dock hoặc taskbar, mục Close Window của macOS, `requestClose`. Trả về false thì cửa sổ vẫn mở.
- `close` không hỏi.
- `on_close` chạy khi cửa sổ đi, trước khi được giải phóng, dù nó đóng theo cách nào.
- [Tài liệu](documents.md) hỏi thay bạn, lưu hoặc bỏ thay đổi của từng tài liệu.

<a id="events"></a>

## Event

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

`myzig.WindowEvent` là một union gồm:

- `focus`, `blur`;
- `moved`: góc trên bên trái, tính bằng điểm màn hình;
- `resized`: kích thước nội dung;
- `minimized`, `maximized`, và `restored` (trở về từ một trong hai).

Event đến trên main thread, mỗi thay đổi một lần. Hệ điều hành hay lặp lại kích thước và lần kích hoạt không đổi gì; myzig bỏ chúng đi.

<a id="title-bars"></a>

## Thanh tiêu đề

`title_bar` là một trong:

- **`.default`**: thanh tiêu đề của hệ thống nằm trên nội dung.
- **`.hidden`**: nội dung lấp đầy cửa sổ, nằm dưới các nút điều khiển cửa sổ của hệ thống.
  - Các nút điều khiển: đèn giao thông của macOS, các nút caption của Windows 11 ở góc trên bên phải (có snap layout khi rê lên nút phóng to), header bar của GTK với các nút tiêu đề.
  - Khoảng trống trong phần `title_bar_height` trên cùng kéo được cửa sổ, như thanh tiêu đề. Bấm đúp ở đó thì phóng to.
  - Trên Windows, các nút caption sáng hay tối theo theme của giao diện native chứ không theo hệ thống. Đó là `theme` của cửa sổ, hoặc theme mà view áp dụng.
- **`.frameless`**: không có thanh tiêu đề và nút điều khiển. Nội dung tự vẽ tất cả và kéo cửa sổ từ các vùng kéo của nó. Cửa sổ vẫn đổi kích thước được từ các mép và vẫn có bóng đổ.

Trong giao diện native:

- Bấm trong dải kéo thì kéo cửa sổ, trừ khi bấm trúng một box tương tác được (nút, tab, field). Những box đó nhận cú bấm.
- View có thanh công cụ cao hơn thanh tiêu đề thì đặt `c.title_bar_height` bằng chiều cao thanh công cụ, và dải kéo đi theo.
- Để tránh đè lên các nút điều khiển của hệ thống, hỏi cửa sổ xem chúng chiếm bao nhiêu chỗ:

```zig
fn view(s: *State, c: *ui.Context) void {
    const area = s.window.titleBar(); // myzig.TitleBarArea
    const bar = ui.div(c).row().itemsCenter().wFull().h(@floatCast(@max(area.height, 40)))
        .pl(@floatCast(area.left + 8)).pr(@floatCast(area.right + 8));
    defer bar.end();
    ui.text(c, "Notes", .{ .weight = .semibold });
}
```

`myzig.TitleBarArea` có `height` mà các nút điều khiển chiếm, và bề rộng chúng che ở bên `left` (đèn giao thông của macOS) và bên `right` (các nút caption của Windows). Nó rỗng:

- với cửa sổ không ẩn thanh tiêu đề;
- khi toàn màn hình;
- trên Linux, nơi header bar của GTK nằm trên nội dung.

Cửa sổ frameless kéo từ thanh tiêu đề riêng của nó: gọi `startDrag()` khi có cú bấm trên đó. Trên Windows 11, cửa sổ frameless tự vẽ nút phóng to thì gọi `setSnapButton(rect)` với hình chữ nhật của nút trong nội dung. Rê chuột lên nút đó sẽ hiện snap layout; truyền null để gỡ.

Trang web đánh dấu vùng kéo bằng CSS:

- phần tử có style `--app-region: drag` kéo được cửa sổ, và bấm đúp thì phóng to;
- `--app-region: no-drag` loại trừ những gì bên trong một vùng kéo, như các nút.

```css
header { --app-region: drag; height: 38px; }
header button { --app-region: no-drag; }
```

<a id="materials"></a>

## Material

```zig
_ = try app.newWindow(.{ .material = .sidebar, .title_bar = .hidden, .content = content });
```

`myzig.Material` là thứ hiện xuyên qua nền cửa sổ, ở nơi hệ thống có material và nội dung để nền trong suốt:

| Material | macOS (vibrancy) | Windows 11 |
|---|---|---|
| `.none` | không có | không có |
| `.sidebar` | của sidebar | Mica |
| `.under_window` | dưới nội dung cửa sổ | Mica Alt (kiểu tab) |
| `.popover` | của popover hoặc HUD | Acrylic |

`setMaterial` đổi nó về sau. Nó trả về false ở nơi hệ thống không có material: Linux, Windows 10, trình duyệt.

<a id="flyouts"></a>

## Flyout

Flyout là một panel không viền, không có nút trên taskbar, đặt cạnh một hình chữ nhật: một box của cửa sổ cha, một điểm trên màn hình, hoặc một icon tray. App trên thanh menu, bộ chọn và danh sách gợi ý đều là flyout.

```zig
const panel = try app.newFlyout(.{
    .tray = tray,                // hoặc .parent = win với .anchor trong nội dung của nó
    .width = 320,
    .height = 420,
    .dismiss = .hide,
    .hidden = true,
    .content = .{ .view = .init(&state, State.panel) },
});
// Bấm icon tray thì bật/tắt nó:
fn trayClicked(s: *State, t: *myzig.Tray) void {
    _ = t;
    if (s.panel.isVisible()) s.panel.hide() else s.panel.show();
}
```

`myzig.FlyoutOptions`:

| Trường | Mặc định | Tác dụng |
|---|---|---|
| `parent` | null | cửa sổ chứa `anchor` trong nội dung; flyout luôn nằm trên nó |
| `tray` | null | neo flyout vào một icon tray (bên dưới) |
| `anchor` | rỗng | một `myzig.flyout.Rect` tính bằng điểm: trong nội dung cửa sổ cha, hoặc trên màn hình nếu không có cha |
| `placement` | `.bottom_start` | phía và cách căn: `bottom`, `top`, `right`, `left`, mỗi cái có `_start`, căn giữa, hoặc `_end` |
| `gap` | 0 | số điểm giữa anchor và flyout |
| `width`, `height` | 200, 200 | kích thước |
| `focusable` | true | nhận bàn phím khi hiện, và bị đóng khi cửa sổ khác lấy bàn phím; nếu false thì không bao giờ nhận bàn phím (tooltip, gợi ý) và ở lại cho tới khi bị đóng |
| `dismiss` | `.close` | flyout làm gì khi bị đóng: `.close` (như người dùng đóng nó) hoặc `.hide` (để hiện lại) |
| `hidden` | false | tạo ở trạng thái ẩn: `show` hiện nó, đặt lại vị trí |
| `popover` | false | trên macOS là popover của hệ thống (`NSPopover`); ở nơi khác là flyout thường (bên dưới) |
| `material` | `.none` | material mờ, trong suốt phía sau nội dung, như của cửa sổ ([Material](#materials)); popover có material riêng |
| `corner_radius` | 0 | bo góc trên macOS, tính bằng điểm (bên dưới) |
| `theme` | null | như của cửa sổ |
| `content` | (bắt buộc) | một view hoặc một trang web |

- **`tray`**: nằm dưới icon trên thanh menu của macOS, nằm trên icon của taskbar đặt ở dưới. Nơi hệ thống không cho biết icon nằm đâu (Linux), flyout được đặt giữa vùng làm việc.
- **`popover`**: material của popover, góc bo tròn và một mũi tên chỉ vào giữa anchor. Nó hiện ở phía của `placement` hoặc phía đối diện; phần còn lại của placement và `gap` không áp dụng. Cần có `parent` hoặc `tray`.
- **`corner_radius`**: material và nội dung bị cắt theo góc bo, bóng đổ cũng theo góc bo. Windows 11 bo góc flyout như bo menu của nó; Linux thì không.

**Đóng flyout.** Flyout focusable bị đóng khi bấm Escape, và khi cửa sổ khác lấy bàn phím: bấm ra chỗ khác, app bị chuyển ra sau. Cú bấm lên chính icon tray của nó được để cho cú click của icon, vốn bật/tắt flyout. Nhờ vậy flyout không bị đóng rồi lại bị chính cú click đó mở lại (macOS, Windows).

**Đặt vị trí.** Flyout được đặt như menu. Trên mỗi trục:

1. nó lật sang phía bên kia của anchor, hoặc đầu bên kia, nếu không vừa mà khi lật thì vừa;
2. rồi nó trượt vào lại trong vùng làm việc;
3. rồi nó co lại cho vừa vùng đó.

**Popover.**

- Nội dung của flyout popover không vẽ nền đè lên material.
- Với `focusable`, nó đóng khi người dùng bấm ra chỗ khác, có hỏi `on_close_request`.
- Mở từ icon tray thì nó kích hoạt app và làm nổi icon khi đang hiện.
- Khi đang hiện, cửa sổ của nó là cửa sổ của popover.

**Di chuyển flyout.**

- `placeFlyout()` đặt lại vị trí khi anchor di chuyển (cửa sổ cha đã di chuyển, hoặc icon tray).
- `setAnchor(rect)` đổi anchor khác.
- `setSize` đổi kích thước tại chỗ.
- `isFlyout()` phân biệt flyout với cửa sổ khác.

<a id="attention-and-progress"></a>

## Gây chú ý và tiến độ

- `flash(true)` gây chú ý cho tới khi cửa sổ có focus. `flash(false)` dừng lại.
  - macOS làm icon trên Dock nảy lên.
  - Windows nháy nút trên taskbar.
  - Linux đánh dấu cửa sổ là khẩn.
- `setProgress(.{ .state = .normal, .value = 0.4 })` hiện tiến độ một tác vụ, một `myzig.Progress`.
  - `state` là `.none`, `.normal`, `.indeterminate`, `.paused` hoặc `.failed`; `value` từ 0 tới 1.
  - Nó hiện trên nút taskbar (Windows) hoặc mục trên launcher (các dock của Linux có API Unity).
  - Nó trả về false ở nơi không có gì để hiện: macOS, nơi `app.setBadge` là badge của Dock.

<a id="documents"></a>

## Tài liệu

- `setDocumentEdited(true)` đánh dấu tài liệu của cửa sổ có thay đổi chưa lưu: một chấm trong nút đóng của macOS, `*` trước tiêu đề trên Windows và Linux. `isDocumentEdited()` đọc lại giá trị này.
- `setRepresentedFile(path)` cho biết cửa sổ đang hiện file nào. Trên macOS, icon của file hiện trên thanh tiêu đề: người dùng kéo được nó, và ⌘-click để xem các thư mục chứa nó. Ở nơi khác không làm gì.

[Tài liệu](documents.md) làm cả hai việc này cho cửa sổ tài liệu.

<a id="files-dropped-on-a-window"></a>

## File thả lên cửa sổ

```zig
fn dropped(s: *State, win: *myzig.Window, paths: []const []const u8) void {
    _ = win;
    for (paths) |p| s.open(p);
}

_ = try app.newWindow(.{ .on_drop = .of(&state, State.dropped), .content = content });
```

`on_drop` nhận đường dẫn của các file thả từ Finder, Explorer hoặc trình quản lý file. Kéo bên trong giao diện native, và kéo ra app khác, nằm ở [Truyền dữ liệu](data-transfer.md) và [Kéo và thả](ui/drag-and-drop.md).

<a id="pages-in-windows"></a>

## Trang web trong cửa sổ

Cửa sổ hiện trang web còn chạy được script trong trang và nạp URL khác:

- `loadUrl(url)` nạp một URL khác.
- `eval(js)` chạy một script, không chờ kết quả.
- `evalResult(js, cb)` tính một biểu thức và chuyển giá trị dạng JSON, hoặc lỗi, cho một `myzig.EvalCallback`.
- `sendOwned(msg)` xếp một message đã mã hóa vào hàng đợi gửi cho trang, từ bất kỳ thread nào; event có kiểu làm việc này cho bạn.

Bản thân trang là `win.page` (null với giao diện native), với tìm kiếm, in, cookie và những thứ khác: xem [Trang web](pages.md).

<a id="platforms"></a>

## Nền tảng

| | macOS | Linux | Windows | trình duyệt |
|---|---|---|---|---|
| cửa sổ | NSWindow | GtkWindow | Win32 | canvas của trang, một cửa sổ |
| giao diện native vẽ bằng | Metal | OpenGL, hoặc CPU | Direct3D 11, hoặc CPU | WebGL 2 |
| trang web | WKWebView | WebKitGTK | WebView2 | không |
| thanh tiêu đề ẩn | đèn giao thông đè lên nội dung | header bar của GTK | nút caption đè lên nội dung, snap layout | không |
| material | vibrancy | không | Mica, Mica Alt, Acrylic (Windows 11) | không |
| flyout | có | có (flyout từ tray đặt giữa) | có | không |
| tiến độ | không (dùng badge của Dock) | launcher Unity | taskbar | không |
| file đại diện | có | không | không | không |

Trong trình duyệt, cửa sổ giao diện native đầu tiên lấp đầy trang. Kích thước, vị trí và trạng thái cửa sổ không có tác dụng ở đó ([Trình duyệt](browsers.md)).
