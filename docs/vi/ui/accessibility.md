<a id="accessibility"></a>

# Khả năng tiếp cận

Công nghệ hỗ trợ đọc cửa sổ giao diện native khi đọc các ứng dụng khác: VoiceOver trên macOS, Orca trên Linux và Trình tường thuật, NVDA hoặc JAWS trên Windows. Nó nhìn thấy các vật dụng có vai trò, tên, giá trị và trạng thái, văn bản cũng như các thành phần được chú trọng và nghe thấy những gì thay đổi. Nó hoạt động trên chúng giống như bàn phím và con trỏ: nó nhấn các nút, chọn hộp, di chuyển thanh trượt, thay thế văn bản của trường văn bản và di chuyển tiêu điểm.

| Nền tảng | myzig nói lên điều gì | Ở đâu |
|---|---|---|
| macOS | NSAccessibility: các thành phần của lớp con thời gian chạy của `NSAccessibilityElement` | `src/ui/access_mac.zig` |
| Linux | AT-SPI qua D-Bus, chỉ trong Zig (không có libatk, không có libdbus) | `src/linux/atspi*.zig`, `dbus*.zig` |
| Windows | Tự động hóa giao diện người dùng: gốc đoạn trả lời `WM_GETOBJECT`, với các mẫu điều khiển | `src/windows/uia*.zig` |
| Trình duyệt | chưa: canvas là tất cả những gì công nghệ hỗ trợ nhìn thấy | |

Không có chi phí nào cho đến khi công nghệ hỗ trợ yêu cầu cửa sổ. Cho đến lúc đó, các mô tả sẽ bị loại bỏ khi các vật dụng tạo ra chúng và không có cây nào được xây dựng. Trên Linux ứng dụng kết nối với bus trợ năng sau khi phiên cho biết công nghệ hỗ trợ được bật; `MYZIG_A11Y=1` vẫn kết nối, hãy thử xem.

<a id="how-it-works"></a>

## Cách hoạt động

Các widget mô tả các hộp của chúng khi chúng xây dựng chúng, với `c.describe(id, description)`. Sau khi khung được bố trí, `src/ui/access_tree.zig` biến các hộp và mô tả của chúng thành một cây gồm các phần tử, mỗi phần tử có một vai trò, tên, giá trị, trạng thái, hành động mà nó thực hiện và hình chữ nhật của nó trong cửa sổ. Bề mặt đưa cây đó vào nền tảng và sau mỗi frame, so sánh nó với frame trước đó để cho người nghe biết những gì đã thay đổi: tiêu điểm, tên, giá trị, trạng thái, phần tử con và thông báo.

Khi công nghệ hỗ trợ tác động lên một phần tử, `ui.access.perform` sẽ chuyển hành động đó thành thao tác mà bàn phím hoặc con trỏ sẽ thực hiện trong khung tiếp theo: nhấn nhấp chuột, lấy tiêu điểm như Tab, tăng thanh trượt nhấn Phải (bước, Lên) và đặt giá trị của trường văn bản sẽ chọn tất cả văn bản của nó và nhập văn bản mới, đồng thời chèn văn bản vào đó (`.insert_text`: văn bản đã chọn của macOS, loại chính tả, Điều khiển bằng giọng nói và loại tự động hóa with) gõ nó lên vùng chọn, ở dấu mũ không có dấu mũ. Vì vậy, một widget không cần gì riêng để hoạt động: những gì hoạt động với bàn phím sẽ hoạt động với công nghệ hỗ trợ.

<a id="names"></a>

## Tên

Các widget tự đặt tên bằng văn bản bên trong chúng: một nút có tiêu đề, hộp kiểm có nhãn, tiêu đề có văn bản. Những người không có văn bản sẽ có nhãn trong tùy chọn của họ:

```zig
_ = ui.slider(c, &s.volume, .{ .label = "Volume" });
_ = ui.textField(c, &s.name, .{ .label = "Name", .placeholder = "Your name" });
```

Chỉ riêng một nút của biểu tượng đã được đặt tên theo tên biểu tượng của nó; làm cho nó tốt hơn bằng cách mô tả nó sau khi nó được xây dựng. Mô tả về một hộp hợp nhất, các trường được đặt chiến thắng cuối cùng:

```zig
const del = ui.button(c, "", .{ .icon = "trash" });
c.describe(del.id, .{ .label = "Delete" });
if (del.clicked) s.deleteSelection();
```

<a id="roles"></a>

## Vai trò

Các hộp không có widget nào mô tả sẽ có vai trò ngay từ bản chất của chúng (`.auto`): văn bản là văn bản, hộp được nhấp vào và lấy tiêu điểm là một nút, hộp cuộn là vùng cuộn và hộp có nhãn hoặc tiêu điểm là một nhóm. Những chiếc hộp khác để lại, con cái đi về với bố mẹ. `.none` để lại một hộp được mô tả nhưng giữ lại các hộp con của nó.

