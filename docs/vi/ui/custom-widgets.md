<a id="custom-widgets"></a>

# Widget tự làm

Mọi widget của myzig là một hàm Zig, dựng từ đúng vài thành phần mà widget của bạn cũng dùng:

- các box mở trên `ui.Context`;
- tương tác đọc từ layout của frame trước;
- các giá trị animate qua nhiều frame;
- phần mô tả cho công nghệ hỗ trợ.

Không có class widget nào để kế thừa, cũng không có object nào phải giữ lại. Widget là một hàm của state của app, được gọi ở mọi frame.

<a id="boxes"></a>

## Box

```zig
const box = c.open(.{ .direction = .row, .gap = 8, .padding = .xy(10, 6), .radius = 999, .control = true }, null);
defer c.end();
// ... các phần tử con ...
c.node(box).style.background = c.theme.accent;
```

- `c.open(style, key)` mở một box với style là một `ui.Style`. Nó trả về chỉ số của box trong danh sách node của frame này. Các phần tử con theo sau cho đến `c.end()`.
- `c.leaf(style, content, key)` thêm một box không có phần tử con. Nội dung của nó là `.none`, một đoạn chữ, một icon hoặc một hình ảnh. Các widget `ui.text`, `ui.icon` và `ui.image` tạo ra những box này.
- `c.node(index)` trả về `*Node`, để đổi style khi đã biết state của nó: màu khi hover, màu nổi bật.
- `ui.row`, `ui.column`, `ui.card` và `ui.div(c)` cũng mở box, với hướng hoặc kiểu dáng đặt sẵn (xem [View](views.md) và [Layout](layout.md)).
- `style.control = true` đánh dấu một control. Nó nhận focus bằng Tab, và vẽ vòng focus khi focus đến từ bàn phím.

<a id="ids"></a>

## Id

Mọi box đều có id. Nhờ id mà state sống qua từ frame này sang frame sau: layout, hover, animation, vị trí scroll, chữ đang được sửa. Id của box lấy từ id của phần tử cha và vị trí của nó giữa các phần tử con của cha, hoặc từ một key:

- `key` (tham số cuối của `open` và `leaf`), hoặc `ui.key(c, k)` đặt trước một widget, đặt tên cho box kế tiếp. Các hàng của một danh sách có key theo id của item giữ được state khi các item phía trên xuất hiện hay biến mất.
- `c.next_key_int = i` làm điều tương tự bằng một số.
- `c.peekId(key)` là id mà phần tử con kế tiếp của box đang mở sẽ nhận. Nó dành cho widget cần biết id của mình trước khi mở box.

<a id="a-box-that-comes-or-goes-moves-the-ids-after-it"></a>

### Box lúc có lúc không làm xê dịch id của các box sau nó

Id tạo từ vị trí sẽ đổi khi vị trí đổi. Lấy ví dụ một box chỉ thỉnh thoảng hiện ra trước một nút: một vạch đánh dấu khi hover lên hàng, một badge khi có thứ gì mới.

- Trong những frame box đó hiện ra, nút nhận một id khác.
- Box vừa xuất hiện lấy id cũ của nút.
- Cú bấm được gán cho id mà con trỏ nằm trên ở frame trước. Nó không tìm thấy nút nào nhận, nên cú bấm mất, không có lỗi nào.

```zig
// Vạch đánh dấu xuất hiện theo hover, và id của nút đổi theo.
if (s.hovered) _ = c.leaf(.{ .width = .{ .px = 3 } }, .none, null);
const it = ui.button(c, project.name, .{});
s.hovered = it.hovered;
```

Có hai cách giữ id đứng yên:

- gắn key cho nút (`c.keyed(project)` hoặc `ui.key(c, project.path)` đặt trước nó): id có key không phụ thuộc vào vị trí, hoặc
- luôn build box đứng trước, và ẩn nó bằng kiểu dáng (nền trong suốt, chiều rộng 0), để các vị trí giữ nguyên.

Build Debug sẽ báo chuyện này. Giả sử không box nào nhận id vừa bị bấm, con trỏ vẫn ở chỗ box đó từng nằm, và box đang ở dưới con trỏ không có mặt ở frame trước. Khi đó log báo một lần `myzig: the box pressed changed its id between frames (a box before it came or went?)`. Build Release không kiểm tra.

Box scroll còn mất nhiều hơn, vì vị trí scroll được giữ theo id của nó:

- Một box lúc có lúc không đứng trước nó (một dòng dính, một banner) khiến nó scroll lại từ đầu.
- Một box cứ frame có frame không làm nó nhảy qua lại giữa đầu trang và chỗ người đọc đang xem.

