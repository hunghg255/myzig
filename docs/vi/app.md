<a id="the-application"></a>

# App

Một app là một `myzig.App`. Nó chạy vòng lặp event của nền tảng, và sở hữu các cửa sổ, thanh menu và icon tray. Nó chuyển cho app những gì hệ thống gửi tới: URL, file, các lần khởi động sau, thay đổi giao diện sáng tối, cú bấm vào thông báo, mạng.

Ở các trang khác:

- cửa sổ: [Cửa sổ](windows.md);
- menu và tray: [Menu](menus.md);
- các dịch vụ của hệ thống (hộp thoại, đường dẫn, secret, tài liệu gần đây, mở khi đăng nhập): [Hệ thống](system.md).

<a id="the-main-function"></a>

## Hàm main

```zig
const std = @import("std");
const myzig = @import("myzig");

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{
        .name = "Notes",
        .id = "com.example.notes",
    });
    defer app.destroy();

    var state: Notes = .{};
    _ = try app.newWindow(.{ .title = "Notes", .content = .{ .view = .init(&state, Notes.view) } });
    try app.run();
}
```

**`App.create`** nhận `std.process.Init` của process (allocator, I/O, tham số dòng lệnh và biến môi trường) và các tùy chọn của app. Nó:

- đọc các cờ riêng của myzig (`--myzig-*`, xem [Testing](ui/testing.md));
- trên macOS, dựng thanh menu với các menu mặc định ([Menu](menus.md));
- trả về app.

Gọi nó từ `main`, trên main thread. Trên macOS, gọi ở chỗ khác sẽ lỗi `error.NotMainThread`.

**`run`** chạy vòng lặp event cho tới khi app thoát, rồi trả về.

- Với `--myzig-generate=DIR`, nó ghi client được sinh ra thay vì chạy ([Binding](bindings.md)).
- Với `--myzig-snapshot=PNG`, nó vẽ cửa sổ native UI đầu tiên ra file.
- Cả hai đều trả về ngay, nên cùng một `main` phục vụ app, client và snapshot của nó.

**`destroy`** đóng các cửa sổ còn lại, gỡ icon tray và thanh menu, và hủy đăng ký các phím tắt toàn cục. Nó nhả khóa single instance, và giải phóng app.

<a id="options"></a>

### Tùy chọn

`myzig.AppOptions` (trường nào cũng có mặc định):

