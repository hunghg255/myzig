<a id="menus-trays-and-global-shortcuts"></a>

# Menu, khay hệ thống và phím tắt toàn cục

Thanh menu, icon ở khay hệ thống và phím tắt toàn cục thuộc về app, không thuộc về một cửa sổ nào. Menu được dựng từ template: mảng `myzig.MenuItem`, giống nhau trên mọi nền tảng. Menu vẽ bên trong native UI (context menu, nút menu, select) là widget: xem [Menu trong native UI](ui/menus.md).

<a id="templates"></a>

## Template

```zig
const Menus = struct {
    fn newNote(m: *Menus, item: *myzig.menu.Item) void {
        _ = item;
        m.notes.add();
    }
    fn wrap(m: *Menus, item: *myzig.menu.Item) void {
        m.editor.wrap = item.checked; // đã được đảo trước đó
    }
    fn small(m: *Menus, _: *myzig.menu.Item) void {
        m.editor.size = 13;
    }
    fn large(m: *Menus, _: *myzig.menu.Item) void {
        m.editor.size = 17;
    }
};

var menus: Menus = .{ .notes = &notes, .editor = &editor };
try app.setMenu(&.{
    .{ .role = .app_menu },
    .{ .label = "File", .submenu = &.{
        .{ .label = "New Note", .accelerator = "CmdOrCtrl+N", .click = .of(&menus, Menus.newNote) },
        .separator,
        .{ .role = .close },
    } },
    .{ .role = .edit_menu },
    .{ .label = "Format", .submenu = &.{
        .{ .label = "Wrap Lines", .id = "wrap", .kind = .checkbox, .checked = true, .click = .of(&menus, Menus.wrap) },
        .separator,
        .{ .label = "Small", .kind = .radio, .checked = true, .click = .of(&menus, Menus.small) },
        .{ .label = "Large", .kind = .radio, .click = .of(&menus, Menus.large) },
    } },
    .{ .role = .view_menu },
    .{ .role = .window_menu },
});
```

