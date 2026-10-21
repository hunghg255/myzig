<a id="documents"></a>

# Tài liệu

Nhiều ứng dụng chỉnh sửa tệp: trình soạn thảo văn bản, ứng dụng vẽ, ứng dụng ghi chú. Người dùng mong đợi các ứng dụng như vậy hoạt động giống nhau, vì `NSDocument` của AppKit và `DocumentGroup` của SwiftUI khiến chúng hoạt động trên máy Mac: một cửa sổ trên mỗi tài liệu, menu Tệp có Mới, Mở, Mở Gần đây, Lưu, Lưu dưới dạng và Hoàn nguyên, dấu chấm hoặc dấu hoa thị khi có các thay đổi chưa được lưu, câu hỏi trước khi những thay đổi đó bị mất, tự động lưu, không bị mất gì khi xảy ra sự cố và các tệp mà các ứng dụng khác thay đổi khi chúng đang mở.

`myzig.Documents(T)` thực hiện tất cả những điều này, trên mọi nền tảng, đối với các tài liệu có nội dung là giá trị Zig thuộc loại `T`. Ứng dụng cho biết cách đọc `T` từ byte của tệp và ghi lại cũng như cách tạo cửa sổ tài liệu; myzig thực hiện phần còn lại. Ví dụ `documents` là trình soạn thảo ghi chú được xây dựng trên đó:

```sh
zig build run-documents                    # an untitled note
zig-out/bin/documents notes.md todo.txt    # these files
```

<a id="setting-up"></a>

## Đang thiết lập

```zig
const std = @import("std");
const myzig = @import("myzig");

const Notes = myzig.Documents([]u8);

/// How a note's content is read and written: the file's text.
const Text = struct {
    fn read(gpa: std.mem.Allocator, bytes: []const u8) anyerror![]u8 {
        return gpa.dupe(u8, bytes);
    }
    fn write(_: std.mem.Allocator, content: *const []u8, w: *std.Io.Writer) anyerror!void {
        try w.writeAll(content.*);
    }
    fn free(gpa: std.mem.Allocator, content: []u8) void {
        gpa.free(content);
    }
    fn new(gpa: std.mem.Allocator) anyerror![]u8 {
        return gpa.alloc(u8, 0);
    }
    fn equal(a: *const []u8, b: *const []u8) bool {
        return std.mem.eql(u8, a.*, b.*);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const app = try myzig.App.create(init, .{ .name = "Notes", .file_extensions = &.{ "md", "txt" } });
    defer app.destroy();
    var host: myzig.DocumentHost = .{ .app = app };
    defer host.deinit();
    var editor: Editor = .{ .app = app, .host = &host };

    const data_dir = myzig.path(gpa, .data, app.options.name) catch null;
    defer if (data_dir) |d| gpa.free(d);
    const notes = try Notes.create(gpa, init.io, host.host(), .{
        .types = &.{
            .{ .name = "Markdown Document", .extensions = &.{ "md", "markdown" } },
            .{ .name = "Plain Text", .extensions = &.{"txt"} },
        },
        .read = Text.read,
        .write = Text.write,
        .free = Text.free,
        .new = Text.new,
        .equal = Text.equal,
        .window = .of(&editor, Editor.window),
        .app_name = app.options.name,
        .data_dir = data_dir,
    });
    defer notes.destroy();
    editor.notes = notes;

    app.options.on_open_file = .of(notes, Notes.openFile);
    try app.setMenu(&.{ .{ .role = .app_menu }, host.fileMenu(Notes, notes), .{ .role = .edit_menu }, .{ .role = .window_menu } });
    host.start(Notes, notes); // once the files the app was started with arrived
    try app.run();
}
```

`myzig.DocumentHost` là những tài liệu cần có của ứng dụng: hộp thoại, bộ hẹn giờ, cửa sổ, xem tệp và các tài liệu gần đây. Nó là một cấu trúc nhỏ được tạo từ ứng dụng (`.{ .app = app }`); `host.host()` trao nó cho `Documents.create`. Các tài liệu chỉ đến được ứng dụng thông qua nó, đó là cách các kiểm thử của chúng chạy mà không cần đến nó.