| Trường | Tác dụng |
|---|---|
| `name` | tên app: menu, thông báo, thư mục data, mục autostart (mặc định `"myzig"`) |
| `id` | dạng DNS ngược (`"com.example.notes"`): khóa single instance, mục URL handler và autostart, service mặc định của secret; rỗng thì dùng tên |
| `quit_on_last_window_closed` | thoát khi cửa sổ cuối cùng đóng (mặc định true) |
| `quit_on_signal` | Ctrl+C và SIGTERM làm app thoát (mặc định true) |
| `url_schemes` | các scheme app mở (`"notes"` cho `notes://...`) |
| `file_extensions` | phần mở rộng của file app mở, chữ thường, không có dấu chấm (`"md"`) |
| `secure_origins` | origin của các server http thường (`"http://192.168.1.10:8080"`) mà trang của chúng được coi là secure context như https, để được xin camera hay micro ([quyền](pages.md#page-events)); chỉ WebView2, WebKit không có cài đặt này |
| `on_open_url` | một URL thuộc scheme của app được mở |
| `on_open_file` | một file thuộc loại của app được mở |
| `on_second_instance` | một lần khởi động sau đã chuyển dòng lệnh của nó sang |
| `on_appearance` | hệ thống chuyển giữa sáng (`false`) và tối (`true`) |
| `on_notification` | một thông báo được bấm |
| `on_network` | máy online hoặc offline, hoặc chi phí kết nối thay đổi |

Các handler là `myzig.Handler(T)`: một method của app cùng con trỏ để gọi nó.

```zig
const Notes = struct {
    dark: bool = false,

    fn openUrl(n: *Notes, url: []const u8) void {
        _ = n;
        std.log.info("open {s}", .{url});
    }
    fn appearance(n: *Notes, dark: bool) void {
        n.dark = dark;
    }
};

var notes: Notes = .{};
const app = try myzig.App.create(init, .{
    .name = "Notes",
    .url_schemes = &.{"notes"},
    .on_open_url = .of(&notes, Notes.openUrl),
    .on_appearance = .of(&notes, Notes.appearance),
});
```

Handler chạy trên main thread. Chuỗi mà chúng nhận chỉ sống trong lời gọi: copy những gì bạn muốn giữ.

<a id="threads"></a>

## Thread

AppKit, GTK, Win32, các trang và native UI sống trên main thread. myzig gọi app ở đó: view, method được bind, cú bấm menu, handler, timer. App không cần khóa cho state của mình miễn là nó ở yên đó.

Việc tốn thời gian nên chạy trên thread riêng. Kết quả được đưa về main thread:

- `myzig.App.after(ms, ctx, func)` gọi `func(ctx)` trên main thread sau `ms` mili giây (`func` là `fn (?*anyopaque) callconv(.c) void`). Trên macOS có thể gọi nó từ thread nào cũng được (libdispatch). Trên Linux và Windows, gọi nó từ main thread.
- [Plugin mainthread](plugins/mainthread.md) đẩy việc sang main thread từ bất kỳ thread nào, trên mọi nền tảng. Nó dùng hàng đợi riêng của main thread: libdispatch, main context của GLib, một cửa sổ chỉ nhận message.
- `Window.sendOwned` xếp một message cho trang từ thread bất kỳ, và `emit` của một `Event` gửi event có kiểu ([Binding](bindings.md)).
- Sau khi state đổi ngoài các event của view (timer, output của process), `Window.redraw` vẽ lại native UI ở lần refresh kế tiếp.

Không có gì polling. Frame được vẽ khi có input, đổi kích thước, hoặc khi animation đang chạy, và app rảnh không tốn CPU.

`myzig.runFor(seconds)` chạy vòng lặp event một lúc rồi trả về. Nó dành cho test headless cần chờ phản hồi, process hoặc timer.

<a id="quitting"></a>

## Thoát

`app.quit()` dừng vòng lặp event. `run` trả về khi event hiện tại được xử lý xong, và `main` đi tiếp tới `destroy`. App tự thoát:

- khi cửa sổ cuối cùng đóng, trừ khi `quit_on_last_window_closed` là false (app tray, app thanh menu);
- khi có Ctrl+C và SIGTERM, và trên Windows khi có Ctrl+Break hoặc console bị đóng, trừ khi `quit_on_signal` là false. Tín hiệu làm app thoát trên main thread, như `quit`; tín hiệu thứ hai thoát ngay;
- trên macOS, từ mục Quit (⌘Q) của menu app và từ Dock. Chúng dừng vòng lặp chứ không thoát hẳn, nên `run` trả về và các `defer` được chạy.

Một cửa sổ có thể giữ mình mở khi người dùng đóng nó, bằng `on_close_request` ([Cửa sổ](windows.md#closing)). Trên macOS, bấm icon Dock của một app không còn cửa sổ nào hiện sẽ mở lại cửa sổ cuối.

<a id="relaunching"></a>

### Khởi động lại

`app.relaunch()` thoát theo cùng cách, rồi khởi động lại app, như sau khi đổi một cài đặt cần khởi động lại.

- Nó khởi động lại khi `destroy` đã giải phóng app: cửa sổ đã đóng, khóa single instance đã nhả.
- Nó chạy file thực thi mà app đang chạy từ đó: bản mới, nếu một bản cập nhật đã thay thế nó.
- Nó truyền các tham số của lần khởi động, bỏ các cờ riêng của myzig, trong thư mục làm việc của lần khởi động.
- Dưới `myzig dev`, bản build thoát với mã 75 thay vì vậy, để `myzig dev` khởi động lại nó.
- Lần chạy ẩn và headless chỉ thoát. Trên trình duyệt, `relaunch` chính là `quit`.

<details>
<summary>Trở lại phía trước trên Windows</summary>

Trên Windows, chỉ app đang ở phía trước mới được đưa một cửa sổ lên trước, và nó mất quyền này khi các cửa sổ của nó đóng. Vì vậy `relaunch` chuyển quyền đó đi trước (`AllowSetForegroundWindow`). Nhờ vậy instance mới mở ở phía trước, thay vì nằm phía sau với nút taskbar nhấp nháy.

</details>

<a id="a-single-instance"></a>

## Single instance

Nhiều app chỉ nên chạy một lần: lần khởi động thứ hai chuyển dòng lệnh của nó cho lần đầu rồi thoát.

```zig
const State = struct {
    window: ?*myzig.Window = null,

    fn second(st: *State, s: myzig.SecondInstance) void {
        std.log.info("launched again in {s} with {d} arguments", .{ s.working_dir, s.args.len });
        if (st.window) |w| w.focus();
    }
};

var state: State = .{};
const app = try myzig.App.create(init, .{
    .name = "Notes",
    .id = "com.example.notes",
    .on_second_instance = .of(&state, State.second),
});
defer app.destroy();
if (!app.requestSingleInstanceLock()) return; // một instance khác đang giữ khóa
```

`requestSingleInstanceLock`:

- trả về true ở instance đầu tiên. Instance đó sau đó nhận tham số và thư mục làm việc của mỗi lần khởi động sau trong `on_second_instance`, không kèm tên chương trình và các cờ của myzig;
- ở một instance sau, chuyển dòng lệnh của nó đi và trả về false: hãy return khỏi `main`.

URL và file trong tham số của lần khởi động sau cũng tới `on_open_url` và `on_open_file`, như của lần khởi động đầu.

Khóa được đặt tên theo `id`:

| Nền tảng | Khóa |
|---|---|
| macOS, Linux | một Unix socket trong `XDG_RUNTIME_DIR`, `TMPDIR` hoặc `/tmp`; socket do instance bị crash để lại sẽ được thay |
| Windows | một named mutex. Cửa sổ ẩn của bên giữ khóa nhận dòng lệnh (`WM_COPYDATA`) và có thể lên phía trước |
| trình duyệt | chỉ có một trang, luôn là instance đầu tiên |

Một bundle macOS được mở lại từ Finder thì do macOS kích hoạt.

<a id="bringing-the-app-forward"></a>

## Đưa app lên phía trước

`app.focus()` đưa app lên phía trước với các cửa sổ theo đúng thứ tự, như khi bấm icon tray để mở phần cài đặt của app.

- Nếu một cửa sổ của app đã ở phía trước thì nó giữ nguyên.
- Nếu không, cửa sổ người dùng dùng gần nhất được đưa lên: cửa sổ cao nhất theo z-order trên Windows, `activateIgnoringOtherApps:` trên macOS, cửa sổ đầu tiên đang hiện trên Linux.
- Flyout không bao giờ nhận bàn phím thì không đưa gì lên.

`focus()` của một cửa sổ đưa chính cửa sổ đó lên.

<a id="deep-links-and-file-associations"></a>

## Deep link và liên kết loại file

App mở URL thuộc scheme riêng của nó (`notes://open/42`) và file thuộc các loại của nó. Hệ thống khởi động app kèm chúng, hoặc giao chúng cho app khi app đang chạy:

```zig
const app = try myzig.App.create(init, .{
    .name = "Notes",
    .id = "com.example.notes",
    .url_schemes = &.{"notes"},
    .file_extensions = &.{ "md", "txt" },
    .on_open_url = .of(&state, State.openUrl),
    .on_open_file = .of(&state, State.openFile),
});
```

- Windows và Linux khởi động app với URL hoặc file làm tham số. `run` giao những URL thuộc scheme của app cho `on_open_url`.
- Nó giao những file có phần mở rộng của app và đang tồn tại cho `on_open_file`: đường dẫn và URL `file:`, đã đổi thành tuyệt đối.
- Trên macOS chúng đến dưới dạng Apple event (`application:openURLs:`), tới cùng các handler đó.
- Với single instance, URL và file của các lần khởi động sau tới handler của instance đầu.

Hệ thống phải biết app xử lý chúng:

- **Gói cài đặt** khai báo chúng. `url_schemes` và `file_associations` trong `myzig.zon` được ghi vào `Info.plist` của bundle macOS, file `.desktop` và MIME type của Linux, và bộ cài Windows ([Cấu hình](configuration.md), [Phân phối](distribution.md)).
- **Lúc chạy**, `myzig.system.registerUrlScheme(app, "notes")` đặt app làm trình xử lý một scheme cho người dùng: registry trên Windows, một mục `.desktop` XDG trên Linux, trình xử lý mặc định trên macOS. Trên macOS, scheme cũng phải có trong `Info.plist`. `registerFileType` làm việc tương tự cho một phần mở rộng. Xem [Hệ thống](system.md).

<a id="notifications"></a>

## Thông báo

```zig
try app.notify(.{
    .id = "sync",
    .title = "Synced",
    .subtitle = "Notes",
    .body = "42 notes are up to date.",
});
app.removeNotification("sync");

// Các nút, và một ô trả lời.
try app.notify(.{
    .id = "chat-42",
    .title = "Ada",
    .body = "Lunch?",
    .actions = &.{
        .{ .id = "reply", .title = "Reply", .reply = true, .placeholder = "Message" },
        .{ .id = "mute", .title = "Mute", .destructive = true },
    },
});
```

| `myzig.Notification` | |
|---|---|
| `id` | cho `removeNotification` và cho phản hồi |
| `title`, `subtitle`, `body` | |
| `silent` | không có âm thanh |
| `actions` | `myzig.NotificationAction`: một `id`, một `title`, `reply` cho ô nhập chữ kèm `placeholder`, `destructive` |
| `group` | gom các thông báo cùng group trong Notification Center (thread identifier của macOS), như các tin nhắn của một cuộc trò chuyện |

Một cú bấm tới `on_notification` dưới dạng `myzig.NotificationResponse`:

- `id` của thông báo;
- `action` được chọn, rỗng nếu bấm vào chính thông báo;
- `reply` đã gõ.

| Nền tảng | Cách làm |
|---|---|
| macOS | UNUserNotificationCenter, action là một notification category: app phải là bundle (`myzig build`) |
| Linux | notification server của desktop qua D-Bus; thông báo có id trùng với một thông báo đang hiện sẽ thay nó |
| Windows | toast (ToastNotificationManager của WinRT), có nút và ô trả lời (bên dưới) |
| trình duyệt | `error.Unsupported` |

**Trên Windows:**

- Toast hiện dưới `id` của app, dùng làm AppUserModelID. App không đóng gói sẽ có một shortcut trong Start menu mang id này ở lần thông báo đầu tiên.
- Cú bấm tới cả khi app đang chạy lẫn sau khi app đã thoát. Shortcut ghi tên toast activator của app: một CLSID suy ra từ `id`, đăng ký dưới `HKCU\Software\Classes\CLSID`.
- Vì vậy cú bấm khởi động app với `--myzig-toast-activated`, và tới `on_notification` khi `run` bắt đầu. App đang chạy thì nhận trực tiếp.
- Ở nơi không hiện được toast, balloon của icon tray đầu tiên của app hiện thay.

<a id="sender-avatars-on-macos"></a>

### Avatar người gửi trên macOS

Một tin nhắn trực tiếp gửi đến có thể ghi tên người gửi. macOS 12 trở lên hiện avatar của người gửi cùng icon nhỏ của app:

```zig
try app.notify(.{
    .id = "message:7",
    .group = "conversation:3",
    .title = "Ada",
    .subtitle = "Lunch",
    .body = "See you at noon",
    .sender = .{ .id = "user:ada", .name = "Ada", .avatar = avatar_png },
});
```

- `sender.id` định danh người đó trong app. Nó không bị hiểu là địa chỉ email hay số điện thoại.
- `name` mặc định là `title`.
- `avatar` là một ảnh đã mã hóa (PNG, JPEG) mà app có sẵn.
- `group` là định danh của cuộc trò chuyện; nếu không có thì dùng `id` của thông báo.
- Đây là tin nhắn đến từ một người, không phải tin của nhóm chat hay tin gửi đi.
- macOS tự bố trí thông báo: subtitle nằm trên body.
- Windows, Linux và trình duyệt bỏ qua `sender`.

App cần:

- capability **Communication Notifications** của Apple App ID của nó;
- `INSendMessageIntent` trong `NSUserActivityTypes` của `Info.plist`;
- chữ ký có entitlement `com.apple.developer.usernotifications.communication`;
- một provisioning profile cho phép entitlement đó, kể cả khi phân phối qua Developer ID.

Đừng cho bản build ad-hoc entitlement bị hạn chế này: macOS có thể từ chối chạy nó.

myzig kiểm tra entitlement đã ký trước khi donate tin nhắn cho SiriKit và cập nhật nội dung thông báo bằng nó. Thông báo thường sẽ hiện khi:

- app thiếu capability;
- người gửi thiếu `id` hoặc `avatar` đọc được;
- việc donate hoặc cập nhật thất bại.

Một thông báo đang được chuẩn bị mà bị xóa hoặc bị thay theo `id` trong lúc đó sẽ không bao giờ hiện.

<a id="appearance"></a>

## Giao diện sáng tối

`on_appearance` nghe hệ thống chuyển giữa sáng và tối.

- Native UI tự theo, trừ khi cửa sổ có `theme` cố định.
- Trang web có `prefers-color-scheme`.
- Handler dành cho màu riêng của app.

`myzig.isDark()` và `myzig.accentColor()` đọc giao diện hiện tại ([Hệ thống](system.md)).

<a id="the-network"></a>

## Mạng

```zig
const s = app.networkStatus();
if (!s.online) showOffline();
if (s.metered) askBeforeDownloading();
```

`myzig.NetworkStatus` có hai trường:

| Trường | |
|---|---|
| `online` | có đường ra ngoài: path ở trạng thái satisfied của macOS, GNetworkMonitor của Linux, kết nối local hoặc internet của Windows. Captive portal cũng tính, như `navigator.onLine` của trình duyệt |
| `metered` | kết nối là mạng di động, hotspot, Low Data Mode, hoặc có chi phí giới hạn hay roaming |

- `on_network` chỉ được gọi khi một trong hai trường đổi. Hệ thống còn báo các thay đổi route và interface không làm chúng đổi, và myzig lọc bỏ những báo đó.
- App bắt đầu theo dõi khi `run` bắt đầu, và chỉ khi `on_network` được đặt.

<a id="the-dock-and-the-taskbar"></a>

## Dock và taskbar

- `app.setBadge("3")` đặt badge cho app: trên icon Dock (macOS), thành con số trên mục launcher của các dock có Unity launcher API (Linux), hoặc vẽ đè lên nút taskbar (Windows, overlay icon của nó). Chuỗi rỗng thì gỡ badge.
- `Window.setProgress` hiện tiến độ của một tác vụ trên nút taskbar (Windows), mục launcher (Linux) hoặc một thanh trên icon Dock (macOS). `Window.flash` xin sự chú ý ([Cửa sổ](windows.md#attention-and-progress)).
- `myzig.system.setJumpList` thêm task vào jump list của nút taskbar Windows, và tài liệu gần đây cũng vào đó ([Hệ thống](system.md)).

<a id="start-at-login"></a>

## Khởi động khi đăng nhập

- `myzig.system.setOpenAtLogin(app, true)` mở app khi người dùng đăng nhập: một login item trên macOS 13 trở lên, cho bundle; một mục Run trên Windows; một mục XDG autostart trên Linux.
- `openAtLogin(app)` cho biết nó có được mở như vậy không.
- `wasOpenedAtLogin(app)` cho biết lần khởi động này có phải là lần như vậy không (mục đó truyền `--myzig-login`). Nó dành cho app khởi động lặng lẽ, không có cửa sổ.

Xem [Hệ thống](system.md).

<a id="platforms"></a>

## Nền tảng

| | macOS | Linux | Windows | trình duyệt |
|---|---|---|---|---|
| vòng lặp event | AppKit | GTK 3 (`dlopen`) | message Win32 | các frame của trang |
| single instance | Unix socket | Unix socket | named mutex | luôn là đầu tiên |
| deep link, file | Apple event | tham số | tham số | không |
| thông báo | UNUserNotificationCenter | D-Bus | balloon của tray, toast | không |
| trạng thái mạng | Network.framework | GNetworkMonitor | network list manager | coi như online |
| badge | Dock | Unity launcher | overlay icon của nút taskbar | không |
| tín hiệu | SIGINT, SIGTERM | SIGINT, SIGTERM | console control event | không |

Trên trình duyệt ([Trình duyệt](browsers.md)), app là một trang:

- `App.create` và `run` chạy như ở nơi khác.
- Cửa sổ native UI lấp đầy canvas của trang.
- Những gì không có ý nghĩa ở đó thì lỗi `error.Unsupported` (tray, thông báo) hoặc không làm gì.
- Phím tắt toàn cục và flyout hoàn toàn không có.
