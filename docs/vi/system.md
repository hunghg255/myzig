<a id="the-system-around-the-app"></a>

# Hệ thống quanh app

Ngoài cửa sổ, app còn làm việc với desktop mà nó chạy trên đó. App:

- hỏi người dùng chọn file;
- mở link trong trình duyệt;
- lưu dữ liệu ở nơi mỗi hệ thống muốn;
- theo giao diện sáng tối của hệ thống;
- lưu mật khẩu trong keychain của hệ thống;
- ghi lại tài liệu gần đây và mở khi đăng nhập;
- giữ máy thức khi đang làm việc;
- theo dõi file mà app khác thay đổi.

Mỗi việc là một lời gọi. Nó làm đúng việc trên macOS, Linux và Windows, và làm điều hợp lý (hoặc trả `error.Unsupported`) trên trình duyệt.

Lời gọi chạy dạng modal (hộp thoại) hoặc đụng tới hệ thống cửa sổ thì chạy trên main thread: từ một cú bấm menu, một method được bind hoặc một view. Xem [App](app.md) về thread.

<a id="dialogs"></a>

## Hộp thoại

`myzig.dialog` có các panel mở, lưu file và hộp thông báo của hệ thống. Chúng chặn cho tới khi người dùng trả lời, rồi trả về câu trả lời:

```zig
const myzig = @import("myzig");

fn importImages(gpa: std.mem.Allocator) !void {
    const paths = (try myzig.dialog.open(gpa, .{
        .title = "Import",
        .button = "Import",
        .multiple = true,
        .extensions = &.{ "png", "jpg" },
    })) orelse return; // đã hủy
    defer myzig.dialog.freePaths(gpa, paths);
    for (paths) |p| std.log.info("import {s}", .{p});
}

fn exportAs(gpa: std.mem.Allocator) !void {
    const path = (try myzig.dialog.save(gpa, .{ .name = "Untitled.md", .extensions = &.{"md"} })) orelse return;
    defer gpa.free(path);
    // ghi file ở `path`
}
```

| `dialog.OpenOptions` | |
|---|---|
| `title`, `message` | |
| `button` | label của nút mặc định |
| `directory` | thư mục panel mở ra lúc đầu |
| `files`, `directories` | được chọn gì; chỉ chọn thư mục với `.files = false, .directories = true` |
| `multiple` | |
| `extensions` | không có dấu chấm |
| `show_hidden` | |

`dialog.SaveOptions` có `title`, `button`, `message`, `directory`, `extensions`, `show_hidden` và `create_directories`, cùng `name`: tên file điền sẵn lúc đầu.

Hộp thông báo trả về chỉ số của nút được bấm, và checkbox của nó có được đánh dấu không. Nút đầu tiên là nút mặc định.

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
| mở, lưu | `NSOpenPanel`, `NSSavePanel` | hộp chọn file native của GTK (của desktop portal nếu có) | các hộp thoại file chung | `error.Unsupported` |
| thông báo | `NSAlert`, có checkbox | hộp thông báo của GTK | một message box | `alert` nếu một nút, ngược lại `confirm` |

- Trên Windows, hộp thoại lưu chưa lọc theo `extensions`.
- Native UI cũng có hộp thoại riêng, vẽ bên trong cửa sổ: xem [overlay](ui/overlays.md).

<a id="opening-things-in-other-apps"></a>

## Mở bằng app khác

`myzig.shell` giao URL và file cho app mà người dùng đã chọn cho chúng:

```zig
_ = myzig.shell.openUrl("https://ziglang.org"); // scheme nào cũng được: https:, mailto:, ...
_ = myzig.shell.openPath("/Users/ada/report.pdf"); // trong app mặc định của nó
myzig.shell.showInFolder("/Users/ada/report.pdf"); // trong Finder hoặc trình quản lý file
_ = myzig.shell.trash("/Users/ada/old.txt"); // vào Thùng rác
myzig.shell.beep(); // âm báo của hệ thống
```

