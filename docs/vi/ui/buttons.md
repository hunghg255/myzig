<a id="buttons-and-small-things"></a>

# Nút và những thứ nhỏ nhặt

Các nút, liên kết, huy hiệu, keycap, biểu tượng, hình ảnh, hình đại diện và các nút quay lại và tiến lên của lịch sử: những phần nhỏ mà hầu hết các lượt xem đều được tạo thành.

<a id="buttons"></a>

![Các nút primary, secondary, ghost, danger và disabled, kèm badge và phím tắt.](../../images/ui/buttons.png)

*Các nút primary, secondary, ghost, danger và disabled, kèm badge và phím tắt.*

## Nút

`ui.button(c, title, options)` vẽ một nút và trả về `ui.Interaction` của nó; `.clicked` là true trong bản dựng xử lý lượt nhấp:

```zig
if (ui.button(c, "Save", .{ .variant = .primary }).clicked) s.save();
if (ui.button(c, "Cancel", .{}).clicked) s.editing = false;
if (ui.button(c, "Delete", .{ .variant = .danger }).clicked) s.remove();
_ = ui.button(c, "Disabled", .{ .disabled = true });
```

`ui.ButtonOptions`:

| lĩnh vực | mặc định | nó làm gì |
|---|---|---|
| `variant` | `.secondary` | `.primary` (dấu), `.secondary` (bề mặt, có viền), `.ghost` (không tô cho đến khi di chuột), `.danger` (màu nguy hiểm) |
| `width` | `.auto` | một `ui.Length`; `.fill` cho một nút trên nút gốc của nó |
| `size` | 14 | kích thước của văn bản, cũng đặt phần đệm |
| `disabled` | false | bị mờ và không bao giờ nhấp chuột, di chuột hoặc tập trung |
| `icon` | `""` | một ký hiệu trước tiêu đề hoặc một mình khi tiêu đề trống |

```zig
// A button of an icon alone: assistive technology reads its symbol's name.
if (ui.button(c, "", .{ .icon = "trash", .variant = .ghost }).clicked) s.remove();
if (ui.button(c, "New", .{ .icon = "plus", .variant = .primary }).clicked) s.add();
```

Các nút dễ dàng lấp đầy khi di chuột và nhấn, chìm nửa điểm khi nhấn, lấy tiêu điểm bàn phím (Tab) và nhấp vào Enter hoặc Space trong khi lấy tiêu điểm. Một cú nhấp chuột đặt `c.changed`, vì vậy những gì nó thay đổi sẽ hiển thị trong khung này.

Tương tác cũng có `hovered`, `pressed` (giữ), `focused`, `double_clicked` và `rect` (nơi nút được đặt lần cuối, null trong khung đầu tiên), cho cửa sổ bật lên được neo vào nút đó hoặc chú giải công cụ:

```zig
const it = ui.button(c, "Share", .{ .icon = "globe" });
if (it.clicked) s.share_open = !s.share_open;
```

Hộp của riêng bạn hoạt động như một nút là `ui.pressable` hoặc `ui.div(c)...clicked()`; xem [widget tùy chỉnh](custom-widgets.md). Nút mở menu là `ui.menuButton`; xem [menu](menus.md).

<a id="links"></a>

## Liên kết

`ui.link(c, title, .{ .size = 14 })` là văn bản có màu nhấn, được gạch chân khi con trỏ ở trên nó, nhấp chuột như một nút (và với Enter trong khi nó có tiêu điểm bàn phím). Nó trả về true khi được nhấp vào:

```zig
if (ui.link(c, "Privacy policy", .{})) _ = myzig.shell.openUrl("https://example.com/privacy");
```

<a id="badges"></a>

## Huy hiệu

`ui.badge(c, str, color)` là một nhãn tròn nhỏ, văn bản của nó là `color` được tô mờ:

```zig
ui.badge(c, "done", c.theme.success);
ui.badge(c, c.print("{d} new", .{s.unread}), c.theme.accent);
```

<a id="key-caps"></a>

## Mũ phím

`ui.kbd(c, str)` vẽ một tổ hợp phím làm nắp phím. Viết các kết hợp với các ký hiệu của máy Mac và để `ui.keys.label` (một hàm thời gian biên dịch) đánh vần chúng giống như nền tảng thực hiện: `⌘⇧M` trên macOS, `Ctrl+Shift+M` ở nơi khác.

```zig
ui.kbd(c, ui.keys.label("⌘K"));
```

<a id="icons"></a>

## Biểu tượng

`ui.icon(c, name, options)` vẽ một biểu tượng theo tên Biểu tượng SF của nó:

```zig
ui.icon(c, "star.fill", .{ .color = c.theme.accent });
ui.icon(c, "doc.text", .{ .size = 13, .frame = 18, .color = c.theme.muted });
```

`ui.IconOptions`: `size` (16), `weight` (`.regular`; Biểu tượng SF vẽ các nét nặng hơn với độ đậm nhạt hơn), `color` (văn bản theo mặc định) và `frame`, một hộp vuông mà biểu tượng được căn giữa, do đó các biểu tượng có chiều rộng khác nhau xếp thành một cột gồm nhiều hàng.

Trên macOS mọi Biểu tượng SF đều có sẵn. Trên Linux, Windows và trong trình duyệt, myzig vẽ các biểu tượng đường riêng của nó, theo cách của Lucide, cho các ký hiệu tên widget và ứng dụng của nó (`src/ui/icons.zig`); một cái tên nó không có gì thu hút ở đó. Họ là:

