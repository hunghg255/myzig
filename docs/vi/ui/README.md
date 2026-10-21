<a id="native-ui"></a>

# Giao diện native

Một cửa sổ có thể hiển thị frontend mà myzig tự vẽ thay vì một trang web. Bạn viết nó trong Zig chỉ với `myzig.ui`: không có HTML, không có JavaScript và không có bản dựng frontend, đồng thời cửa sổ không bắt đầu webview, vì vậy, nó mở ngay lập tức và sử dụng ít bộ nhớ. myzig vẽ nó trên GPU nếu có thể, với Metal trên macOS, Direct3D 11 trên Windows, OpenGL trên Linux và WebGL 2 trong trình duyệt và với bộ kết xuất CPU riêng (cùng pixel) ở mọi nơi khác; xem [kết xuất](rendering.md).

```zig
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

/// The app's state.
const Counter = struct {
    n: i64 = 0,

    /// Builds the window's interface from the state, for every frame.
    fn view(s: *Counter, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 12 });
        defer ui.end(c);
        ui.textf(c, .{ .size = 40, .weight = .bold }, "{d}", .{s.n});
        if (ui.button(c, "Increment", .{ .variant = .primary }).clicked) s.n += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Counter" });
    defer app.destroy();
    var state: Counter = .{};
    _ = try app.newWindow(.{
        .title = "Counter",
        .width = 420,
        .height = 300,
        .content = .{ .view = .init(&state, Counter.view) },
    });
    try app.run();
}
```

View là chế độ ngay lập tức: một chức năng trong trạng thái của bạn myzig chạy trên luồng chính bất cứ khi nào có điều gì đó xảy ra (đầu vào, thay đổi kích thước, bước hoạt ảnh). Widget là các lệnh gọi hàm trả lời cùng một lúc: `ui.button` trả về xem nó có được nhấp vào hay không, `ui.toggle` lật `bool` mà bạn cung cấp. Không có đối tượng widget nào để giữ lại, không có lệnh gọi lại để đăng ký và không có ràng buộc nào để cập nhật: bạn thay đổi trạng thái của mình và khung tiếp theo sẽ hiển thị điều đó. Khi một tương tác thay đổi trạng thái, myzig sẽ xây dựng lại khung trước khi vẽ, để màn hình không bao giờ bị trễ so với trạng thái.

Không có polling nào. Một khung được vẽ khi nhập, khi thay đổi kích thước, trong khi hoạt ảnh chạy hoặc khi ứng dụng yêu cầu (`Window.redraw`, `c.frameIn`); một cửa sổ nhàn rỗi không sử dụng CPU.

<a id="what-a-frame-keeps-of-what-you-pass"></a>

## Khung hình giữ lại những gì bạn vượt qua

Một khung được xây dựng, sau đó bố trí, rồi vẽ: bố cục và vẽ chạy sau khi view đã quay trở lại. Văn bản được sao chép vào bộ nhớ của khung khi chúng được hiển thị (`ui.text`, `ui.richText` và các khoảng, nhãn, chú giải công cụ, trường của nó, những gì `c.describe` cho biết công nghệ hỗ trợ), do đó, một view có thể giải phóng hoặc thay đổi một chuỗi ngay sau khi hiển thị nó. Các slice và con trỏ khác mà widget lấy (byte của ảnh, tên biểu tượng, độ dốc, điểm của khung vẽ) được đọc ở vị trí của chúng cho đến khi khung được vẽ: truyền hằng số, bộ nhớ riêng của ứng dụng hoặc định dạng của khung (`c.print("{d} left", .{n})` vào một arena được giải phóng khi khung tiếp theo bắt đầu, `c.alloc()` cung cấp arena đó cho bất kỳ thứ gì khác), không bao giờ là bộ đệm trên ngăn xếp của chức năng xem. Để giải phóng dữ liệu như vậy mà view hiển thị, hãy giải phóng dữ liệu đó sau khung (sự kiện tiếp theo hoặc khung sau) hoặc giữ bản sao cũ để cập nhật thêm một lần nữa.

<a id="two-ways-to-write-boxes"></a>

## Hai cách để viết hộp

Các hàm đơn giản có cấu trúc `ui.Style`, theo cách của CSS flexbox:

```zig
ui.row(c, .{ .gap = 8, .padding = .all(12), .background = c.theme.surface, .radius = 8 });
defer ui.end(c);
```

`ui.div` tạo kiểu cho cùng một hộp bằng một chuỗi các phương thức nhỏ, như GPUI thực hiện:

```zig
const card = ui.div(c).row().p(12).gap(8).bg(c.theme.surface).rounded(8).hover(c.theme.surface_hover);
defer card.end();
if (card.clicked()) s.open = !s.open;
```

Cả hai đều làm những chiếc hộp giống nhau; trộn chúng một cách tự do. Xem [bố cục](layout.md) và [kiểu dáng](styling.md).

<a id="run-it-without-a-window"></a>

## Chạy nó mà không có cửa sổ

Mọi view đều có thể được điều khiển trong kiểm thử với `ui.Tester`, xây dựng và vẽ khung ngoài màn hình, nhấp chuột, nhập và chụp ảnh màn hình, trên đồng hồ mà bạn tự nâng cao:

