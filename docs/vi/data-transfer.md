<a id="clipboard-and-drag-data"></a>

# Clipboard và dữ liệu kéo thả

App chuyển dữ liệu theo hai cách: clipboard (copy và paste) và kéo thả. myzig có:

- clipboard của hệ thống, dưới dạng các hàm gọi đơn giản trong `myzig.clipboard`;
- một mô hình dữ liệu chung cho những gì cú kéo mang theo, trong `myzig.transfer`;
- file được thả lên cửa sổ từ trình quản lý file, qua `WindowOptions.on_drop`;
- cú kéo rời cửa sổ sang app khác (`myzig.systemDrag`), và cú thả từ app khác vào (`myzig.systemDrop`).

Kéo thả *bên trong* một cửa sổ có UI native nằm ở trang [kéo thả](ui/drag-and-drop.md): box kéo được, đích thả, bản xem trước chạy theo con trỏ. Trang này nói về dữ liệu, và về những gì đi sang app khác.

Ví dụ `clipboard` copy cùng một ghi chú dưới dạng chữ, HTML và file. Ví dụ `drag-drop` kéo ghi chú, chữ, URL và file giữa hai cửa sổ và ra các app khác:

```sh
zig build run-clipboard
zig build run-drag-drop
```

<a id="the-clipboard"></a>

## Clipboard

```zig
const myzig = @import("myzig");

myzig.clipboard.writeText("Hello");
if (try myzig.clipboard.readText(gpa)) |s| {
    defer gpa.free(s);
}

try myzig.clipboard.writeHtml(gpa, "<b>Hello</b>", "Hello"); // kèm chữ thuần cho app khác
if (try myzig.clipboard.readHtml(gpa)) |html| gpa.free(html);

try myzig.clipboard.writeImage(gpa, png_bytes); // các byte của một file PNG
if (try myzig.clipboard.readImage(gpa)) |png| gpa.free(png); // ảnh chụp màn hình, ảnh vừa copy, dạng PNG

try myzig.clipboard.writeFiles(gpa, &.{"/Users/ada/report.pdf"}); // như lệnh Copy của trình quản lý file
if (try myzig.clipboard.readFiles(gpa)) |paths| myzig.dialog.freePaths(gpa, paths);

const seen = myzig.clipboard.changeCount(); // đổi mỗi khi có thứ gì ghi vào clipboard
```

- Mỗi hàm đọc trả về null khi clipboard không có loại dữ liệu đó.
- Người gọi giải phóng những gì hàm đọc trả về.
- Một lần ghi thay thế toàn bộ nội dung clipboard trước đó.

| | Chữ | HTML | Ảnh | File |
|---|---|---|---|---|
| macOS | `public.utf8-plain-text` | `public.html` | `public.png`, nếu không có thì TIFF chuyển sang PNG | URL file |
| Linux | chữ của GTK | `text/html` | GdkPixbuf, dạng PNG | `text/uri-list` và `x-special/gnome-copied-files` của GNOME |
| Windows | `CF_UNICODETEXT` | "HTML Format" kèm header chứa các offset | định dạng "PNG" mà trình duyệt ghi, nếu không có thì DIB | `CF_HDROP`, như Explorer copy |
| Trình duyệt | Clipboard API (khi ghi); đọc thì trả về thứ app đã ghi | chỉ chữ | không | không |

- Trên Linux, thứ myzig ghi được phục vụ từ bộ nhớ cho đến khi app khác chiếm clipboard, giống GTK.
- `changeCount` luôn là 0 trong trình duyệt.

**Dữ liệu bất kỳ.** `myzig.clipboard.writeData(&data)` ghi một `myzig.transfer.Data`, mọi item với mọi định dạng của nó. `formats()` liệt kê những gì clipboard đang có, và `read(mime)` đọc một định dạng.

Định dạng do một provider `Lazy` cung cấp chỉ được tạo khi có app paste nó:

- trên Windows, qua delayed rendering (`WM_RENDERFORMAT`);
- trên macOS, qua `NSPasteboardItemDataProvider`;
- trên Linux, khi GTK yêu cầu.

Ô nhập, text area và trình soạn thảo của UI native tự copy, cut và paste chữ qua clipboard. Trong test, `ui.Tester` có clipboard riêng, nên test không bao giờ đụng tới clipboard của người dùng.

<a id="transfer-data"></a>

## Dữ liệu transfer

`myzig.transfer.Data` là thứ mà một cú kéo mang theo. App cũng có thể tự dựng nó cho copy và paste của riêng mình.

- Nó chứa các *item* có thứ tự: một ghi chú, ba file.
- Mỗi item cung cấp nhiều *định dạng* thay thế nhau cho cùng một nội dung: chữ của ghi chú và HTML của nó.
- Định dạng được đặt tên theo MIME type.
- Byte được đưa ngay, hoặc chỉ được tạo khi bên nhận yêu cầu.

