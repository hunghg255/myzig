<a id="accessibility"></a>

# Trợ năng

Công nghệ hỗ trợ đọc cửa sổ có UI native giống như đọc các app khác: VoiceOver trên macOS, Orca trên Linux, và Narrator, NVDA hoặc JAWS trên Windows.

- Nó thấy các widget kèm role, tên, giá trị và trạng thái của chúng.
- Nó thấy các đoạn chữ và những phần tử nhận focus.
- Nó nghe được những gì thay đổi.
- Nó thao tác như bàn phím và con trỏ: bấm nút, tick checkbox, kéo slider, thay chữ trong ô nhập và di chuyển focus.

| Nền tảng | myzig dùng gì | Ở đâu |
|---|---|---|
| macOS | NSAccessibility: phần tử là một subclass tạo lúc runtime của `NSAccessibilityElement` | `src/ui/access_mac.zig` |
| Linux | AT-SPI qua D-Bus, viết hoàn toàn bằng Zig (không libatk, không libdbus) | `src/linux/atspi*.zig`, `dbus*.zig` |
| Windows | UI Automation: một fragment root trả lời `WM_GETOBJECT`, có các control pattern | `src/windows/uia*.zig` |
| Trình duyệt | chưa có: công nghệ hỗ trợ chỉ thấy canvas | |

Mọi thứ không tốn gì cho đến khi công nghệ hỗ trợ hỏi tới cửa sổ. Trước đó, mô tả của widget bị bỏ đi ngay khi được tạo, và không có cây nào được dựng.

Trên Linux, app kết nối tới accessibility bus khi session báo công nghệ hỗ trợ đang bật. `MYZIG_A11Y=1` thì luôn kết nối, để thử.

<a id="how-it-works"></a>

## Cách hoạt động

1. Widget mô tả các box của mình trong lúc dựng chúng, bằng `c.describe(id, description)`.
2. Khi frame đã layout xong, `src/ui/access_tree.zig` biến các box và mô tả của chúng thành một cây phần tử. Mỗi phần tử có role, tên, giá trị, trạng thái, các action nó nhận và hình chữ nhật của nó trong cửa sổ.
3. Surface đưa cây đó cho nền tảng.
4. Sau mỗi frame, nó so cây với cây trước. Nó báo cho bên lắng nghe những gì đã đổi: focus, tên, giá trị, trạng thái, phần tử con và các thông báo.

Khi công nghệ hỗ trợ thao tác trên một phần tử, `ui.access.perform` biến action đó thành việc mà bàn phím hoặc con trỏ sẽ làm ở frame tiếp theo:

| Action | Trở thành |
|---|---|
| press | một cú bấm |
| focus | focus, như khi Tab chuyển tới |
| increment | Right trên slider, Up trên stepper |
| đặt giá trị của ô nhập | chọn hết chữ trong ô rồi gõ giá trị mới |
| chèn chữ (`.insert_text`) | gõ đè lên vùng chọn, hoặc tại con trỏ soạn thảo nếu không có vùng chọn |

`.insert_text` là selected text của macOS, thứ mà đọc chính tả, Voice Control và các công cụ tự động hóa dùng để gõ.

Vì vậy widget không cần thêm gì riêng để được điều khiển. Cái gì dùng được bằng bàn phím thì dùng được với công nghệ hỗ trợ.

<a id="names"></a>

## Tên

Widget tự đặt tên bằng chữ bên trong nó: nút theo title, checkbox theo label, heading theo nội dung. Widget không có chữ thì nhận label trong tùy chọn:

```zig
_ = ui.slider(c, &s.volume, .{ .label = "Volume" });
_ = ui.textField(c, &s.name, .{ .label = "Name", .placeholder = "Your name" });
```

Nút chỉ có icon thì được đặt tên theo tên symbol. Muốn tên tốt hơn, mô tả nó sau khi dựng. Các mô tả của cùng một box được gộp lại, trường nào đặt sau cùng thì thắng:

```zig
const del = ui.button(c, "", .{ .icon = "trash" });
c.describe(del.id, .{ .label = "Delete" });
if (del.clicked) s.deleteSelection();
```

<a id="roles"></a>

## Role

Box không được widget nào mô tả thì nhận role theo bản chất của nó (`.auto`):

- chữ là text;
- box được bấm và nhận focus là button;
- box có scroll là scroll area;
- box có label hoặc có focus là group;
- các box khác bị bỏ qua, phần tử con của chúng chuyển lên phần tử cha.

`.none` bỏ qua một box đã được mô tả nhưng vẫn giữ các phần tử con của nó.

`ui.AccessRole` (`ui.access.Role`) có các role của widget trong myzig: `group`, `text`, `button`, `link`, `checkbox`, `radio`, `switch_`, `slider`, `progress`, `text_field`, `image`, `list`, `list_item`, `scroll_area`, `dialog`, `alert_dialog`, `popup`, `tooltip`, `popup_button`, `combo_box`, `tab_list`, `tab`, `tab_panel`, `splitter`, `status`, `table`, `row`, `cell`, `column_header`, `tree`, `tree_item`, `menu_button`, `toolbar`, `radio_group`, `toggle_button`, `disclosure`, `meter`, `stepper`, `color_well`, `menu`, `menu_bar`, `menu_item`, `menu_item_checkbox`, `menu_item_radio` và `heading`.