- `openUrl`, `openPath` và `trash` trả về việc đã làm được hay chưa.
- `showInFolder` chọn file trong một cửa sổ Finder trên macOS, và mở thư mục chứa nó ở nơi khác.
- Trên Linux chúng chạy `xdg-open`; trên Windows, lệnh open của shell.
- Trên trình duyệt, `openUrl` mở một tab. Trình duyệt có thể chặn nó nếu không nằm trong một cú bấm.
- `beep` chạy trên macOS và trình duyệt.

**`trash`** chạy trên macOS (Thùng rác) và Windows (Recycle Bin, qua `IFileOperation`). Trên Windows, đường dẫn tương đối tính từ thư mục làm việc. Ở nơi khác, hiện nó trả về false.

`trash` không bao giờ xóa hẳn. Nếu mục đó không vào thùng rác được, nó trả về false và để nguyên mục đó. Trên Windows, đó là:

- mục quá lớn so với Recycle Bin;
- mục nằm trên ổ không có Recycle Bin, như ổ mạng và nhiều ổ di động.

Nếu không, Windows sẽ xóa những mục này mà không hỏi.

<a id="the-app-s-directories"></a>

## Các thư mục của app

`myzig.appPath` trả về các thư mục riêng của app, ở nơi mỗi hệ thống muốn. Nó tạo chúng (trừ `temp`) nếu chưa có:

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

Biến XDG nào không phải đường dẫn tuyệt đối thì bị bỏ qua, đúng như đặc tả.

`myzig.path` cũng biết các thư mục chuẩn của người dùng. Nó nhận một `myzig.Directory`: `data` và `cache` (của riêng app, được tạo sẵn), `home`, `documents`, `downloads`, `desktop` hoặc `temp`:

```zig
const downloads = try myzig.path(gpa, .downloads, app.options.name);
defer gpa.free(downloads);
```

Trên trình duyệt, cả hai trả về thư mục trong hệ thống file WASI trong bộ nhớ mà trang cung cấp: `/home`, `/tmp`, `/home/.local/share/Name`. Hệ thống file này tồn tại bằng thời gian của trang.

<a id="appearance"></a>

## Giao diện sáng tối

- `myzig.isDark()` cho biết hệ thống có đang ở dark mode không.
- `myzig.accentColor()` trả về màu accent người dùng đã chọn, dạng sRGB `[3]f32`.

Native UI tự theo cả hai (xem [styling](ui/styling.md)). Các hàm này dành cho app tự vẽ hoặc tự chọn màu.

- macOS: giao diện thực tế của app và `controlAccentColor`.
- Linux: tối khi `GTK_THEME` là một theme tối; màu accent là một màu xanh cố định.
- Windows: cài đặt "apps use light theme".
- Trình duyệt: `prefers-color-scheme`, hoặc `data-myzig-theme="dark"` hay `"light"` mà trang đặt trên phần tử gốc.

<a id="locale-and-languages"></a>

## Locale và ngôn ngữ

`myzig.system` trả về locale và các ngôn ngữ của người dùng, cho app tự định dạng hoặc tự dịch. [i18n](i18n.md) làm cả hai việc này:

```zig
const tag = try myzig.system.locale(gpa); // "en-US", BCP 47
defer gpa.free(tag);
const region = try myzig.system.region(gpa); // "US"
defer gpa.free(region);
const langs = try myzig.system.languages(gpa); // ưu tiên nhất đứng đầu
defer myzig.system.freeList(gpa, langs);
```

Trên Linux chúng lấy từ `LANGUAGE`, `LC_ALL`, `LC_MESSAGES`, `LC_TIME` và `LANG`, đổi thành tag BCP 47. Trên trình duyệt chúng lấy từ `navigator.languages`.

<a id="recent-documents"></a>

## Tài liệu gần đây

```zig
try myzig.system.addRecentDocument(app, "/Users/ada/Notes.md");
const recent = try myzig.system.recentDocuments(app);
defer myzig.system.freeList(app.gpa, recent);
myzig.system.clearRecentDocuments(app);
```