Build Debug cũng báo chuyện này (`scroll_check.zig`). Nó áp dụng khi một box đã scroll khỏi đầu biến mất khỏi layout, và một box scroll có id khác, rộng bằng nó, chiếm chỗ của nó.

Khi đó log báo một lần `myzig: a scrolled box changed its id between frames`, hoặc `myzig: a scrolling box changes its id back and forth between frames` khi id cũ quay lại. Thay đổi ở frame có cú bấm hoặc phím (chuyển tab) được coi là cố ý, trừ khi nó đổi qua đổi lại.

**Bộ nhớ mà box giữ.**

- `c.leaf` sao chép chuỗi và span của box chữ vào bộ nhớ của frame. `c.describe` cũng làm vậy với các chuỗi của nó.
- Các slice khác mà box giữ được đọc sau khi view trả về: byte của hình ảnh, tên icon, gradient. Hãy truyền bộ nhớ của chính app hoặc của frame (`c.print`, `c.alloc()`), không bao giờ truyền buffer nằm trên stack.

<a id="interactions"></a>

## Tương tác

`c.interact(index, opts)` cho biết con trỏ và bàn phím liên quan thế nào tới box `index`, dựa trên layout của frame trước. Nó cũng làm box nhận con trỏ. Nó trả về một `ui.Interaction`:

| Trường | |
|---|---|
| `id` | id của box |
| `rect` | vị trí của nó ở frame trước, null ở frame đầu tiên |
| `hovered` | con trỏ nằm trên nó, hoặc trên một box bên trong nó, như `:hover` của CSS |
| `pressed` | đang được giữ: đã bấm xuống trên nó và chưa thả |
| `clicked` | bấm và thả trên nó, hoặc được bấm bằng phím hay bởi công nghệ hỗ trợ |
| `double_clicked` | cú bấm thứ hai của một cú double click (cũng tính là một cú bấm) |
| `focused` | nó đang có focus bàn phím |

- Với `.focusable = true`, box nhận focus khi được bấm, và có mặt trong thứ tự Tab.
- Với `.keys = true`, Enter và Space bấm nó khi nó có focus, như với nút hay checkbox.
- Cú bấm chỉ đến box tương tác trên cùng nằm dưới con trỏ. Hover thì đến cả các box chứa nó.

`ui.pressable(c, style, hover_color)` mở một box và tương tác với nó. Box có vòng focus của một control. Nếu có màu, nền của nó chuyển dần về màu đó khi hover. Phần lớn widget bắt đầu từ đây.

<a id="state-changes"></a>

## Thay đổi state

Widget mà tương tác làm đổi state của app thì đặt `c.changed`. Khi đó frame được build lại trước khi vẽ, nên màn hình không bao giờ chậm hơn state: checkbox vừa bấm hiện dấu tick ngay trong frame đó.

Giống các widget có sẵn, widget của bạn nhận giá trị của app qua con trỏ (`*bool`, `*usize`, `*f32`). Chúng trả về chuyện đã xảy ra: `clicked`, `changed`, `submitted`.

<a id="animated-values"></a>

## Giá trị animate

```zig
const t = c.animate(it.id, 0, if (on.*) 1 else 0, 16);
c.node(track).style.background = c.theme.track.mix(c.theme.success, t);
```

`c.animate(id, salt, target, speed)` chuyển một số được giữ cho box `id` dần về `target`, và trả về giá trị hiện tại. Dùng nó cho hiệu ứng mờ khi hover, núm của switch, một phần mở ra.

- `speed` càng lớn càng nhanh.
- `salt` phân biệt nhiều giá trị của cùng một box.
- Khi còn giá trị chưa tới target, cửa sổ vẽ thêm frame. Khi tất cả đã tới, nó dừng: không có gì chạy polling.

Spring, keyframe, timeline và transition tự làm: xem [Chuyển động](motion.md). Đồng hồ và frame:

- `c.frameIn(seconds)` xin một frame trong vòng chừng đó giây: bước kế tiếp của spinner, giây kế tiếp của đồng hồ.
- `c.animationFrame()` xin một frame sớm nhất màn hình có thể hiện, cho view animate từ `c.time` ở mọi frame.
- `c.dt` là thời gian từ frame trước. `c.time` là số giây từ frame đầu tiên: đồng hồ của context, mà `ui.Tester` điều khiển trong test.
- `ui.overlays.memo(c, id, salt, default)` giữ một số bất kỳ cho box qua các frame: điểm nắm khi kéo, lúc tooltip bắt đầu. Nó bị quên một lúc sau khi box biến mất.

<a id="input"></a>

## Input

`c.input` là input của event này:

