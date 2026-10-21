<a id="custom-widgets"></a>

# Tiện ích tùy chỉnh

Mỗi widget của myzig là một hàm Zig được tạo từ một vài phần giống nhau, một widget mà bạn sử dụng: các hộp được mở trên `ui.Context`, tương tác được đọc từ bố cục của khung cuối cùng, các giá trị được tạo hoạt ảnh trên các khung và mô tả về công nghệ hỗ trợ. Không có lớp widget nào để mở rộng và không có đối tượng nào được giữ lại để giữ lại: widget là một hàm trạng thái của ứng dụng, được gọi trên mọi frame.

<a id="boxes"></a>

## Hộp

`c.open(style, key)` mở một hộp được tạo kiểu bằng `ui.Style` và trả về chỉ mục của nó trong danh sách nút của khung này; con của nó theo sau cho đến `c.end()`. `c.leaf(style, content, key)` thêm một hộp không có con, có nội dung là `.none`, văn bản, biểu tượng hoặc hình ảnh (các widget `ui.text`, `ui.icon` và `ui.image` tạo ra những thứ này). `c.node(index)` trả về `*Node`, để thay đổi kiểu của nó sau khi biết trạng thái của nó (màu di chuột, điểm đánh dấu).

```zig
const box = c.open(.{ .direction = .row, .gap = 8, .padding = .xy(10, 6), .radius = 999, .control = true }, null);
defer c.end();
// ... children ...
c.node(box).style.background = c.theme.accent;
```

`ui.row`, `ui.column`, `ui.card` và `ui.div(c)` cũng mở các hộp với hướng hoặc hình thức được thiết lập (xem [View](views.md) và [Bố cục](layout.md)). `style.control = true` đánh dấu một điều khiển: nó lấy tiêu điểm bằng Tab và vẽ vòng lấy nét khi tiêu điểm đến từ bàn phím.

<a id="ids"></a>

## Id

Mỗi hộp đều có một id, đó là cách trạng thái tồn tại từ frame này sang frame tiếp theo: bố cục, di chuột, hoạt ảnh, độ lệch cuộn, văn bản được chỉnh sửa. Id của hộp đến từ hộp cha và vị trí của nó trong số các hộp con của hộp cha hoặc từ một khóa:

- `key` (đối số cuối cùng của `open` và `leaf`) hoặc `ui.key(c, k)` trước một widget, đặt tên cho hộp tiếp theo: các hàng của danh sách được khóa theo id của mục sẽ giữ nguyên trạng thái khi các mục phía trên chúng đến và đi.
- `c.next_key_int = i` thực hiện tương tự với một số.
- `c.peekId(key)` là id mà phần tử con tiếp theo của hộp mở sẽ nhận được, đối với một widget phải biết id của nó trước khi mở hộp.

<a id="a-box-that-comes-or-goes-moves-the-ids-after-it"></a>

### Một hộp đến hoặc đi sẽ di chuyển các id sau nó

Id được tạo từ một địa điểm sẽ thay đổi khi địa điểm đó thay đổi. Một hộp đôi khi chỉ hiển thị trước một nút (một dấu trong khi hàng được di chuột, một huy hiệu khi có nội dung mới) cung cấp cho nút một id khác trong các khung mà nó hiển thị và hộp đi kèm sẽ lấy id cũ của nút. Nhấn, thực hiện trên id, con trỏ đã ở khung cuối cùng, sau đó không tìm thấy nút nào để lấy nó: nhấp chuột bị mất mà không có lỗi.

```zig
// The mark comes with the hover, and the button's id goes with it.
if (s.hovered) _ = c.leaf(.{ .width = .{ .px = 3 } }, .none, null);
const it = ui.button(c, project.name, .{});
s.hovered = it.hovered;
```

Hoặc giữ nguyên id:

- nhấn nút (`c.keyed(project)` hoặc `ui.key(c, project.path)` trước nó): id có khóa không phụ thuộc vào vị trí của nó hoặc
- luôn xây dựng hộp trước nó và ẩn nó bằng giao diện của nó (nền trong suốt, chiều rộng bằng 0), để các địa điểm vẫn giữ nguyên.

