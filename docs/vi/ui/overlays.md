<a id="overlays"></a>

# Lớp phủ

Lớp phủ là các hộp được vẽ trên mọi thứ khác trong cửa sổ: cửa sổ bật lên bên cạnh một phần tử, chú giải công cụ, hộp thoại trên cửa sổ bị mờ, hộp thoại cảnh báo và lời chúc mừng. Menu và lựa chọn cũng là lớp phủ; họ có [một trang của riêng mình](menus.md).

Lớp phủ được tạo ở vị trí thuộc về nó trong view, bên cạnh nội dung mở nó nhưng nó được bố trí trên cửa sổ (`Context.openOverlay`) và nó đưa con trỏ đến trước các hộp bên dưới nó. Liệu một hiển thị có phải là trạng thái của ứng dụng hay không: một `ui.OverlayState` được giữ trong cấu trúc của ứng dụng, ứng dụng này sẽ mở và widget sẽ đóng khi người dùng loại bỏ nó.

![Popover đang mở, neo vào nút Edit name.](../../images/ui/popover.png)

*Popover đang mở, neo vào nút Edit name.*

```zig
const State = struct {
    pop: ui.OverlayState = .{},
    rename: ui.OverlayState = .{},
    alert: ui.OverlayState = .{},
    toasts: ui.Toasts = .{},
    name: ui.TextBuffer = .{},
};
```

`OverlayState` có `show`, `close` và `toggle` và trường `open`. Trong khung mà người dùng đã đóng nó (Escape, nhấn bên ngoài) cờ `dismissed` của nó được đặt: lớp phủ phải luôn mở sẽ đặt `open` quay lại `true` sau đó. Khi mở, nó sẽ ghi nhớ tiêu điểm bàn phím và trả lại tiêu điểm khi đóng, vì vậy Tab tiếp tục từ nút đã mở nó.

<a id="popovers"></a>

## Cửa sổ bật lên

`ui.popover(c, &state, anchor, opts)` hiển thị một bảng bên cạnh phần tử `anchor` (bất kỳ `ui.Interaction`: một nút, một `ui.pressable`) trong khi `state.open` và trả về null khi nó bị đóng. Con của nó làm theo, sau đó là `end` của bảng điều khiển:

```zig
const more = ui.button(c, "Edit name…", .{});
if (more.clicked) s.pop.toggle();
if (ui.popover(c, &s.pop, more, .{})) |p| {
    defer p.end();
    ui.text(c, "Name", .{ .weight = .semibold });
    _ = ui.textField(c, &s.name, .{ .placeholder = "A name" });
    if (ui.button(c, "Done", .{ .variant = .primary }).clicked) s.pop.close();
}
```

Một lần nhấn bên ngoài cửa sổ bật lên hoặc Escape sẽ đóng nó và nhấn vào phần bên dưới con trỏ, giống như cách các cửa sổ bật lên của web thực hiện: một lần nhấn vào một nút khác sẽ đóng cửa sổ bật lên và nhấn nút đó, đồng thời nhấn vào neo sẽ đóng nó khi mỏ neo chuyển đổi nó. Đầu tiên, lối thoát đi đến nội dung bên trong bảng điều khiển (danh sách mở của một lựa chọn, cửa sổ bật lên của trường), sau đó đến bảng điều khiển.

`ui.PopoverOptions`:

| trường | Mặc định | |
|---|---|---|
| `side` | `.below` | `.below`, `.above`, `.right` hoặc `.left` của mỏ neo |
| `align` | `.start` | `.start` (sắp thẳng hàng với điểm bắt đầu của mỏ neo) hoặc `.center` |
| `gap` | 6 | điểm giữa neo và bảng điều khiển |
| `padding` | `.all(8)` | phần đệm của bảng điều khiển |
| `gap_children` | 4 | khoảng cách giữa những đứa trẻ của bảng điều khiển |
| `width` | `.auto` | chiều rộng của bảng điều khiển |
| `max_width` | 360 | |
| `bare` | false | không có vẻ ngoài riêng biệt: tạo kiểu với `Panel.style()` |

