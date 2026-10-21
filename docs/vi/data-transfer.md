<a id="clipboard-and-drag-data"></a>

# Clipboard và kéo dữ liệu

Ứng dụng di chuyển dữ liệu theo hai cách: bảng tạm (sao chép và dán) và kéo và thả. myzig có bảng nhớ tạm của hệ thống dưới dạng các lệnh gọi đơn giản trong `myzig.clipboard`, một mô hình dữ liệu cho những gì các thao tác kéo mang trong `myzig.transfer`, các tệp được thả trên cửa sổ từ trình quản lý tệp thông qua `WindowOptions.on_drop` và trên Windows các thao tác kéo rời khỏi cửa sổ cho các ứng dụng khác (`myzig.systemDrag`).

Kéo và thả *trong* cửa sổ giao diện native (hộp có thể kéo, mục tiêu thả, bản xem trước theo con trỏ) nằm trong [kéo và thả](ui/drag-and-drop.md); trang này trình bày về dữ liệu và những gì được đưa vào các ứng dụng khác.

Ví dụ `clipboard` sao chép cùng một ghi chú dưới dạng văn bản, HTML và tệp, còn ví dụ `drag-drop` kéo ghi chú, văn bản, URL và tệp giữa hai cửa sổ và ra các ứng dụng khác:

```sh
zig build run-clipboard
zig build run-drag-drop
```

<a id="the-clipboard"></a>

## Bảng nhớ tạm

```zig
const myzig = @import("myzig");

myzig.clipboard.writeText("Hello");
if (try myzig.clipboard.readText(gpa)) |s| {
    defer gpa.free(s);
}

try myzig.clipboard.writeHtml(gpa, "<b>Hello</b>", "Hello"); // with plain text for other apps
if (try myzig.clipboard.readHtml(gpa)) |html| gpa.free(html);

try myzig.clipboard.writeImage(gpa, png_bytes); // a PNG file's bytes
if (try myzig.clipboard.readImage(gpa)) |png| gpa.free(png); // a screenshot, a copied image, as PNG

try myzig.clipboard.writeFiles(gpa, &.{"/Users/ada/report.pdf"}); // as a file manager's Copy
if (try myzig.clipboard.readFiles(gpa)) |paths| myzig.dialog.freePaths(gpa, paths);

const seen = myzig.clipboard.changeCount(); // changes whenever anything writes to it
```

Mỗi lần đọc trả về null khi bảng tạm không chứa loại đó; những gì nó trả về người gọi sẽ giải phóng. Việc ghi sẽ thay thế những gì mà bảng tạm đã giữ.

| | văn bản | HTML | hình ảnh | tập tin |
|---|---|---|---|---|
| macOS | `public.utf8-plain-text` | `public.html` | `public.png`, nếu không thì TIFF được chuyển đổi thành PNG | URL tập tin |
| Linux | văn bản GTK | `text/html` | GdkPixbuf, dưới dạng PNG | `text/uri-list` và `x-special/gnome-copied-files` của Gnome |
| Windows | `CF_UNICODETEXT` | "HTML Định dạng" với tiêu đề bù trừ của nó | trình duyệt ghi định dạng "PNG", nếu không thì ghi là DIB | `CF_HDROP`, dưới dạng bản sao của Explorer |
| trình duyệt | API Clipboard (ghi); đọc trả lại những gì ứng dụng đã viết | chỉ văn bản | không | không |

Trên Linux, những gì myzig ghi sẽ được cung cấp từ bộ nhớ cho đến khi một ứng dụng khác lấy bảng nhớ tạm, giống như GTK. `changeCount` là 0 trong trình duyệt.

`myzig.clipboard.writeData(&data)` viết `myzig.transfer.Data`, mọi mục ở mọi định dạng của nó; `formats()` liệt kê những gì bảng tạm chứa và `read(mime)` đọc một cái. Định dạng do nhà cung cấp `Lazy` cung cấp chỉ được tạo khi ứng dụng dán nó: trên Windows thông qua hiển thị bị trì hoãn (`WM_RENDERFORMAT`), trên macOS đến `NSPasteboardItemDataProvider`, trên Linux theo yêu cầu của GTK.

