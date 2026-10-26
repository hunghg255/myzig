<a id="the-application"></a>

# Ứng dụng

Một ứng dụng là một `myzig.App`: nó chạy vòng lặp sự kiện của nền tảng, sở hữu các cửa sổ, thanh menu và các biểu tượng trên khay, đồng thời trao cho ứng dụng những gì tiếp cận được từ hệ thống (URL, tệp, lần khởi chạy sau, thay đổi giao diện, lần nhấp vào thông báo, mạng). Windows nằm trong [Cửa sổ](windows.md), các menu và khay trong [Menus](menus.md), các dịch vụ của hệ thống (hộp thoại, đường dẫn, bí mật, tài liệu gần đây, mở khi đăng nhập) trong [Hệ thống](system.md).

<a id="the-main-function"></a>

## Chức năng chính

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

`App.create` lấy `std.process.Init` (bộ cấp phát, I/O, đối số và môi trường của quy trình) cũng như các tùy chọn của ứng dụng. Nó phân tích các cờ riêng của myzig (`--myzig-*`, xem [Testing](ui/testing.md)), trên macOS thiết lập thanh menu với các menu mặc định ([Menus](menus.md)) và trả về ứng dụng. Gọi nó từ `main`, trên luồng chính: trên macOS nó không thành công với `error.NotMainThread` ở nơi khác.

`run` chạy vòng lặp sự kiện cho đến khi ứng dụng thoát và quay lại. Thay vào đó, với `--myzig-generate=DIR` nó ghi client được tạo ([Bindings](bindings.md)); với `--myzig-snapshot=PNG` nó vẽ cửa sổ đầu tiên của giao diện native vào một tệp. Cả hai đều quay trở lại cùng một lúc, do đó `main` giống nhau phục vụ ứng dụng, client và ảnh chụp nhanh của ứng dụng.

`destroy` đóng các cửa sổ còn lại, xóa các biểu tượng trên khay và thanh menu, hủy đăng ký các phím tắt chung, mở khóa phiên bản duy nhất và giải phóng ứng dụng.

<a id="options"></a>

### Tùy chọn

`myzig.AppOptions` (mỗi trường đều có giá trị mặc định):

| lĩnh vực | nó làm gì |
|---|---|
| `name` | tên ứng dụng: menu, thông báo, thư mục dữ liệu, mục tự khởi động (mặc định `"myzig"`) |
| `id` | DNS đảo ngược (`"com.example.notes"`): khóa phiên bản đơn, trình xử lý URL và các mục tự khởi động, dịch vụ mặc định của bí mật; tên khi trống |
| `quit_on_last_window_closed` | thoát khi cửa sổ cuối cùng đóng lại (mặc định true) |
| `quit_on_signal` | Ctrl+C và SIGTERM thoát ứng dụng (mặc định true) |
| `url_schemes` | các chương trình mà ứng dụng mở ra (`"notes"` cho `notes://...`) |
| `file_extensions` | phần mở rộng của tập tin nó mở ra, chữ thường, không có dấu chấm (`"md"`) |
| `secure_origins` | origin của các server http thường (`"http://192.168.1.10:8080"`) mà trang của chúng là secure context như https, để xin được camera hay micro ([quyền](pages.md)); chỉ WebView2, WebKit không có thiết lập này |
| `on_open_url` | một URL của các chương trình của nó đã được mở |
| `on_open_file` | một tập tin thuộc loại của nó đã được mở |
| `on_second_instance` | lần ra mắt sau đó đã chuyển giao dòng lệnh của nó |
| `on_appearance` | hệ thống chuyển đổi giữa ánh sáng (`false`) và bóng tối (`true`) |
| `on_notification` | một thông báo đã được nhấp vào |
| `on_network` | máy tính trực tuyến hoặc ngoại tuyến hoặc chi phí kết nối của nó đã thay đổi |

Trình xử lý là `myzig.Handler(T)`, một phương thức của ứng dụng và một con trỏ để gọi nó:

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

Trình xử lý chạy trên luồng chính. Chuỗi họ nhận được trực tiếp cho cuộc gọi: sao chép những gì bạn giữ.

<a id="threads"></a>

## Luồng

