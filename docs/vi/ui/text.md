<a id="text"></a>

# Văn bản

`ui.text` hiển thị một chuỗi trong `ui.TextStyle`; `ui.textf` định dạng nó trước tiên vào bộ nhớ của khung:

```zig
ui.text(c, "Large Title", .{ .size = 30, .weight = .bold });
ui.text(c, "Italic, for emphasis.", .{ .italic = true });
ui.text(c, "const mono = \"monospaced, for code\";", .{ .mono = true, .size = 13 });
ui.textf(c, .{ .mono = true, .size = 12 }, "{d:.0}%", .{s.volume * 100});
```

Chuỗi (và các khoảng của văn bản đa dạng thức) được sao chép vào bộ nhớ của khung: bố cục đo chuỗi đó và vẽ nó sau khi view quay trở lại, vì vậy view có thể giải phóng hoặc thay đổi bản sao của chính nó ngay sau `ui.text`, giống như hai khung lần lượt xây dựng lại một danh sách tên. Các chuỗi trong bộ nhớ của khung (`c.print`, `c.alloc()`) cũng được sao chép; đối với văn bản có nhiều megabyte, hãy hiển thị phần đang xem (như `ui.textArea` và `ui.codeEditor` làm).

<a id="style"></a>

## Phong cách

| lĩnh vực | mặc định | nó làm gì |
|---|---|---|
| `size` | 14 | kích thước phông chữ, tính bằng điểm |
| `weight` | `.regular` | `.regular`, `.medium`, `.semibold` hoặc `.bold` |
| `color` | `c.theme.text` | màu của văn bản |
| `wrap` | false | ngắt dòng để vừa với chiều rộng mà cha mẹ đưa ra |
| `mono` | false | phông chữ đơn cách |
| `italic` | false | mặt in nghiêng hoặc mặt nghiêng thông thường ở chỗ không có mặt nào |
| `leading` | 1 | chiều cao của dòng là bội số của phông chữ (1,4 hoặc 1,5 đối với văn xuôi nhẹ nhàng) |
| `family` | null | một nhóm của riêng nó, thay cho chủ đề (`font` hoặc `mono_font`) |
| `features` | `""` | Tính năng OpenType bằng dấu phẩy: `"calt=0,ss01"`, `"-liga"`, `"+zero"` (DirectWrite và HarfBuzz) |
| `weight_value` | 0 | trọng lượng từ 100 đến 900 thay cho `weight`; 0 cho `weight` |

Văn bản không ngắt dòng thì rộng như cũ. Văn bản được bao bọc có chiều rộng mà phần gốc của nó cho phép (`.fill`) và ngắt quãng ở các khoảng trắng trên bao nhiêu dòng tùy ý; trong một hàng có quá ít khoảng trống, nó sẽ nhường chỗ lại, do đó, nhãn bên cạnh nút sẽ bao bọc thay vì đẩy nút ra:

```zig
ui.text(c, "Text wraps to the width its box gets. Resize the window to watch these lines break again.",
    .{ .wrap = true, .color = c.theme.muted, .leading = 1.4 });
```

<a id="headings-and-labels"></a>

## Tiêu đề và nhãn

`ui.heading(c, str)` là tiêu đề in đậm 22 điểm, được công nghệ hỗ trợ đọc làm tiêu đề; `ui.label(c, str)` là văn bản 13 điểm có màu nhạt, dành cho chú thích và thông tin phụ.

```zig
ui.heading(c, "Settings");
ui.label(c, c.print("{d} of {d} left", .{ left, total }));
```

<a id="rich-text"></a>

## Văn bản phong phú

`ui.richText(c, str, spans, style)` vẽ một đoạn có phạm vi byte có giao diện riêng. Mỗi `ui.Span` bao gồm byte `[start, end)` và có thể đặt:

| lĩnh vực | nó làm gì |
|---|---|
| `color` | màu của văn bản (đầu ra ANSI, tô sáng cú pháp) |
| `weight` | trọng lượng khác |
| `italic` | chữ nghiêng |
| `mono` | phông chữ đơn cách (mã nội tuyến), nhỏ hơn một chút để phù hợp |
| `background` | điền vào phía sau văn bản (dấu, mã nội tuyến) |
| `underline`, `strike` | một dòng bên dưới hoặc xuyên qua nó |

```zig
const s = "Spans: bold, italic, code, a link, struck, marked.";
// Spans are copied, as the string is: the frame's memory or the app's.
const spans = c.alloc().dupe(ui.Span, &.{
    .{ .start = 7, .end = 11, .weight = .bold },
    .{ .start = 13, .end = 19, .italic = true },
    .{ .start = 21, .end = 25, .mono = true, .background = c.theme.surface_hover },
    .{ .start = 27, .end = 33, .color = c.theme.accent, .underline = true },
    .{ .start = 35, .end = 41, .strike = true },
    .{ .start = 43, .end = 49, .background = ui.Color.hex(0xffd60a).alpha(0.4) },
}) catch &.{};
ui.richText(c, s, spans, .{ .wrap = true });
```

Các khoảng văn bản chỉ tô màu, tô hoặc gạch chân giữ nhánh tối ưu của văn bản thuần túy; các khoảng thay đổi phông chữ (dạng đậm, chữ nghiêng, dấu cách đơn) định hình đoạn văn dưới dạng các đường chạy, bao bọc chúng. Cả hai đều được lưu trữ trên các khung dưới dạng văn bản thuần túy.

Đối với toàn bộ tài liệu, hãy xem [Markdown](markdown.md), vẽ tiêu đề, danh sách, khối mã và bảng từ văn bản Markdown và [trình soạn thảo văn bản đa dạng thức](rich-text.md) để biết văn bản theo kiểu người dùng.