Các trường văn bản, vùng văn bản và trình soạn thảo của Giao diện native tự sao chép, cắt và dán văn bản qua bảng nhớ tạm. Trong các kiểm thử, `ui.Tester` có một khay nhớ tạm riêng nên các kiểm thử không bao giờ chạm vào khay nhớ tạm của người dùng.

<a id="transfer-data"></a>

## Truyền dữ liệu

`myzig.transfer.Data` là nội dung mà thao tác kéo mang lại và là nội dung mà ứng dụng có thể xây dựng để sao chép và dán riêng: *mục* (một ghi chú, ba tệp), mỗi tệp cung cấp *định dạng* thay thế của cùng một nội dung (văn bản của ghi chú và HTML của nó), được đặt tên theo loại MIME, với các byte được cung cấp ngay bây giờ hoặc chỉ được tạo khi người nhận yêu cầu:

```zig
const transfer = myzig.transfer;

const Note = struct {
    title: []const u8,
    body: []const u8,

    /// Made once per data, when a receiver reads it.
    fn json(n: *Note, gpa: std.mem.Allocator) anyerror![]u8 {
        return std.json.Stringify.valueAlloc(gpa, n.*, .{});
    }
};

var data = try transfer.Data.init(gpa, &.{.{ .reps = &.{
    transfer.bytes(transfer.text, note.title),
    transfer.lazy("application/vnd.example.note+json", .of(&note, Note.json)),
} }});
defer data.deinit();
```

`Data.init` sao chép các định dạng và byte được cung cấp. Mỗi biểu diễn là `transfer.bytes(format, bytes)` hoặc `transfer.lazy(format, provider)`, trong đó `transfer.Provider.of(ptr, func)` lấy một phương thức `fn (x: *X, gpa: std.mem.Allocator) anyerror![]u8`. Provider lazy chạy tối đa một lần cho mỗi dữ liệu, khi người nhận đọc định dạng của nó lần đầu tiên, do đó, việc kéo một tài liệu lớn sẽ không mất phí gì cho đến khi nó rơi xuống nơi muốn có định dạng đắt tiền. Những gì nó trỏ đến phải tồn tại lâu dài như dữ liệu; ví dụ `drag-drop` giữ một bản sao của ghi chú như khi quá trình kéo bắt đầu.

Tên định dạng myzig:

- `transfer.text` (`text/plain`), `transfer.html` (`text/html`), `transfer.markdown` (`text/markdown`), `transfer.png` (`image/png`),
- `transfer.uri_list` (`text/uri-list`) và `transfer.file_list`, danh sách URI được biết là chứa các tệp cục bộ: danh sách tệp của hệ thống,
- bất kỳ loại MIME nào của ứng dụng, chẳng hạn như `application/vnd.example.note+json`.

Các phím tắt tạo dữ liệu chung: `transfer.textData(gpa, s)` (một mục văn bản), `transfer.fileData(gpa, paths)` (một mục trên mỗi tệp, dưới dạng URL tệp) và `transfer.valueData(gpa, T, ptr)`, giá trị Zig của quy trình này.

<a id="reading"></a>

### Đọc

Người nhận yêu cầu các định dạng mà họ muốn theo thứ tự ưu tiên:

```zig
const wanted = [_][]const u8{ note_format, transfer.file_list, transfer.uri_list, transfer.text };

fn receive(data: *transfer.Data, a: std.mem.Allocator) !void {
    const f = data.preferred(&wanted) orelse return;
    if (std.mem.eql(u8, f, note_format)) {
        const bytes = try data.read(a, f);
        const note = try std.json.parseFromSliceLeaky(Note, a, bytes, .{});
        _ = note;
    } else if (std.mem.eql(u8, f, transfer.text)) {
        const s = try data.read(a, f);
        _ = s;
    } else {
        const files = try data.files(a); // local paths
        _ = files;
    }
}
```

