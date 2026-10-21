<a id="right-to-left"></a>

# Phải sang trái

Tiếng Ả Rập, tiếng Do Thái, tiếng Ba Tư và tiếng Urdu đọc từ phải sang trái và giao diện của ứng dụng bằng các ngôn ngữ đó cũng vậy: một hàng bắt đầu ở bên phải, thanh bên ở bên phải, mũi tên quay lại chỉ sang phải. Giao diện native đặt một cửa sổ ra ngoài để khi được yêu cầu, như `TextDirection` của Flutter, `LayoutDirection` của SwiftUI và CSS của `direction` sẽ làm (`src/ui/direction.zig`, sau mygo).

Như trong Godot, tọa độ không được phản chiếu: x vẫn phát triển về bên phải trong hình chữ nhật, trong khung vẽ và ở vị trí con trỏ. Chỉ có cách bố trí là.

<a id="the-direction"></a>

## Hướng

`ui.Direction` là `.ltr` hoặc `.rtl`. Một cửa sổ được chuyển từ trái sang phải cho đến khi view có nội dung khác, với `ui.direction.set` hoặc, từ ngôn ngữ của ứng dụng, `ui.direction.fromLocale`, chuyển từ phải sang trái cho tiếng Ả Rập, tiếng Do Thái, tiếng Ba Tư và tiếng Urdu (nó đọc `i18n.direction` của thẻ):

```zig
fn view(s: *App, c: *ui.Context) void {
    ui.direction.fromLocale(c, myzig.i18n.locale());
    // ...
}
```

Hướng được giữ bởi cửa sổ: đặt lại nó, mỗi khung sẽ tốn một lần tra cứu và việc thay đổi nó sẽ tạo lại khung, để các widget được tạo trước khi thay đổi sẽ đọc khung mới.

Mỗi hộp đều có hướng của hộp chứa nó, trừ khi nó được cấp một hộp riêng với `ui.direction.scope`, ngay sau khi nó được mở và trước các hộp con của nó. Số điện thoại, mẫu mã hoặc điều khiển của trình phát đa phương tiện nằm từ trái sang phải trong cửa sổ từ phải sang trái:

```zig
const player = c.open(.{ .direction = .row, .gap = 8 }, "player");
ui.direction.scope(c, player, .ltr);
_ = ui.button(c, "", .{ .icon = "backward.fill" });
_ = ui.button(c, "", .{ .icon = "play.fill" });
_ = ui.button(c, "", .{ .icon = "forward.fill" });
c.end();
```

Các widget của riêng bạn vẽ những điểm dọc theo một đường đọc hướng của nội dung được xây dựng hiện tại:

```zig
const forward = if (ui.direction.current(c) == .rtl) "chevron.left" else "chevron.right";
ui.icon(c, forward, .{});
```

`ui.direction.isRtl(c)` cũng nói như vậy; `ui.direction.arrows(c)` cung cấp các phím di chuyển qua lại dọc theo một dòng (`.back` và `.forth`: Trái và Phải, đổi chỗ từ phải sang trái) và `ui.direction.alongLine(c, t)` biến một phần từ đầu dòng thành một phần từ bên trái, dưới dạng giá trị của thanh trượt bên dưới con trỏ.

<a id="what-mirrors"></a>

## Những tấm gương nào

Từ phải sang trái, khi bố cục đã đặt cây từ trái sang phải, `ui.direction.mirror` (`layout.arrange` chạy) sẽ di chuyển từng hộp của hộp từ phải sang trái sang phía bên kia của cây, với mọi thứ bên trong:

- Một hàng xếp con của nó ra từ bên phải; `align_items` và `justify` bắt đầu ở bên phải.
- Phần đệm được cung cấp ở bên trái sẽ chuyển sang bên phải và độ lệch hộp tuyệt đối từ bên trái sẽ được bù từ bên phải.
- [Lưới](grid.md) đặt các cột của chúng từ bên phải.
- [Nhóm tập trung](navigation.md) di chuyển đến mục tiếp theo của họ bằng Bên trái.
- Các trang của [router](navigation.md) được đẩy vào từ bên trái.

Lớp phủ giữ vị trí mà widget của chúng cung cấp cho chúng, theo tọa độ cửa sổ và đặt phần bên trong của chúng theo hướng của cửa sổ.

<a id="what-does-not"></a>

## Cái gì không

- Văn bản, biểu tượng, hình ảnh và nội dung vẽ trên [canvas](drawing.md) không được phản chiếu: dấu kiểm, kính lúp và biểu đồ được đọc từ trái sang phải. Vẽ những gì phải chỉ ra hướng khác sau khi đọc `ui.direction.current`.
- Các phần điền và nút điều khiển tự vẽ dọc theo một đường (thanh trượt, thanh tiến trình, công tắc) tuân theo bố cục phản chiếu của các hộp, nhưng các điều khiển chưa đọc hướng cho các phím mũi tên và bên điền của chúng, như mygo đã làm. Mã cần đọc là `alongLine` và `arrows`.
- [inspector](inspector.md) đọc từ trái sang phải.

<a id="trying-it"></a>

## Đang thử nó

Nút **RTL** của [inspector](inspector.md) đặt cửa sổ của nó từ phải sang trái hoặc quay lại để thử giao diện trước khi dịch. [Tester](testing.md) đặt cửa sổ của nó từ phải sang trái sau `ui.direction.set(&t.ctx, .rtl)`, như một quá trình kiểm tra bố cục sẽ:

```zig
var t: ui.Tester = undefined;
try t.init(gpa, .init(&page, Page.view), .{ .width = 400, .height = 300 });
defer t.deinit();
ui.direction.set(&t.ctx, .rtl);
t.frame();
const back = t.findText("Back").?;
try std.testing.expect(back.x > 200); // the row starts at the right
```

`src/ui/tests_direction.zig` kiểm tra các hàng, căn chỉnh, phần đệm, độ lệch, một hộp được giữ từ trái sang phải bên trong, lớp phủ, hướng từ một ngôn ngữ và các widget mũi tên được đọc.

Hướng ngôn ngữ của ứng dụng xuất phát từ [i18n](../i18n.md): `i18n.direction(tag)`, ngôn ngữ giả `ar-XB` (`i18n.pseudo_bidi`) cũng đọc từ phải sang trái.
