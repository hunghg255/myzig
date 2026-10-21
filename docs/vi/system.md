<a id="the-system-around-the-app"></a>

# Hệ thống xung quanh ứng dụng

Ngoài cửa sổ, một ứng dụng sẽ giao tiếp với máy tính để bàn mà nó chạy trên đó: nó yêu cầu người dùng cung cấp các tệp, mở liên kết trong trình duyệt, giữ dữ liệu ở nơi mỗi hệ thống muốn, theo dõi giao diện của hệ thống, lưu trữ mật khẩu trong móc khóa của hệ thống, ghi lại các tài liệu gần đây, mở khi đăng nhập, giữ cho máy tính luôn hoạt động trong khi hoạt động và xem các tệp mà các ứng dụng khác thay đổi. Mỗi lệnh gọi này là một lệnh gọi thực hiện đúng trên macOS, Linux và Windows, cũng như một lệnh gọi nào đó hợp lý (hoặc `error.Unsupported`) trong trình duyệt.

Các cuộc gọi chạy theo phương thức (hộp thoại) hoặc chạm vào hệ thống cửa sổ sẽ chạy trên luồng chính, từ một cú nhấp chuột vào menu, một phương thức liên kết hoặc một dạng xem; xem [ứng dụng](app.md) để biết luồng.

<a id="dialogs"></a>

## Hộp thoại

`myzig.dialog` có bảng điều khiển và hộp thông báo mở và lưu của hệ thống. Họ chặn cho đến khi người dùng trả lời và trả lời:

```zig
const myzig = @import("myzig");

fn importImages(gpa: std.mem.Allocator) !void {
    const paths = (try myzig.dialog.open(gpa, .{
        .title = "Import",
        .button = "Import",
        .multiple = true,
        .extensions = &.{ "png", "jpg" },
    })) orelse return; // canceled
    defer myzig.dialog.freePaths(gpa, paths);
    for (paths) |p| std.log.info("import {s}", .{p});
}

fn exportAs(gpa: std.mem.Allocator) !void {
    const path = (try myzig.dialog.save(gpa, .{ .name = "Untitled.md", .extensions = &.{"md"} })) orelse return;
    defer gpa.free(path);
    // write the file at `path`
}
```

`dialog.OpenOptions` có `title`, `button` (nhãn của nút mặc định), `message`, `directory` (nơi bảng điều khiển bắt đầu), `files` và `directories` (có thể chọn nội dung nào; chỉ các thư mục có `.files = false, .directories = true`), `multiple`, `extensions` (không có dấu chấm) và `show_hidden`. `dialog.SaveOptions` có `title`, `button`, `message`, `directory`, `name` (tên tệp bắt đầu bằng), `extensions`, `show_hidden` và `create_directories`.

Hộp thông báo trả về chỉ mục của nút được nhấn, nút đầu tiên là mặc định và hộp kiểm của nó có được chọn hay không:

```zig
const r = myzig.dialog.message(.{
    .title = "Delete the note?",
    .detail = "You can't undo this action.",
    .kind = .warning, // .info, .warning, .critical
    .buttons = &.{ "Delete", "Cancel" },
    .checkbox = "Don't ask again",
});
if (r.button == 0) deleteNote();
if (r.checked) prefs.ask_before_delete = false;
```

| | macOS | Linux | Windows | trình duyệt |
|---|---|---|---|---|
| mở, lưu | `NSOpenPanel`, `NSSavePanel` | Trình chọn tệp gốc của GTK (có cổng thông tin dành cho máy tính để bàn) | hộp thoại tập tin chung | `error.Unsupported` |
| tin nhắn | `NSAlert`, với hộp kiểm | Hộp thoại tin nhắn của GTK | một hộp tin nhắn | `alert` cho một nút, nếu không thì `confirm` |

Trên Windows hộp thoại đang mở hiện tại chọn một tệp duy nhất và chưa có hộp thoại nào lọc theo `extensions`. Giao diện native cũng có các hộp thoại riêng, được vẽ bên trong cửa sổ: xem [lớp phủ](ui/overlays.md).

<a id="opening-things-in-other-apps"></a>

## Mở mọi thứ trong các ứng dụng khác

`myzig.shell` cung cấp URL và tệp cho ứng dụng mà người dùng đã chọn cho chúng:

```zig
_ = myzig.shell.openUrl("https://ziglang.org"); // any scheme: https:, mailto:, ...
_ = myzig.shell.openPath("/Users/ada/report.pdf"); // in its default app
myzig.shell.showInFolder("/Users/ada/report.pdf"); // in Finder or the file manager
_ = myzig.shell.trash("/Users/ada/old.txt"); // to the Trash
myzig.shell.beep(); // the system's alert sound
```

`openUrl`, `openPath` và `trash` trả về xem họ có làm điều đó hay không. `showInFolder` chọn tệp trong cửa sổ Finder trên macOS và mở thư mục của nó ở nơi khác. Trên Linux họ chạy `xdg-open`; trên Windows động từ mở của shell. `trash` hoạt động trên macOS (Thùng rác) và Windows (thùng rác, thông qua `IFileOperation`; đường dẫn tương đối là thư mục làm việc) và trả về false ở nơi khác cho đến nay; `beep` hoạt động trên macOS và trong trình duyệt. Trong trình duyệt `openUrl` mở một tab mà trình duyệt có thể chặn bên ngoài một cú nhấp chuột.

`trash` không bao giờ xóa vĩnh viễn: nếu mục đó không thể chuyển vào thùng rác, nó sẽ trả về false và để mục đó ở nguyên đó. Trên Windows là một mục quá lớn đối với thùng rác hoặc trên một ổ đĩa không có thùng rác, vì các chia sẻ mạng và nhiều ổ đĩa di động, mà Windows sẽ xóa mà không cần hỏi.

<a id="the-app-s-directories"></a>

## Thư mục của ứng dụng

`myzig.appPath` cung cấp các thư mục riêng của ứng dụng, nơi mỗi hệ thống muốn có chúng và tạo chúng (tất cả trừ `temp`) khi chúng bị thiếu:

```zig
const logs = try myzig.appPath(gpa, .logs, "Notes");
defer gpa.free(logs);
```

| `myzig.AppDir` | macOS | Linux | Windows |
|---|---|---|---|
| `data` | `~/Library/Application Support/Name` | `$XDG_DATA_HOME/Name` (`~/.local/share/Name`) | `%APPDATA%\Name` |
| `config` | `~/Library/Application Support/Name` | `$XDG_CONFIG_HOME/Name` (`~/.config/Name`) | `%APPDATA%\Name` |
| `cache` | `~/Library/Caches/Name` | `$XDG_CACHE_HOME/Name` (`~/.cache/Name`) | `%LOCALAPPDATA%\Name\Cache` |
| `logs` | `~/Library/Logs/Name` | `$XDG_STATE_HOME/Name/logs` (`~/.local/state/Name/logs`) | `%LOCALAPPDATA%\Name\Logs` |
| `temp` | `$TMPDIR` | `$TMPDIR` hoặc `/tmp` | `%TEMP%` |

Các biến XDG không phải là đường dẫn tuyệt đối sẽ bị bỏ qua, như thông số kỹ thuật cho biết.

`myzig.path` cũng biết các thư mục tiêu chuẩn của người dùng. Phải mất `myzig.Directory`: `data` và `cache` (của riêng ứng dụng, được tạo), `home`, `documents`, `downloads`, `desktop` và `temp`:

```zig
const downloads = try myzig.path(gpa, .downloads, app.options.name);
defer gpa.free(downloads);
```

Trong trình duyệt, cả hai đều trả lời bằng các thư mục của hệ thống tệp WASI trong bộ nhớ mà trang lưu trữ (`/home`, `/tmp`, `/home/.local/share/Name`), tồn tại trong suốt thời gian của trang.

<a id="appearance"></a>

## Ngoại hình

`myzig.isDark()` cho biết liệu hệ thống có hiển thị chế độ tối hay không và `myzig.accentColor()` trả về màu nhấn mà người dùng đã chọn, như sRGB `[3]f32`. Giao diện native tự tuân theo cả hai (xem [kiểu dáng](ui/styling.md)); đây là những ứng dụng vẽ hoặc chọn màu của riêng chúng.

- macOS: giao diện hiệu quả của ứng dụng và `controlAccentColor`.
- Linux: tối khi `GTK_THEME` đặt tên cho chủ đề tối; giọng là một màu xanh cố định.
- Windows: cài đặt "ứng dụng sử dụng giao diện sáng".
- Trình duyệt: `prefers-color-scheme` hoặc `data-myzig-theme="dark"` hoặc `"light"` của chính trang đó trên phần tử gốc của nó.