- `data.has(format)` cho biết liệu một mục có cung cấp định dạng hay không và `data.formats(a)` liệt kê tất cả các mục đó mà không lặp lại.
- `data.preferred(wanted)` trả về giá trị đầu tiên trong số `wanted` được cung cấp.
- `data.read(a, format)` trả về byte của nó, các mục được kết hợp lại khi hệ thống chuyển: văn bản được nối bởi dòng mới, danh sách URI theo CRLF, các định dạng khác của mục đầu tiên. Các provider lazy chạy ngay bây giờ. Các byte nằm trong bộ nhớ của `a`: cung cấp cho nó một arena.
- `data.files(a)` trả về đường dẫn cục bộ của danh sách tệp hoặc danh sách URI. `transfer.urlOfPath` và `transfer.pathOfUrl` chuyển đổi giữa các đường dẫn và `file:` URL (`file:///C:/x` là `C:/x` trên Windows).
- `data.value(T)` trả về giá trị của loại `T` dữ liệu cung cấp hoặc null.
- `data.clone(gpa)` tạo một bản sao độc lập để giữ cho dữ liệu được chuyển giao cho một frame duy nhất.

<a id="values"></a>

### Giá trị

`transfer.valueData(gpa, T, ptr)` cung cấp một con trỏ tới giá trị Zig theo định dạng `transfer.value_format(T)` (`application/x-myzig-value;type=...`). Nó không bao giờ rời khỏi quy trình: dữ liệu gốc không bao giờ chứa con trỏ, vì vậy các giá trị chỉ tiếp cận các mục tiêu thả của cửa sổ riêng của ứng dụng, được đọc chúng bằng `data.value(T)`. Di chuyển một nhiệm vụ từ danh sách này sang danh sách khác thật đơn giản:

```zig
if (d.starting) d.offer(try transfer.valueData(gpa, Task, task));
// in the target:
if (t.dropped) |drop| drop.data.value(Task).?.done = true;
```

<a id="effects"></a>

### Hiệu ứng

Thao tác kéo cho biết thao tác thả có thể làm gì với dữ liệu của nó, `transfer.Effects` trong số `copy`, `move` và `link` (chỉ sao chép theo mặc định; `.copy_move` cả hai) và mục tiêu cho biết những gì nó chấp nhận. `transfer.negotiate` chọn hiệu ứng: hiệu ứng mà các phím bổ trợ gợi ý khi cả hai đầu đều cho phép (Tùy chọn sao chép và Lệnh di chuyển trên macOS; Ctrl sao chép và Shift di chuyển đi nơi khác), nếu không thì sao chép, sau đó di chuyển, rồi liên kết. Một nguồn tin cho biết `.move` đã xóa giá trị của nó.

<a id="files-dropped-on-windows"></a>

## Tập tin bị rơi trên windows

Một cửa sổ có `on_drop` chấp nhận các tệp được kéo vào đó từ Finder, Explorer và trình quản lý tệp. Trình xử lý nhận được đường dẫn tuyệt đối của chúng, hợp lệ trong suốt cuộc gọi:

```zig
const Pane = struct {
    fn droppedFiles(p: *Pane, _: *myzig.Window, paths: []const []const u8) void {
        var data = transfer.fileData(p.gpa, paths) catch return;
        defer data.deinit();
        p.receive(&data); // the same code as for drops within the window
    }
};

_ = try app.newWindow(.{
    .title = "Drop here",
    .on_drop = .of(&pane, Pane.droppedFiles),
    .content = .{ .view = .init(&pane, Pane.view) },
});
```

Đó là `NSDraggingDestination` trên macOS, đích kéo của GTK trên Linux và `WM_DROPFILES` trên Windows. Cho đến nay chỉ có các tệp được chấp nhận theo cách này; văn bản và các định dạng khác được kéo từ các ứng dụng khác thì không.

<a id="drags-that-leave-the-window"></a>

## Kéo rời khỏi cửa sổ

