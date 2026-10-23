# Sheet

`ui.sheet` mở panel modal sát một cạnh cửa sổ. Dùng để xem chi tiết, cài
đặt hoặc bộ lọc bên cạnh màn hình hiện tại.

![Chi tiết workspace trong panel bên phải.](../../images/ui/sheet.png)

```zig
// Trong state: details: ui.OverlayState = .{},
if (ui.button(c, "Chi tiết", .{}).clicked) s.details.show();
if (ui.sheet(c, &s.details, .{ .label = "Chi tiết dự án" })) |panel| {
    defer panel.end();
    ui.heading(c, "Chi tiết dự án");
    _ = ui.textField(c, &s.name, .{ .width = .fill, .label = "Tên" });
    if (ui.button(c, "Lưu", .{}).clicked) {
        s.save();
        s.details.close();
    }
}
```

Giữ `OverlayState` trong state app. Panel chứa widget thông thường và
cuộn khi nội dung dài hơn vùng hiển thị. Nó dùng chung nền modal, xử lý
Escape và trả focus của [dialog](overlays.md). Phần nền không nhận input
con trỏ; Tab và Shift+Tab chỉ di chuyển bên trong panel.

| `SheetOptions` | Mặc định | Ý nghĩa |
|---|---|---|
| `side` | `.right` | `.left`, `.right`, `.top`, `.bottom`: cạnh vật lý của cửa sổ |
| `size` | `360` | Chiều rộng trái/phải, chiều cao trên/dưới, theo point |
| `label` | `"Sheet"` | Tên modal dialog cho accessibility |
| `dismissible` | `true` | Bấm nền sẽ đóng |
| `escape` | `true` | Escape đóng sau khi các điều khiển con xử lý trước |

Kích thước được giới hạn theo cửa sổ, kể cả sau resize. Nội dung theo
hướng chữ của app; `side` luôn chỉ cạnh vật lý. Khi mở, panel mờ dần và
dịch nhẹ; Reduce Motion hiển thị ngay. Khi đóng, panel biến mất và trả
focus về điều khiển trước đó.

Xem trang **Feedback** trong [Gallery](../../../examples/gallery/feedback.zig).
