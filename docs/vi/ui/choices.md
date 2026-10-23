<a id="choices"></a>

# Các điều khiển lựa chọn

Nhóm này gồm hộp kiểm và công tắc cho một tùy chọn, nhóm hộp kiểm cho nhiều tùy chọn, nút radio và segmented control để chọn một trong vài giá trị, cùng điều khiển đánh giá sao. Mỗi điều khiển sửa trạng thái qua con trỏ và trả về true khi người dùng thay đổi giá trị, để ứng dụng xử lý thay đổi đó.

<a id="checkboxes"></a>

![Công tắc, checkbox và segmented control trong Gallery.](../../images/ui/toggles.png)

*Công tắc, checkbox và segmented control trong Gallery.*

## Hộp kiểm

`ui.checkbox(c, title, &value)` vẽ hộp kiểm cùng nhãn và đảo giá trị `bool` khi nhấn chuột, hoặc nhấn Enter hay Space lúc có focus:

```zig
_ = ui.checkbox(c, "Remember me", &s.remember);
if (ui.checkbox(c, "Show hidden files", &s.hidden)) s.reload();
```

Dấu chọn xuất hiện và biến mất với hiệu ứng easing. Nhãn cũng thuộc điều khiển, nên nhấn vào nhãn sẽ đảo trạng thái. Để tiêu đề trống nếu chỉ cần hộp kiểm, chẳng hạn trong cột lựa chọn của bảng.

<a id="checkbox-groups"></a>

## Nhóm hộp kiểm

`ui.checkboxGroup(c, title, values, labels)` vẽ một hộp kiểm tổng phía trên các hộp kiểm con, thường dùng cho danh sách quyền. Mỗi phần tử của `values` (kiểu `[]bool`) có nhãn tương ứng trong `labels` và được thụt lề bên dưới. Hộp tổng được chọn khi tất cả mục con được chọn, hoặc hiện dấu gạch ngang khi chỉ một số mục được chọn. Nhấn hộp tổng, hoặc Space khi nó có focus, để chọn tất cả; nếu đã chọn hết thì bỏ chọn tất cả. Hàm trả về true khi có thay đổi:

```zig
const State = struct {
    notify: [3]bool = .{ true, false, true },
};

_ = ui.checkboxGroup(c, "Notifications", &s.notify, &.{ "Mail", "Calendar", "Reminders" });
```

Công nghệ hỗ trợ nhận biết hộp tổng là hộp kiểm ở trạng thái bật, tắt hoặc mixed.

<a id="switches"></a>

## Công tắc

`ui.toggle(c, title, &value)` là công tắc giống trong iOS và phần cài đặt macOS, dành cho tùy chọn có hiệu lực ngay:

```zig
_ = ui.toggle(c, "Notifications", &s.notifications);
if (ui.toggle(c, "Dark", &s.dark)) s.theme.switchTo(if (s.dark) ui.Theme.dark_theme else ui.Theme.light);
```

Khi bật, nút tròn trượt sang bên và phần nền chuyển sang màu success. Trong [biểu mẫu](forms.md), có thể để tiêu đề trống và dùng nhãn của trường.

<a id="radio-buttons"></a>

## Nút radio

![Nhóm radio và mức đánh giá bốn sao.](../../images/ui/choices.png)

*Nhóm radio và mức đánh giá bốn sao.*

`ui.radio(c, &selected, value, title)` vẽ một nút radio. Nút được chọn khi `selected.*` bằng `value`; phép so sánh dùng `std.meta.eql`, nên có thể dùng số nguyên, enum, struct hoặc kiểu khác. Nhấn nút để đặt giá trị; hàm trả về true khi thao tác đó chọn nút:

```zig
ui.row(c, .{ .gap = 16, .align_items = .center });
defer ui.end(c);
_ = ui.radio(c, &s.alignment, 0, "Left");
_ = ui.radio(c, &s.alignment, 1, "Center");
_ = ui.radio(c, &s.alignment, 2, "Right");
```

Việc nhấp vào cái đã chọn sẽ không thay đổi gì và trả về false.

<a id="radio-groups"></a>

## Nhóm radio

`ui.radioGroup(c, &selected, choices, options)` vẽ một nút radio cho mỗi phần tử của `choices` (kiểu `[]const ui.Choice(T)`, gồm `label` và `value`). Cả nhóm là một điểm focus bàn phím: dùng phím mũi tên để chuyển lựa chọn, Home để chọn mục đầu và End để chọn mục cuối. Hàm trả về true khi lựa chọn thay đổi:

```zig
const Plan = enum { free, pro, team };

_ = ui.radioGroup(c, &s.plan, &.{
    .{ .label = "Free", .value = .free },
    .{ .label = "Pro", .value = .pro },
    .{ .label = "Team", .value = .team },
}, .{ .row = true, .gap = 16 });
```

`ui.RadioGroupOptions`: `row` (một hàng thay vì một cột) và `gap` (8). Công nghệ hỗ trợ đọc nhóm dưới dạng nhóm radio và vị trí của mỗi nút trong đó.

<a id="segmented-controls"></a>

## Segmented control

`ui.segmented(c, options, &selected)` chọn một trong vài nhãn, tương tự segmented control của AppKit. `options` là slice các chuỗi và `selected` là chỉ số kiểu `usize`. Hàm trả về true khi lựa chọn thay đổi:

```zig
_ = ui.segmented(c, &.{ "List", "Grid", "Columns" }, &s.view_mode);
switch (s.view_mode) {
    0 => s.listView(c),
    1 => s.gridView(c),
    else => s.columnView(c),
}
```

Mục được chọn nổi trên màu surface và có bóng đổ; hiệu ứng easing chuyển trạng thái giữa các mục.

<a id="ratings"></a>

## Đánh giá sao

`ui.rating(c, &value, options)` vẽ một hàng sao, trong đó `value` (kiểu `u8`) là số sao được tô. Nhấn một sao để đặt điểm; nhấn lại sao đang được chọn để xóa điểm. Khi có focus, dùng phím mũi tên, Home và End để đổi điểm. Khi rê con trỏ, các sao xem trước giá trị sẽ được chọn nếu nhấn. Hàm trả về true khi điểm thay đổi:

```zig
_ = ui.rating(c, &s.stars, .{});
ui.text(c, c.print("{d} of 5", .{s.stars}), .{ .color = c.theme.muted });
```

`ui.RatingOptions`: `max` (5 sao) và `size` (18 điểm).

<a id="toggling-from-the-keyboard"></a>

## Chuyển đổi từ bàn phím

Các điều khiển này nhận focus bằng Tab và hiển thị viền focus khi điều khiển bằng bàn phím. Enter và Space đảo trạng thái hộp kiểm và công tắc; phím mũi tên thay đổi lựa chọn của nhóm radio và đánh giá sao. Kiểm thử sử dụng chúng theo cùng cách:

```zig
try t.clickText("Large"); // selects the radio button labeled "Large"
t.key(.right);            // the next choice of a focused radio group
```

Xem [kiểm thử](testing.md).