- con trỏ: `mouse`, `down`, `pressed`, `released`, `click_count`, và `right_pressed`, `middle_pressed` cho các nút chuột khác;
- các phím bổ trợ;
- phím: `key`, `shortcut`;
- chữ được gõ: `chars`.

Widget xử lý một phím thì lấy phím đó đi, để những gì build sau không thấy nó nữa. `c.shortcut(...)` lấy một tổ hợp phím, còn `ui.overlays.takeKey(c, k)` lấy một phím đơn. Input chữ tự làm, cho loại trình soạn thảo mà myzig chưa có, đọc các `ui.TextOp`; xem [Nhập chữ](text-input.md).

| Đặt | để |
|---|---|
| `c.wants_moves` | theo con trỏ bên trong một box, như dấu chữ thập của đồ thị |
| `c.wants_wheel` | nhận con lăn chuột ở chỗ không có gì scroll |
| `c.wants_keys` | nhận phím nhấn xuống và nhả lên (`input.key_down`, `input.key_up`), cho game |
| `c.cursor` | xin một kiểu con trỏ đè lên kiểu mà widget đặt: `.arrow`, `.hand`, `.text`, `.resize_left_right`, `.resize_up_down` |

<a id="accessibility"></a>

## Accessibility

`c.describe(id, description)` cho công nghệ hỗ trợ biết box là gì: vai trò, label, giá trị, và nó có đang được tick, mở rộng, chọn hay bị tắt không. Widget có sẵn tự mô tả mình; widget của bạn cũng nên vậy:

```zig
c.describe(it.id, .{ .role = .switch_, .label = title, .checked = if (on.*) .on else .off });
```

Xem [Accessibility](accessibility.md) để biết các vai trò và phần còn lại của `ui.AccessDescription`.

<a id="a-widget-of-your-own"></a>

## Một widget tự làm

Một viên pill bật tắt một `*bool`. Nó mang màu accent khi bật, nhận focus, bấm được bằng Enter và Space, chuyển màu mượt, và được mô tả là một nút bật tắt:

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
    if (it.focused and c.focus_visible) n.style.border = th.ring;
    ui.text(c, title, .{ .size = 13, .weight = .medium, .color = th.text.mix(th.accent_text, t) });
    return it.clicked;
}
```

Dùng nó như mọi widget khác: `if (pill(c, "Wrap", &s.wrap)) s.relayout();`. Test nó bằng `ui.Tester`: `try t.clickText("Wrap")` (xem [Test](testing.md)).

<a id="widgets-without-a-look"></a>

## Widget không có kiểu dáng

Một số widget có biến thể không mang kiểu dáng riêng. Nó lo con trỏ, bàn phím và focus, còn màu sắc và hình dạng để bạn quyết định:

| Không có kiểu dáng | |
|---|---|
| `ui.popover(..., .{ .bare = true })` | tạo style cho panel bằng `Panel.style()` ([Overlay](overlays.md)) |
| `ui.dialog(..., .{ .bare = true })` | `Dialog.backdropStyle()` và `Dialog.panelStyle()` |
| `ui.tooltipBase`, `ui.tooltipEnd` | tooltip tự làm bên cạnh một phần tử |
| `ui.textField(..., .{ .bare = true })` | ô nhập không viền, không nền, không vòng focus, nằm trong khung của bạn (ô soạn tin chat) |
| `ui.textArea(..., .{ .bare = true })` | tương tự cho chữ nhiều dòng ([Text area](text-area.md)) |
| `ui.richTextEditorBase` | trình soạn rich text không có box bao ngoài ([Rich text](rich-text.md)) |
| `ui.shaderBox` | box được vẽ bằng shader của bạn ([Shader](shaders.md)) |

Với menu, select và các overlay tự làm khác, hãy dùng các thành phần trong `ui.overlays`. Chúng đặt panel cạnh phần tử neo, đóng nó khi bấm ra ngoài, và trả focus về (xem [Overlay](overlays.md#building-overlays-of-your-own)).

Các danh sách có sẵn dùng những hàm phụ về hàng, danh sách và lựa chọn trong `src/ui/structure.zig`:

- di chuyển lựa chọn bằng phím mũi tên, Home, End và Page;
- chọn theo tiền tố gõ vào;
- màu của hàng.

<a id="theme"></a>

## Theme

`c.theme` là `ui.Theme` của cửa sổ: `background`, `surface`, `surface_hover`, `text`, `muted`, `border`, `ring`, `accent`, `accent_hover`, `accent_text`, `track`, `knob`, `danger`, `success`, `shadow`, và `dark`. Hãy vẽ bằng màu của theme, không dùng màu cố định. Khi đó widget theo được chế độ sáng, tối, và theme riêng của app (xem [Style](styling.md)).