<a id="documents-and-their-content"></a>

## Tài liệu và nội dung của chúng

`Documents(T).create(gpa, io, host, options)` mất:

- `types`: các loại tệp, mỗi loại là `DocumentType` với `name` mà hộp thoại mở hiển thị và `extensions` của nó (không có dấu chấm, chữ thường). Tài liệu mới được lưu với phần mở rộng đầu tiên của loại đầu tiên.
- `read`: tạo `T` từ byte của tệp; một lỗi khiến tập tin không được mở và hiển thị một thông báo.
- `write`: ghi `T` dưới dạng byte của tệp vào `std.Io.Writer`. Việc ghi vào một tệp tạm thời, sau đó thay thế tệp của tài liệu, do đó việc lưu không thành công sẽ không bao giờ để lại một nửa tệp.
- `free`: giải phóng nội dung mà tài liệu không còn giữ nữa (tùy chọn đối với nội dung không sở hữu gì).
- `new`: nội dung của tài liệu mới; `std.mem.zeroes(T)` không có nó.
- `equal`: so sánh hai nội dung. Với nó, việc đặt nội dung bằng với nội dung của tệp sẽ khiến tài liệu không được chỉnh sửa lại, giống như việc hoàn tác lại tài liệu đó.
- `window`: tạo cửa sổ tài liệu (bên dưới).
- `autosave` (`.in_place` hoặc `.off`), `autosave_delay_ms` (5000) và `backup_delay_ms` (1000), được mô tả bên dưới.
- `ask_on_quit`: yêu cầu lưu khi thoát, thay vì giữ lại tài liệu cho lần khởi chạy tiếp theo.
- `no_untitled`: không có tài liệu không có tiêu đề khi ứng dụng khởi động mà không có gì để mở (thay vào đó, một ứng dụng hiển thị cửa sổ bắt đầu).
- `strings`: văn bản của tin nhắn và nút, `DocumentStrings`, bằng tiếng Anh theo mặc định, để dịch.
- `app_name`: tên ứng dụng, trong tiêu đề cửa sổ tắt macOS.
- `data_dir`: thư mục dữ liệu của ứng dụng, nơi lưu giữ các bản sao khôi phục; không ai được giữ mà không có nó.
- `max_size`: tệp lớn nhất được đọc (1 GiB).

Mỗi tài liệu đang mở là một `Notes.Document`. `content` của nó là `T` nó sở hữu. Một view ghi `doc.content` và một chỉnh sửa sẽ cung cấp cho tài liệu một nội dung mới hoặc cho biết nội dung đã thay đổi:

- `doc.set(content)` thay thế nội dung mà tài liệu sở hữu sau đó, giải phóng nội dung cũ bằng `free`. Đây là một bản chỉnh sửa, trừ khi `equal` cho biết đó là nội dung của tệp.
- `doc.changed()` cho biết nội dung có thể thay đổi đã được thay đổi tại chỗ.
- `doc.setEdited(edited)` dành cho một ứng dụng hiểu rõ hơn, từ lịch sử hoàn tác của chính nó: `false` làm cho nội dung được tính là của tệp mà không cần ghi nó.

`doc.state()` trả về `DocumentState` cho tiêu đề và trạng thái của cửa sổ: `name` (tệp hoặc "Không có tiêu đề", "Chưa có tiêu đề 2"...), `path` của nó (trống khi không có tiêu đề) và liệu nó có phải là `edited`, `read_only`, trong `conflict` (một ứng dụng khác đã thay đổi tệp của nó trong khi nó có những thay đổi chưa được lưu) hoặc `deleted`.

Hai trình xử lý trên tài liệu sẽ cho cửa sổ biết điều gì đã xảy ra: `doc.on_reload` chạy khi nội dung được đọc lại từ tệp (được hoàn nguyên hoặc thay đổi bởi một ứng dụng khác), do đó cửa sổ hiển thị nội dung mới; `doc.on_state` chạy sau khi trạng thái thay đổi. `Documents.on_change` chạy sau khi trạng thái của bất kỳ tài liệu nào thay đổi, đối với menu Tệp.

