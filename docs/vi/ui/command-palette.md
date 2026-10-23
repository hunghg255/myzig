# Command Palette

`ui.commandPalette` hiển thị danh sách lệnh có tìm kiếm trong một dialog
modal. Khi kích hoạt, nó trả về chỉ số ban đầu của lệnh trong danh sách app.

![Các lệnh workspace có icon, phím tắt và lệnh xuất file bị vô hiệu hóa.](../../images/ui/command-palette.png)

```zig
// Trong state: commands: ui.CommandState = .{},
if (c.shortcut(.{ .key = 'k', .cmd = true })) s.commands.toggle();
const items: []const ui.CommandItem = &.{
    .{ .title = "File mới", .group = "File", .keywords = "create", .icon = "doc.text" },
    .{ .title = "Cài đặt", .group = "Ứng dụng", .keywords = "preferences" },
    .{ .title = "Xuất file", .group = "File", .disabled = !s.has_files },
};
if (ui.commandPalette(c, &s.commands, items, .{})) |index| s.runCommand(index);
```

Giữ `CommandState` trong state app. `show`, `close`, `toggle` quản lý overlay;
`query` là buffer tìm kiếm, `selected` là chỉ số gốc của kết quả đang chọn.
Mỗi lần mở lại sẽ xóa truy vấn. Dựng palette sau phần còn lại của view để
các điều khiển đang có cơ hội xử lý input trước.

## Lệnh và tùy chọn

Mỗi lệnh có `title` và các trường tùy chọn `group`, `keywords`, `icon`,
`shortcut` (chữ hiển thị), `disabled`. Đặt các lệnh cùng nhóm cạnh nhau.
Tìm kiếm trong tiêu đề/từ khóa, không phân biệt hoa thường ASCII; kết quả
khớp tiền tố đứng trước. Lệnh disabled vẫn hiển thị nhưng bàn phím bỏ qua.

| `CommandOptions` | Mặc định | Ý nghĩa |
|---|---|---|
| `width` | `.{ .px = 480 }` | Chiều rộng dialog, không vượt cửa sổ |
| `max_height` | `320` | Chiều cao tối đa của danh sách trước khi cuộn |
| `label` | `"Commands"` | Tên dialog/danh sách cho accessibility |
| `placeholder` | `"Search commands…"` | Gợi ý tìm kiếm |
| `search_label` | `"Search commands"` | Tên ô nhập cho accessibility |
| `empty_label` | `"No commands found."` | Chữ khi không có kết quả |

Ô tìm kiếm giữ focus khi nhập. Lên/Xuống di chuyển vòng qua các kết quả
đang bật; Home/End đến đầu/cuối. Enter hoặc bấm chuột kích hoạt lệnh.
Space vẫn là chữ tìm kiếm. Kết quả được chọn tự cuộn vào vùng nhìn thấy
và được công nghệ hỗ trợ nhận qua active descendant của ô nhập.

Tab ở trong dialog. Escape, bấm nền hoặc kích hoạt lệnh sẽ đóng palette
và trả focus về điều khiển mở nó. Palette mở ngay, không có animation vào.

## Dùng chung Actions

Nếu app dùng [`ui.Actions`](navigation.md), adapter dùng lại tiêu đề, icon,
trạng thái enabled và nhãn phím tắt:

```zig
if (s.actions.commandPalette(c, &s.commands, .{})) |cmd| s.run(cmd);
```

Hàm trả về enum của lệnh và cập nhật `actions.last`, như `menuItem` và
`button`. Nhãn phím tắt chỉ để hiển thị; dùng `actions.shortcuts(c)` để
xử lý các tổ hợp phím tương ứng.

Xem [Gallery](../../../examples/gallery/feedback.zig) để thử lệnh mở
[Sheet](sheet.md) hoặc cập nhật workspace.
