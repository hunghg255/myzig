# Nhóm nút và nút bật/tắt

![Nhóm hành động và lựa chọn một hoặc nhiều giá trị.](../../images/ui/button-groups.png)

`buttonGroup` ghép các hành động liên quan thành một nhóm. Gọi `end` sau
khi thêm các nút:

```zig
var group = ui.buttonGroup(c, .{ .label = "Thao tác tài liệu" });
if (group.button("Lưu", .{ .variant = .primary })) save();
if (group.button("Nhân bản", .{})) duplicate();
group.end();
```

`ButtonGroupOptions` có `vertical`, `label` và `disabled`. Từng nút nhận
`ButtonOptions` thông thường. Nút bị khóa không kích hoạt và không nhận
focus bàn phím.

`toggleGroup` dùng mảng boolean do ứng dụng giữ, mỗi phần tử ứng với một mục:

```zig
// State giữ giữa các frame:
styles: [3]bool = .{ true, false, false },

// Trong view:
_ = ui.toggleGroup(c, &.{
    .{ .label = "Đậm" },
    .{ .label = "Nghiêng" },
    .{ .label = "Gạch chân", .disabled = true },
}, &s.styles, .{ .multiple = true, .label = "Định dạng" });
```

`ToggleGroupItem` có nhãn, tên icon và cờ `disabled`. Mặc định chỉ chọn một
mục; khởi tạo nhiều nhất một cờ `true`. `multiple = true` cho phép chọn
nhiều mục. `allow_empty = false` giữ lại lựa chọn cuối cùng. Mảng cờ và
danh sách mục phải có cùng số phần tử.

Cả hai nhóm chỉ chiếm một điểm Tab. Phím mũi tên, Home và End chuyển focus,
bỏ qua nút bị khóa; Space hoặc Enter kích hoạt nút. Nhóm dọc dùng Up/Down,
nhóm ngang hỗ trợ bố cục phải sang trái. Nút bật/tắt công bố trạng thái chọn
cho công cụ hỗ trợ tiếp cận.

Xem trang **Actions & choices** trong Gallery và
[nhóm focus](navigation.md).