<a id="windows"></a>

## Cửa sổ

Trình tạo cửa sổ tạo cửa sổ của tài liệu, trong giao diện native hoặc bằng một trang và trả về nó. `.of(&state, State.method)` sử dụng phương thức `fn (s: *State, doc: *Notes.Document) !*myzig.Window`:

```zig
const Editor = struct {
    app: *myzig.App,
    host: *myzig.DocumentHost,
    notes: *Notes = undefined,

    fn window(e: *Editor, doc: *Notes.Document) anyerror!*myzig.Window {
        const n = try e.app.gpa.create(Note);
        n.* = .{ .gpa = e.app.gpa, .doc = doc, .editor = .init(e.app.gpa, doc.content) };
        n.win = try e.app.newWindow(.{
            .title = doc.name(),
            .state = myzig.windowState("note"),
            .content = .{ .view = .init(n, Note.view) },
        });
        doc.on_reload = .of(n, Note.reloaded);
        doc.on_state = .of(n, Note.stateChanged);
        try e.host.attach(Notes, e.notes, n.win); // closing the window closes the document
        return n.win;
    }
};
```

Các tài liệu đặt tiêu đề cửa sổ của chúng: tên tài liệu trên macOS và các nơi khác có dấu hoa thị khi được chỉnh sửa và tên ứng dụng ở sau nó (`*Notes.md - Notes`).

`host.attach(Notes, notes, win)` làm cho việc đóng cửa sổ đóng tài liệu của nó; `on_close` của cửa sổ vẫn chạy. Một cửa sổ đóng theo cách đó sẽ giữ lại những thay đổi chưa được lưu của tài liệu trong bản sao khôi phục của nó, do đó không có gì bị mất. Để hỏi trước khi cửa sổ đóng, như AppKit thực hiện, hãy cung cấp cho cửa sổ `on_close_request` để hỏi tài liệu, lưu hoặc loại bỏ các thay đổi của nó và cho biết liệu nó có thể đóng hay không:

```zig
fn mayClose(n: *Note, _: *myzig.Window) bool {
    return !n.doc.edited or n.doc.askToSave();
}
// .on_close_request = .of(n, Note.mayClose),
```

Tệp của tài liệu có thể thay đổi trong khi cửa sổ của nó ở chế độ nền, nơi mà người xem tệp có thể đã bỏ lỡ nó; gọi `notes.windowFocused(win)` và `notes.windowBlurred(win)` từ `on_event` (`.focus`, `.blur`) của cửa sổ để xem tệp khi cửa sổ quay lại và để tự động lưu khi cửa sổ thoát ra, giống như các ứng dụng Mac thường làm.

<a id="opening"></a>

## Khai mạc

- `notes.new()` tạo một tài liệu không có tiêu đề trong cửa sổ của nó.
- `notes.open(path)` mở một tệp hoặc tập trung vào cửa sổ của nó khi nó đã mở. Nó ghi lại các tập tin trong các tài liệu gần đây.
- `notes.openDialog()` hỏi xem nên mở tệp nào, thuộc loại tài liệu nào.
- `notes.openFile(path)` mở một tệp mà hệ thống cấp cho ứng dụng, nếu đó là một trong các loại của nó (`handles`): chuyển tệp đó cho `AppOptions.on_open_file`, tệp này sẽ nhận các tệp thuộc `file_extensions` của ứng dụng từ Finder, Explorer, dòng lệnh và các phiên bản mới hơn của ứng dụng (xem [ứng dụng](app.md)).
- `notes.start(paths)` mở những gì ứng dụng bắt đầu với: tài liệu gặp sự cố hoặc thoát ra với những thay đổi chưa được lưu, sau đó là `paths`, nếu không thì là tài liệu không có tiêu đề. `host.start(Notes, notes)` gọi nó ở lượt đầu tiên của vòng lặp, sau khi các tệp mà ứng dụng được khởi động đã đạt tới `on_open_file`.

`notes.find(path)`, `notes.forWindow(win)` và `notes.focused()` (tài liệu của cửa sổ được đặt tiêu điểm) tra cứu tài liệu.

<a id="saving"></a>

## Đang lưu