`addRecentDocument` ghi một file vào hai danh sách:

- của hệ thống: menu Open Recent và menu Dock của macOS, Recent items và jump list của app trên Windows, danh sách file dùng gần đây của Linux;
- của riêng app, lưu trong `recent-documents.txt` ở thư mục data của app.

`recentDocuments` trả về danh sách riêng của app: mới nhất trước, tối đa mười mục, chỉ các file còn tồn tại. `clearRecentDocuments` xóa danh sách đó. Trên Linux, các file gần đây khác của người dùng vẫn giữ nguyên.

[Tài liệu](documents.md) ghi lại những gì chúng mở và hiện danh sách trong menu File.

**Jump list.** Trên Windows, `system.setJumpList(app, tasks)` đặt các Task trong jump list của app, hiện khi bấm chuột phải vào nút của app trên taskbar. Ở nơi khác nó không làm gì.

- Mỗi task là một `JumpTask` có `title`, `description`, `path`, `args` và một icon.
- Windows giữ danh sách sau khi app thoát: đặt một lần lúc khởi động.
- Tốt nhất task nên chạy một URL thuộc scheme riêng của app, URL này tới `on_open_url`.

<a id="open-at-login"></a>

## Mở khi đăng nhập

```zig
try myzig.system.setOpenAtLogin(app, true);
const on = myzig.system.openAtLogin(app);
if (myzig.system.wasOpenedAtLogin(app)) {
    // do hệ thống khởi động: ở yên trong tray, không hiện cửa sổ
}
```

| Nền tảng | App mở khi đăng nhập nhờ |
|---|---|
| Windows | một mục Run |
| Linux | một mục XDG autostart |
| macOS 13 trở lên | một login item (cho app đã đóng gói bundle) |

`wasOpenedAtLogin` nhận ra lần khởi động như vậy trên Windows và Linux, nơi mục đó truyền `--myzig-login`.

<details>
<summary>Quyền administrator khi đăng nhập trên Windows</summary>

Mục Run khởi động app bằng token bình thường (không nâng quyền) của người dùng, kể cả khi người dùng là administrator. Vì vậy app không tạo được network adapter, không đổi được proxy của hệ thống và không ghi được vào các thư mục được bảo vệ.

App cần quyền administrator thì không gọi `setOpenAtLogin`:

- Thay vào đó, nó đăng ký một logon task trong Task Scheduler với run level `HighestAvailable` (`schtasks /Create /SC ONLOGON /RL HIGHEST`). Task này khởi động app với quyền cao mà không hỏi.
- Bản thân việc tạo task cũng cần quyền administrator. Nên app xin quyền một lần, khi người dùng bật cài đặt này.
- `wasOpenedAtLogin` không nhận ra lần khởi động như vậy. Hãy cho lệnh của task một tham số riêng của app để làm việc đó.

</details>

<a id="url-schemes-and-file-types"></a>

## URL scheme và loại file

App mở URL riêng của nó (`notes://open?id=4`) và file thuộc các loại của nó khi hệ thống giao cho. Chúng tới `AppOptions.on_open_url` và `on_open_file`. Xem [App](app.md) về các handler, và về `url_schemes` và `file_extensions` để khai báo chúng.

```zig
try myzig.system.registerUrlScheme(app, "notes"); // rẻ: gọi mỗi lần khởi động
if (!myzig.system.isUrlSchemeRegistered(app, "notes")) {}
try myzig.system.unregisterUrlScheme(app, "notes");
try myzig.system.registerFileType(app, "md", "Markdown Document");
try myzig.system.unregisterFileType(app, "md");
```

`registerUrlScheme` đặt app làm trình xử lý scheme cho người dùng:

| Nền tảng | Cách làm |
|---|---|
| Windows | trong registry |
| Linux | trong một desktop entry được đặt làm mặc định trong `mimeapps.list`, như `xdg-mime default` |
| macOS | làm trình xử lý mặc định của một scheme mà `Info.plist` của bundle phải khai báo ([phân phối](distribution.md) ghi nó) |