Bản dựng gỡ lỗi cho biết điều đó: khi không có hộp nào trả lời id được nhấn trong khi con trỏ vẫn ở vị trí của hộp đó và hộp hiện ở bên dưới con trỏ không có khung trước đó, nhật ký sẽ cho biết một lần `myzig: the box pressed changed its id between frames (a box before it came or went?)`. Bản phát hành không kiểm tra.

Hộp cuộn mất nhiều hơn: phần bù của nó được giữ bởi id của nó, do đó, một hộp đến hoặc đi trước nó (một dòng cố định, một biểu ngữ) sẽ bắt đầu nó ở trên cùng và một hộp hiển thị mọi frame khác sẽ khiến nó nhảy giữa đầu và nơi người đọc rời khỏi nó. Bản dựng gỡ lỗi cũng cho biết điều đó (`scroll_check.zig`): khi một hộp cuộn từ trên cùng biến mất khỏi bố cục và một hộp cuộn của một id khác, có chiều rộng tương đương, sẽ thay thế nó, nhật ký sẽ thông báo một lần `myzig: a scrolled box changed its id between frames` hoặc `myzig: a scrolling box changes its id back and forth between frames` khi id cũ quay trở lại. Một thay đổi trên khung bằng một cú nhấp chuột hoặc một phím (chuyển tab) được coi là có ý nghĩa, trừ khi nó chuyển qua lại.

Chuỗi và khoảng của hộp văn bản được sao chép vào bộ nhớ của khung bởi `c.leaf`, cũng như các chuỗi `c.describe` lấy. Các slice khác mà hộp giữ lại (byte của ảnh, tên biểu tượng, độ dốc) được đọc sau khi view trả về: chuyển bộ nhớ của chính ứng dụng hoặc của khung (`c.print`, `c.alloc()`), không bao giờ là bộ đệm trên ngăn xếp.

<a id="interactions"></a>

## Tương tác

`c.interact(index, opts)` cho biết con trỏ và bàn phím liên quan như thế nào với hộp `index`, từ bố cục của khung cuối cùng và làm cho nó lấy con trỏ. Nó trả về `ui.Interaction`:

| trường | |
|---|---|
| `id` | id của hộp |
| `rect` | nó ở đâu trong khung cuối cùng, null trong frame đầu tiên |
| `hovered` | con trỏ ở trên nó hoặc trên một hộp bên trong nó, như CSS's `:hover` |
| `pressed` | giữ xuống: nhấn vào nó và chưa được thả ra |
| `clicked` | nhấn và thả trên đó hoặc nhấn bằng phím hoặc bằng công nghệ hỗ trợ |
| `double_clicked` | lần nhấp thứ hai của lần nhấp đúp (đó cũng là lần nhấp) |
| `focused` | nó có tiêu điểm bàn phím |

Với `.focusable = true` hộp sẽ lấy tiêu điểm khi được nhấn và nối theo thứ tự của Tab; với `.keys = true`, Enter và Space nhấp vào nó trong khi nó có tiêu điểm, khi họ thực hiện nút hoặc hộp kiểm. Máy nhấn sẽ chuyển đến hộp tương tác trên cùng chỉ dưới con trỏ; di chuột cũng đi đến các hộp chứa nó.

`ui.pressable(c, style, hover_color)` mở một hộp và tương tác với nó, bằng vòng lấy nét của điều khiển và được cung cấp màu sắc, nền sẽ dễ dàng hướng về phía hộp khi di chuột. Hầu hết các vật dụng đều bắt đầu ở đó.

<a id="state-changes"></a>

## Thay đổi trạng thái

Một widget có tương tác thay đổi trạng thái của ứng dụng sẽ đặt `c.changed`. Sau đó, khung sẽ được tạo lại trước khi được vẽ, do đó màn hình không bao giờ bị trễ trạng thái: hộp kiểm được nhấp vào sẽ hiển thị đã được chọn trong cùng một khung. Các widget lấy giá trị của ứng dụng bằng con trỏ (`*bool`, `*usize`, `*f32`) và trả về những gì đã xảy ra, `clicked`, `changed`, `submitted`, giống như các widget tích hợp sẵn.