`checkmark` `xmark` `plus` `chevron.down` `chevron.up` `chevron.right` `chevron.up.chevron.down` `arrow.right` `arrow.up` `arrow.clockwise` `arrow.right.square` `arrow.up.left.and.arrow.down.right` `arrow.triangle.branch` `magnifyingglass` `circle` `circle.dotted` `checkmark.circle.fill` `stop.circle` `play.fill` `pause.fill` `star.fill` `sparkles` `wand.and.stars` `person.fill` `photo` `doc` `doc.text` `doc.richtext` `doc.on.doc` `folder` `trash` `pencil` `square.and.pencil` `paperclip` `globe` `network` `terminal` `terminal.fill` `command` `cpu` `memorychip` `brain` `cube` `internaldrive` `desktopcomputer` `wrench.and.screwdriver` `exclamationmark.triangle` `questionmark.circle` `info.circle` `xmark.octagon` `ellipsis.circle` `hand.raised` `list.bullet` `checklist` `sun.max` `moon` `circle.lefthalf.filled` `chart.bar.xaxis` `equal.square` `plus.square` `xmark.square` `rectangle.on.rectangle` `chevron.left.forwardslash.chevron.right` `text.cursor` `textformat` `code` `flame` `waveform.path.ecg` `clear`

Sử dụng những tên này trong các ứng dụng dành cho mọi nền tảng. Để có ảnh của riêng bạn, hãy sử dụng ảnh hoặc [SVG](drawing.md).

<a id="images"></a>

## Hình ảnh

`ui.image(c, options)` hiển thị hình ảnh từ các byte được mã hóa của nó và trả về false (không vẽ gì) nếu chúng không thể được giải mã:

```zig
const logo = @embedFile("logo.png");

_ = ui.image(c, .{ .key = "logo", .bytes = logo, .max_width = 120, .label = "myzig" });
```

`ui.ImageOptions`:

| lĩnh vực | mặc định | nó làm gì |
|---|---|---|
| `key` | (bắt buộc) | đặt tên cho hình ảnh: cùng một khóa được giải mã một lần |
| `bytes` | (bắt buộc) | hình ảnh được mã hóa, được người gọi lưu giữ trong khi nó được hiển thị |
| `max_width`, `max_height` | 480, 360 | cần nhiều chỗ nhất, tính bằng điểm |
| `radius` | 8 | các góc của nó |
| `opacity` | 1 | độ mờ của nó |
| `label` | `""` | những gì nó thể hiện, đối với công nghệ hỗ trợ; hình ảnh không tên là trang trí |

Một hình ảnh giữ nguyên tỷ lệ và được hiển thị ở một nửa kích thước pixel (pixel của nó được lấy ở dạng 2×), không bao giờ lớn hơn, trong phòng tối đa. Nó được giải mã một lần cho mỗi khóa (bằng ImageIO trên macOS, đọc PNG, JPEG, HEIC, v.v.; bởi bộ giải mã PNG của myzig ở nơi khác và trên Windows bởi Thành phần hình ảnh Windows cho phần còn lại: JPEG, GIF, BMP, TIFF, ICO, WebP), được chia tỷ lệ thành tối đa 1024 pixel ở cạnh dài nhất của nó và được đóng gói thành một atlas hình ảnh. mẫu bộ kết xuất. Một hình ảnh mới bên dưới một phím đã được sử dụng sẽ hiển thị hình ảnh cũ: đưa cho một hình ảnh đã thay đổi một phím mới. `ui.imageSize(c, key, bytes)` là kích thước của nó tính bằng pixel khi được giải mã (null khi nó không giải mã), để tự điều chỉnh kích thước bằng `size`: một trình xem có thể phóng to và xoay.

<a id="avatars"></a>

## Hình đại diện

`ui.avatar(c, name, options)` hiển thị một người hoặc một vật dưới dạng một vòng tròn: hình ảnh của nó được cắt tròn hoặc chữ cái đầu của từ đầu tiên và cuối cùng trong tên của nó trên một màu được chọn từ tên (mỗi tên giữ nguyên màu riêng):

```zig
ui.avatar(c, "Ada Lovelace", .{});
ui.avatar(c, "Linus", .{ .size = 24 });
ui.avatar(c, s.user.name, .{ .image = .{ .key = s.user.id, .bytes = s.user.photo } });
```

`ui.AvatarOptions`: `size` (32 điểm) và `image`, `ui.ImageOptions` được hiển thị thay vì tên viết tắt khi giải mã.

<a id="history-buttons"></a>

## Nút lịch sử

`ui.historyButtons` vẽ các nút quay lại và chuyển tiếp của lịch sử, như trong thanh công cụ của Finder hoặc của trình duyệt, bị tắt ở cuối và trả về nơi cần đến (`ui.HistoryAction`: `.none`, `.back` hoặc `.forward`):

```zig
switch (ui.historyButtons(c, .{ .can_back = s.at > 0, .can_forward = s.at + 1 < s.visited.len })) {
    .back => s.at -= 1,
    .forward => s.at += 1,
    .none => {},
}
```

Với `shortcuts` (bật theo mặc định), họ cũng sử dụng các phím tiến và lùi: Command-[ và Command-] trên macOS, Alt-Left và Alt-Right ở nơi khác. [router](navigation.md) lưu giữ lịch sử như vậy cho bạn.
