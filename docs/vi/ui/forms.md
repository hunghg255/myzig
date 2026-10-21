<a id="forms"></a>

# Biểu mẫu

Các điều khiển nhãn của trường, hiển thị mô tả hoặc lỗi bên dưới chúng và đặt tên cho chúng cho công nghệ hỗ trợ. Một biểu mẫu sắp xếp các nhãn của các trường của nó thành một cột riêng; một bộ trường nhóm các trường dưới một chú giải và có thể vô hiệu hóa chúng cùng nhau; `ui.validate` kiểm tra giá trị.

<a id="fields"></a>

## Trường

`ui.field(c, title, options)` gắn nhãn cho điều khiển được tạo tiếp theo, nhãn phía trên nó như trên web và trả về `ui.Field` để kết thúc sau khi điều khiển được tạo:

```zig
const f = ui.field(c, "Email", .{ .description = "For receipts.", .err = ui.validate.email(s.email.text()) });
_ = ui.textField(c, &s.email, .{ .width = .{ .px = 260 } });
f.end();
```

`ui.FieldOptions`:

| lĩnh vực | nó thể hiện điều gì |
|---|---|
| `description` | văn bản bên dưới điều khiển, có màu bị tắt |
| `err` | có gì sai với giá trị bên dưới điều khiển trong màu nguy hiểm mà đường viền của điều khiển chiếm giữ; trống là hợp lệ |

Một cú nhấp chuột vào nhãn sẽ tập trung điều khiển. Tên có thể truy cập của điều khiển là nhãn, mô tả lỗi (hoặc mô tả) và được đánh dấu là không hợp lệ khi có lỗi. Bất kỳ điều khiển nào cũng hoạt động: trường văn bản, lựa chọn, chuyển đổi, nhập ngày; trường tìm thấy điều khiển đầu tiên được tạo sau nhãn của nó.

<a id="forms-1"></a>

## Biểu mẫu

`ui.form(c, options)` đặt nhãn của các trường của nó trong một cột bên cạnh các điều khiển, căn chỉnh sang bên phải, rộng bằng nhãn rộng nhất và ngang bằng với dòng đầu tiên của văn bản điều khiển, giống như cài đặt của macOS (hoặc ở giữa điều khiển không có văn bản, dưới dạng công tắc, mô tả bên dưới nhãn đó hoặc không và liên tiếp với văn bản bên cạnh dấu chấm hoặc biểu tượng: `Style.baselines`). Giữ biểu mẫu trong một biến (các trường của nó thay đổi nó) và tạo các trường bằng `field` của chính nó:

```zig
var fm = ui.form(c, .{});
{
    defer fm.end();
    const n = fm.field("Name", .{});
    _ = ui.textField(c, &s.name, .{ .placeholder = "Ada Lovelace", .width = .{ .px = 260 } });
    n.end();
    const p = fm.field("Password", .{ .err = ui.validate.minLength(c, s.password.text(), 8) });
    _ = ui.textField(c, &s.password, .{ .password = true, .width = .{ .px = 260 } });
    p.end();
    const snd = fm.field("Sound effects", .{});
    _ = ui.toggle(c, "", &s.sounds);
    snd.end();
}
```

`ui.FormOptions`: `gap` (12, giữa các trường) và `label_gap` (12, giữa cột nhãn và điều khiển'). Chiều rộng của nhãn được đo khi biểu mẫu được tạo; khi nó thay đổi, khung sẽ được tạo lại ngay lập tức, do đó không có khung nào hiển thị các nhãn không được căn chỉnh.

<a id="fieldsets"></a>

## Bộ trường

`ui.fieldset(c, legend, options)` nhóm các trường dưới một chú giải. Với `disabled`, các trường bị làm mờ và không nhận dữ liệu đầu vào: một hộp phía trên chúng sẽ nhận mỗi lần nhấn và tiêu điểm bàn phím sẽ rời khỏi chúng. Kết thúc nó bằng `end`:

```zig
const set = ui.fieldset(c, "Notifications", .{ .disabled = !s.signed_in });
const snd = fm.field("Sound effects", .{});
_ = ui.toggle(c, "", &s.sounds);
snd.end();
set.end();
```

`ui.FieldsetOptions`: `disabled` và `gap` (12). Một tập trường có thể chứa các trường của biểu mẫu (như trên, giữa các lệnh gọi `field` của biểu mẫu) hoặc `ui.field`s đơn giản.

<a id="validation"></a>

## Xác thực

`ui.validate` có các bước kiểm tra trả về lỗi để hiển thị, trống khi giá trị hợp lệ, sẵn sàng cho `err` của trường:

| kiểm tra | lỗi |
|---|---|
| `required(s)` | "Bắt buộc." cho một giá trị trống hoặc trống |
| `email(s)` | "Nhập địa chỉ email." trừ khi nó trông giống như vậy (trống là hợp lệ) |
| `minLength(c, s, n)` | "Ít nhất n ký tự." ít hơn `n` ký tự (trống là hợp lệ) |
| `number(c, s, lo, hi)` | "Nhập một con số." hoặc "Giữa lo và hi." (trống là hợp lệ) |
| `first(errors)` | séc đầu tiên không trống trong số nhiều séc |

Kết hợp `required` với một kiểm tra khác để tìm giá trị phải được cung cấp:

```zig
.err = ui.validate.first(&.{ ui.validate.required(s.email.text()), ui.validate.email(s.email.text()) }),
```

`ui.Validation` đếm lỗi của biểu mẫu, để bật nút gửi hoặc cho biết số lỗi còn lại: `check(err)` chuyển lỗi, đếm lỗi và `ok()` cho biết liệu có lỗi nào không.

```zig
fn form(s: *State, c: *ui.Context) void {
    var v: ui.Validation = .{};
    var fm = ui.form(c, .{});
    {
        defer fm.end();
        const n = fm.field("Name", .{ .err = if (s.submitted) v.check(ui.validate.required(s.name.text())) else "" });
        _ = ui.textField(c, &s.name, .{ .width = .{ .px = 260 } });
        n.end();
        const e = fm.field("Email", .{ .err = v.check(ui.validate.email(s.email.text())) });
        _ = ui.textField(c, &s.email, .{ .width = .{ .px = 260 } });
        e.end();
    }
    ui.row(c, .{ .gap = 12, .align_items = .center });
    defer ui.end(c);
    if (ui.button(c, "Submit", .{ .variant = .primary }).clicked) s.submitted = true;
    if (s.submitted) ui.text(c, if (v.ok()) "All good." else c.print("{d} to fix", .{v.errors}), .{
        .color = if (v.ok()) c.theme.success else c.theme.danger,
    });
}
```

Chỉ hiển thị lỗi của các trường bắt buộc trống khi người dùng cố gắng gửi, như trên và lỗi của nội dung được nhập cùng một lúc. Lỗi là chuỗi trong tiếng Anh; đối với các ngôn ngữ khác, hãy viết séc của riêng bạn (bất kỳ hàm nào trả về một chuỗi đều hoạt động) với các tin nhắn từ [i18n](../i18n.md).