Widget tự viết, dựng từ các box, tự nói nó là gì:

```zig
fn wifiSwitch(c: *ui.Context, on: *bool) void {
    const i = c.open(.{ .width = .{ .px = 36 }, .height = .{ .px = 20 }, .radius = 10, .background = if (on.*) c.theme.accent else c.theme.border }, "wifi");
    const it = c.interact(i, .{ .focusable = true, .keys = true });
    c.describe(it.id, .{ .role = .switch_, .label = "Wi-Fi", .checked = if (on.*) .on else .off });
    if (it.clicked) {
        on.* = !on.*;
        c.changed = true;
    }
    c.end();
}
```

`c.describeOpen(description)` mô tả box đang mở trong cùng, cho các widget không giữ id.

<a id="states-and-values"></a>

## Trạng thái và giá trị

`ui.AccessDescription` (`ui.access.Description`) mang những gì một role cần, như các state của ARIA trên web. Trường nào để null thì được suy ra từ box:

| Trường | Cho biết |
|---|---|
| `label`, `value` | tên, và giá trị (chữ trong ô nhập, lựa chọn mà popup button đang hiện) |
| `description` | thông tin thêm ngoài tên, đọc sau tên: chữ hướng dẫn, một lỗi |
| `placeholder` | thứ ô nhập rỗng hiển thị |
| `checked` | `.off`, `.on` hoặc `.mixed`: của checkbox, switch, radio, toggle hoặc mục menu |
| `expanded`, `expandable`, `has_popup` | thứ phần tử mở ra có đang hiện không, nó có mở bằng expand và collapse không, nó có mở popup không |
| `selected`, `selectable`, `multiselectable` | lựa chọn trong tab, danh sách, cây, nhóm radio |
| `range` | `.{ .min, .max, .now, .step }` của slider, thanh tiến trình, meter hoặc stepper |
| `level` | cấp của heading, hoặc độ sâu của mục trong cây, tính từ 1 |
| `pos_in_set`, `set_size` | đây là mục thứ mấy trong tất cả các mục, đã dựng hay chưa: "5 of 10 000" |
| `active_descendant` | id của lựa chọn đang có focus trong khi phần tử này vẫn giữ focus (lựa chọn đang được highlight của combobox) |
| `selection` | vùng chọn trong ô nhập, tính bằng byte của giá trị |
| `disabled`, `read_only`, `password`, `multiline`, `invalid`, `vertical`, `modal` | đúng như tên; `modal` khiến mọi thứ phía sau dialog không tương tác được |

Phần tử trong cây còn mang các action nó nhận (`ui.access.Actions`): press, focus, increment, decrement, set value, scroll into view, expand. Chúng suy ra từ role và trạng thái: nút bị disable thì không nhận action nào.

<a id="lists-and-tables"></a>

## Danh sách và bảng

- Các hàng của một [danh sách](lists.md) ảo cho biết mình là hàng thứ mấy trong tất cả các hàng, dù danh sách chỉ dựng những hàng đang hiện.
- Hàng và ô của bảng được đặt tên theo chữ bên trong.
- Để tới một phần tử nằm ngoài vùng nhìn thấy, công nghệ hỗ trợ xin `scroll_into_view`. Việc đó scroll các box bao quanh nó.

<a id="announcements"></a>

## Thông báo

```zig
if (ui.button(c, "Save", .{}).clicked) {
    s.save();
    c.announce("Saved");
}
```

`c.announce(text)` báo cho công nghệ hỗ trợ một tin không làm đổi focus, như tìm kiếm xong hay file đã lưu.

- Tin được đọc một lần, sau thứ đang được đọc.
- Nó dùng announcement của VoiceOver, của AT-SPI, và một live region dạng polite trên Windows.
- Dựng lại frame thì không thông báo hai lần.
- [Toast](overlays.md) là phần tử `status`, được đọc khi hiện ra.

<a id="testing-it"></a>

## Test

`ui.Tester` ([Testing](testing.md)) dựng cùng một cây. Một test có thể kiểm tra những gì công nghệ hỗ trợ thấy, và thao tác như nó. Bật mô tả, chạy một frame, rồi dựng cây:

```zig
var t: ui.Tester = undefined;
try t.init(gpa, .init(&app, App.view), .{ .height = 480 });
defer t.deinit();
t.ctx.access.enabled = true;
t.frame();

var tree: ui.AccessTree = .init(gpa);
defer tree.deinit();
tree.build(&t.ctx);

const save = tree.byName(.button, "Save") orelse return error.NoSave;
try std.testing.expect(save.actions.press and save.states.focusable);
const volume = tree.byName(.slider, "Volume").?;
try std.testing.expectEqual(@as(f64, 0.5), volume.range.now);

ui.access.perform(&t.ctx, save.id, save.role, .press);
t.frame();
tree.build(&t.ctx);
try std.testing.expectEqualStrings("Saved", tree.announcements[0]);
```

- `tree.find(id)`, `tree.byName(role, name)`, `tree.count(role)` và `tree.at(point)` tìm phần tử.
- `tree.focus` là id của phần tử đang có focus.

Các test nằm ở:

- `src/ui/tests_access.zig` và `tests_access_widgets.zig` test mọi widget theo cách này.
- `src/linux/atspi_test.zig` và `atspi_bus_test.zig` test AT-SPI server.
- `src/windows/uia_test.zig` test UI Automation provider.