- `doc.save()` thực hiện những gì Tệp > Lưu thực hiện: một tài liệu không có tiêu đề hỏi nơi lưu nó, một tài liệu chỉ đọc cho một tệp khác và một tài liệu có tệp mà ứng dụng khác đã thay đổi xem có ghi đè lên nó hay không (Vẫn lưu, Hoàn nguyên, Hủy). Nó trả về false khi tài liệu chưa được lưu.
- `doc.saveAs(null)` hỏi ở đâu; `doc.saveAs(path)` lưu ở đó. Tên không có phần mở rộng sẽ thuộc loại đầu tiên.
- `doc.saveAnyway()` ghi nó ngay cả khi một ứng dụng khác đã thay đổi tệp của nó.
- `doc.revert()` đọc lại tệp của nó, loại bỏ các thay đổi chưa được lưu.
- `doc.duplicate()` mở một bản sao không có tiêu đề ("Bản sao ghi chú") trong một cửa sổ riêng.
- `doc.rename(new_name)` đổi tên tập tin trong thư mục của nó và `doc.moveTo(dir)` di chuyển nó sang thư mục khác.
- `doc.close()` đóng cửa sổ, yêu cầu lưu trước ở nơi cần lưu và trả về false khi cửa sổ vẫn mở.

Lưu không thành công hiển thị thông báo có lỗi và giữ nguyên các thay đổi.

<a id="autosave"></a>

## Tự động lưu

Với `autosave = .in_place` (mặc định), tài liệu có tệp sẽ tự lưu trong giây lát sau khi người dùng ngừng chỉnh sửa (`autosave_delay_ms`), ít nhất 30 giây một lần trong khi họ tiếp tục chỉnh sửa, khi cửa sổ của nó mất tiêu điểm và khi đóng, như các ứng dụng Mac thường làm. Các tài liệu không có tiêu đề, chỉ đọc và bị xóa cũng như các tài liệu xung đột sẽ không tự động lưu: các thay đổi của chúng vẫn ở trong bản sao khôi phục cho đến khi người dùng lưu.

Với `.off`, tài liệu sẽ lưu khi người dùng lưu và việc đóng tài liệu có những thay đổi chưa được lưu sẽ hỏi xem có lưu chúng hay không.

<a id="recovery-copies"></a>

## Bản sao phục hồi

Với `data_dir`, ngay sau khi người dùng ngừng chỉnh sửa (`backup_delay_ms`), một tài liệu có các thay đổi chưa được lưu sẽ ghi chúng vào một bản sao khôi phục, giống như các bản sao lưu của VS Code, do đó xảy ra sự cố, buộc phải thoát hoặc thoát mà tài liệu không bị mất gì. Các bản sao được lưu giữ trong `<data>/Recovery/<kind>`, trong một phiên của phiên bản đang chạy mà một tệp bị khóa cho biết vẫn còn hoạt động: một phiên bản khác của ứng dụng sẽ để nguyên phiên bản đó. Lần khởi chạy tiếp theo (`start`) sẽ mở tài liệu của các phiên không có phiên bản nào được giữ lại, đã chỉnh sửa với những thay đổi chưa được lưu của chúng. Một tập tin được thay đổi trong lúc đó đang bị xung đột; một tập tin đã bị xóa là `deleted` và việc lưu sẽ ghi lại nó.

Việc lưu, hoàn nguyên và loại bỏ sẽ xóa bản sao của tài liệu.

<a id="quitting"></a>

## Đang bỏ cuộc

`notes.quit()` thoát sau khi tài liệu được xử lý và `notes.prepareQuit()` chỉ quản lý chúng và cho biết liệu ứng dụng có thể thoát hay không: tài liệu được lưu tự động được lưu, các tài liệu khác giữ bản sao khôi phục của chúng cho lần khởi chạy tiếp theo hoặc với `ask_on_quit` người dùng sẽ được hỏi về từng tài liệu (nhiều tài liệu cùng một lúc: Lưu tất cả, Không lưu, Hủy). Sử dụng nó từ mục menu Thoát của chính ứng dụng thay vì vai trò thoát đơn giản.

