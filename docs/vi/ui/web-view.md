<a id="web-views-in-native-ui"></a>

# Lượt xem trang web trong giao diện native

Một cửa sổ giao diện native có thể hiển thị các trang web trong các hộp riêng: ngăn trợ giúp, bản xem trước, một trang frontend web của ứng dụng bên cạnh các điều khiển gốc của ứng dụng đó. `ui.webView` đặt webview của hệ thống (WebView2, WebKitGTK, WKWebView) vào hộp bố cục, mọi frame:

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

`ui.WebView` là nội dung ứng dụng giữ lại: trang được tạo khung đầu tiên hiển thị trang đó và tồn tại cho đến khi `destroy()` hoặc cửa sổ của trang đó đóng lại. `page` của nó là trang của nền tảng, với các phương thức tương tự như của cửa sổ (`load`, `eval`, `evalResult`, `goBack`, `setZoom`, …) và `shown` cho biết khung cuối cùng hiển thị nó ở đâu (null khi bị ẩn).

`ui.WebViewOptions`:

| lĩnh vực | |
|---|---|
| `page` | các tùy chọn của trang, dưới dạng `PageOptions` của cửa sổ (đọc khi trang được tạo) |
| `width`, `height` | kích thước của hộp, `.fill` theo mặc định |
| `grow`, `min_width`, `min_height` | như bất kỳ hộp nào |
| `padding`, `background`, `border`, `border_width`, `radius` | xung quanh trang, trong hộp |
| `key` | khóa của hộp, để trang theo sau nó khi view được sắp xếp lại |

<a id="what-it-does"></a>

## Nó làm gì

- **Vị trí.** Sau mỗi khung, trang được đặt vào hộp nội dung của hộp, gắn vào các pixel của thiết bị và được cắt bằng các hộp cuộn và hộp kẹp xung quanh nó. Nó ẩn khi không có cái nào hiển thị, khi hộp của nó mờ dần thành không có gì hoặc khi view ngừng xây dựng nó; nó giữ trang của nó trong khi ẩn. Một cửa sổ có thể hiển thị một số.
- **Cùng một trang với cửa sổ.** Cầu nối, dịch vụ liên kết, sự kiện (`Event.emit(window)` và `broadcast` cũng tiếp cận lượt xem web), kênh, lược đồ, độ tin cậy và `eval` hoạt động như trong một cửa sổ trang. `myzig.window.close()` từ một trang được nhúng sẽ để cửa sổ mở.
- **Bàn phím.** Tab dừng ở view web và di chuyển vào trang (Shift+Tab từ cuối); trên Windows, Tab qua phần cuối của trang sẽ quay lại giao diện native. Việc nhấp vào trang sẽ khiến giao diện native mất tập trung; nhấp vào giao diện native sẽ đưa bàn phím trở lại.
- **Giao diện native trên đó.** Những gì giao diện native vẽ trên view web — cửa sổ bật lên, menu, hộp thoại và phông nền, lời chúc mừng, chú giải công cụ và các hộp được vẽ sau nó — hiển thị phía trên trang, trong *bìa*: một cửa sổ con xếp lớp trên Windows, một widget phía trên nó trong GtkOverlay của cửa sổ trên Linux, một NSView trên macOS, được vẽ bởi bộ kết xuất CPU với độ trong suốt, chỉ khi có thứ gì đó chồng lên nhau và chỉ khi nó thay đổi. Bìa lấy con trỏ ở nơi nó mờ và gửi nó đến giao diện native; trang này có được nó ở mọi nơi khác.
- **Kéo vùng.** Các phần tử được tạo kiểu `--app-region: drag` trong trang sẽ di chuyển cửa sổ, như trong cửa sổ trang.

<a id="testing-it"></a>

## Đang thử nghiệm nó

`v.probe()` đọc lại vị trí thực sự của view native và vị trí của nó; `v.probeCover()`, `v.coverMatchesFrame()` và `v.clickCover(x, y)` thực hiện tương tự cho bìa. `examples/embed-webview` chạy kiểm tra riêng với `--check` (`zig build test-pages` chạy kiểm tra ẩn trên Windows).

<a id="platforms"></a>

## Nền tảng

| | làm thế nào |
|---|---|
| Windows | bộ điều khiển WebView2 có cửa sổ trong cửa sổ "clip" con ở phần hiển thị; bìa là các cửa sổ con nhiều lớp (`UpdateLayeredWindow`) |
| Linux | vùng vẽ di chuyển vào GtkOverlay ở view web đầu tiên; mỗi trang là một trang con GtkLayout được đặt thông qua `get-child-position`; bìa là các vùng vẽ có hình dạng đầu vào |
| macOS | một clip NSView (che đi các giới hạn của nó) trên view của bề mặt, với WKWebView trong đó; bìa được lật ngược NSView có `hitTest:` rơi qua nơi trong suốt |
| trình duyệt | không có sẵn |

Chưa hoàn tất: chuyển đổi hộp của view web (nó được đặt ở giới hạn của nó), độ mờ không phải là không có hoặc đầy đủ và trang trong cây khả năng truy cập của giao diện native.