Trường hợp không còn chỗ trên `side`, bảng điều khiển sẽ ở phía bên kia; dọc theo nó, nó xếp hàng ở điểm bắt đầu (hoặc điểm cuối, nơi điểm bắt đầu sẽ rời khỏi cửa sổ) và sau đó được di chuyển vào bên trong cửa sổ, cách các cạnh của nó 4 điểm. Bảng điều khiển mờ dần trên các frame đầu tiên của nó.

Cửa sổ bật lên trần không có nền, đường viền, bán kính hoặc bóng. `Panel.style()` của nó trả về `*ui.Style` của hộp bảng điều khiển, để biến nó thành của riêng bạn:

```zig
if (ui.popover(c, &s.pop, more, .{ .bare = true })) |p| {
    defer p.end();
    const st = p.style();
    st.background = c.theme.accent;
    st.radius = 12;
    st.padding = .all(12);
    ui.text(c, "Saved", .{ .color = .white });
}
```

<a id="tooltips"></a>

## Chú giải công cụ

`ui.tooltip(c, anchor, tip)` hiển thị `tip` phía trên phần tử `anchor` (bên dưới phần tử không có khoảng trống phía trên), được căn giữa khi con trỏ đã nằm trên phần tử đó trong `0.6` giây hoặc ngay lập tức khi nó tập trung vào bàn phím hoặc một mẹo khác hoạt động ít hơn `0.4` giây trước, do đó, việc di chuyển dọc theo thanh công cụ sẽ hiển thị từng mẹo cùng một lúc. Nó đi khi con trỏ rời đi; nhấn vào phần tử hoặc Escape sẽ ẩn nó cho đến khi con trỏ rời đi và quay lại. Con trỏ đi qua nó.

```zig
const share = ui.button(c, "Share", .{});
ui.tooltip(c, share, "Share with others");
```

Mẹo được đọc cho công nghệ hỗ trợ sau tên của thành phần, dù được hiển thị hay không. Thời gian của nó là đồng hồ của ngữ cảnh, do đó, quá trình kiểm tra sẽ nâng cao đồng hồ của Người kiểm tra thay vì chờ đợi (xem [Kiểm thử](testing.md)).

Mẹo của riêng bạn: `ui.tooltipBase(c, anchor)` mở hộp mẹo và trả về chỉ mục nút của nó trong khi nó hiển thị, null nếu không; thêm nội dung của nó, sau đó là `ui.tooltipEnd(c, anchor)`, đặt nội dung đó theo phần tử của nó.

```zig
const info = ui.button(c, "Shortcuts", .{});
if (ui.tooltipBase(c, info)) |box| {
    c.node(box).style.background = c.theme.surface;
    c.node(box).style.border = c.theme.border;
    ui.text(c, "Open", .{ .weight = .semibold });
    ui.kbd(c, ui.keys.label("⌘O"));
    ui.tooltipEnd(c, info);
}
```

<a id="dialogs"></a>

## Hộp thoại

![Hộp thoại Rename nằm trên view được làm tối.](../../images/ui/dialog.png)

*Hộp thoại Rename nằm trên view được làm tối.*

`ui.dialog(c, &state, opts)` hiển thị một bảng điều khiển được căn giữa trên cửa sổ bị mờ trong khi `state.open` và trả về `ui.Dialog` (null khi đóng), có con theo sau, sau đó là `end`:

```zig
if (ui.button(c, "Rename…", .{}).clicked) s.rename.show();
if (ui.dialog(c, &s.rename, .{})) |d| {
    defer d.end();
    ui.text(c, "Rename the note", .{ .weight = .bold, .size = 16 });
    if (ui.textField(c, &s.name, .{ .width = .{ .px = 280 } }).submitted) s.rename.close();
    ui.row(c, .{ .gap = 8, .justify = .end, .width = .fill });
    defer ui.end(c);
    if (ui.button(c, "Cancel", .{}).clicked) s.rename.close();
    if (ui.button(c, "Save", .{ .variant = .primary }).clicked) s.rename.close();
}
```