`notes.destroy()` đóng mọi tài liệu mà không cần hỏi: những thay đổi chưa được lưu vẫn nằm trong bản sao khôi phục của chúng.

<a id="files-changed-by-other-apps"></a>

## Các tập tin được thay đổi bởi các ứng dụng khác

Mỗi tài liệu đang mở sẽ xem tệp của nó (`myzig.file_watch`, xem [hệ thống](system.md)). Khi một ứng dụng khác thay đổi nó:

- một tài liệu không có những thay đổi chưa được lưu sẽ đọc lại nó (`on_reload`);
- một tài liệu có các thay đổi chưa được lưu nằm trong `conflict`: các thay đổi của nó vẫn nằm trong bản sao khôi phục, quá trình lưu tự động dừng và lần lưu tiếp theo sẽ hỏi xem có ghi đè lên tệp hay hoàn nguyên về tệp đó hay không. Ví dụ `documents` hiển thị một thanh có Hoàn nguyên và Lưu trong cửa sổ của nó;
- một tập tin được đổi tên hoặc di chuyển trong thư mục của nó sẽ được theo dõi: tài liệu tìm thấy nó theo danh tính của tập tin mà nó đọc hoặc ghi lần cuối (inode của nó, chỉ mục tệp của nó trên Windows và loại của nó, để một tập tin sử dụng lại inode của một nút đã bị xóa sẽ không được sử dụng cho nó), lấy đường dẫn mới của nó, xem nó và ghi lại như gần đây. Điều đó áp dụng cho một tệp mà một ứng dụng khác đã thay thế, khi người chỉnh sửa lưu và đổi tên ngay sau đó: tài liệu biết tệp mà nó đã đọc, không chỉ tệp mà nó đã mở;
- một tập tin đã xóa sẽ để lại tài liệu của nó ở trạng thái mở, `deleted`, và việc lưu sẽ ghi lại nó.

<a id="the-file-menu"></a>

## Trình đơn Tệp

`host.fileMenu(Notes, notes)` trả về menu Tệp: Mới, Mở…, Mở Gần đây (với Menu Xóa), Lưu, Lưu dưới dạng…, Hoàn nguyên (Hoàn nguyên về Đã lưu trên macOS) và Đóng, bằng các phím tắt thông thường và Thoát macOS. Các mục của nó hoạt động trên tài liệu của cửa sổ tập trung. Id vật phẩm của nó bắt đầu bằng `documents.` (`documents.save`). Mở Gần đây liệt kê các tài liệu gần đây của ứng dụng (`myzig.system.recentDocuments`); xây dựng lại menu và đặt nó bằng `app.setMenu` khi chúng thay đổi, từ `notes.on_change`. Xem [menu](menus.md) để biết phần còn lại của thanh menu.

<a id="platform-differences"></a>

## Sự khác biệt về nền tảng

Tài liệu hoạt động giống nhau ở mọi nơi; điều khác biệt là những gì họ sử dụng:

- Tiêu đề cửa sổ chỉ hiển thị tên trên macOS và `*Name - App` ở nơi khác.
- Các tài liệu gần đây cũng đi vào danh sách của hệ thống: Mở Gần đây và Dock trên macOS, Các mục gần đây và danh sách nhảy trên Windows, các tệp được sử dụng gần đây trên Linux.
- Các hộp thoại là ([hệ thống](system.md) liệt kê chúng); trên Windows hộp thoại mở hiện tại sẽ chọn một tệp.
- Trong trình duyệt không có tệp để xem hoặc hộp thoại cung cấp đường dẫn: không thể mở tài liệu ở đó.

<a id="what-is-left-out"></a>

## Những gì còn sót lại

Bên cạnh `NSDocument`, không có phiên bản tài liệu nào (Duyệt tất cả các phiên bản của Mac), không có tài liệu iCloud, không có gói tài liệu (thư mục được hiển thị dưới dạng một tệp) và không có tài liệu bị khóa. Các tài liệu không chia sẻ lịch sử hoàn tác với ứng dụng: một ứng dụng có lịch sử riêng của nó (vùng văn bản) sẽ thông báo các tài liệu có `setEdited`.
