<a id="web-views-in-native-ui"></a>

# Web view trong native UI

`ui.webView` hiện một trang web trong một box của cửa sổ native UI: khung trợ giúp, bản xem trước, hoặc một trang của frontend web nằm cạnh các control native. Nó đặt web view của hệ thống (WebView2, WebKitGTK, WKWebView) vào một box của layout, ở mỗi frame:

```zig
const State = struct {
    docs: ui.WebView = .{},

    fn view(s: *State, c: *ui.Context) void {
        ui.row(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        sidebar(c);
        _ = ui.webView(c, &s.docs, .{
            .page = .{ .url = "/notes.html", .assets = &assets },
            .grow = 1,
            .radius = 12,
            .key = "notes",
        });
    }
};
```

App giữ một `ui.WebView`:

- Trang được tạo ở frame đầu tiên hiện nó. Nó sống tới khi gọi `destroy()` hoặc cửa sổ của nó đóng.
- `page` là trang của nền tảng, có các method như của cửa sổ (`load`, `eval`, `evalResult`, `goBack`, `setZoom`, …).
- `shown` cho biết frame trước hiện nó ở đâu, null khi đang ẩn.

| `ui.WebViewOptions` | |
|---|---|
| `page` | tùy chọn của trang, như `PageOptions` của cửa sổ (đọc lúc tạo trang) |
| `width`, `height` | kích thước box, mặc định `.fill` |
| `grow`, `min_width`, `min_height` | như mọi box |
| `padding`, `background`, `border`, `border_width`, `radius` | quanh trang, trong box |
| `key` | key của box, để trang đi theo nó khi view đổi thứ tự |

<a id="what-it-does"></a>

## Nó làm gì

**Vị trí**

- Sau mỗi frame, trang được đặt vào content box của box, khớp với pixel của thiết bị và bị cắt bởi các box scroll và clip bao quanh.
- Nó ẩn đi khi không còn phần nào hiện ra, khi box của nó mờ hẳn, hoặc khi view thôi dựng nó. Khi ẩn nó vẫn giữ trang.
- Một cửa sổ có thể hiện nhiều web view.

**Cùng một trang như của cửa sổ**

- Bridge, các service được bind, event, channel, scheme, trust và `eval` hoạt động như trong cửa sổ trang.
- `Event.emit(window)` và `broadcast` cũng tới được web view.
- `myzig.window.close()` gọi từ trang nhúng thì cửa sổ vẫn mở.
- Phần tử có style `--app-region: drag` kéo được cửa sổ, như trong cửa sổ trang.

**Bàn phím**

- Tab dừng ở web view rồi đi vào trang; Shift+Tab đi vào từ cuối trang.
- Trên Windows, Tab qua khỏi hai đầu trang thì quay về native UI.
- Bấm vào trang thì native UI mất focus. Bấm vào native UI thì nó lấy lại bàn phím.

**Native UI phía trên.** Popover, menu, dialog cùng nền mờ của chúng, toast, tooltip và các box vẽ sau web view hiện phía trên trang, trong một *cover*:

- Renderer CPU vẽ nó với độ trong suốt, chỉ ở chỗ có thứ chồng lên và chỉ khi có thay đổi.
- Chỗ nào nó không trong suốt thì nó nhận con trỏ và chuyển cho native UI. Mọi chỗ khác thì trang nhận con trỏ.
- Trên Windows nó là cửa sổ con layered, trên Linux là một widget phía trên trang trong GtkOverlay của cửa sổ, trên macOS là một NSView.

<a id="testing-it"></a>

## Test

| | |
|---|---|
| `v.probe()` | đọc lại vị trí thật của view native và vị trí nó nên ở |
| `v.probeCover()`, `v.coverMatchesFrame()`, `v.clickCover(x, y)` | như trên, cho cover |

`examples/embed-webview` tự kiểm tra với `--check`. `zig build test-pages` chạy nó ở chế độ ẩn trên Windows.

<a id="platforms"></a>

## Nền tảng

| | cách làm |
|---|---|
| Windows | một WebView2 controller dạng windowed trong cửa sổ con "clip" đặt ở phần nhìn thấy; cover là các cửa sổ con layered (`UpdateLayeredWindow`) |
| Linux | drawing area chuyển vào một GtkOverlay khi có web view đầu tiên; mỗi trang là một phần tử con GtkLayout, đặt vị trí qua `get-child-position`; cover là các drawing area có input shape |
| macOS | một NSView clip (cắt theo bounds của nó) phía trên view của surface, chứa WKWebView; cover là các NSView lật trục, có `hitTest:` cho con trỏ đi xuyên qua chỗ trong suốt |
| trình duyệt | không có |

Chưa làm:

- transform cho box của web view: nó được đặt theo bounds;
- opacity khác 0 hoặc 1;
- trang trong cây accessibility của native UI.