<a id="animated-values"></a>

## Giá trị hoạt hình

`c.animate(id, salt, target, speed)` di chuyển một số được giữ cho hộp `id` về phía `target` tại `speed` (lớn hơn là nhanh hơn) và trả về giá trị của nó ngay bây giờ: độ mờ của di chuột, núm của công tắc, lỗ mở. `salt` cho biết một số giá trị của một hộp riêng biệt. Trong khi một giá trị chưa đạt được mục tiêu, cửa sổ sẽ vẽ một khung khác; một khi tất cả đã có, nó dừng lại: không có polling nào.

```zig
const t = c.animate(it.id, 0, if (on.*) 1 else 0, 16);
c.node(track).style.background = c.theme.track.mix(c.theme.success, t);
```

Để biết các lò xo, frame chính, dòng thời gian và chuyển tiếp của riêng chúng, hãy xem [Chuyển động](motion.md). `c.frameIn(seconds)` yêu cầu một frame trong vòng nhiều giây đó (bước tiếp theo của vòng quay, giây của đồng hồ) và `c.animationFrame()` cho một frame ngay khi màn hình có thể hiển thị frame đó, đối với các view hoạt hình từ `c.time` mọi frame. `c.dt` là thời gian kể từ frame cuối cùng và `c.time` số giây kể từ frame đầu tiên: đồng hồ của ngữ cảnh mà Người kiểm tra nâng cao trong các kiểm thử.

`ui.overlays.memo(c, id, salt, default)` giữ bất kỳ số nào cho một hộp trên các khung (khoảng chênh lệch khi kéo, thời điểm bắt đầu tiền boa), bị quên một lúc sau khi hộp không còn nữa.

<a id="input"></a>

## Đầu vào

`c.input` là đầu vào của sự kiện này: con trỏ (`mouse`, `down`, `pressed`, `released`, `click_count`, và `right_pressed` và `middle_pressed` cho các nút khác), công cụ sửa đổi, khóa (`key`, `shortcut`) và văn bản được nhập (`chars`). Một widget trả lời một khóa sẽ lấy nó, do đó những gì được xây dựng sau này cũng không nhìn thấy nó: `c.shortcut(...)` lấy một tổ hợp phím và `ui.overlays.takeKey(c, k)` một khóa đơn giản. Kiểu nhập văn bản của riêng bạn (thiếu trình soạn thảo thuộc loại myzig) đọc `ui.TextOp`s; xem [Nhập văn bản](text-input.md).

Đặt `c.wants_moves` trong khi view đi theo con trỏ bên trong một hộp (hình chữ thập của biểu đồ), `c.wants_wheel` để lấy bánh xe ở nơi không có gì cuộn và `c.wants_keys` để nhận các phím đi xuống và lên (`input.key_down`, `input.key_up`) cho trò chơi. `c.cursor` yêu cầu con trỏ qua những gì các widget đã đặt (`.arrow`, `.hand`, `.text`, `.resize_left_right`, `.resize_up_down`).

<a id="accessibility"></a>

## Khả năng tiếp cận

`c.describe(id, description)` cho công nghệ hỗ trợ biết hộp là gì: vai trò, nhãn, giá trị của nó, liệu nó được kiểm tra, mở rộng, chọn hay vô hiệu hóa. Các vật dụng tích hợp tự mô tả; một widget của riêng bạn cũng nên:

```zig
c.describe(it.id, .{ .role = .switch_, .label = title, .checked = if (on.*) .on else .off });
```

Xem [Khả năng truy cập](accessibility.md) để biết các vai trò và phần còn lại của `ui.AccessDescription`.

<a id="a-widget-of-your-own"></a>

## Một widget của riêng bạn