`ui.AccessRole` (`ui.access.Role`) có vai trò là các widget của myzig: `group`, `text`, `button`, `link`, `checkbox`, `radio`, `switch_`, `slider`, `progress`, `text_field`, `image`, `list`, `list_item`, `scroll_area`, `dialog`, `alert_dialog`, `popup`, `tooltip`, `popup_button`, `combo_box`, `tab_list`, `tab`, `tab_panel`, `splitter`, `status`, `table`, `row`, `cell`, `column_header`, `tree`, `tree_item`, `menu_button`, `toolbar`, `radio_group`, `toggle_button`, `disclosure`, `meter`, `stepper`, `color_well`, `menu`, `menu_bar`, `menu_item`, `menu_item_checkbox`, `menu_item_radio` và `heading`.

Một widget của riêng bạn, được rút ra từ các hộp, cho biết nó là gì:

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

`c.describeOpen(description)` mô tả hộp trong cùng đang mở, dành cho các vật dụng không chứa id.

<a id="states-and-values"></a>

## Trạng thái và giá trị

`ui.AccessDescription` (`ui.access.Description`) đáp ứng những gì vai trò cần, giống như các trạng thái của ARIA thực hiện trên web. Các trường còn lại null được tìm thấy từ hộp:

| trường | Nó nói gì |
|---|---|
| `label`, `value` | tên và giá trị (văn bản của trường văn bản, lựa chọn mà nút bật lên hiển thị) |
| `description` | hơn cái tên, hãy đọc theo sau nó: văn bản trợ giúp, một lỗi |
| `placeholder` | trường văn bản trống hiển thị gì |
| `checked` | `.off`, `.on` hoặc `.mixed`: hộp kiểm, công tắc, radio, chuyển đổi hoặc mục menu |
| `expanded`, `expandable`, `has_popup` | liệu phần tử mở ra có hiển thị hay không, liệu nó có mở bằng cách mở rộng và thu gọn hay không, liệu nó có mở cửa sổ bật lên hay không |
| `selected`, `selectable`, `multiselectable` | lựa chọn trong tab, danh sách, cây, nhóm radio |
| `range` | `.{ .min, .max, .now, .step }` của thanh trượt, thanh tiến trình, đồng hồ đo hoặc bước |
| `level` | thứ hạng của tiêu đề hoặc độ sâu của mục cây, từ 1 |
| `pos_in_set`, `set_size` | hạng mục nào trong số tất cả hạng mục này, được xây dựng hay chưa: "5 trên 10 000" |
| `active_descendant` | id của tùy chọn có tiêu điểm trong khi phần tử này giữ nó (tùy chọn được đánh dấu của hộp tổ hợp) |
| `selection` | lựa chọn của trường văn bản, tính bằng byte giá trị của nó |
| `disabled`, `read_only`, `password`, `multiline`, `invalid`, `vertical`, `modal` | như được đặt tên; `modal` làm cho nội dung đằng sau hộp thoại trở nên trơ |

Các phần tử của cây cũng thực hiện các hành động mà chúng thực hiện (`ui.access.Actions`: nhấn, tập trung, tăng, giảm, đặt giá trị, cuộn vào view, mở rộng), từ vai trò và trạng thái của chúng: nút bị vô hiệu hóa sẽ không có tác dụng nào.

<a id="lists-and-tables"></a>

## Danh sách và bảng

Các hàng của [danh sách](lists.md) ảo cho biết chúng là hàng nào trong số tất cả các hàng, mặc dù danh sách chỉ xây dựng những hàng trong view; các hàng và ô của bảng được đặt tên theo văn bản bên trong chúng. Công nghệ hỗ trợ di chuyển đến một phần tử ngoài tầm nhìn sẽ yêu cầu `scroll_into_view` để cuộn các hộp xung quanh phần tử đó.

<a id="announcements"></a>

## Thông báo

Tin tức không di chuyển trọng tâm, khi tìm kiếm được thực hiện hoặc tệp được lưu, sẽ tiếp cận công nghệ hỗ trợ với `c.announce(text)`: tin tức sẽ đọc một lần, sau nội dung đang đọc (thông báo của VoiceOver, AT-SPI và khu vực trực tiếp lịch sự trên Windows). Một khung được xây dựng lại không thông báo hai lần. [Toasts](overlays.md) là các phần tử `status`, được đọc khi chúng hiển thị.

```zig
if (ui.button(c, "Save", .{}).clicked) {
    s.save();
    c.announce("Saved");
}
```

<a id="testing-it"></a>

## Đang thử nghiệm nó

[Tester](testing.md) xây dựng cùng một cây, do đó, quá trình kiểm tra có thể kiểm tra xem công nghệ hỗ trợ nhìn thấy gì và hoạt động như thế nào. Bật mô tả, chạy khung và tạo cây:

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

`tree.find(id)`, `tree.byName(role, name)`, `tree.count(role)` và `tree.at(point)` tìm các phần tử; `tree.focus` là id của tập trung. `src/ui/tests_access.zig` và `tests_access_widgets.zig` kiểm tra mọi widget theo cách này; `src/linux/atspi_test.zig` và `atspi_bus_test.zig` kiểm tra máy chủ AT-SPI và `src/windows/uia_test.zig` nhà cung cấp Tự động hóa giao diện người dùng.