| `myzig.MenuItem` | |
|---|---|
| `label` | chữ của mục; để trống thì dùng label của role |
| `accelerator` | tổ hợp phím của mục ([Accelerator](#accelerators)) |
| `role` | một mục chuẩn hoặc cả một menu chuẩn ([Role](#roles)) |
| `kind` | `.normal`, `.checkbox` hoặc `.radio` |
| `checked` | state ban đầu của mục checkbox hoặc radio |
| `disabled` | bị làm xám |
| `hidden` | bị bỏ qua |
| `tooltip` | hiện khi rê chuột (macOS) |
| `id` | để tìm lại mục sau này bằng `app.menuItem(id)` |
| `submenu` | một template riêng: mục này mở nó ra |
| `click` | một `myzig.MenuClick`: `.of(&state, State.method)` với `fn method(s: *State, item: *myzig.menu.Item) void` |

`.separator` là đường kẻ ngăn giữa các nhóm mục.

- Click chạy trên main thread.
- `checked` của mục checkbox được đảo trước khi click của nó chạy.
- Mục radio được đánh dấu, các mục còn lại trong nhóm bị bỏ đánh dấu. Một nhóm là các mục radio đứng liền nhau, tới separator hoặc một mục khác loại.
- Trên Windows, Linux và trình duyệt, myzig tự dựng menu và giữ nguyên các chuỗi của template. Template tạo lúc chạy, cùng các context của `click`, phải sống lâu hơn menu.

<a id="roles"></a>

### Role

Role cho một mục label, accelerator và hành động của hệ thống. App không phải viết gì cho nó:

| role | macOS | Windows và Linux |
|---|---|---|
| `.about` | About *App* | bỏ qua |
| `.hide`, `.hide_others`, `.unhide` | Hide *App* (⌘H), Hide Others (⌥⌘H), Show All | bỏ qua |
| `.quit` | Quit *App* (⌘Q) | E&xit |
| `.undo`, `.redo` | Undo (⌘Z), Redo (⇧⌘Z) | Ctrl+Z, Ctrl+Y |
| `.cut`, `.copy`, `.paste`, `.delete`, `.select_all` | ⌘X, ⌘C, ⌘V, Delete, ⌘A | Ctrl+X, Ctrl+C, Ctrl+V, Delete, Ctrl+A |
| `.minimize`, `.zoom` | Minimize (⌘M), Zoom | Minimize, Maximize |
| `.close` | Close Window (⌘W) | Close (Ctrl+W) |
| `.toggle_full_screen` | Enter Full Screen (⌃⌘F) | Toggle Full Screen (F11) |
| `.front` | Bring All to Front | bỏ qua |

- Các role chỉnh sửa tác động lên thứ đang giữ bàn phím: ô nhập chữ của native UI, hoặc phần tử đang có focus trong trang.
- Các role cửa sổ tác động lên cửa sổ ở phía trước.
- Mục có cả role lẫn `click` thì chạy click của nó.

Bốn role đại diện cho cả một menu, với các mục quen thuộc:

| role | macOS | Windows và Linux |
|---|---|---|
| `.app_menu` | tên app: About, Hide, Hide Others, Show All, Quit | File: Exit |
| `.edit_menu` | Edit: Undo, Redo, Cut, Copy, Paste, Select All | Edit: như trên, thêm Delete |
| `.view_menu` | View: Enter Full Screen | View: Toggle Full Screen |
| `.window_menu` | Window: Minimize, Zoom, Bring All to Front, Close | Window: Minimize, Maximize, Close |

- Role cả menu mà có `submenu` riêng thì giữ tiêu đề và role, nhưng hiện các mục đó thay thế. `label` trở thành tiêu đề của nó.
- Trên macOS, `.window_menu` cũng là nơi AppKit liệt kê các cửa sổ.
- Trên macOS, mọi app khởi đầu với `myzig.App.default_menu`: menu app, Edit, View và Window.
- Trên macOS, hãy giữ `.edit_menu` trong menu của bạn. Ô nhập chữ của trang web cần nó để copy và paste bằng bàn phím.
- Trên Windows và Linux, app không có menu cho tới khi gọi `setMenu`.

<a id="changing-items"></a>

### Thay đổi mục

```zig
if (app.menuItem("wrap")) |item| {
    item.setChecked(false);
    item.setEnabled(editor.open);
}
```

`app.menuItem(id)` tìm mục trên thanh menu có `id` đó trong template.

| | |
|---|---|
| `setChecked` | đánh dấu mục checkbox hoặc radio; mục radio bỏ đánh dấu cả nhóm |
| `setEnabled` | làm xám hoặc không |
| `setLabel` | đổi chữ của mục (macOS) |
| `item.checked`, `item.id` | đọc state của mục |

Muốn đổi nhiều hơn thì gọi lại `setMenu` với template khác. Nó thay cả thanh menu.

<a id="the-menu-bar"></a>

## Thanh menu

`app.setMenu(template)` thay thanh menu:

- **macOS**: thanh menu ở đầu màn hình, dựng bằng NSMenu.
- **Windows**: thanh menu ở đầu mọi cửa sổ có thanh tiêu đề, dựng bằng HMENU. Cửa sổ ẩn thanh tiêu đề hoặc không có khung thì không có. Dấu check và mục bị làm xám được cập nhật mỗi lần mở menu.
- **Linux**: không hiện thanh nào; accelerator hoạt động trong mọi cửa sổ.
- **Trình duyệt**: không hiện thanh nào; accelerator hoạt động trong trang.

Phím và label:

- Ở mọi nơi, accelerator của một mục menu sẽ chạy mục đó, cả trong native UI lẫn trong trang.
- Trên Windows và Linux, `&` trong label đánh dấu phím tắt gạch chân của nó (`"&File"`), như tiêu đề của các menu chuẩn. `"&&"` là một dấu &. macOS hiện label đúng như viết.
- Trên Windows và Linux, view nào đặt `c.keys_first` sẽ nhận tổ hợp phím trước accelerator của thanh menu. Giá trị này được giữ qua các frame. Accelerator chỉ chạy khi view không nhận phím đó: terminal đang giữ bàn phím sẽ giữ Ctrl+L hay Ctrl+W cho shell của nó.

<a id="context-menus"></a>

## Context menu

Context menu của native UI là một widget, `ui.contextMenu`. myzig vẽ nó trong lớp riêng của cửa sổ, có điều hướng bằng bàn phím, submenu và dấu check: xem [Menu trong native UI](ui/menus.md). Trang web hiện menu riêng của chúng, hoặc menu của webview (có Inspect Element khi bật `inspectable`).

<a id="tray-icons"></a>

## Icon ở khay hệ thống

```zig
const Tray = struct {
    fn show(t: *Tray, _: *myzig.menu.Item) void {
        t.window.show();
        t.window.focus();
    }
    fn clicked(t: *Tray, _: *myzig.Tray) void {
        t.window.show();
    }
};

var tray_state: Tray = .{ .window = win };
const tray = try app.newTray(.{
    .icon = @embedFile("tray.png"),
    .symbol = "bolt.fill",
    .tooltip = "Sync",
    .menu = &.{
        .{ .label = "Show Window", .click = .of(&tray_state, Tray.show) },
        .separator,
        .{ .role = .quit },
    },
    .on_click = .of(&tray_state, Tray.clicked),
});
```

`app.newTray` thêm một icon vào vùng trạng thái của thanh menu (macOS), vùng thông báo (Windows) hoặc panel (Linux).

| `myzig.TrayOptions` | |
|---|---|
| `id` | tên của icon qua các lần chạy, không trùng giữa các icon của app ([Nhiều icon](#several-icons)) |
| `title` | chữ cạnh icon (thanh menu của macOS, các panel Linux có hiện label); ở nơi khác là tooltip khi không có tooltip |
| `symbol` | tên một SF Symbol (`"star.fill"`), vẽ thành ảnh template theo giao diện của thanh menu (macOS) |
| `icon` | các byte của một file PNG (vuông 16 hoặc 32 pixel hợp với Windows); để trống thì dùng icon của app |
| `template` | icon đen và trong suốt: macOS tô màu cho hợp thanh menu, Windows hiện nó màu trắng trên taskbar tối |
| `tooltip` | hiện khi rê chuột |
| `menu` | một template, hiện khi bấm chuột phải (Windows) hoặc khi bấm bất kỳ (nơi khác) |
| `on_click` | một `myzig.TrayClick`: bấm chuột trái trên Windows, bấm trên macOS khi không có menu, bấm vào GtkStatusIcon trên Linux |
| `on_appearance` | một `myzig.TrayClick`, được gọi khi thanh chứa icon chuyển tối hoặc sáng (`tray.dark()`) |

- Icon tồn tại tới khi gọi `app.removeTray(tray)` hoặc app kết thúc.
- Đổi nó bằng `setTitle`, `setTooltip`, `setSymbol` (macOS), `setIcon(png)` và `setMenu(app.options.name, template)`.
- `popUpMenu()` mở menu của nó từ code (Windows, Linux).

Cách mỗi nền tảng hiển thị:

- **macOS**: một NSStatusItem trên thanh menu. Có menu thì bấm sẽ mở menu; không có thì bấm sẽ gọi `on_click`.
- **Windows**: icon ở vùng thông báo. Bấm chuột trái gọi `on_click`, chuột phải mở menu. Icon khay đầu tiên cũng hiện các thông báo của app ([Thông báo](app.md#notifications)).
- **Linux**: một StatusNotifierItem qua libayatana-appindicator, nạp bằng `dlopen`. Panel hiện menu của nó khi bấm. Không có thư viện này thì dùng GtkStatusIcon (panel X11 có system tray): bấm gọi `on_click`, chuột phải mở menu. Chạy không có màn hình thì lỗi `error.Headless`.
- **Trình duyệt**: `error.Unsupported`.

App sống ở khay hệ thống thì:

- đặt `quit_on_last_window_closed = false`, để đóng cửa sổ mà app vẫn chạy;
- giữ một mục `.quit` trong menu của khay;
- hiện panel dưới icon bằng một flyout neo vào icon khay ([Flyout](windows.md#flyouts)).

Các lần chạy headless (`--myzig-hidden`, `--myzig-eval`) không nên thêm icon: kiểm tra `app.flags.hidden` trước.

<a id="several-icons"></a>

### Nhiều icon

App có thể hiện nhiều icon, như một app thanh menu hiện mỗi số đo trong một mục riêng.

- **macOS**: icon mới nằm bên trái các icon đã có. Người dùng di chuyển icon bằng cách giữ ⌘ và kéo. Icon có `id` sẽ trở về chỗ người dùng đặt mỗi khi được tạo lại, ở lần chạy sau hoặc sau `removeTray`. `id` là autosave name của status item.
- **Windows**: người dùng chọn icon nào hiện trên taskbar, icon nào nằm trong phần tràn. Icon có `id` giữ lựa chọn đó bất kể app tạo các icon theo thứ tự nào. Nó được đánh số theo `id` (FNV-1a, bật bit cao nhất), không đếm theo thứ tự tạo.
- **Linux**: panel tự sắp xếp icon.

<a id="dark-and-light-bars"></a>

### Thanh tối và sáng

Icon template tự theo màu của thanh. Icon có màu, ví dụ icon vẽ mỗi số đo một màu, tự chọn màu vẽ cho hợp thanh:

- `tray.dark()` cho biết thanh có tối không.
- `on_appearance` được gọi trên main thread khi thanh đổi màu. Gọi lại `setIcon` trong đó.
- **macOS**: thanh menu theo cách AppKit tô màu các mục của nó, dựa vào giao diện hệ thống hoặc hình nền dưới thanh trong mờ.
- **Windows**: taskbar theo chế độ của hệ thống, có thể khác chế độ của các app.
- **Linux**: panel vẽ icon theme theo cách riêng, và `dark()` là false.

<a id="global-shortcuts"></a>

## Phím tắt toàn cục

Phím tắt toàn cục tới được app ngay cả khi app khác đang ở phía trước, như các launcher (Spotlight, Raycast, PowerToys Run):

```zig
const Launcher = struct {
    panel: *myzig.Window,

    fn toggle(l: *Launcher, _: void) void {
        if (l.panel.isVisible()) l.panel.hide() else {
            l.panel.show();
            l.panel.focus();
        }
    }
};

var launcher: Launcher = .{ .panel = panel };
const id = try app.registerHotkey("Alt+Shift+Space", .of(&launcher, Launcher.toggle));
defer app.unregisterHotkey(id);
```

`registerHotkey` nhận một [accelerator](#accelerators) và một `myzig.Handler(void)`, chạy trên main thread mỗi lần phím được bấm. Nó trả về id của phím tắt để dùng với `unregisterHotkey`. Các lỗi:

- `error.UnsupportedKey`: phím mà phím tắt toàn cục không dùng được, hoặc không có phím;
- `error.Unavailable`: app khác đã giữ nó, hoặc hệ thống từ chối;
- `error.Unsupported`: hệ thống không có phím tắt toàn cục.

| nền tảng | cách làm |
|---|---|
| macOS | RegisterEventHotKey của Carbon |
| Windows | RegisterHotKey trên cửa sổ ẩn của app |
| Linux | X11 key grab trên cửa sổ gốc, với Caps Lock và Num Lock bật hoặc tắt; trên Wayland là GlobalShortcuts của desktop portal (desktop hỏi người dùng cho phép một lần) |
| trình duyệt | không có |

`App.destroy` hủy đăng ký các phím tắt còn lại.

<a id="accelerators"></a>

## Accelerator

Các phím bổ trợ và một phím, nối bằng `+`:

```
CmdOrCtrl+N   CmdOrCtrl+Shift+K   Alt+Up   F5   Cmd+,   Cmd++   Ctrl+Space
```

| phần | tên |
|---|---|
| ⌘ trên macOS, Ctrl ở nơi khác | `CmdOrCtrl`, `CommandOrControl`, `Cmd`, `Command`, `Super`, `Meta` |
| Control | `Ctrl`, `Control` |
| Alt, ⌥ | `Alt`, `Option` |
| Shift | `Shift` |
| phím có tên | `Up`, `Down`, `Left`, `Right`, `Enter`, `Return`, `Tab`, `Space`, `Escape`, `Esc`, `Backspace`, `Delete`, `Home`, `End`, `PageUp`, `PageDown`, `Plus`, `F1` tới `F20` |
| phím khác | chính ký tự đó (`N`, `,`, `/`); `Cmd++` là phím cộng |

- Tên không phân biệt hoa thường.
- Trên Windows và Linux, ⌘ và Ctrl đều là Ctrl. Menu hiện accelerator theo cách các hệ thống đó viết (`Ctrl+Shift+K`).
- macOS hiện chúng bằng ký hiệu riêng.
- Trong native UI, `ui.keys.label("⌘P")` và `ui.shortcutLabel` viết tổ hợp phím theo nền tảng ([Navigation](ui/navigation.md)).