`unregisterUrlScheme` hoàn tác việc này trên Windows và Linux.

`registerFileType` thêm app vào danh sách Open with của một phần mở rộng file trên Windows. macOS khai báo loại file trong bundle, còn Linux trong desktop entry của app. Ở hai nơi đó nó trả về `error.Unsupported`.

<a id="keeping-the-system-awake"></a>

## Giữ máy thức

```zig
const awake = try myzig.system.preventSleep(app, "Exporting the video", .system);
defer awake.release();
```

- `.system` giữ máy không ngủ khi rảnh. Màn hình vẫn có thể tắt.
- `.display` giữ cả màn hình luôn bật.

Nó dùng power request trên Windows và power assertion trên macOS. Trên Linux nó dùng cơ chế chặn screen saver qua session bus, giữ cả hai thức.

<a id="secrets"></a>

## Secret

`myzig.secrets` lưu mật khẩu và token, được hệ thống mã hóa cho người dùng, theo service và account, như keytar:

```zig
try myzig.secrets.set(gpa, "com.example.notes", "ada@example.com", token);
if (try myzig.secrets.get(gpa, "com.example.notes", "ada@example.com")) |t| {
    defer gpa.free(t);
    // dùng token
}
_ = try myzig.secrets.delete("com.example.notes", "ada@example.com"); // false nếu không có
```

- macOS: generic password trong Keychain.
- Windows: generic credential của Credential Manager, target là `service/account`, mã hóa bằng DPAPI.
- Linux: keyring của người dùng (GNOME Keyring, KWallet, KeePassXC) qua libsecret, nạp bằng `dlopen`, với schema của keytar. Ở đây secret là chữ (không có byte NUL). Không có libsecret thì trả `error.Unsupported`.
- Trình duyệt: `error.Unsupported`.

<a id="watching-files"></a>

## Theo dõi file

`myzig.file_watch.watch` gọi một handler trên main thread khi một file có thể đã thay đổi: bị app khác ghi, thay thế, đổi tên hoặc xóa.

- Thay đổi ở một file khác trong cùng thư mục cũng có thể đánh thức nó, nên handler tự kiểm tra file.
- Nó dùng kqueue trên macOS, inotify trên Linux và change notification trên Windows. Không có gì polling.
- Trình duyệt không theo dõi được (`error.Unsupported`).

```zig
const Doc = struct {
    path: []const u8,

    fn onChange(ctx: ?*anyopaque) callconv(.c) void {
        const d: *Doc = @ptrCast(@alignCast(ctx));
        _ = d; // stat d.path, đọc lại nếu nó đã đổi
    }
};

const w = try myzig.file_watch.watch(doc.path, &doc, Doc.onChange);
defer w.cancel();
```

[Tài liệu](documents.md) theo dõi file của chúng theo cách này. [Plugin watch](plugins/watch.md) theo dõi cả cây thư mục.

<a id="pipes-and-processes"></a>

## Pipe và process

`myzig.fdwatch` chạy một handler trên main thread khi một file descriptor (pipe, pseudo-terminal) có byte để đọc, và khi một process con kết thúc. Nó không cần thread riêng của app, và không polling:

```zig
const out = try myzig.fdwatch.readable(pipe_fd, &job, Job.onOutput);
defer out.cancel();
const done = try myzig.fdwatch.exited(pid, &job, Job.onExit);
defer done.cancel();
```

- Handler có cùng chữ ký với handler theo dõi file, `fn (ctx: ?*anyopaque) callconv(.c) void`. Nó đọc những gì đang có.
- Nó cũng chạy một lần khi tới cuối file.
- macOS dùng source của libdispatch, Linux dùng source của GLib.
- App Windows thì chờ trên handle. Ở đó cả hai hiện trả về `error.Unsupported`; [plugin terminal](plugins/terminal.md) dùng ConPTY.