AppKit, GTK, Win32, các trang và giao diện native tồn tại trên luồng chính và myzig gọi ứng dụng ở đó: lượt xem, phương thức liên kết, số lần nhấp vào menu, trình xử lý, bộ hẹn giờ. Không có gì trong ứng dụng cần khóa cho trạng thái riêng của nó miễn là nó vẫn ở đó.

Công việc mất nhiều thời gian thuộc về một luồng riêng, kết quả của nó quay trở lại luồng chính:

- `myzig.App.after(ms, ctx, func)` gọi `func(ctx)` trên luồng chính sau `ms` mili giây (`func` là `fn (?*anyopaque) callconv(.c) void`). Trên macOS nó có thể được gọi từ bất kỳ luồng nào (libdispatch); trên Linux và Windows gọi nó từ luồng chính.
- Các bài đăng [mainthread](plugins/mainthread.md) hoạt động với luồng chính từ bất kỳ nền tảng nào khác, trên mọi nền tảng, thông qua hàng đợi riêng của luồng chính (libdispatch, ngữ cảnh chính của GLib, cửa sổ chỉ có tin nhắn).
- `Window.sendOwned` xếp hàng tin nhắn cho một trang từ bất kỳ chuỗi nào và `Event` của `emit` gửi các sự kiện đã nhập ([Bindings](bindings.md)).
- Sau khi trạng thái thay đổi bên ngoài các sự kiện của view (bộ đếm thời gian, đầu ra của quá trình), `Window.redraw` rút lại giao diện native ở lần làm mới tiếp theo.

Không có polling nào: các khung được vẽ khi nhập, thay đổi kích thước hoặc trong khi hoạt ảnh chạy và ứng dụng không hoạt động không sử dụng CPU.

`myzig.runFor(seconds)` chạy vòng lặp sự kiện một lúc rồi trả về, đối với các bài kiểm tra headless chờ phản hồi, xử lý hoặc tính giờ.

<a id="quitting"></a>

## Đang bỏ cuộc

`app.quit()` dừng vòng lặp sự kiện; `run` trả về sau khi sự kiện hiện tại được xử lý và `main` chuyển sang `destroy`. Ứng dụng tự thoát:

- khi cửa sổ cuối cùng của nó đóng lại, trừ khi `quit_on_last_window_closed` là false (ứng dụng khay, ứng dụng thanh menu);
- trên Ctrl+C và SIGTERM, và trên Windows trên Ctrl+Break và bảng điều khiển đóng, trừ khi `quit_on_signal` là false. Tín hiệu thoát trên luồng chính, giống như `quit`; cái thứ hai thoát ra ngay lập tức;
- trên macOS, từ Thoát (⌘Q) và Dock của menu ứng dụng, dừng vòng lặp thay vì thoát, vì vậy `run` quay lại và `defer`s chạy.

`app.relaunch()` thoát theo cách tương tự, sau đó khởi động lại ứng dụng sau khi `destroy` giải phóng nó (các cửa sổ của nó đóng, khóa phiên bản duy nhất của nó được giải phóng): tệp thực thi mà nó chạy từ (cái mới, sau khi có bản cập nhật thay thế nó) với các đối số của lần khởi chạy, không có cờ riêng của myzig, trong thư mục làm việc của lần khởi chạy; sau khi thay đổi cài đặt cần khởi động lại, chẳng hạn. Trên Windows chỉ ứng dụng ở phía trước mới có thể đưa cửa sổ về phía trước và nó sẽ hiển thị cửa sổ đó khi cửa sổ đóng: `relaunch` chuyển sang bên phải trước tiên (`AllowSetForegroundWindow`), do đó, phiên bản mới sẽ mở ở phía trước thay vì phía sau bằng nút thanh tác vụ nhấp nháy. Trong `myzig dev`, bản dựng thoát ra với mã 75 thay vào đó, để `myzig dev` khởi động lại bản dựng; bị ẩn và headless chỉ chạy và thoát và trong trình duyệt `relaunch` là `quit`.

