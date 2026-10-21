<a id="inspector"></a>

# Thanh tra

Trình kiểm tra là bảng điều khiển của nhà phát triển được gắn ở bên phải cửa sổ giao diện native, khi các công cụ dành cho nhà phát triển của trình duyệt hiển thị một trang: cây hộp mà view được tạo, hình chữ nhật, phần đệm, kiểu và nội dung của hộp được chọn hoặc bên dưới con trỏ, được viền trên nội dung và thời lượng của các frame cuối cùng (`src/ui/inspector.zig`, sau mygo).

Một ứng dụng chọn tham gia: nó giữ trạng thái của thanh tra và xây dựng nó lần cuối trong view của nó, trên các hộp được tạo trước đó.

```zig
const App = struct {
    count: i64 = 0,
    inspector: ui.Inspector = .{},

    fn view(s: *App, c: *ui.Context) void {
        {
            const col = ui.div(c).column().sizeFull().center().gap(12);
            defer col.end();
            ui.textf(c, .{ .size = 40, .weight = .bold }, "{d}", .{s.count});
            if (ui.button(c, "Increment", .{ .variant = .primary }).clicked) s.count += 1;
        }
        ui.inspector(c, &s.inspector); // last
    }
};
```

<a id="opening-it"></a>

## Mở nó

| Phím | Họ làm gì |
|---|---|
| F12 hoặc Alt+Cmd+I trên macOS và Ctrl+Shift+I ở nơi khác | mở và đóng bảng điều khiển |
| Shift+Cmd+C (Ctrl+Shift+C) | mở nó ra để chọn một hộp hoặc ngừng chọn |
| Thoát hiểm | dừng chọn |

Bảng điều khiển lấy 340 điểm ở bên phải cửa sổ: nội dung được cung cấp phần còn lại, dưới dạng phần đệm trên hộp gốc của cửa sổ. Từ phải sang trái, bảng điều khiển gắn ở bên trái, nơi nội dung được phản chiếu để lại khoảng trống. Bản thân bảng điều khiển luôn đọc từ trái sang phải.

<a id="what-it-shows"></a>

## Những gì nó cho thấy

- **Thanh công cụ**: **Chọn** chọn hộp bên dưới con trỏ (nắp bên trên nội dung sẽ lấy con trỏ, do đó thao tác nhấp chuột sẽ chuyển đến trình kiểm tra chứ không phải đến hộp); **RTL** đặt cửa sổ ra [phải sang trái](right-to-left.md) hoặc quay lại để thử giao diện trước khi dịch; **Đóng**.
- **Hiệu suất**: thời gian xây dựng, bố cục và vẽ của frame cuối cùng tính bằng mili giây, các hộp của frame đó, phiên bản của bộ kết xuất và số lần view được tạo (chuyển) và một thanh cho mỗi frame trong số 60 frame cuối cùng so với tốc độ làm mới ở 60 Hz (16,7 mili giây), màu đỏ khi chậm hơn. Đây là `FrameStats` (`c.stats`) của ngữ cảnh. xem [Hiệu suất](performance.md).
- **Cây**: mỗi hộp của khung, được thụt vào theo chiều sâu, được đặt tên theo tên của nó: `Text "…"`, `Icon name`, `Image`, hoặc `Row`, `Column`, `Scroll` và `Pressable` cùng với số lượng con của chúng. Đó là một [danh sách] ảo(lists.md), do đó, một khung gồm hàng nghìn hộp vẫn hoạt động nhanh. Di chuột một hàng sẽ phác thảo hộp của nó; nhấp vào chọn nó.
- **Các chi tiết** của hộp được di chuột, phần còn lại được chọn: hình chữ nhật, phần đệm, hướng (hướng bố cục riêng và hướng đọc của nó), khoảng cách, chiều rộng và chiều cao, tăng trưởng, căn chỉnh, nền, đường viền, bán kính, độ mờ và độ lệch, các cờ của nó (`scroll`, `absolute`, `clip`, `follow_end`, `selectable`, `control`, tương tác, tập trung), nó là gì giữ (văn bản với phông chữ và màu sắc, biểu tượng, hình ảnh của nó) và id của nó.

Hộp được di chuột hoặc được chọn sẽ được viền trên nội dung giống như trình duyệt thực hiện: phần đệm màu xanh lá cây, hộp nội dung màu xanh lam và kích thước bên cạnh.

<a id="in-builds"></a>

## Trong bản dựng

Trình kiểm tra chỉ là một phần của bản dựng gỡ lỗi. Trong các bản phát hành, `ui.Inspector` là một cấu trúc trống và `ui.inspector` không làm gì cả, vì vậy các lệnh gọi vẫn nằm trong mã và không tốn phí phát hành. Tùy chọn xây dựng của myzig `inspector` ghi đè theo cách đó:

```sh
zig build -Doptimize=ReleaseFast -Dinspector=true   # in myzig's own examples
```

và trong `build.zig` của ứng dụng, thông qua phần phụ thuộc:

```zig
const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize, .inspector = true }).module("myzig");
```

Mã giữ trạng thái và lệnh gọi `ui.inspector` biên dịch giống nhau trong mọi bản dựng: không cần phải bảo vệ gì.

<a id="pages"></a>

## Trang web

Windows trong số các trang web có trình kiểm tra riêng của webview thay thế: Trình kiểm tra web của Safari trên macOS, WebKitGTK trên Linux và các công cụ dành cho nhà phát triển của Edge trên Windows. `PageOptions.inspectable` (bật theo mặc định) cho phép điều đó và `openDevTools` của trang sẽ mở nó (xem [Trang](../pages.md)).

`src/ui/tests_inspector.zig` kiểm tra việc mở, chọn, chọn và chuyển đổi từ phải sang trái thông qua [Tester](testing.md).