```zig
var t: ui.Tester = undefined;
try t.init(std.testing.allocator, .init(&state, Counter.view), .{});
defer t.deinit();
try t.clickText("Increment");
try std.testing.expect(t.hasText("1"));
```

Xem [thử nghiệm](testing.md).

<a id="the-guides"></a>

## Các hướng dẫn viên

Nền tảng:

- [Lượt xem](views.md): chức năng xem, `ui.View`, ngữ cảnh, id và khóa, trạng thái thay đổi từ bên ngoài, khung theo yêu cầu.
- [Bố cục](layout.md): hàng, cột, kích thước, tăng trưởng, căn chỉnh, đệm, cuộn, hộp tuyệt đối, cắt bớt.
- [Tạo kiểu](styling.md): màu sắc, đường viền, bóng, chủ đề, sáng và tối, chủ đề được đặt tên, điểm nhấn, tùy chọn của màn hình, Oklch.
- [Văn bản](text.md): kiểu văn bản, ngắt dòng, khoảng phong phú, tiêu đề và nhãn, phông chữ, văn bản có thể chọn, thu phóng.

Widget:

- [Nút và những thứ nhỏ nhặt](buttons.md): nút, liên kết, huy hiệu, mũ phím, biểu tượng, hình ảnh, hình đại diện, nút lịch sử.
- [Lựa chọn](choices.md): hộp kiểm, nhóm hộp kiểm, công tắc, nút radio, nhóm radio, điều khiển phân đoạn, xếp hạng.
- [Phạm vi](ranges.md): thanh trượt, thanh trượt phạm vi, bước, đầu vào số, mét, thanh tiến trình, vòng quay.
- [Nhập văn bản](text-input.md): trường văn bản, trường tìm kiếm, trường mã thông báo, hộp tổ hợp, tự động hoàn thành, phương thức nhập và thao tác văn bản.
- [Ngày và màu](dates-and-colors.md): lịch, đầu vào ngày và giờ, bộ chọn màu và giếng.
- [Biểu mẫu](forms.md): trường được gắn nhãn, biểu mẫu, tập hợp trường, xác thực.
- [Lớp phủ](overlays.md): cửa sổ bật lên, chú giải công cụ, hộp thoại, hộp thoại cảnh báo, chúc mừng.
- [Menus](menus.md): menu, menu ngữ cảnh, nút menu, lựa chọn.
- [Cấu trúc](structures.md): tab, thành phần thu gọn, accordion, phần tách, thanh bên, thanh công cụ, đường dẫn.
- [Danh sách, cây và bảng](lists.md): danh sách ảo, cây, đường viền, bảng, view lưới.
- [Bố cục lưới](grid.md): lưới kiểu CSS gồm các rãnh và ô.
- [Điều hướng](navigation.md): bộ định tuyến, hành động và lối tắt, nhóm tiêu điểm.
- [Kéo và thả](drag-and-drop.md): kéo trong và ngoài cửa sổ.
- [Tiện ích tùy chỉnh](custom-widgets.md): hộp, tương tác, giá trị hoạt ảnh, tay cầm: cách tạo ra các widget riêng của myzig.

Vẽ và nội dung phong phú:

- [Chuyển động](motion.md): giá trị hoạt ảnh, lò xo, khung hình chính, dòng thời gian, chuyển tiếp, ít chuyển động hơn.
- [Biến đổi và hiệu ứng](transforms.md): di chuyển, chia tỷ lệ và xoay hộp, chuyển màu, làm mờ, hiệu ứng phông nền.
- [Bản vẽ](drawing.md): khung vẽ đường dẫn, phần tô màu và nét vẽ, SVG.
- [Biểu đồ](chart.md): đường, thanh, vùng, v.v, phát trực tuyến.
- [Markdown](markdown.md): Các tiện ích mở rộng của CommonMark và GitHub, được phát trực tuyến khi nó xuất hiện.
- [Vùng văn bản](text-area.md): văn bản nhiều dòng, sợi dây, tài liệu.
- [Trình chỉnh sửa mã và trình xem khác biệt](code-editor.md): tô sáng cú pháp, máng xối, khác biệt.
- [Văn bản có định dạng](rich-text.md): trình soạn thảo văn bản có định dạng và thanh công cụ của nó.
- [Shaders](shaders.md): các shader được viết một lần, được vẽ bởi mọi bộ kết xuất.
- [View web](web-view.md): các trang web trong hộp giao diện native, với giao diện native được vẽ phía trên chúng.

Chất lượng:

- [Khả năng truy cập](accessibility.md): công nghệ hỗ trợ đọc gì, vai trò và mô tả trên mỗi nền tảng.
- [Phải sang trái](right-to-left.md): bố cục phản chiếu.
- [Inspector](inspector.md): cây hộp của cửa sổ đang chạy (F12).
- [Đang kiểm tra](testing.md): `ui.Tester` và cờ `--myzig-*` của ứng dụng.
- [Đang kết xuất](rendering.md): bộ kết xuất và CPU song sinh của chúng.
- [Hiệu suất](performance.md): giá khung và cách giữ giá khung ở mức rẻ.

Giao diện native cũng chạy trong trình duyệt, được xây dựng cho `wasm32-wasi`; xem [trình duyệt](../browsers.md).