Trong giao diện native, thao tác kéo rời khỏi cửa sổ của nó sẽ tiếp tục trong quá trình kéo và thả của hệ thống, để ghi chú, văn bản, URL và tệp đến được các cửa sổ và ứng dụng khác (trình soạn thảo văn bản, Explorer), khi `ui.DragDrop` của cửa sổ có `external`:

```zig
const win = try app.newWindow(.{ .title = "Notes", .content = .{ .view = .init(&pane, Pane.view) } });
pane.dnd.external = myzig.systemDrag(win);
```

`myzig.systemDrag(win)` trả về lực kéo của hệ thống trong đó myzig có một và null ở nơi khác, nơi các lực kéo nằm trong cửa sổ của chúng:

- **Windows**: `DoDragDrop` của OLE, với `IDataObject` cung cấp định dạng dữ liệu khi các ứng dụng khác đọc chúng: `CF_UNICODETEXT` cho văn bản, `CF_HDROP` cho tệp, "HTML Định dạng", "PNG" và các tên MIME khác dưới dạng định dạng bảng nhớ tạm đã đăng ký. Provider lazy chạy khi ứng dụng nhận yêu cầu. Nhấn Escape để hủy; hiệu ứng rơi sẽ quay trở lại nguồn dưới dạng `finished.effect`.
- **macOS**: phiên kéo AppKit (`beginDraggingSessionWithItems:`) của các mục trong bảng dán; **Linux**: Lực kéo của GTK, byte của mỗi định dạng được tạo khi ứng dụng được thả xuống yêu cầu.

`finished` (a `ui.DragFinished`) của nguồn cho biết sự việc đã kết thúc như thế nào: `effect` là điều mục tiêu đã làm, `canceled` không có gì giảm xuống, `escaped` rằng người dùng đã kéo lên (Escape, `dd.cancel()`) thay vì để nó đi qua không có mục tiêu và `screen` khi lực kéo rời khỏi cửa sổ kết thúc, theo các điểm từ màn hình chính trên cùng bên trái (null cho cái kết thúc ở cửa sổ, ở con trỏ). Ví dụ: một tab buông ra bên ngoài mọi cửa sổ là `canceled and !escaped` tại `screen`: ứng dụng sẽ mở một cửa sổ cho tab đó ở đó.

`External` là một cặp ngữ cảnh và hàm `start`, do đó, một ứng dụng có thể tự thực hiện thao tác kéo: `start` được gọi trong khung, con trỏ rời khỏi cửa sổ và không được chặn; sau đó, bên ngoài khung, nó kéo dữ liệu của `DragDrop.active`, sau đó gọi `dd.externalEnd(.{ .effect = effect, .escaped = escaped, .screen = point })` (`dd.externalDone(effect)` khi nó không biết gì nữa; `.none` khi không có gì lấy nó) và vẽ một khung.

<a id="drops-from-other-apps"></a>

## Giảm từ các ứng dụng khác

```zig
try myzig.systemDrop(window, &state.dnd, &.{"application/x-myapp"});
```

`myzig.systemDrop` tạo một cửa sổ giao diện native lấy những gì các ứng dụng khác kéo vào đó (văn bản, URL, HTML, tệp, hình ảnh và các loại bổ sung được đặt tên) vào mục tiêu `ui.DragDrop` của nó, vì các thao tác kéo trong cửa sổ là ([kéo và thả](ui/drag-and-drop.md)): IDropTarget của OLE trên Windows, đích kéo của GTK trên Linux, NSDragDestination trên macOS. Các trang tự giảm xuống, giống như trình duyệt.

<a id="platform-differences"></a>

## Sự khác biệt về nền tảng

| | bìa kẹp hồ sơ | tập tin bị rơi trên windows | kéo ra khỏi cửa sổ |
|---|---|---|---|
| macOS | văn bản, HTML, hình ảnh, tập tin | vâng | NSKéoNguồn |
| Linux | văn bản, HTML, hình ảnh, tập tin | vâng | Nguồn kéo của GTK |
| Windows | văn bản, HTML, hình ảnh, tập tin | vâng | OLE |
| trình duyệt | văn bản | không | không |
