<a id="documents"></a>

# Tài liệu

`myzig.Documents(T)` cho một app chỉnh sửa tệp những gì người dùng chờ đợi ở nó, trên mọi nền tảng. Nó hoạt động như `NSDocument` của AppKit và `DocumentGroup` của SwiftUI trên Mac:

- mỗi tài liệu một cửa sổ;
- menu File có New, Open, Open Recent, Save, Save As và Revert;
- một dấu chấm hoặc dấu sao khi còn thay đổi chưa lưu;
- hỏi lại trước khi các thay đổi đó bị mất;
- tự động lưu, và không mất gì khi app bị crash;
- theo dõi các tệp bị app khác sửa trong lúc đang mở.

Nội dung của một tài liệu là một giá trị Zig kiểu `T`. App cho biết cách đọc một `T` từ các byte của tệp, cách ghi ngược lại, và cách tạo cửa sổ cho tài liệu. Phần còn lại myzig lo. Ví dụ `documents` là một trình soạn ghi chú dựng trên nó:

```sh
zig build run-documents                    # an untitled note
zig-out/bin/documents notes.md todo.txt    # these files
```

<a id="setting-up"></a>

## Thiết lập

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

`myzig.DocumentHost` là những gì tài liệu cần từ app: dialog, timer, cửa sổ, việc theo dõi tệp và danh sách tài liệu gần đây.

- Nó là một struct nhỏ tạo từ app: `.{ .app = app }`.
- `host.host()` đưa nó cho `Documents.create`.
- Tài liệu chỉ chạm tới app qua nó. Nhờ vậy test của chúng chạy được mà không cần app.

<a id="documents-and-their-content"></a>

## Tài liệu và nội dung

`Documents(T).create(gpa, io, host, options)` nhận:

| Tùy chọn | Mặc định | |
|---|---|---|
| `types` | | các loại tệp, mỗi loại là một `DocumentType` (bên dưới) |
| `read` | | tạo một `T` từ các byte của tệp |
| `write` | | ghi một `T` thành các byte của tệp vào một `std.Io.Writer` |
| `free` | | giải phóng nội dung mà tài liệu không còn giữ |
| `new` | `std.mem.zeroes(T)` | nội dung của tài liệu mới |
| `equal` | | so sánh hai nội dung |
| `window` | | tạo cửa sổ cho tài liệu (xem [Cửa sổ](#windows)) |
| `autosave` | `.in_place` | hoặc `.off` (xem [Tự động lưu](#autosave)) |
| `autosave_delay_ms` | 5000 | khoảng ngừng chỉnh sửa trước khi tự động lưu |
| `backup_delay_ms` | 1000 | khoảng ngừng trước khi ghi bản khôi phục |
| `ask_on_quit` | `false` | hỏi lưu khi thoát, thay vì giữ tài liệu cho lần chạy sau |
| `no_untitled` | `false` | không tạo tài liệu chưa đặt tên khi app khởi động mà không có gì để mở |
| `strings` | tiếng Anh | chữ của thông báo và nút, một `DocumentStrings`, để dịch |
| `app_name` | `""` | tên app, trong tiêu đề cửa sổ ngoài macOS |
| `data_dir` | `null` | nơi giữ bản khôi phục; không có thì không giữ |
| `max_size` | 1 GiB | tệp lớn nhất được đọc |

- Một `DocumentType` có `name`, hiện trong dialog mở tệp, và `extensions`: không có dấu chấm, viết thường. Tài liệu mới được lưu với phần mở rộng đầu tiên của loại đầu tiên.
- Khi `read` lỗi, tệp không được mở và một thông báo hiện ra.
- `write` ghi vào một tệp tạm, rồi tệp này thay thế tệp của tài liệu. Lưu thất bại không bao giờ để lại nửa tệp.
- `free` là tùy chọn với nội dung không sở hữu gì.
- Có `equal` thì đặt một nội dung bằng nội dung của tệp sẽ làm tài liệu trở lại chưa sửa, giống như undo về đúng chỗ đó.
- `no_untitled` hợp với app hiện một cửa sổ khởi đầu thay vào đó.

Mỗi tài liệu đang mở là một `Notes.Document`. `content` của nó là `T` mà nó sở hữu. View đọc `doc.content`. Một lần sửa sẽ đưa cho tài liệu nội dung mới, hoặc báo rằng nội dung đã đổi:

| Lời gọi | |
|---|---|
| `doc.set(content)` | thay nội dung, tài liệu sở hữu nội dung mới; giải phóng cái cũ bằng `free`. Đây là một lần sửa, trừ khi `equal` nói nó giống nội dung của tệp |
| `doc.changed()` | một nội dung khả biến đã bị sửa tại chỗ |
| `doc.setEdited(edited)` | cho app tự biết qua lịch sử undo của mình: `false` coi nội dung là của tệp, mà không ghi gì |

`doc.state()` trả về một `DocumentState`, dùng cho tiêu đề và trạng thái của cửa sổ:

- `name`: tên tệp, hoặc "Untitled", "Untitled 2"...;
- `path`: rỗng khi chưa đặt tên;
- `edited`, `read_only`, `deleted`;
- `conflict`: app khác đã sửa tệp trong khi tài liệu còn thay đổi chưa lưu.

Các handler báo cho cửa sổ biết chuyện gì đã xảy ra:

- `doc.on_reload` chạy khi nội dung được đọc lại từ tệp: do revert, hoặc do app khác sửa. Cửa sổ hiện nội dung mới.
- `doc.on_state` chạy sau khi state của tài liệu đổi.
- `Documents.on_change` chạy sau khi state của bất kỳ tài liệu nào đổi, dùng cho menu File.

<a id="windows"></a>

## Cửa sổ

Hàm tạo cửa sổ tạo cửa sổ của một tài liệu, bằng native UI hoặc bằng một trang, và trả về nó. `.of(&state, State.method)` nhận một method `fn (s: *State, doc: *Notes.Document) !*myzig.Window`:

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

Tài liệu tự đặt tiêu đề cho cửa sổ:

- trên macOS: tên tài liệu;
- nơi khác: thêm dấu sao khi đã sửa, và tên app ở sau: `*Notes.md - Notes`.

`host.attach(Notes, notes, win)` làm cho việc đóng cửa sổ cũng đóng tài liệu của nó. `on_close` riêng của cửa sổ vẫn chạy. Cửa sổ đóng theo cách đó giữ các thay đổi chưa lưu trong bản khôi phục, nên không mất gì.

Muốn hỏi trước khi cửa sổ đóng, như AppKit làm, hãy cho cửa sổ một `on_close_request` hỏi tài liệu. Tài liệu lưu hoặc bỏ các thay đổi, rồi cho biết cửa sổ có được đóng không:

```zig
fn mayClose(n: *Note, _: *myzig.Window) bool {
    return !n.doc.edited or n.doc.askToSave();
}
// .on_close_request = .of(n, Note.mayClose),
```

Gọi `notes.windowFocused(win)` và `notes.windowBlurred(win)` từ `on_event` của cửa sổ (`.focus`, `.blur`), như các app Mac:

- khi có focus, tài liệu xem lại tệp của nó, vì việc theo dõi tệp có thể đã bỏ lỡ một thay đổi khi cửa sổ nằm phía sau;
- khi mất focus, nó tự động lưu.

<a id="opening"></a>

## Mở tài liệu

| Lời gọi | |
|---|---|
| `notes.new()` | một tài liệu chưa đặt tên trong cửa sổ của nó |
| `notes.open(path)` | mở một tệp, hoặc focus cửa sổ của nó nếu đã mở; ghi tệp vào danh sách gần đây |
| `notes.openDialog()` | hỏi mở những tệp nào, thuộc các loại của tài liệu |
| `notes.openFile(path)` | mở tệp mà hệ thống đưa cho app, nếu thuộc một loại của nó (`handles`) |
| `notes.start(paths)` | mở những gì app khởi động cùng |
| `notes.find(path)`, `notes.forWindow(win)`, `notes.focused()` | tìm tài liệu; `focused` là của cửa sổ đang có focus |

- Đưa `openFile` cho `AppOptions.on_open_file`. Nó nhận các tệp thuộc `file_extensions` của app từ Finder, Explorer, dòng lệnh và các instance chạy sau của app (xem [App](app.md)).
- `start` mở các tài liệu còn thay đổi chưa lưu sau một lần crash hoặc thoát, rồi đến `paths`, nếu không có gì thì một tài liệu chưa đặt tên.
- `host.start(Notes, notes)` gọi `start` ở vòng lặp đầu tiên, sau khi các tệp app khởi động cùng đã tới `on_open_file`.

<a id="saving"></a>

## Lưu

| Lời gọi | |
|---|---|
| `doc.save()` | việc File > Save làm; false khi tài liệu không được lưu |
| `doc.saveAs(null)`, `doc.saveAs(path)` | hỏi lưu ở đâu, hoặc lưu vào đó |
| `doc.saveAnyway()` | ghi đè dù app khác đã sửa tệp |
| `doc.revert()` | đọc lại tệp, bỏ các thay đổi chưa lưu |
| `doc.duplicate()` | mở một bản sao chưa đặt tên ("Notes copy") trong cửa sổ riêng |
| `doc.rename(new_name)` | đổi tên tệp trong thư mục của nó |
| `doc.moveTo(dir)` | chuyển tệp sang thư mục khác |
| `doc.close()` | đóng cửa sổ, hỏi lưu trước khi cần; false khi cửa sổ vẫn mở |

- `save` với tài liệu chưa đặt tên sẽ hỏi lưu ở đâu.
- `save` với tài liệu chỉ đọc sẽ hỏi một tệp khác.
- `save` với tài liệu có tệp bị app khác sửa sẽ hỏi có ghi đè không: Save Anyway, Revert, Cancel.
- Tên không có phần mở rộng sẽ nhận phần mở rộng của loại đầu tiên.
- Lưu thất bại thì hiện thông báo kèm lỗi và giữ nguyên các thay đổi.

<a id="autosave"></a>

## Tự động lưu

Với `autosave = .in_place`, mặc định, tài liệu có tệp sẽ tự lưu, như các app Mac:

- một lúc sau khi người dùng ngừng chỉnh sửa (`autosave_delay_ms`);
- ít nhất mỗi 30 giây khi người dùng vẫn đang sửa;
- khi cửa sổ mất focus, và khi nó đóng.

Tài liệu chưa đặt tên, chỉ đọc hoặc đã bị xóa không tự động lưu, tài liệu đang conflict cũng vậy. Thay đổi của chúng nằm trong bản khôi phục cho tới khi người dùng lưu.

Với `.off`, tài liệu chỉ lưu khi người dùng lưu. Đóng một tài liệu còn thay đổi chưa lưu sẽ hỏi có lưu không.

<a id="recovery-copies"></a>

## Bản khôi phục

Có `data_dir` thì một lúc sau khi người dùng ngừng sửa (`backup_delay_ms`), tài liệu còn thay đổi chưa lưu sẽ ghi chúng vào một bản khôi phục. Nó giống backup của VS Code. Crash, buộc thoát, hay thoát mà giữ tài liệu đều không làm mất gì.

- Bản khôi phục nằm trong `<data>/Recovery/<kind>`, trong một session của instance đang chạy. Một tệp bị khóa cho biết session còn sống, nên instance khác của app không đụng vào.
- Lần chạy sau (`start`) mở tài liệu của các session không instance nào giữ: ở trạng thái đã sửa, kèm các thay đổi chưa lưu.
- Tệp đã đổi trong lúc đó thì ở trạng thái conflict.
- Tệp đã bị xóa thì là `deleted`, và lưu sẽ ghi lại nó.
- Lưu, revert và bỏ thay đổi đều xóa bản khôi phục của tài liệu.

<a id="quitting"></a>

## Thoát

- `notes.quit()` thoát khi các tài liệu đã được xử lý xong.
- `notes.prepareQuit()` chỉ xử lý chúng, và cho biết app có được thoát không. Dùng nó từ mục Quit riêng của app thay cho role quit thông thường.
- `notes.destroy()` đóng mọi tài liệu mà không hỏi. Thay đổi chưa lưu nằm lại trong bản khôi phục.

Xử lý các tài liệu nghĩa là:

- tài liệu tự động lưu thì được lưu;
- các tài liệu khác giữ bản khôi phục cho lần chạy sau;
- hoặc, với `ask_on_quit`, người dùng được hỏi về từng cái. Nhiều cái một lúc thì có Save All, Don't Save, Cancel.

<a id="files-changed-by-other-apps"></a>

## Tệp bị app khác sửa

Mỗi tài liệu đang mở theo dõi tệp của nó (`myzig.file_watch`, xem [hệ thống](system.md)). Khi app khác sửa tệp:

- Tài liệu không có thay đổi chưa lưu sẽ đọc lại tệp (`on_reload`).
- Tài liệu có thay đổi chưa lưu sẽ ở trạng thái `conflict`. Thay đổi nằm lại trong bản khôi phục, tự động lưu dừng, và lần lưu kế tiếp hỏi ghi đè tệp hay revert về nó. Khi đó ví dụ `documents` hiện một thanh có Revert và Save trong cửa sổ.
- Tệp bị đổi tên hoặc chuyển trong cùng thư mục vẫn được bám theo. Tài liệu nhận đường dẫn mới, theo dõi nó và ghi nó vào danh sách gần đây.
- Tệp bị xóa thì tài liệu vẫn mở, ở trạng thái `deleted`. Lưu sẽ ghi lại tệp.

<details><summary>Cách tìm lại tệp đã bị chuyển</summary>

Tài liệu tìm tệp theo danh tính của tệp nó đọc hoặc ghi gần nhất: inode của tệp (file index trên Windows) và loại của nó. Loại tệp giúp không nhầm một tệp dùng lại inode của tệp đã bị xóa.

Điều này đúng cả với tệp bị app khác thay thế, như cách các editor lưu, rồi đổi tên ngay sau đó. Tài liệu biết tệp mà nó đã đọc, không chỉ tệp nó đã mở.

</details>

<a id="the-file-menu"></a>

## Menu File

`host.fileMenu(Notes, notes)` trả về menu File, với các phím tắt quen thuộc:

- New, Open…, Open Recent (có Clear Menu);
- Save, Save As…, Revert (Revert to Saved trên macOS) và Close;
- Quit, ngoài macOS.

Các mục của nó tác động lên tài liệu của cửa sổ đang có focus. Id của chúng bắt đầu bằng `documents.` (`documents.save`).

Open Recent liệt kê tài liệu gần đây của app (`myzig.system.recentDocuments`). Khi danh sách đổi, từ `notes.on_change`, hãy dựng lại menu và đặt nó bằng `app.setMenu`. Xem [menu](menus.md) cho phần còn lại của thanh menu.

<a id="platform-differences"></a>

## Khác biệt giữa các nền tảng

Tài liệu hoạt động như nhau ở mọi nơi. Khác nhau là những gì chúng dùng:

- Tiêu đề cửa sổ chỉ hiện tên trên macOS, và `*Name - App` ở nơi khác.
- Tài liệu gần đây cũng vào danh sách của hệ thống: Open Recent và Dock trên macOS, Recent items và jump list trên Windows, recently used files trên Linux.
- Dialog là của hệ thống ([hệ thống](system.md) liệt kê chúng). Trên Windows, dialog mở tệp hiện chỉ chọn được một tệp.
- Trong trình duyệt không có tệp để theo dõi, cũng không có dialog trả về đường dẫn. Ở đó không mở được tài liệu.

<a id="what-is-left-out"></a>

## Những gì chưa có

So với `NSDocument`, chưa có:

- phiên bản tài liệu (Browse All Versions của Mac);
- tài liệu iCloud;
- document package (thư mục hiện như một tệp);
- tài liệu bị khóa.

Tài liệu không dùng chung lịch sử undo với app. App có lịch sử riêng, như của một text area, báo cho tài liệu bằng `setEdited`.
