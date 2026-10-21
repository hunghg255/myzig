<a id="text-area"></a>

# Vùng văn bản

`ui.textArea` chỉnh sửa văn bản nhiều dòng: gói hoặc cuộn sang một bên, bằng các phím của nền tảng, con trỏ, bảng tạm, hoàn tác và phương thức nhập. Văn bản của nó là `ui.TextArea` mà ứng dụng lưu giữ, có tài liệu là một sợi dây, do đó, văn bản gồm một trăm nghìn dòng sẽ chỉnh sửa nhanh như một trong mười và chỉ những dòng trong view mới được hiển thị. [Trình chỉnh sửa mã](code-editor.md) được xây dựng trên cùng một phần.

Đối với một dòng văn bản, hãy sử dụng `ui.textField` ([Nhập văn bản](text-input.md)).

```zig
const Notes = struct {
    body: ui.TextArea,

    fn view(s: *Notes, c: *ui.Context) void {
        const r = ui.textArea(c, &s.body, .{ .placeholder = "Notes", .lines = .{ 3, 12 } });
        if (r.changed) s.save();
    }
};

var notes: Notes = .{ .body = .init(gpa, "Hello") };
defer notes.body.deinit();
```

`zig build run-text-buffer` chỉnh sửa 100 000 dòng (`examples/text-buffer`); trang Văn bản của thư viện và `examples/code-editor` cũng hiển thị các vùng văn bản.

<a id="options"></a>

## Tùy chọn

`ui.TextAreaOptions`:

| lĩnh vực | mặc định | ý nghĩa |
|---|---|---|
| `width` | `.fill` | chiều rộng của nó |
| `height` | 140 điểm | chiều cao của nó |
| `lines` | null | phát triển cùng với văn bản của nó từ các hàng `lines[0]` đến `lines[1]`, qua đó nó cuộn, giống như trường thông báo (thay cho `height`) |
| `size` | 14 | kích thước của văn bản |
| `mono` | false | phông chữ đơn cách |
| `wrap` | true | quấn hàng dài; false cuộn chúng sang một bên bằng thanh cuộn |
| `placeholder` | `""` | hiển thị trong khi nó trống |
| `read_only` | false | có thể lựa chọn và sao chép, không thể chỉnh sửa |
| `tab` | false | Tab gõ một tab, thay vì di chuyển tiêu điểm |
| `bare` | false | không có hộp riêng (viền, tô màu, vòng lấy nét): dành cho người soạn thảo điền vào cửa sổ |

Nó trả về `ui.TextAreaResult`: `changed` (văn bản đã thay đổi khung này), `focused`, `first_line` và `last_line`, các dòng mà nó đã tạo, với `lines` (mỗi dòng được tạo và trên cùng của nó tính từ đầu view, khi nó được cuộn, trong bộ nhớ khung) và `row_h`, cho những gì ứng dụng đặt lên các dòng.

<a id="editing"></a>

## Chỉnh sửa

Mọi thứ mà trường văn bản của nền tảng thực hiện:

- Mũi tên, có phím Shift để chọn; bằng các từ có Tùy chọn (macOS) hoặc Kiểm soát (Linux, Windows); đến đầu dòng bằng Command hoặc Home và End; đến cuối văn bản; Trang lên và trang xuống. Lên và xuống giữ cột họ bắt đầu từ.
- Phím lùi và xóa theo ký tự, từ và đến đầu dòng.
- Chọn tất cả, sao chép, cắt và dán qua bảng nhớ tạm của hệ thống (của riêng Người kiểm tra trong các bài kiểm tra).
- Hoàn tác và làm lại. Các ký tự được gõ liên tiếp, trong vòng một giây, là một bước; việc xóa liên tiếp cũng vậy.
- Phương thức nhập (tiếng Trung, tiếng Nhật, tiếng Hàn, phím chết): thành phần được hiển thị được gạch chân trong văn bản cho đến khi được cam kết.
- Con trỏ: một cú nhấp chuột sẽ đặt dấu mũ, một thao tác kéo sẽ chọn, một cú nhấp đúp sẽ chọn một từ và nhấp ba lần vào một dòng, kéo theo từ hoặc dòng từ đó; Shift-click sẽ mở rộng vùng chọn.