<a id="locale-and-languages"></a>

## Địa điểm và ngôn ngữ

`myzig.system` trả lời bằng ngôn ngữ và ngôn ngữ của người dùng, đối với các ứng dụng tự định dạng hoặc dịch ([i18n](i18n.md) thực hiện cả hai):

```zig
const tag = try myzig.system.locale(gpa); // "en-US", BCP 47
defer gpa.free(tag);
const region = try myzig.system.region(gpa); // "US"
defer gpa.free(region);
const langs = try myzig.system.languages(gpa); // most preferred first
defer myzig.system.freeList(gpa, langs);
```

Trên Linux chúng đến từ `LANGUAGE`, `LC_ALL`, `LC_MESSAGES`, `LC_TIME` và `LANG`, được chuyển thành thẻ BCP 47; trong trình duyệt từ `navigator.languages`.

<a id="recent-documents"></a>

## Tài liệu gần đây

```zig
try myzig.system.addRecentDocument(app, "/Users/ada/Notes.md");
const recent = try myzig.system.recentDocuments(app);
defer myzig.system.freeList(app.gpa, recent);
myzig.system.clearRecentDocuments(app);
```

`addRecentDocument` ghi lại một tệp trong danh sách của hệ thống (menu Mở gần đây và menu Dock của macOS, Windows' Các mục gần đây và danh sách nhảy của ứng dụng, các tệp được sử dụng gần đây của Linux) và trong chính ứng dụng, được lưu giữ trong `recent-documents.txt` trong thư mục dữ liệu của nó. `recentDocuments` trả về danh sách riêng của ứng dụng, mới nhất đầu tiên, nhiều nhất là mười, chỉ những tệp vẫn tồn tại. `clearRecentDocuments` quên chúng; trên Linux, các tệp gần đây khác của người dùng vẫn được giữ nguyên. [Tài liệu](documents.md) ghi lại những gì họ mở và hiển thị danh sách trong menu Tệp của họ.

Trên Windows, `system.setJumpList(app, tasks)` đặt Nhiệm vụ trong danh sách nhảy của ứng dụng (nhấp chuột phải vào nút trên thanh tác vụ), mỗi danh sách `JumpTask` có `title`, `description`, `path`, `args` và một biểu tượng. Windows giữ danh sách sau khi thoát ứng dụng: đặt danh sách một lần khi khởi động. Tác vụ tốt nhất nên chạy URL của lược đồ riêng của ứng dụng, đạt tới `on_open_url`. Ở nơi khác nó không làm gì cả.

<a id="open-at-login"></a>

## Mở khi đăng nhập

```zig
try myzig.system.setOpenAtLogin(app, true);
const on = myzig.system.openAtLogin(app);
if (myzig.system.wasOpenedAtLogin(app)) {
    // started by the system: stay in the tray, show no window
}
```

Ứng dụng sẽ mở khi đăng nhập với mục Chạy trên Windows, mục tự khởi động XDG trên Linux và mục đăng nhập trên macOS 13 trở lên (đối với các ứng dụng đi kèm). `wasOpenedAtLogin` phân biệt lần khởi chạy như vậy trên Windows và Linux, trong đó mục nhập vượt qua `--myzig-login`.

<a id="url-schemes-and-file-types"></a>

## Lược đồ URL và loại tệp

Ứng dụng sẽ mở các URL riêng (`notes://open?id=4`) và các tệp thuộc loại của nó khi hệ thống chuyển giao chúng, thông qua `AppOptions.on_open_url` và `on_open_file` (xem [ứng dụng](app.md) để biết trình xử lý và `url_schemes` và `file_extensions` để đặt tên cho chúng):

```zig
try myzig.system.registerUrlScheme(app, "notes"); // cheap: at every launch
if (!myzig.system.isUrlSchemeRegistered(app, "notes")) {}
try myzig.system.unregisterUrlScheme(app, "notes");
try myzig.system.registerFileType(app, "md", "Markdown Document");
try myzig.system.unregisterFileType(app, "md");
```

`registerUrlScheme` đặt ứng dụng làm trình xử lý lược đồ của người dùng: trong sổ đăng ký trên Windows, trong mục nhập trên máy tính để bàn được đặt làm mặc định trong `mimeapps.list` trên Linux (như `xdg-mime default` thực hiện) và trên macOS làm trình xử lý mặc định của lược đồ mà `Info.plist` của gói phải khai báo ([phân phối](distribution.md) viết nó). `unregisterUrlScheme` hoàn tác nó trên Windows và Linux. `registerFileType` thêm ứng dụng vào danh sách Mở bằng của tiện ích mở rộng tệp trên Windows; macOS khai báo loại tệp trong gói và Linux trong mục nhập trên màn hình của ứng dụng, nơi nó trả về `error.Unsupported`.

<a id="keeping-the-system-awake"></a>

## Giữ cho hệ thống luôn tỉnh táo

```zig
const awake = try myzig.system.preventSleep(app, "Exporting the video", .system);
defer awake.release();
```

`.system` giữ cho máy tính không ở chế độ ngủ khi không hoạt động (màn hình vẫn có thể tắt); `.display` vẫn bật màn hình. Nó sử dụng các yêu cầu nguồn điện trên Windows, xác nhận nguồn điện trên macOS và trên Linux, sự ức chế của trình bảo vệ màn hình đối với bus phiên, giúp cả hai luôn hoạt động.

<a id="secrets"></a>

## Bí mật

`myzig.secrets` lưu trữ mật khẩu và mã thông báo được hệ thống, dịch vụ và tài khoản mã hóa cho người dùng, giống như keytar:

```zig
try myzig.secrets.set(gpa, "com.example.notes", "ada@example.com", token);
if (try myzig.secrets.get(gpa, "com.example.notes", "ada@example.com")) |t| {
    defer gpa.free(t);
    // use the token
}
_ = try myzig.secrets.delete("com.example.notes", "ada@example.com"); // false if there was none
```

- macOS: mật khẩu chung trong Chuỗi khóa.
- Windows: thông tin xác thực chung của Trình quản lý thông tin xác thực, mục tiêu `service/account`, được mã hóa bằng DPAPI.
- Linux: khóa của người dùng (Khóa Gnome, KWallet, KeePassXC) thông qua libsecret, được tải với `dlopen`, với lược đồ của keytar; bí mật là văn bản ở đó (không có byte NUL). Không có libsecret, `error.Unsupported`.
- Trình duyệt: `error.Unsupported`.

<a id="watching-files"></a>

## Xem tập tin

`myzig.file_watch.watch` gọi trình xử lý trên luồng chính khi một tệp có thể đã thay đổi: được ghi, thay thế, đổi tên hoặc xóa bởi một ứng dụng khác. Một thay đổi đối với một tệp khác trong thư mục của nó cũng có thể đánh thức nó, vì vậy trình xử lý sẽ xem xét chính tệp đó. Nó sử dụng kqueue trên macOS, inotify trên Linux và thay đổi thông báo trên Windows; không có polling nào. Trình duyệt không có đồng hồ (`error.Unsupported`).

```zig
const Doc = struct {
    path: []const u8,

    fn onChange(ctx: ?*anyopaque) callconv(.c) void {
        const d: *Doc = @ptrCast(@alignCast(ctx));
        _ = d; // stat d.path, read it again if it changed
    }
};

const w = try myzig.file_watch.watch(doc.path, &doc, Doc.onChange);
defer w.cancel();
```

[Tài liệu](documents.md) xem tập tin của họ theo cách này. [watch](plugins/watch.md) theo dõi toàn bộ cây thư mục.

<a id="pipes-and-processes"></a>

## Đường ống và quy trình

`myzig.fdwatch` chạy trình xử lý trên luồng chính khi bộ mô tả tệp (ống, terminal giả) có byte để đọc và khi quá trình con thoát ra mà không có luồng của riêng ứng dụng và không có vòng polling:

```zig
const out = try myzig.fdwatch.readable(pipe_fd, &job, Job.onOutput);
defer out.cancel();
const done = try myzig.fdwatch.exited(pid, &job, Job.onExit);
defer done.cancel();
```

Trình xử lý có cùng chữ ký với tệp xem, `fn (ctx: ?*anyopaque) callconv(.c) void` và đọc nội dung ở đó; nó cũng chạy một lần ở cuối tập tin. macOS sử dụng các nguồn libdispatch, Linux GLib. Thay vào đó, các ứng dụng Windows chờ trên các tay cầm và hiện tại cả hai đều trả về `error.Unsupported` ([terminal](plugins/terminal.md) sử dụng ConPTY ở đó).
