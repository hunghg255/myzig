# Chọn nhiều mục

![Popup tìm kiếm và giữ nhiều lựa chọn.](../../images/ui/multi-select.png)

`multiSelect` kết hợp ô tìm kiếm và danh sách có đánh dấu chọn. Bộ lọc chỉ
đổi các mục đang hiển thị, giữ nguyên chỉ số gốc và lựa chọn ngoài bộ lọc.

```zig
// State của ứng dụng:
languages: [3]bool = .{ true, false, false },
language_picker: ui.MultiSelectState = .{},

// Trong view:
if (ui.multiSelect(c, &s.language_picker,
    &.{ "Zig", "TypeScript", "Rust" }, &s.languages,
    .{ .label = "Ngôn ngữ" },
)) savePreferences();
```

Giữ state và mảng boolean giữa các frame. Danh sách mục và mảng cờ phải có
cùng số phần tử. Chỉ số định danh mục; nếu đổi thứ tự danh sách, ứng dụng
cần đổi mảng cờ tương ứng. Không cần allocator hay hàm hủy.

`MultiSelectOptions` gồm `label`, `placeholder` tìm kiếm, `empty_label`,
`width`, `max_height`, `disabled` và mảng `disabled_items` tùy chọn ứng với
từng mục. Mục đang chọn nhưng bị khóa vẫn giữ trạng thái chọn.

Tìm kiếm không phân biệt hoa thường. Up/Down bỏ qua mục bị khóa; Home/End
đi tới hai đầu; Enter bật/tắt mục hiện tại. Bấm mục giữ popup mở và trả focus
về ô tìm kiếm. Done, Escape hoặc bấm ngoài đóng popup. Escape trả focus về
nút mở. Hàm trả `true` khi lựa chọn thay đổi.

Xem **Actions & choices** trong Gallery và
[combobox chọn một mục](menus.md).