Trên macOS các phím đi qua hệ thống nhập văn bản (`NSTextInputClient`), do đó, các ràng buộc phím riêng của người dùng sẽ được áp dụng; ở nơi khác chúng được ánh xạ khi nền tảng liên kết chúng (`src/ui/textarea_keys.zig`).

<a id="the-state"></a>

## Nhà nước

`ui.TextArea` chứa tài liệu (`doc`, `ui.TextDoc`), lựa chọn (`sel`, `ui.TextSel`: `anchor` và `caret` độ lệch byte), thành phần của phương thức nhập và nội dung mà view giữ giữa các khung. Tạo nó bằng `ui.TextArea.init(gpa, text)`, giải phóng nó bằng `deinit()`.

Ứng dụng đọc và thay đổi nó giữa các khung:

| phương pháp | làm |
|---|---|
| `text(gpa)` | toàn bộ văn bản, để tưởng nhớ `gpa` |
| `len()` | chiều dài của nó tính bằng byte |
| `setText(s)` | thay thế văn bản dưới dạng chỉnh sửa, việc hoàn tác sẽ lấy lại |
| `reset(s)` | thay thế nó dưới dạng một tài liệu mới, không có lịch sử (một tệp đã được mở) |
| `select(anchor, caret)`, `collapse(at)` | thiết lập lựa chọn |
| `selectedText(gpa)` | văn bản của lựa chọn |
| `caretLine()` | dòng dấu mũ, từ 0 |
| `insert(s)` | gõ `s` vào dấu mũ, giống như bàn phím |
| `replaceSelection(s, kind)`, `replaceRange(a, b, s, kind)` | thay thế văn bản, như một bước hoàn tác |
| `deleteTo(at)` | xóa lựa chọn hoặc từ dấu mũ tới `at` |
| `undo()`, `redo()` | |
| `takeChanged()` | liệu văn bản có thay đổi kể từ cuộc gọi cuối cùng không |
| `wordAt(i)`, `lineRange(line)` | phạm vi của một từ và một dòng |
| `prevChar`, `nextChar`, `prevWord`, `nextWord` | ranh giới từ một byte |

```zig
if (ui.button(c, "Insert date", .{}).clicked) {
    s.body.insert(c.print("{d}-{d:0>2}-{d:0>2}", .{ y, m, d }));
}
if (ui.button(c, "Clear", .{ .disabled = s.body.len() == 0 }).clicked) s.body.setText("");
```

Độ lệch là byte UTF-8; dấu mũ không bao giờ dừng lại bên trong một ký tự.

<a id="the-document"></a>

## Tài liệu

`ui.TextDoc` là văn bản mà vùng văn bản hoặc trình chỉnh sửa mã chỉnh sửa: một sợi dây, lịch sử hoàn tác của nó và nhật ký các dòng mà mỗi lần chỉnh sửa được thay thế, các view này đọc để cập nhật những gì chúng giữ trên mỗi dòng (các hàng được bao bọc, trạng thái đánh dấu) mà không cần xem phần còn lại của tài liệu. Nó có thể được sử dụng một mình:

```zig
var doc = ui.TextDoc.init(gpa, source);
defer doc.deinit();
doc.replace(0, 0, "// Generated.\n"); // one step of undo
const first = doc.line(gpa, 0);        // without its newline
```