Một viên thuốc chuyển đổi `*bool`, có màu nhấn khi bật, có thể lấy tiêu điểm, nhấn Enter và Space, nới lỏng và được mô tả dưới dạng nút chuyển đổi:

```zig
const ui = @import("myzig").ui;

pub fn pill(c: *ui.Context, title: []const u8, on: *bool) bool {
    const th = c.theme;
    const box = c.open(.{ .direction = .row, .gap = 6, .padding = .xy(12, 5), .radius = 999, .border = th.border, .control = true }, null);
    defer c.end();
    const it = c.interact(box, .{ .focusable = true, .keys = true });
    if (it.clicked) {
        on.* = !on.*;
        c.changed = true;
    }
    c.describe(it.id, .{ .role = .toggle_button, .label = title, .checked = if (on.*) .on else .off });
    const t = c.animate(it.id, 0, if (on.*) 1 else 0, 18);
    const hover = c.animate(it.id, 1, if (it.hovered) 1 else 0, 20);
    const n = c.node(box);
    n.style.background = th.surface.mix(th.surface_hover, hover).mix(th.accent, t);
    if (it.focused and c.focus_visible) n.style.border = th.accent;
    ui.text(c, title, .{ .size = 13, .weight = .medium, .color = th.text.mix(th.accent_text, t) });
    return it.clicked;
}
```

Sử dụng nó như bất kỳ sản phẩm nào khác: `if (pill(c, "Wrap", &s.wrap)) s.relayout();` và kiểm tra nó bằng Bộ kiểm tra: `try t.clickText("Wrap")` (xem [Kiểm tra](testing.md)).

<a id="widgets-without-a-look"></a>

## Widget không cần nhìn

Một số widget có một biến thể không có giao diện riêng, biến thể này xử lý con trỏ, bàn phím và tiêu điểm, đồng thời để lại màu sắc và hình dạng cho bạn:

| Không cần nhìn | |
|---|---|
| `ui.popover(..., .{ .bare = true })` | tạo kiểu cho bảng điều khiển bằng `Panel.style()` ([Lớp phủ](overlays.md)) |
| `ui.dialog(..., .{ .bare = true })` | `Dialog.backdropStyle()` và `Dialog.panelStyle()` |
| `ui.tooltipBase`, `ui.tooltipEnd` | một mẹo của riêng bạn bên cạnh một phần tử |
| `ui.textField(..., .{ .bare = true })` | một trường không có đường viền, vòng điền hoặc tiêu điểm, bên trong khung của bạn (trình soạn thảo trò chuyện) |
| `ui.textArea(..., .{ .bare = true })` | tương tự đối với văn bản nhiều dòng ([Vùng văn bản](text-area.md)) |
| `ui.richTextEditorBase` | trình soạn thảo văn bản đa dạng thức không có hộp ([Rich text](rich-text.md)) |
| `ui.shaderBox` | một hộp được vẽ bởi shader của bạn ([Shaders](shaders.md)) |

Đối với các menu, phần chọn và các lớp phủ khác của riêng bạn, các phần trong `ui.overlays` đặt một bảng bên cạnh điểm neo của nó, đóng nó lại để nhấn ra bên ngoài và đưa tiêu điểm trở lại (xem [Lớp phủ](overlays.md#building-overlays-of-your-own)). Các hàng, danh sách và trợ giúp lựa chọn trong `src/ui/structure.zig` (di chuyển lựa chọn bằng các mũi tên, phím Home, End và Page; chọn theo tiền tố đã nhập; màu hàng) là những gì mà danh sách tích hợp sẵn sử dụng.

<a id="theme"></a>

## Chủ đề

`c.theme` là `ui.Theme` của cửa sổ: `background`, `surface`, `surface_hover`, `text`, `muted`, `border`, `accent`, `accent_hover`, `accent_text`, `track`, `knob`, `danger`, `success`, `shadow` và `dark`. Vẽ bằng màu sắc chứ không phải màu cố định để widget tuân theo ánh sáng và bóng tối cũng như chủ đề riêng của ứng dụng (xem [Tạo kiểu](styling.md)).
