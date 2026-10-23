# Item

`ui.item` ghép hình đại diện hoặc icon, tiêu đề, mô tả và các nút thao tác
thành một hàng nội dung. Dùng cho danh sách file, thành viên, thông báo và cài đặt.

![Các Item có icon file, avatar, nhãn trạng thái và nút thao tác riêng.](../../images/ui/items.png)

```zig
const row = ui.item(c, .{ .label = "Báo cáo dự án" });
defer row.end();
row.icon("doc.text");
row.content("Báo cáo dự án", "Tài liệu PDF · Cập nhật hôm nay");
if (ui.button(c, "Mở", .{}).clicked) s.openReport();
```

Phần chữ chiếm chiều rộng còn lại và tự xuống dòng; các nút giữ chiều rộng
của mình. Có thể đặt widget thông thường trước hoặc sau `content` để thêm
ảnh, badge hoặc nhiều nút. Item là một nhóm accessibility; mỗi nút giữ
focus và hành động riêng. Bấm vào nội dung không kích hoạt cả hàng.

## Tùy chọn và phương thức

| `ItemOptions` | Mặc định | Ý nghĩa |
|---|---|---|
| `width` | `.fill` | Chiều rộng hàng |
| `variant` | `.outline` | `.plain`, `.outline` hoặc `.muted` |
| `size` | `.normal` | `.normal` hoặc `.small`, điều chỉnh khoảng cách và cỡ tiêu đề |
| `label` | `""` | Tên nhóm cho công nghệ hỗ trợ |

| Phương thức | Ý nghĩa |
|---|---|
| `icon(name)` | Icon theo theme trong một vùng có chiều rộng cố định |
| `avatar(name, options)` | Dùng `ui.avatar`, hỗ trợ ảnh và chữ viết tắt dự phòng |
| `content(title, description)` | Tiêu đề và mô tả tùy chọn; cả hai tự xuống dòng |
| `end()` | Đóng hàng sau khi thêm các widget thao tác |

```zig
const member = ui.item(c, .{ .variant = .muted, .size = .small });
defer member.end();
member.avatar("Ada Lovelace", .{ .size = 32 });
member.content("Ada Lovelace", "Chủ workspace");
ui.badge(c, "Owner", c.theme.accent);
```

Với các hàng lặp lại, gọi `ui.keyed(c, record.id)` trước `ui.item` để giữ
ID ổn định, như các [nội dung danh sách](lists.md). Thứ tự hàng tuân theo
[hướng giao diện](right-to-left.md). Widget dùng chung layout và theme trên
macOS, Linux, Windows và trình duyệt.

Trang **Composition** trong [Gallery](../../../examples/gallery/composites.zig)
có ví dụ tương tác. Ghép Item với [Pagination](pagination.md) khi tải dữ liệu theo trang.
