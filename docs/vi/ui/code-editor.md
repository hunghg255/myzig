<a id="code-editor-and-diff-viewer"></a>

# Trình chỉnh sửa mã và trình xem khác biệt

`ui.codeEditor` chỉnh sửa mã nguồn, sau trình soạn thảo của Zed và mygo của `ui/editor`: một dãy số dòng, màu cú pháp, dòng của dấu mũ được điền, thụt lề, dấu ngoặc và dấu ngoặc kép đóng khi chúng được nhập, dấu ngoặc ở dấu mũ khớp, một thanh tìm kiếm cũng thay thế (theo kiểu chữ, toàn bộ từ hoặc biểu thức thông thường), đi đến một dòng và dấu kết thúc mềm hoặc dòng dài cuộn sang một bên. `ui.diffView` hiển thị những thay đổi giữa hai văn bản, hợp nhất hoặc cạnh nhau. Cả hai chỉ xây dựng các dòng trong view, do đó, một tệp gồm 100 000 dòng có chi phí tương đương với một màn hình.

![Trình soạn thảo Zig với tô màu cú pháp và số dòng.](../../images/ui/code-editor.png)

*Trình soạn thảo Zig với tô màu cú pháp và số dòng.*

```zig
const Editor = struct {
    code: ui.CodeEditor,

    fn view(s: *Editor, c: *ui.Context) void {
        _ = ui.codeEditor(c, &s.code, .{});
    }
};

var s: Editor = .{ .code = .init(gpa, source, "main.zig") };
defer s.code.deinit();
```

`zig build run-code-editor` chỉnh sửa các tệp của một số ngôn ngữ, với những thay đổi của chúng so với các tệp như cũ (`examples/code-editor`); headless: `zig-out/bin/code-editor --myzig-snapshot=diff.png --myzig-script="click:Changes"`.

<a id="the-editor"></a>

## Biên tập viên

`ui.CodeEditor.init(gpa, text, name)` tạo trình soạn thảo của `text`, được đánh dấu là ngôn ngữ của tệp `name` (null: không có). Giải phóng nó bằng `deinit()`. Các trường và phương thức của nó:

| | |
|---|---|
| `area` | `ui.TextArea`: văn bản, vùng chọn, hoàn tác ([Vùng văn bản](text-area.md)) |
| `wrap` | các dòng bao bọc theo chiều rộng của trình soạn thảo, thay vì cuộn sang một bên |
| `wrap_column` | với `wrap`, các dòng bao quanh cột này hoặc ở chiều rộng gần hơn (0, mặc định: chiều rộng) |
| `read_only` | có thể lựa chọn, có thể tìm kiếm và có thể sao chép, không thể chỉnh sửa |
| `indent` | `unit` (một cấp độ: `"    "` theo mặc định hoặc `"\t"`) và `tab_size` (4) |
| `find` | trạng thái của thanh tìm kiếm: `open`, `replacing`, `query`, `replacement`, `flags` (`case`, `word`, `regex`), `matches` |
| `setLanguage(name)` | đánh dấu dưới dạng tệp có tên `name` hoặc tên ngôn ngữ (`"zig"`, `"go"`); null không có gì cả |
| `goToLine(line)` | đặt dấu mũ ở đầu dòng (từ 1) và hiển thị nó |
| `openFind(replacing)` | mở thanh tìm kiếm, trên văn bản của vùng chọn |
| `closeBars()` | đóng thanh tìm và đi tới |
| `own_find_bar` | ứng dụng tự vẽ thanh tìm kiếm từ `find`, `query_id`, `replacement_id` và `focus_next` (người chỉnh sửa vẫn tìm, đánh dấu và lấy chìa khóa) |
| `extra` | ứng dụng thêm những gì vào dòng (bên dưới) |
| `background` | nền của văn bản (null: nền sáng hoặc tối mặc định) |
| `guides` | màu cho các dòng ở mỗi cấp độ thụt đầu dòng (null: none) |
| `syntax.colors` | màu của mã thông báo, `ui.SyntaxColors` (null: mặc định) |

Ứng dụng đọc và chỉnh sửa văn bản thông qua `area`, như với vùng văn bản:

```zig
const ta = &s.code.area;
const line = ta.caretLine();
const col = ta.sel.caret - ta.doc.lineStart(line);
ui.text(c, c.print("Ln {d}, Col {d}", .{ line + 1, col + 1 }), .{ .size = 12 });
const modified = ta.doc.canUndo();
```

`ui.CodeEditorOptions`: `width` và `height` (`.fill`), `size` (13), `line_numbers` (true), `current_line` (true: điền vào dòng dấu mũ), `leading` (1,45, chiều cao của dòng là bội số của phông chữ), `weight` (hoặc `weight_value`, 100 đến 900), `family` (đơn cách của chủ đề khi null), `features` (OpenType, vì `ui.TextStyle` lấy chúng) và `placeholder`. Nó trả về chức năng của vùng văn bản (`changed`, `focused`, `first_line`, `last_line`).

<a id="what-the-app-adds-to-the-lines"></a>

## Ứng dụng thêm gì vào dòng

`extra`, `ui.CodeEditor.Extra`, cho phép ứng dụng trang trí các dòng khi chúng được tạo, chỉ cho các dòng trong view: `marks(ctx, c, line, start, str)` trả về hình nền của các lần chạy (`ui.TextMark`s: phạm vi byte của dòng và màu: các lần xuất hiện khác của một từ; `end` của `ui.TextMark.whole` lấp đầy dòng trên view, bên dưới vùng chọn: các khối xung đột), `gutter(ctx, c, line)` màu cho thanh dọc theo cạnh trái của máng xối (các dòng đã thay đổi kể từ khi thực hiện cam kết) và `after(ctx, c, line)` a `ui.TextAfter`, văn bản mờ sau khi kết thúc dòng (lỗi của dòng dấu mũ, một ghi chú). Nhấn vào rãnh sẽ đặt `area.gutter_press` về dòng của nó để ứng dụng đọc và xóa.

```zig
s.code.extra = .{ .ctx = s, .gutter = State.changed, .after = State.blame };
s.code.guides = c.theme.text.alpha(0.08);
```

<a id="keys"></a>

## Phím