Một cửa sổ có thể tự mở khi người dùng đóng nó, với `on_close_request` ([Cửa sổ](windows.md#closing)). Trên macOS, việc nhấp vào biểu tượng Dock của một ứng dụng không có cửa sổ hiển thị sẽ mở lại ứng dụng cuối cùng.

<a id="a-single-instance"></a>

## Một trường hợp duy nhất

Nhiều ứng dụng chỉ nên chạy một lần: lần khởi chạy thứ hai sẽ chuyển dòng lệnh của nó sang lần khởi chạy đầu tiên và thoát.

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
if (!app.requestSingleInstanceLock()) return; // another instance has it
```

`requestSingleInstanceLock` trả về true trong phiên bản đầu tiên, sau đó nhận các đối số của mỗi lần khởi chạy sau đó (không có chương trình và cờ của myzig) và thư mục làm việc trong `on_second_instance`. Trong trường hợp sau, nó chuyển dòng lệnh của mình và trả về false: return from `main`. Các URL và tệp trong số các đối số của lần khởi chạy sau cũng đạt tới `on_open_url` và `on_open_file`, giống như lần khởi chạy đầu tiên.

Khóa được đặt tên theo `id`. Trên macOS và Linux đó là ổ cắm Unix trong `XDG_RUNTIME_DIR`, `TMPDIR` hoặc `/tmp` (một phiên bản bị lỗi bên trái được thay thế); trên Windows một mutex có tên, cửa sổ ẩn của chủ sở hữu nhận dòng lệnh (`WM_COPYDATA`) và có thể chiếm tiền cảnh. Thay vào đó, gói macOS được mở lại từ Finder sẽ được kích hoạt bởi macOS. Trong trình duyệt có một trang, luôn là trang đầu tiên.

<a id="bringing-the-app-forward"></a>

## Đưa ứng dụng về phía trước

`app.focus()` đưa ứng dụng lên phía trước với các cửa sổ theo thứ tự, khi nhấp chuột vào biểu tượng khay sẽ mở cài đặt của ứng dụng: một cửa sổ của ứng dụng đã có ở phía trước vẫn ở đó, nếu không thì cửa sổ mà người dùng sử dụng lần cuối sẽ xuất hiện (cửa sổ cao nhất của ứng dụng theo thứ tự z trên Windows, `activateIgnoringOtherApps:` trên macOS, cửa sổ đầu tiên hiển thị trên Linux). Flyouts không bao giờ chiếm lấy bàn phím không mang lại điều gì về phía trước. `focus()` của chính cửa sổ sẽ mang đến cửa sổ đó.

<a id="deep-links-and-file-associations"></a>

## Liên kết sâu và liên kết tập tin

Một ứng dụng sẽ mở URL của các lược đồ riêng của nó (`notes://open/42`) và các tệp thuộc loại của nó khi hệ thống khởi chạy nó cùng với chúng hoặc chuyển chúng cho ứng dụng đó trong khi nó chạy:

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

Windows và Linux khởi động ứng dụng với URL hoặc tệp làm đối số: `run` chuyển các lược đồ đó của ứng dụng cho `on_open_url` và các tệp có tiện ích mở rộng tồn tại của nó (đường dẫn và `file:` URL, được đặt tuyệt đối) cho `on_open_file`. Vào macOS chúng xuất hiện dưới dạng sự kiện của Apple (`application:openURLs:`), cùng một trình xử lý. Với một phiên bản duy nhất, các URL và tệp của lần khởi chạy sau này sẽ đến được trình xử lý của phiên bản đầu tiên.

Hệ thống phải biết ứng dụng xử lý chúng:

- **Các gói** khai báo chúng: `url_schemes` và `file_associations` trong `myzig.zon` đi vào macOS của gói `Info.plist`, tệp Linux `.desktop` và các loại MIME cũng như trình cài đặt Windows ([Cấu hình](configuration.md), [Phân phối](distribution.md)).
- **Tại thời điểm chạy**, `myzig.system.registerUrlScheme(app, "notes")` biến ứng dụng thành trình xử lý lược đồ của người dùng (đăng ký trên Windows, mục nhập XDG `.desktop` trên Linux, trình xử lý mặc định trên macOS, trong đó lược đồ cũng phải nằm trong `Info.plist`); `registerFileType` thực hiện tương tự đối với tiện ích mở rộng. Xem [Hệ thống](system.md).

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

// Buttons, and a reply field.
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

`myzig.Notification` có `id` (cho `removeNotification` và cho phản hồi), `title`, `subtitle`, `body`, `silent` không có âm thanh và `actions` (`myzig.NotificationAction`: `id`, `title`, `reply` cho trường văn bản có `placeholder`, `destructive`). Một lần nhấp đạt đến `on_notification` dưới dạng `myzig.NotificationResponse`, với `id` của thông báo, `action` được chọn (trống cho lần nhấp vào chính thông báo) và `reply` được nhập. `group` tập hợp các thông báo chia sẻ nó trong Trung tâm thông báo (mã nhận dạng chuỗi của macOS), chẳng hạn như tin nhắn của cuộc trò chuyện.

| nền tảng | làm thế nào |
|---|---|
| macOS | UNUserNotificationCenter, hành động dưới dạng danh mục thông báo: ứng dụng phải là một gói (`myzig build`) |
| Linux | máy chủ thông báo của máy tính để bàn qua D-Bus; một cái có id của một cái hiển thị sẽ thay thế nó |
| Windows | chúc mừng (ToastNotificationManager của WinRT), với các nút và trường trả lời, bên dưới `id` của ứng dụng làm AppUserModelID của nó; một ứng dụng chưa được đóng gói sẽ có lối tắt menu Bắt đầu mang nó trong thông báo đầu tiên. Các lần nhấp đến trong khi ứng dụng chạy và sau khi ứng dụng thoát: phím tắt đặt tên cho trình kích hoạt thông báo toast của ứng dụng (CLSID có nguồn gốc từ `id` của nó, được đăng ký theo `HKCU\Software\Classes\CLSID`), do đó, một lần nhấp sẽ khởi động ứng dụng với `--myzig-toast-activated` và đạt đến `on_notification` sau khi `run` bắt đầu; một ứng dụng đang chạy sẽ nhận được nó trực tiếp. Ở những nơi không thể hiển thị thông báo toast, bong bóng của biểu tượng khay đầu tiên của ứng dụng |
| trình duyệt | `error.Unsupported` |

<a id="sender-avatars-on-macos"></a>

### Hình đại diện của người gửi trên macOS

Một tin nhắn trực tiếp đến có thể nêu tên người gửi, có hình đại diện macOS 12 trở lên hiển thị cùng với biểu tượng nhỏ của ứng dụng:

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

`sender.id` nhận dạng người trong ứng dụng; nó không được coi là địa chỉ email hoặc số điện thoại. `name` mặc định là `title`; `avatar` là hình ảnh được mã hóa (PNG, JPEG) mà ứng dụng có sẵn. `group` là mã nhận dạng của cuộc trò chuyện, `id` của thông báo không có mã nhận dạng nào. Đó là tin nhắn đến từ một người, không phải tin nhắn nhóm hay tin nhắn gửi đi. macOS đưa ra thông báo: phụ đề nằm phía trên nội dung.

Ứng dụng cần có khả năng **Thông báo liên lạc** của ID ứng dụng Apple, `INSendMessageIntent` trong `Info.plist`'s `NSUserActivityTypes` và chữ ký có quyền `com.apple.developer.usernotifications.communication` và hồ sơ cấp phép ủy quyền cho ứng dụng đó (cũng để phân phối ID nhà phát triển). Không cấp quyền hạn chế cho bản dựng đặc biệt: macOS có thể từ chối khởi chạy bản dựng đó. myzig kiểm tra quyền đã ký trước khi gửi tin nhắn cho SiriKit và cập nhật nội dung thông báo với nó; không có khả năng, với người gửi thiếu `id` hoặc `avatar` có thể đọc được hoặc khi quyên góp hoặc cập nhật không thành công, thông báo thông thường sẽ hiển thị. Trong khi đó, một thông báo đang được chuẩn bị bị xóa hoặc thay thế theo `id` của nó sẽ không bao giờ hiển thị. Windows, Linux và trình duyệt bỏ qua `sender`.

<a id="appearance"></a>

## Ngoại hình

`on_appearance` nghe thấy hệ thống chuyển đổi giữa sáng và tối. Giao diện native tự theo sau trừ khi cửa sổ có `theme` cố định và các trang có `prefers-color-scheme`; trình xử lý dành cho màu sắc riêng của ứng dụng. `myzig.isDark()` và `myzig.accentColor()` đọc giao diện hiện tại ([System](system.md)).

<a id="the-network"></a>

## Mạng lưới

```zig
const s = app.networkStatus();
if (!s.online) showOffline();
if (s.metered) askBeforeDownloading();
```

`myzig.NetworkStatus` cho biết máy tính có phải là `online` (lối ra: đường dẫn thỏa mãn của macOS, GNetworkMonitor của Linux, kết nối cục bộ hoặc internet của Windows; cổng bị khóa được tính, như đối với `navigator.onLine` của trình duyệt) và kết nối có phải là `metered` (di động, điểm phát sóng, Chế độ dữ liệu thấp, chi phí giới hạn hoặc chuyển vùng). `on_network` chỉ được gọi khi một trong số chúng thay đổi: hệ thống báo cáo các thay đổi về tuyến đường và giao diện khiến chúng giữ nguyên như cũ và myzig lọc chúng ra. Ứng dụng bắt đầu xem khi `run` khởi động và chỉ khi `on_network` được đặt.

<a id="the-dock-and-the-taskbar"></a>

## Dock và thanh tác vụ

- `app.setBadge("3")` đặt một huy hiệu trên biểu tượng Dock (macOS), số lượng mục nhập trình khởi chạy của các dock có API trình khởi chạy Unity (Linux) hoặc một huy hiệu được vẽ trên nút thanh tác vụ (Windows, biểu tượng lớp phủ của nó); trống loại bỏ nó.
- `Window.setProgress` hiển thị tiến trình của tác vụ trên nút thanh tác vụ (Windows), mục nhập trình khởi chạy (Linux) hoặc thanh trên biểu tượng Dock (macOS); `Window.flash` yêu cầu sự chú ý ([Cửa sổ](windows.md#attention-and-progress)).
- `myzig.system.setJumpList` cung cấp các tác vụ trong danh sách nhảy của nút thanh tác vụ Windows và các tài liệu gần đây sẽ điền vào đó ([Hệ thống](system.md)).

<a id="start-at-login"></a>

## Bắt đầu lúc đăng nhập

`myzig.system.setOpenAtLogin(app, true)` mở ứng dụng khi người dùng đăng nhập (mục đăng nhập trên macOS 13 trở lên, dành cho các gói; mục Chạy trên Windows; mục nhập tự động khởi động XDG trên Linux), `openAtLogin(app)` cho biết liệu điều đó có xảy ra hay không và `wasOpenedAtLogin(app)` liệu lần khởi chạy này có phải là lần khởi động như vậy hay không (mục nhập này vượt qua `--myzig-login`), đối với một ứng dụng khởi động lặng lẽ, không có cửa sổ. Xem [Hệ thống](system.md).

<a id="platforms"></a>

## Nền tảng

| | macOS | Linux | Windows | trình duyệt |
|---|---|---|---|---|
| vòng lặp sự kiện | AppKit | GTK 3 (`dlopen`) | Tin nhắn Win32 | khung của trang |
| trường hợp duy nhất | Ổ cắm Unix | Ổ cắm Unix | tên là mutex | luôn luôn đầu tiên |
| liên kết sâu, tập tin | sự kiện của Apple | lý lẽ | lý lẽ | không |
| thông báo | Trung tâm thông báo UNUser | D-Bus | khay bóng bay, thông báo toast | không |
| trạng thái mạng | Mạng.framework | GNetworkMonitor | quản lý danh sách mạng | giả định trực tuyến |
| huy hiệu | bến tàu | Trình khởi chạy đoàn kết | không | không |
| tín hiệu | SIGINT, SIGTERM | SIGINT, SIGTERM | sự kiện điều khiển bảng điều khiển | không |

Trong các trình duyệt ([Trình duyệt](browsers.md)), ứng dụng là một trang: `App.create` và `run` hoạt động như những nơi khác, các cửa sổ của giao diện native lấp đầy khung vẽ của trang và những gì không có ý nghĩa sẽ bị lỗi với `error.Unsupported` (khay, thông báo) hoặc không làm gì cả; các phím tắt và bảng thả xuống toàn cầu hoàn toàn không có ở đó.