- Số đọc: `len()`, `lineCount()`, `lineStart(i)`, `lineEnd(i)`, `lineOf(offset)`, `byteAt(i)`, `line(gpa, i)`, `slice(gpa, a, b)`, `text(gpa)`.
- Chỉnh sửa: `replace(a, b, s)` và `set(s)` là một bước hoàn tác từng bước; `reset(s)` làm tài liệu mới. Một số chỉnh sửa nối một bước giữa `begin(kind, sel, time)` và `end(sel)`, mỗi chỉnh sửa được thực hiện bằng `edit(a, b, s)`.
- Lịch sử: `undo()` và `redo()` trả về lựa chọn để khôi phục; `canUndo()`, `canRedo()`; `max_undo` (1000 bước) và `group_seconds` (1 giây, trong đó việc gõ sẽ nối với bước trước); `breakGroup()` biến lần gõ tiếp theo thành một bước riêng.
- Thay đổi: `version` bị ảnh hưởng bởi mỗi lần chỉnh sửa. `spliceSeq()` là một số thứ tự, và `splicesSince(seen)` các mối nối kể từ một (mỗi dòng một dòng, nó thay thế bao nhiêu dòng và bao nhiêu dòng được đặt ở đó), hoặc null khi chúng biến mất và người đọc phải đọc lại mọi thứ.

<a id="the-rope"></a>

## Sợi dây

`ui.Rope` là văn bản dưới dạng cây cân bằng (AVL) gồm các đoạn UTF-8, sau sợi dây của Zed: các lá của nó sở hữu tối đa 2 KB mỗi lá và các nhánh của nó đếm số byte và dòng mới bên dưới chúng. Một chỉnh sửa chạm vào các lá mà nó thay đổi và đường dẫn đến chúng, đồng thời điểm bắt đầu của một dòng, một dòng byte và một phạm vi văn bản được tìm thấy trong O(log n). `replace(a, b, s)`, `lineStart(line)`, `lineOf(at)`, `slice(gpa, a, b)`, `chunks(from)` và `lines(gpa, first)` lặp lại nó. Không giống như sợi dây của mygo, cây được thay đổi tại chỗ: thao tác hoàn tác sẽ giữ lại các chỉnh sửa chứ không phải phiên bản.

<a id="large-texts"></a>

## Văn bản lớn

Chỉ các hàng trong view mới được tạo, với một vài hàng ở trên và dưới, vì vậy chi phí của một frame chỉ bằng giá của một màn hình. Các hàng được bao bọc được đo một lần và giữ nguyên trên mỗi dòng (được cập nhật từ các phần nối của tài liệu), do đó thanh cuộn biết chiều cao của văn bản mà không cần đặt nó ra ngoài. Với `wrap = false` các dòng dài cuộn sang một bên và dòng rộng nhất được hiển thị cho đến nay có kích thước thanh cuộn ngang.

Một dòng có kích thước từ 4 KB trở lên (mã được rút gọn, nhật ký không có ngắt, megabyte dữ liệu trên một dòng) được trình bày thành từng phần có tối đa 256 byte và được giữ với các hàng của nó trên các khung (`textlayout_long.zig`): một khung định hình và bao bọc tối đa 32 KB các dòng dài mà nó hiển thị, do đó, một dòng lớn hiển thị các hàng đầu tiên cùng một lúc và phần còn lại trên các khung tiếp theo, thay vì dừng khung hiển thị nó. Một bản chỉnh sửa sẽ giữ lại các phần trước nó, do đó, việc gõ một dòng dài sẽ định hình phần trong đó và các phần sau đó. Của một dòng không ngắt dòng, những gì hiển thị sẽ được vẽ chứ không phải toàn bộ văn bản của nó.

<a id="testing"></a>

## Kiểm tra

```zig
var s: Notes = .{ .body = .init(gpa, "") };
defer s.body.deinit();
var t: ui.Tester = undefined;
try t.init(gpa, .init(&s, Notes.view), .{});
defer t.deinit();
try t.clickText("Notes");     // the placeholder: focuses it
t.typeText("Hello\nworld");
const text = s.body.text(gpa);
defer gpa.free(text);
try std.testing.expectEqualStrings("Hello\nworld", text);
```

Trình kiểm tra nhập các ký tự, phím, tổ hợp phím (`t.shortcut`) và các thao tác của phương thức nhập (`t.textOps`) và giữ một bảng tạm của riêng nó. Xem `src/ui/tests_textarea.zig` và [Thử nghiệm](testing.md).