Một hộp thoại sẽ giữ cửa sổ cho chính nó: phông nền của nó sẽ lấy con trỏ, nhấn vào phông nền sẽ đóng hộp thoại trừ khi `dismissible` là false và Escape sẽ đóng hộp thoại đó (trừ khi `escape` là false) sau khi không có gì bên trong lấy Escape trước. Trọng tâm đằng sau nó bị loại bỏ khi nó mở ra và được trả lại khi nó đóng lại.

`ui.DialogOptions`:

| trường | Mặc định | |
|---|---|---|
| `width` | `.{ .px = 360 }` | chiều rộng của bảng điều khiển |
| `padding` | `.all(20)` | |
| `gap` | 12 | giữa những đứa trẻ của bảng điều khiển |
| `dismissible` | true | một cái nhấn trên phông nền sẽ đóng nó lại |
| `escape` | true | Escape đóng nó lại |
| `bare` | false | không cần nhìn: tạo kiểu cho nó bằng `Dialog.backdropStyle()` và `Dialog.panelStyle()` |
| `animated` | true | mờ dần khi mở |
| `trap_focus` | true | Tab và Shift+Tab chỉ di chuyển trong dialog |

<a id="alert-dialogs"></a>

## Hộp thoại cảnh báo

`ui.alertDialog(c, &state, title, message, buttons)` hỏi về điều gì đó quan trọng, giống như cảnh báo của AppKit: tiêu đề, thông báo và một hàng nút, nút cuối cùng là mặc định, được vẽ bằng màu nhấn mà Enter sẽ nhấp vào. Escape đóng nó không chọn gì; một báo chí bên ngoài không làm gì cả. Chọn một nút sẽ đóng nó lại. Nó trả lời `ui.AlertResult`:

```zig
if (ui.button(c, "Delete…", .{ .variant = .danger }).clicked) s.alert.show();
switch (ui.alertDialog(c, &s.alert, "Delete “Groceries”?", "You can't undo this.", &.{ "Cancel", "Delete" })) {
    .none => {},
    .chosen => |i| if (i == 1) s.deleteNote(),
    .dismissed => {},
}
```

`.chosen` mang chỉ mục của nút được nhấp (chỉ mục cuối cùng dành cho Enter); `.dismissed` có nghĩa là Escape đã đóng nó, giống như việc hủy bỏ.

Đối với các hộp thông báo riêng của hệ thống, sẽ chặn cho đến khi được trả lời và được hệ điều hành vẽ ra, hãy xem `myzig.dialog` trong [Hệ thống](../system.md).

<a id="toasts"></a>

## Nâng cốc chúc mừng

![Thông báo toast có thao tác Undo ở cuối view.](../../images/ui/toast.png)

*Thông báo toast có thao tác Undo ở cuối view.*

Lời chúc mừng là những tin nhắn ngắn ở gần cuối cửa sổ, kết quả của những gì người dùng vừa làm sẽ xuất hiện sau vài giây. Ứng dụng giữ một `ui.Toasts` trên mỗi cửa sổ và thêm vào nó từ bất kỳ đâu trong view:

```zig
if (ui.button(c, "Save", .{}).clicked) _ = s.toasts.show("Saved");
if (ui.button(c, "Delete", .{}).clicked) s.undo = s.toasts.showAction("Moved to Trash", "Undo");
if (ui.button(c, "Connect", .{}).clicked) _ = s.toasts.add(.{ .title = "Couldn't connect", .kind = .@"error" });
```

và xây dựng chúng một lần, cuối cùng trong view, để chúng nằm trên các lớp phủ khác:

```zig
const r = ui.toasts(c, &s.toasts);
if (r.action) |id| if (id == s.undo) s.restore();
```

`ui.Toast`, `add` cần những gì (chuỗi của nó được sao chép, vì vậy `c.print` vẫn ổn):

| trường | Mặc định | |
|---|---|---|
| `title` | | |
| `description` | `""` | dòng thứ hai |
| `kind` | `.info` | `.info`, `.success` hoặc `.@"error"`, đặt biểu tượng và màu sắc của nó |
| `timeout` | 0 | giây nó hiển thị: 4 khi 0 (8 với một hành động), cho đến khi đóng khi âm |
| `action` | `""` | một nút đóng nó, được báo cáo bởi `ui.toasts` |
| `key` | `""` | đặt tên cho nó: thêm một lời chúc mừng với phím của một cái hiển thị những thay đổi cái đó, hiển thị lại (tiêu đề của nó khi trống) |

`add`, `show` và `showAction` trả về id của thông báo toast; `close(id)`, `closeAll()`, `has(id)` và `count()` hãy làm theo những gì họ nói. `ui.toasts` trả về `ui.ToastResult` có `action` là thông báo toast có nút được nhấp vào trong khung này và `closed` nút được đóng bằng nút đóng.

Ba chương trình mới nhất, xếp chồng lên nhau; những người lớn tuổi hơn đang ẩn nấp chờ đợi, thời gian của họ đang trôi đi. Thời gian của họ là đồng hồ của ngữ cảnh (`Context.time`), không phải của bức tường và nó dừng khi con trỏ nằm trên chúng. Con trỏ đi qua căn phòng xung quanh họ.

<a id="building-overlays-of-your-own"></a>

## Xây dựng lớp phủ của riêng bạn

Cửa sổ bật lên, menu, lựa chọn và hộp tổ hợp được tạo thành từ các phần trong `ui.overlays` (`overlay_base.zig`), mà widget của riêng bạn có thể sử dụng:

- `overlays.overlay(c, style, seed)` mở một hộp phía trên cửa sổ (`Context.openOverlay`) có id đến từ `seed`, để các hộp được tạo sau nó giữ nguyên id của chúng khi nó đến và đi: một mẹo hiển thị không được thay đổi id của nút bên cạnh nó. `overlays.seedOf(&state)` tạo một địa chỉ gốc của tiểu bang.
- `OverlayState.sync(c)` ghi lại frame mà nó mở ra và lấy lại tiêu điểm khi nó đóng lại; nó trả về nếu nó hiển thị. `justOpened(c)` là true trong khung đầu tiên của nó, `record(c, lo)` ghi chú các hộp mà nó đã tạo và `pressedOutside(c, anchor_id)` cho biết liệu lực ép của khung này có hạ cánh bên ngoài chúng và bên ngoài mỏ neo hay không; `dismiss(c)` đóng nó lại như người dùng đã làm.
- `overlays.attach(anchor, size, window, side, align, gap)` tính toán vị trí của bảng điều khiển và `overlays.place(c, index, anchor, side, align, gap)` đo hộp lớp phủ và di chuyển nó đến đó, giống như cách bảng điều khiển thực hiện khi nó kết thúc; cái cuộn đầu tiên được cắt vào phòng ở phía lớn hơn của mỏ neo (`overlays.roomAlong`), nơi nó cuộn.
- `overlays.takeKey(c, key)` lấy khóa từ sự kiện này, vì vậy những gì được tạo sau này sẽ không nhìn thấy khóa đó: lớp phủ ở trên sẽ lấy Escape trước.
- `overlays.fadeIn(c, id, opened)` là độ mờ của bảng điều khiển mờ dần.

Xem [Tiện ích tùy chỉnh](custom-widgets.md) để biết các hộp, hoạt động tương tác và giá trị hoạt ảnh được tạo nên từ đó.