Ngoài các phím của vùng văn bản ([Vùng văn bản](text-area.md#editing)); "Mod" là Lệnh trên macOS và Điều khiển ở nơi khác:

| phím | làm |
|---|---|
| Mod+F | tìm thấy |
| Mod+Tùy chọn+F (macOS), Ctrl+H | tìm và thay thế |
| Mod+G, Mod+Shift+G (macOS), F3, Shift+F3 | trận đấu tiếp theo và trận đấu trước đó |
| Ctrl+G | đi đến một dòng |
| Thoát hiểm | đóng các thanh hoặc thu gọn vùng chọn |
| Tab, Shift+Tab | thụt lề và thụt lề các dòng đã chọn (hoặc nhập một cấp độ tại dấu mũ) |
| Mod+], Mod+[ | thụt lề và thụt dòng |
| Mod+/ | nhận xét các dòng ra hoặc quay lại bằng nhận xét dòng của ngôn ngữ (không có gì trong một mà không có) |
| Alt+Z | quấn hàng dài, hay không |
| Mod+C, Mod+X không có lựa chọn | sao chép hoặc cắt dòng dấu mũ |

Khi mã được gõ:

- Enter giữ nguyên mức thụt dòng của dòng, thêm một cấp sau dấu ngoặc mở và đặt dấu ngoặc đóng trên một dòng riêng giữa một cặp.
- Dấu ngoặc và dấu ngoặc kép sẽ đóng khi chúng được nhập, bao bọc vùng chọn khi có một và gõ dấu kết thúc một bước lên trên nó; Backspace lấy một cặp trống.
- Dấu ngoặc ở dấu mũ và đối tác của nó được đánh dấu, đối tác của nó tìm kiếm trong phạm vi 2000 dòng và 64 KB (một vài dòng dài là toàn bộ tệp).

<a id="languages"></a>

## Ngôn ngữ

Trình chỉnh sửa nêu bật những gì view [Markdown](markdown.md) làm nổi bật (Zig, JavaScript và TypeScript, Go, Python, Rust, C và họ của nó, đánh dấu, Markdown, khác biệt và khoảng 60 thứ khác), theo phần mở rộng của tệp hoặc tên ngôn ngữ. `ui.languageFor(name)` tìm ngôn ngữ của tên tệp (null khi không có). Các dòng được mã hóa một dòng tại một thời điểm từ trạng thái mà mỗi dòng bắt đầu (bên trong một nhận xét khối, một chuỗi nhiều dòng) và các trạng thái được giữ trên mỗi dòng: sau khi chỉnh sửa, chỉ các dòng từ nó được mã hóa lại, cho đến khi một dòng bắt đầu ở trạng thái mà nó đã bắt đầu trước đó và chỉ đến mức các dòng được hiển thị. Trong một dòng dài hơn 20 000 byte, 20 000 byte đầu tiên được tô màu và phần còn lại là đơn giản, như Mã VS thực hiện, và màu của một dòng dài được giữ cho đến khi văn bản thay đổi: các dòng dài được trình bày ngân sách của khung tại một thời điểm, dưới dạng [vùng văn bản](text-area.md).

<a id="find-and-replace"></a>

## Tìm và thay thế

Thanh tìm kiếm tìm thấy truy vấn khớp với một dòng tại một thời điểm, dưới dạng văn bản thuần túy (có hoặc không có chữ hoa, toàn bộ từ) hoặc dưới dạng biểu thức chính quy, chỉ được tìm thấy lại khi truy vấn, các tùy chọn của truy vấn hoặc văn bản thay đổi. Thay thế thay thế kết quả phù hợp hiện tại hoặc tất cả chúng; bằng biểu thức chính quy, `$1` đến `$9` sẽ thay thế các nhóm của nó.

Một ứng dụng có thanh tìm kiếm có giao diện riêng đặt `own_find_bar`: trình chỉnh sửa không vẽ gì và thanh của ứng dụng chỉnh sửa `find.query` và `find.replacement`, gọi `find.step` và `find.replaceOne` / `replaceAll`, cung cấp bàn phím cho các trường của nó khi `focus_next` hỏi (`.query`, `.replacement`), giữ lại id của chúng trong `query_id` và `replacement_id` và đóng bằng `closeBars()`; `ui.findBarEscaped(c, id)` cho biết một trường đã lấy Escape.

Các biểu thức chính quy được đối sánh bằng một máy quay lui nhỏ (`src/ui/editor/regex.zig`): hằng và ký tự thoát (`\d \w \s \b` và các phủ định của chúng, `\t \n`), `.`, các lớp (`[a-z]`, `[^…]`), neo (`^ $`), các nhóm (bắt và `(?:…)`), luân phiên và bộ định lượng `* + ? {n} {n,} {n,m}`, tham lam hay lười biếng. Một loạt các bước sẽ ngăn không cho mô hình bệnh lý treo trình soạn thảo: vượt qua nó, một dòng sẽ không khớp.

<a id="the-diff-viewer"></a>

## Trình xem khác biệt

![Bản diff với dòng bị xóa màu đỏ và dòng thêm mới màu xanh.](../../images/ui/diff.png)

*Bản diff với dòng bị xóa màu đỏ và dòng thêm mới màu xanh.*

```zig
var d = try ui.DiffView.init(gpa, before, after, "main.zig");
defer d.deinit();

// In the view:
const st = d.stats();
ui.text(c, c.print("+{d}  −{d}", .{ st.added, st.deleted }), .{ .size = 13 });
if (ui.segmented(c, &.{ "Unified", "Split" }, &s.split)) d.setMode(if (s.split == 1) .split else .unified);
ui.diffView(c, &d, .{});
```

`ui.DiffView` so sánh từng dòng văn bản và giữ nguyên các hàng mà nó hiển thị. `init(gpa, old, new, name)` sao chép cả hai văn bản và đánh dấu chúng là ngôn ngữ của `name`; `set(old, new)` so sánh các văn bản mới (ví dụ về trình soạn thảo làm như vậy khi `area.doc.version` của trình soạn thảo thay đổi).

- `setMode(mode)`: `ui.DiffMode.unified` (các dòng đã xóa chồng lên các dòng đã thêm) hoặc `.split` (các dòng cạnh nhau, các dòng được căn chỉnh).
- `context`: các dòng không thay đổi được hiển thị xung quanh mỗi thay đổi (3). Các lần chạy dài hơn giữa các thay đổi sẽ thu gọn thành một hàng mà một cú nhấp chuột sẽ mở rộng; `expandAll()` và `collapseAll()` thực hiện điều đó trong mỗi lần chạy.
- `stats()`: các dòng `added` và `deleted`.

Mỗi bên có số dòng và màu cú pháp, đồng thời các từ thay đổi trong một dòng đã thay đổi sẽ được đánh dấu, trừ khi hai dòng đó ít giống nhau hơn `ui.DiffViewOptions.min_same` (0,3 byte của chúng giống nhau). Các tùy chọn cũng có `width`, `height`, `size` (13), `colors` (mã thông báo', a `ui.SyntaxColors`), `digits` (của cột số) và `family`, `features` và `weight_value` như trình chỉnh sửa có chúng. `scroll_to`, một hàng, hiển thị hàng đó ở đầu trong khung tiếp theo.

Một số khác biệt trong một cuộn (mỗi tệp dưới tiêu đề, các hàng của ứng dụng nằm giữa chúng) được tạo từ các hàng: sau `dv.build()`, `ui.diffRow(c, &dv, i, opts)` tạo hàng `i` của `dv.rows`, `ui.diffRowHeight(c, opts)` cao, trong danh sách của ứng dụng. Các dòng dài quấn ở đó thành các phần của hàng: `ui.diffWrapColumns(c, &dv, opts, width, split)` là số lượng ký tự mà một bên có chỗ cho, `ui.diffRowParts(&dv, i, cols)` có bao nhiêu phần mà hàng `i` lấy và `ui.diffRowPart(c, &dv, i, opts, part, cols)` tạo thành một (số dòng và ký hiệu ở đầu tiên).

<a id="comparing-texts-yourself"></a>

## Tự so sánh văn bản

`ui.diff` là sự so sánh dưới góc nhìn của người xem, như mygo's `internal/diff`: Thuật toán O(ND) của Myers trong không gian tuyến tính, với giới hạn chi phí của xdiff, giới hạn thời gian trên các văn bản lớn không liên quan ở mức giá chênh lệch có thể không phải là tối thiểu.

```zig
const old_lines = try ui.diff.splitLines(gpa, before);
defer gpa.free(old_lines);
const new_lines = try ui.diff.splitLines(gpa, after);
defer gpa.free(new_lines);
const hunks = try ui.diff.lines(gpa, old_lines, new_lines);
defer gpa.free(hunks);
for (hunks) |h| {
    // Old lines h.a0..h.a1 replaced by new lines h.b0..h.b1.
}
```

- `diff.lines(gpa, a, b)` so sánh chuỗi các dòng, `diff.ints(gpa, a, b)` số nguyên; cả hai đều trả về `diff.Hunk`s (`a0`, `a1`, `b0`, `b1`; `a0 == a1` là phần chèn, `b0 == b1` là xóa).
- `diff.words(gpa, a, b)` so sánh hai dòng từng từ: phạm vi byte của mỗi dòng đã thay đổi, nối qua các khoảng trắng giữa chúng và `same`, có bao nhiêu dòng trong số chúng giữ nguyên, từ 0 đến 1. Giải phóng nó bằng `deinit(gpa)`.

<a id="testing"></a>

## Kiểm tra

Trình chỉnh sửa hoạt động trong Trình kiểm tra như trong một cửa sổ, với bảng nhớ tạm riêng của Trình kiểm tra:

```zig
var s: Editor = .{ .code = .init(gpa, "fn main() {}\n", "main.zig") };
defer s.code.deinit();
var t: ui.Tester = undefined;
try t.init(gpa, .init(&s, Editor.view), .{});
defer t.deinit();
try t.clickText("main");
const mac = @import("builtin").os.tag == .macos;
_ = t.shortcut(if (mac) .{ .key = 'f', .cmd = true } else .{ .key = 'f', .ctrl = true });
try std.testing.expect(s.code.find.open);
```

Xem `src/ui/tests_editor.zig`, `src/ui/tests_diff.zig` và [Thử nghiệm](testing.md).