<a id="selectable-text"></a>

## Văn bản có thể lựa chọn

Hộp có kiểu `selectable = true` cho phép con trỏ chọn văn bản của nó và các văn bản con của nó, dưới dạng terminal hoặc trang: nhấn vào văn bản sẽ bắt đầu lựa chọn, kéo sẽ mở rộng văn bản đó qua các dòng và hộp theo thứ tự đọc và Sao chép (⌘C hoặc Ctrl+C hoặc menu Chỉnh sửa) sao chép văn bản đó, trừ khi trường văn bản được lấy tiêu điểm có lựa chọn riêng. Thao tác kéo để chọn không phải là nhấp chuột.

```zig
ui.column(c, .{ .selectable = true, .gap = 6 });
defer ui.end(c);
for (s.log_lines) |line| ui.text(c, line, .{ .mono = true, .size = 12 });
```

Các điều khiển bên trong hộp có thể chọn (`control = true`, giống như các nút, nút chuyển đổi và liên kết) sẽ giữ cho văn bản của chúng nằm ngoài vùng chọn, do đó, con trỏ sẽ đặt một bàn tay lên khắp chúng.

<a id="fonts"></a>

## Phông chữ

Trên macOS, văn bản được định hình và đo lường bằng CoreText trong phông chữ của hệ thống (SF Pro và SF Mono). Trên Linux và Windows và trên macOS được xây dựng với `-Dportable=true`, myzig tự định hình văn bản từ các phông chữ TrueType và OpenType đã cài đặt (`src/ui/tt/`): các thư mục phông chữ của hệ thống được đọc một lần, mỗi mặt được xác định theo họ, độ đậm, độ nghiêng và chiều rộng của nó, đồng thời được tải khi sử dụng lần đầu, với các phông chữ kerning và phông chữ dự phòng cho các ký tự mà phông chữ thiếu. Các trình duyệt nhận được phông chữ trong gói trang web (xem [trình duyệt](../browsers.md)).

Chủ đề đặt tên cho các họ, null cho hệ thống:

```zig
var t = ui.Theme.light;
t.font = "Inter";
t.mono_font = "JetBrains Mono";
_ = try app.newWindow(.{ .title = "Notes", .theme = t, .content = .{ .view = .init(&state, State.view) } });
```

Một family chưa được cài đặt sẽ quay trở lại hệ thống. Việc khớp một kiểu sẽ chọn khuôn mặt gần nhất với nhóm: in đậm cho `.bold`, in nghiêng cho `.italic`, nếu không thì khuôn mặt thông thường nghiêng khoảng 11 độ.

<a id="how-text-is-drawn"></a>

## Cách văn bản được vẽ

Một dòng văn bản được định hình một lần thành một bố cục (hình tượng, vị trí và phông chữ phù hợp) mà việc đo lường và vẽ tranh chia sẻ. Bố cục được lưu vào bộ nhớ đệm trong khi chúng được sử dụng, do đó, nhãn vẫn giữ nguyên sẽ không mất phí bố trí lại. Glyph được rasterize một lần thành atlas glyph ở tỷ lệ của màn hình và được vẽ dưới dạng các hình tứ giác có kết cấu với mọi hình chữ nhật, đường viền và bóng trong khung, do đó, văn bản thay đổi mọi frame (bộ đếm, đồng hồ) sẽ phải tạo hình và không cần tạo điểm ảnh. Trên macOS nhánh tối ưu chính xác cho ASCII có thể in được (`src/ui/shaper.zig`) bỏ qua CoreText cho hầu hết các nhãn và một kiểm thử chứng minh rằng nó đưa ra văn bản giống như CoreText.

Định hình là của hệ thống: CoreText trên macOS, DirectWrite trên Windows (`src/ui/text_dw*.zig`: phân loại tập lệnh, dự phòng phông chữ, vị trí glyph, rasterization thang độ xám, biểu tượng cảm xúc màu) và HarfBuzz với FreeType và cấu hình phông chữ trên Linux (`src/ui/text_hb*.zig`, `text_ft.zig`, `text_fc.zig`, tất cả đều được tải trong thời gian chạy; biểu tượng cảm xúc màu từ bitmap màu của họ). Văn bản theo nhiều hướng được chia thành các phần chạy bằng thuật toán hai chiều Unicode (`src/ui/bidi.zig`, UAX #9) và được trình bày theo thứ tự trực quan; Dấu mũ di chuyển theo thứ tự logic và các lựa chọn theo hướng hiển thị dưới dạng nhiều phạm vi. Các chữ cái Ả Rập nối lại, các chữ ghép mà một phông chữ đã được sử dụng và các ký tự mà một phông chữ thiếu (CJK, biểu tượng cảm xúc) đều đến từ các phông chữ dự phòng. Văn bản đơn giản có các ký tự được nhìn thấy sẽ có nhánh tối ưu và có cùng bố cục. Trong trường hợp thiếu thư viện (Linux, trình duyệt trần), trình đọc TrueType của chính myzig (`src/ui/tt/`) sẽ định hình văn bản như trước.

<a id="zoom"></a>

## Thu phóng

`c.setZoom(z)` chia tỷ lệ mọi văn bản của cửa sổ theo `z`, từ 0,5 đến 3, như ⌘= và ⌘- của ứng dụng; các hộp có kích thước bằng văn bản của họ sẽ phát triển cùng với nó. Kích thước văn bản của máy tính để bàn thông qua [`ui.preferences.apply`](styling.md#the-desktops-preferences), thiết lập mức thu phóng.

<a id="icons"></a>

## Biểu tượng

`ui.icon` vẽ một ký hiệu theo tên, theo dòng văn bản; xem [nút và những thứ nhỏ nhặt](buttons.md#icons).
