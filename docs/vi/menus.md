<a id="menus-trays-and-global-shortcuts"></a>

# Menu, khay và phím tắt chung

Thanh menu, biểu tượng khay và lối tắt chung là của ứng dụng chứ không phải của cửa sổ. Các menu được xây dựng từ các mẫu: mảng `myzig.MenuItem`, giống nhau trên mọi nền tảng. Các menu được vẽ bên trong giao diện native (menu ngữ cảnh, nút menu, lựa chọn) là các widget: xem [Giao diện native menu](ui/menus.md).

<a id="templates"></a>

## Mẫu

```zig
const Menus = struct {
    fn newNote(m: *Menus, item: *myzig.menu.Item) void {
        _ = item;
        m.notes.add();
    }
    fn wrap(m: *Menus, item: *myzig.menu.Item) void {
        m.editor.wrap = item.checked; // already toggled
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

`myzig.MenuItem` có:

| lĩnh vực | nó là gì |
|---|---|
| `label` | văn bản của nó; nhãn riêng của vai trò khi trống |
| `accelerator` | tổ hợp phím của nó ([Accelerators](#accelerators)) |
| `role` | một mục tiêu chuẩn hoặc toàn bộ menu tiêu chuẩn ([Vai trò](#roles)) |
| `kind` | `.normal`, `.checkbox` hoặc `.radio` |
| `checked` | trạng thái ban đầu của hộp kiểm hoặc mục radio |
| `disabled` | chuyển sang màu xám |
| `hidden` | bị bỏ rơi |
| `tooltip` | hiển thị khi di chuột (macOS) |
| `id` | để tìm mục sau bằng `app.menuItem(id)` |
| `submenu` | một mẫu riêng: mục này sẽ mở nó |
| `click` | một `myzig.MenuClick`: `.of(&state, State.method)` với `fn method(s: *State, item: *myzig.menu.Item) void` |

`.separator` là ranh giới giữa các nhóm mục.

Nhấp chuột chạy trên luồng chính. `checked` của mục hộp kiểm được bật tắt trước khi nhấp chuột của mục đó chạy và mục radio được chọn và các mục khác trong nhóm của nó không được chọn: các mục radio cạnh nhau, cho đến dấu phân cách hoặc loại mục khác, đều là một nhóm.

Mẫu thường là chữ, như trên. Trong đó myzig tự xây dựng các menu (Windows, Linux, trình duyệt), các mục sẽ giữ chuỗi của mẫu, do đó, mẫu được tạo trong thời gian chạy và bối cảnh `click` phải tồn tại lâu hơn menu.

<a id="roles"></a>

### Vai trò

Một vai trò cung cấp cho một mục nhãn, phím tắt và hành động của hệ thống, vì vậy ứng dụng không ghi gì cho mục đó:

| vai trò | macOS | Windows và Linux |
|---|---|---|
| `.about` | Giới thiệu về *Ứng dụng* | bị bỏ rơi |
| `.hide`, `.hide_others`, `.unhide` | Ẩn *Ứng dụng* (⌘H), Ẩn ứng dụng khác (⌥⌘H), Hiển thị tất cả | bị bỏ rơi |
| `.quit` | Thoát *Ứng dụng* (⌘Q) | &Thoát |
| `.undo`, `.redo` | Hoàn tác (⌘Z), Làm lại (⇧⌘Z) | Ctrl+Z, Ctrl+Y |
| `.cut`, `.copy`, `.paste`, `.delete`, `.select_all` | ⌘X, ⌘C, ⌘V, Xóa, ⌘A | Ctrl+X, Ctrl+C, Ctrl+V, Xóa, Ctrl+A |
| `.minimize`, `.zoom` | Thu nhỏ (⌘M), Thu phóng | Giảm thiểu, tối đa hóa |
| `.close` | Đóng cửa sổ (⌘W) | Đóng (Ctrl+W) |
| `.toggle_full_screen` | Vào toàn màn hình (⌃⌘F) | Chuyển đổi toàn màn hình (F11) |
| `.front` | Đưa tất cả lên phía trước | bị bỏ rơi |

Vai trò chỉnh sửa hoạt động trên nội dung có bàn phím: trường văn bản giao diện native, thành phần tập trung của trang. Vai trò cửa sổ hoạt động trên cửa sổ phía trước. Một mục có vai trò và `click` sẽ chạy nhấp chuột.

Bốn vai trò đại diện cho toàn bộ menu, chứa đầy các mục thông thường của chúng:

| vai trò | macOS | Windows và Linux |
|---|---|---|
| `.app_menu` | tên ứng dụng: Giới thiệu, Ẩn, Ẩn người khác, Hiển thị tất cả, Thoát | Tập tin: Thoát |
| `.edit_menu` | Chỉnh sửa: Hoàn tác, Làm lại, Cắt, Sao chép, Dán, Chọn tất cả | Chỉnh sửa: tương tự, với Xóa |
| `.view_menu` | Xem: Vào toàn màn hình | Xem: Chuyển đổi toàn màn hình |
| `.window_menu` | Cửa sổ: Thu nhỏ, Thu phóng, Đưa tất cả ra phía trước, Đóng | Cửa sổ: Thu nhỏ, Phóng to, Đóng |

Vai trò toàn bộ menu có `submenu` của riêng nó sẽ giữ tiêu đề và vai trò của nó và thay vào đó hiển thị các mục đó; với `label`, nhãn là tiêu đề của nó. Trên macOS, `.window_menu` cũng là menu AppKit liệt kê các cửa sổ.

Trên macOS mọi ứng dụng đều bắt đầu bằng `myzig.App.default_menu`: menu ứng dụng, Chỉnh sửa, Xem và Cửa sổ. Các trường văn bản của trang web cần có menu Chỉnh sửa để sao chép và dán bằng bàn phím ở đó, vì vậy hãy giữ `.edit_menu` trong menu của riêng bạn. Trên Windows và Linux, ứng dụng không có menu cho đến khi nó gọi `setMenu`.

<a id="changing-items"></a>

### Thay đổi mục

```zig
if (app.menuItem("wrap")) |item| {
    item.setChecked(false);
    item.setEnabled(editor.open);
}
```

`app.menuItem(id)` tìm thấy mục của thanh menu có mẫu có `id`. `setChecked` thay đổi hộp kiểm hoặc mục radio (việc chọn mục radio sẽ bỏ chọn nhóm của nó), `setEnabled` làm nó chuyển sang màu xám hay không; `item.checked` và `item.id` đọc nó. Trên macOS `setLabel` thay đổi văn bản của nó. Để thay đổi nhiều hơn, hãy gọi lại `setMenu` bằng một mẫu khác: nó thay thế thanh menu.

<a id="the-menu-bar"></a>

## Thanh thực đơn

`app.setMenu(template)` thay thế thanh menu:

- **macOS**: thanh menu phía trên màn hình, được xây dựng từ NSMenus.
- **Windows**: một thanh menu ở đầu mỗi cửa sổ có thanh tiêu đề (các cửa sổ có thanh tiêu đề bị ẩn hoặc không có khung), được xây dựng từ HMENU; séc và các mục màu xám được làm mới khi mỗi menu mở ra.
- **Linux**: không có thanh nào hiển thị; bộ tăng tốc của vật phẩm hoạt động trong mọi cửa sổ.
- **Trình duyệt**: không có thanh hiển thị; bộ tăng tốc hoạt động trong trang.

Ở mọi nơi, tổ hợp phím dùng để tăng tốc mục menu sẽ chạy mục đó trong giao diện native và trong các trang. Trên Windows và Linux, `&` trong nhãn đánh dấu từ gợi nhớ của nó (`"&File"`; `"&&"` là ký hiệu và), giống như tiêu đề của menu tiêu chuẩn; macOS hiển thị nhãn như được viết.

Trên Windows và Linux, một view đặt `c.keys_first` (được giữ trên các khung) được cung cấp một tổ hợp phím trước bộ tăng tốc của thanh menu. View này chỉ chạy khi view không nhận nó: một terminal có bàn phím giữ Ctrl+L hoặc Ctrl+W cho lớp shell của nó.

<a id="context-menus"></a>

## Menu ngữ cảnh

Menu ngữ cảnh của giao diện native là một widget, `ui.contextMenu`, được vẽ bởi myzig trong lớp riêng của cửa sổ, với điều hướng bàn phím, menu con và kiểm tra: xem [Giao diện native menu](ui/menus.md). Các trang hiển thị trang của chính chúng hoặc của webview (với Kiểm tra phần tử trong khi `inspectable` được đặt).

<a id="tray-icons"></a>

## Biểu tượng khay

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

`app.newTray` thêm biểu tượng vào vùng trạng thái của thanh menu (macOS), vùng thông báo (Windows) hoặc bảng điều khiển (Linux). `myzig.TrayOptions`:

| lĩnh vực | nó là gì |
|---|---|
| `id` | đặt tên cho biểu tượng trong các lần ra mắt, duy nhất trong số các biểu tượng của ứng dụng (bên dưới) |
| `title` | văn bản bên cạnh biểu tượng (thanh menu của macOS, bảng Linux hiển thị nhãn); chú giải công cụ ở nơi khác khi không có |
| `symbol` | Tên của Biểu tượng SF (`"star.fill"`), được vẽ dưới dạng hình ảnh mẫu theo giao diện của thanh menu (macOS) |
| `icon` | byte của tệp PNG (bộ hình vuông 16 hoặc 32 pixel Windows); biểu tượng của ứng dụng khi trống |
| `template` | biểu tượng có màu đen và trong suốt: macOS tô màu cho phù hợp với thanh menu, Windows hiển thị màu trắng trên thanh tác vụ tối |
| `tooltip` | hiển thị khi di chuột |
| `menu` | một mẫu, được hiển thị khi nhấp chuột phải (Windows) hoặc bất kỳ lần nhấp chuột nào (ở nơi khác) |
| `on_click` | a `myzig.TrayClick`: nhấp chuột trái vào Windows, nhấp chuột vào macOS khi không có menu, nhấp chuột vào GtkStatusIcon trên Linux |
| `on_appearance` | `myzig.TrayClick` được gọi là thanh biểu tượng hiển thị chuyển sang màu tối hoặc sáng (`tray.dark()`) |

Biểu tượng tồn tại cho đến khi `app.removeTray(tray)` hoặc khi ứng dụng kết thúc. Thay đổi nó bằng `setTitle`, `setTooltip`, `setSymbol` (macOS), `setIcon(png)` và `setMenu(app.options.name, template)`; `popUpMenu()` mở menu từ mã (Windows, Linux).

Một ứng dụng có thể hiển thị một số biểu tượng, vì một ứng dụng trên thanh menu hiển thị các số đo của từng biểu tượng trong một mục riêng. Trên macOS, một biểu tượng mới sẽ nằm bên trái những biểu tượng đã có ở đó và người dùng di chuyển các biểu tượng bằng cách kéo chúng với ⌘ được giữ: đặt cho mỗi biểu tượng một `id`, duy nhất trong số các biểu tượng của ứng dụng và nó sẽ quay trở lại vị trí mà người dùng đặt bất cứ khi nào nó được tạo lại, vào lần khởi chạy tiếp theo hoặc sau `removeTray` (tên tự động lưu của mục trạng thái). Trên Windows, nơi người dùng chọn biểu tượng nào hiển thị trên thanh tác vụ thay vì tràn ra, một biểu tượng có `id` sẽ giữ nguyên lựa chọn đó bất kể thứ tự mà ứng dụng tạo biểu tượng: nó được đánh số bằng `id` (FNV-1a, với bộ bit cao), không được tính khi xuất hiện các biểu tượng. Linux bảng tự đặt các biểu tượng.

Biểu tượng mẫu tự đi theo thanh. Một biểu tượng có màu, khi người ta vẽ từng thước đo bằng màu riêng của nó, vẽ mực cho thanh: `tray.dark()` cho biết thanh đó có tối hay không — thanh menu macOS khi AppKit tô màu các mục của nó (theo giao diện của hệ thống hoặc hình nền bên dưới thanh mờ), thanh tác vụ Windows ở chế độ của hệ thống, có thể khác với chế độ của ứng dụng — và `on_appearance` được gọi trên luồng chính khi nó quay lại thành `setIcon`. Linux các bảng vẽ luồng biểu tượng theo cách riêng của chúng: `dark()` là false ở đó.

Cách mỗi nền tảng hiển thị nó:

- **macOS**: một NSStatusItem trên thanh menu. Với một menu, một cú nhấp chuột sẽ mở nó ra; không có ai, một cú nhấp chuột sẽ gọi `on_click`.
- **Windows**: biểu tượng khu vực thông báo. Nhấp chuột trái gọi `on_click`, nhấp chuột phải sẽ mở menu. Biểu tượng khay đầu tiên cũng hiển thị các thông báo của ứng dụng ([Thông báo](app.md#notifications)).
- **Linux**: StatusNotifierItem thông qua libayatana-appindicator (được tải bằng `dlopen`), bảng này sẽ hiển thị cùng với menu của nó khi nhấp chuột. Khi thiếu thư viện, GtkStatusIcon (bảng X11 có khay hệ thống): một cú nhấp chuột sẽ gọi `on_click`, một cú nhấp chuột phải sẽ mở menu. Quá trình chạy không có màn hình không thành công với `error.Headless`.
- **Trình duyệt**: `error.Unsupported`.

Các ứng dụng nằm trong bộ khay `quit_on_last_window_closed = false`, do đó việc đóng cửa sổ sẽ khiến chúng chạy và giữ mục `.quit` trong menu của khay. Một bảng bên dưới biểu tượng, giống như các ứng dụng trên thanh menu, là một hộp thả xuống được neo vào biểu tượng khay ([Flyouts](windows.md#flyouts)).

Headless chạy (`--myzig-hidden`, `--myzig-eval`) không được thêm biểu tượng nào: trước tiên hãy kiểm tra `app.flags.hidden`.

<a id="global-shortcuts"></a>

## Phím tắt chung

Một lối tắt chung sẽ tiếp cận ứng dụng trong khi một ứng dụng khác ở phía trước, khi trình khởi chạy mở (Spotlight, Raycast, PowerToys Run):

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

`registerHotkey` nhận [bộ tăng tốc](#accelerators) và `myzig.Handler(void)`, chạy trên luồng chính khi được nhấn và trả về id của phím tắt cho `unregisterHotkey`. Nó không thành công với:

- `error.UnsupportedKey`: một phím mà phím tắt chung không thể sử dụng hoặc không sử dụng;
- `error.Unavailable`: ứng dụng khác có nó hoặc hệ thống từ chối nó;
- `error.Unsupported`: hệ thống không có phím tắt chung.

| nền tảng | làm thế nào |
|---|---|
| macOS | RegisterEventHotKey của Carbon |
| Windows | RegisterHotKey trên cửa sổ ẩn của ứng dụng |
| Linux | một phím X11 trên cửa sổ gốc, bật hoặc tắt Caps Lock và Num Lock; trên Wayland GlobalShortcuts của cổng thông tin máy tính để bàn (máy tính để bàn yêu cầu người dùng cho phép chúng một lần) |
| trình duyệt | không có sẵn |

`App.destroy` hủy đăng ký các phím tắt còn lại.

<a id="accelerators"></a>

## Máy gia tốc

Bộ tăng tốc được viết dưới dạng bộ sửa đổi và khóa được nối bởi `+`:

```
CmdOrCtrl+N   CmdOrCtrl+Shift+K   Alt+Up   F5   Cmd+,   Cmd++   Ctrl+Space
```

| một phần | tên |
|---|---|
| ⌘ trên macOS, Ctrl ở nơi khác | `CmdOrCtrl`, `CommandOrControl`, `Cmd`, `Command`, `Super`, `Meta` |
| Kiểm soát | `Ctrl`, `Control` |
| Thay thế, ⌥ | `Alt`, `Option` |
| ca | `Shift` |
| khóa được đặt tên | `Up`, `Down`, `Left`, `Right`, `Enter`, `Return`, `Tab`, `Space`, `Escape`, `Esc`, `Backspace`, `Delete`, `Home`, `End`, `PageUp`, `PageDown`, `Plus`, `F1` tới `F20` |
| các phím khác | chính ký tự đó (`N`, `,`, `/`); `Cmd++` đặt tên cho phím dấu cộng |

Tên không phân biệt chữ hoa chữ thường. Trên Windows và Linux, ⌘ và Ctrl đều là Ctrl và các menu hiển thị bộ tăng tốc khi các hệ thống đó ghi chúng (`Ctrl+Shift+K`). macOS hiển thị chúng bằng các ký hiệu của nó. Trong giao diện native, `ui.keys.label("⌘P")` và `ui.shortcutLabel` viết các tổ hợp phím cho nền tảng ([Navigation](ui/navigation.md)).