```zig
const transfer = myzig.transfer;

const Note = struct {
    title: []const u8,
    body: []const u8,

    /// Tạo một lần cho mỗi data, khi bên nhận đọc nó.
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

`Data.init` sao chép các định dạng và byte được đưa vào. Mỗi biểu diễn là một trong hai:

- `transfer.bytes(format, bytes)`;
- `transfer.lazy(format, provider)`. `transfer.Provider.of(ptr, func)` nhận một method `fn (x: *X, gpa: std.mem.Allocator) anyerror![]u8`.

Một provider lazy chạy nhiều nhất một lần cho mỗi data, khi bên nhận đọc định dạng của nó lần đầu. Vì vậy kéo một tài liệu lớn không tốn gì cho tới khi nó được thả vào nơi cần định dạng đắt đỏ đó.

Thứ mà provider trỏ tới phải sống lâu bằng data. Vì vậy ví dụ `drag-drop` giữ một bản sao của ghi chú như lúc cú kéo bắt đầu.

Các định dạng myzig đặt tên:

- `transfer.text` (`text/plain`), `transfer.html` (`text/html`), `transfer.markdown` (`text/markdown`), `transfer.png` (`image/png`),
- `transfer.uri_list` (`text/uri-list`) và `transfer.file_list`, một URI list chắc chắn chứa file cục bộ: danh sách file của hệ thống,
- MIME type bất kỳ của riêng app, như `application/vnd.example.note+json`.

Các hàm tắt tạo dữ liệu thông dụng:

- `transfer.textData(gpa, s)`: một item chữ;
- `transfer.fileData(gpa, paths)`: mỗi file một item, dạng URL file;
- `transfer.valueData(gpa, T, ptr)`: một giá trị Zig của chính process này.

<a id="reading"></a>

### Đọc

Bên nhận xin các định dạng nó muốn, theo thứ tự ưu tiên của nó:

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
        const files = try data.files(a); // đường dẫn cục bộ
        _ = files;
    }
}
```

- `data.has(format)` cho biết có item nào cung cấp định dạng đó không. `data.formats(a)` liệt kê tất cả, không trùng lặp.
- `data.preferred(wanted)` trả về định dạng đầu tiên trong `wanted` có được cung cấp.
- `data.read(a, format)` trả về byte của nó. Provider lazy chạy ngay lúc này. Byte nằm trong bộ nhớ của `a`: hãy truyền một arena.
- `data.read` gộp các item như cách hệ thống làm: chữ nối bằng xuống dòng, URI list nối bằng CRLF, định dạng khác thì lấy của item đầu tiên.
- `data.files(a)` trả về các đường dẫn cục bộ trong một file list hoặc URI list.
- `transfer.urlOfPath` và `transfer.pathOfUrl` chuyển qua lại giữa đường dẫn và URL `file:`. Trên Windows, `file:///C:/x` là `C:/x`.
- `data.value(T)` trả về giá trị kiểu `T` mà data cung cấp, hoặc null.
- `data.clone(gpa)` tạo một bản sao độc lập. Dùng nó để giữ lại data mà cú thả chỉ đưa cho trong một frame.

<a id="values"></a>

### Giá trị

```zig
if (d.starting) d.offer(try transfer.valueData(gpa, Task, task));
// ở đích thả:
if (t.dropped) |drop| drop.data.value(Task).?.done = true;
```

`transfer.valueData(gpa, T, ptr)` cung cấp một con trỏ tới giá trị Zig dưới định dạng `transfer.value_format(T)` (`application/x-myzig-value;type=...`).

- Nó không bao giờ rời khỏi process: dữ liệu native không bao giờ chứa con trỏ.
- Vì vậy giá trị chỉ tới được các đích thả trong cửa sổ của chính app. Chúng đọc nó bằng `data.value(T)`.
- Chuyển một task từ danh sách này sang danh sách khác chỉ đơn giản như đoạn code trên.

<a id="effects"></a>

### Hiệu ứng thả

Cú kéo cho biết cú thả được phép làm gì với dữ liệu: một `transfer.Effects` gồm `copy`, `move` và `link`. Mặc định chỉ có copy; `.copy_move` cho phép cả hai. Đích thả cho biết nó nhận gì.

`transfer.negotiate` chọn hiệu ứng:

1. hiệu ứng mà phím bổ trợ gợi ý, khi cả hai bên đều cho phép;
2. nếu không thì copy, rồi move, rồi link.

| Phím bổ trợ | macOS | Nơi khác |
|---|---|---|
| copy | Option | Ctrl |
| move | Command | Shift |

Nguồn kéo nhận được `.move` thì xóa giá trị của mình.

<a id="files-dropped-on-windows"></a>

## File thả lên cửa sổ

Cửa sổ có `on_drop` nhận file kéo vào từ Finder, Explorer và các trình quản lý file. Handler nhận đường dẫn tuyệt đối của chúng, chỉ hợp lệ trong lúc gọi:

```zig
const Pane = struct {
    fn droppedFiles(p: *Pane, _: *myzig.Window, paths: []const []const u8) void {
        var data = transfer.fileData(p.gpa, paths) catch return;
        defer data.deinit();
        p.receive(&data); // cùng đoạn code dùng cho cú thả bên trong cửa sổ
    }
};

_ = try app.newWindow(.{
    .title = "Drop here",
    .on_drop = .of(&pane, Pane.droppedFiles),
    .content = .{ .view = .init(&pane, Pane.view) },
});
```

- Đây là `NSDraggingDestination` trên macOS, drag destination của GTK trên Linux và `WM_DROPFILES` trên Windows.
- Theo đường này chỉ có file. Với chữ và các định dạng khác từ app khác, xem [Drops from other apps](#drops-from-other-apps).

<a id="drags-that-leave-the-window"></a>

## Kéo ra khỏi cửa sổ

```zig
const win = try app.newWindow(.{ .title = "Notes", .content = .{ .view = .init(&pane, Pane.view) } });
pane.dnd.external = myzig.systemDrag(win);
```

Trong UI native, cú kéo rời khỏi cửa sổ có thể tiếp tục trong cơ chế kéo thả của hệ thống. Khi đó ghi chú, chữ, URL và file tới được cửa sổ khác và app khác, như trình soạn thảo văn bản hay Explorer. Điều này cần `external` trên `ui.DragDrop` của cửa sổ.

`myzig.systemDrag(win)` trả về cơ chế kéo của hệ thống ở nơi myzig có. Ở nơi khác nó trả về null, và cú kéo chỉ ở trong cửa sổ.

| | Cơ chế kéo của hệ thống |
|---|---|
| Windows | `DoDragDrop` của OLE, với một `IDataObject` |
| macOS | một dragging session của AppKit (`beginDraggingSessionWithItems:`) gồm các pasteboard item |
| Linux | drag của GTK; byte của mỗi định dạng được tạo khi app nhận yêu cầu |

Trên Windows:

- `IDataObject` cung cấp các định dạng của data theo cách app khác đọc: `CF_UNICODETEXT` cho chữ, `CF_HDROP` cho file, "HTML Format", "PNG". Các tên MIME khác trở thành định dạng clipboard được đăng ký.
- Provider lazy chạy khi app nhận yêu cầu.
- Escape thì hủy. Hiệu ứng của cú thả quay về nguồn dưới dạng `finished.effect`.

**Cú kéo kết thúc ra sao.** `finished` của nguồn, một `ui.DragFinished`, cho biết:

| Trường | |
|---|---|
| `effect` | đích thả đã làm gì |
| `canceled` | không có gì được thả |
| `escaped` | người dùng bỏ cú kéo (Escape, `dd.cancel()`), chứ không phải thả ở chỗ không có đích |
| `screen` | nơi cú kéo đã rời cửa sổ kết thúc, tính bằng điểm từ góc trên bên trái màn hình chính; null nếu nó kết thúc trong cửa sổ, tại con trỏ |

Ví dụ, một tab được thả ra ngoài mọi cửa sổ là `canceled and !escaped` tại `screen`. App mở một cửa sổ cho nó ở đó.

<details>
<summary>Tự viết cơ chế kéo</summary>

Một `External` là một cặp gồm context và hàm `start`, nên app có thể gắn cơ chế kéo của riêng mình.

1. `start` được gọi trong frame mà con trỏ rời cửa sổ. Nó không được block.
2. Sau đó, bên ngoài frame, nó kéo data của `DragDrop.active`.
3. Rồi nó gọi `dd.externalEnd(.{ .effect = effect, .escaped = escaped, .screen = point })`, hoặc `dd.externalDone(effect)` khi không biết gì thêm. Hiệu ứng là `.none` khi không có gì nhận.
4. Nó vẽ một frame.

</details>

<a id="drops-from-other-apps"></a>

## Thả từ app khác

```zig
try myzig.systemDrop(window, &state.dnd, &.{"application/x-myapp"});
```

`myzig.systemDrop` cho một cửa sổ có UI native nhận những gì app khác kéo vào, đưa tới các đích thả trong `ui.DragDrop` của nó. Đó là chữ, URL, HTML, file, ảnh và các kiểu bổ sung được liệt kê. Nó hoạt động giống cú kéo bên trong cửa sổ ([kéo thả](ui/drag-and-drop.md)).

- Đây là IDropTarget của OLE trên Windows, drag destination của GTK trên Linux và NSDraggingDestination trên macOS.
- Trên Windows, file không đích nào nhận vẫn tới `on_drop` của cửa sổ.
- Trang web tự nhận cú thả, như trình duyệt.

<a id="platform-differences"></a>

## Khác biệt giữa các nền tảng

| | Clipboard | File thả lên cửa sổ | Kéo ra khỏi cửa sổ |
|---|---|---|---|
| macOS | chữ, HTML, ảnh, file | có | NSDraggingSource |
| Linux | chữ, HTML, ảnh, file | có | drag source của GTK |
| Windows | chữ, HTML, ảnh, file | có | OLE |
| Trình duyệt | chữ | không | không |
