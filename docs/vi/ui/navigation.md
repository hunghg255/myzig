<a id="navigation-actions-and-focus"></a>

# Điều hướng, hành động và trọng tâm

Cách người dùng di chuyển qua ứng dụng giao diện native: các trang có lịch sử (bộ định tuyến), nút quay lại và chuyển tiếp, các lệnh của ứng dụng được cung cấp dưới dạng tổ hợp phím, các mục menu và nút cùng một lúc (hành động) và tiêu điểm của bàn phím: Tab, nhóm tiêu điểm và bộ điều khiển di chuyển tiêu điểm khỏi mã.

<a id="the-router"></a>

## Bộ định tuyến

`ui.Router` lưu giữ lịch sử của các trang trong một cửa sổ hoặc của một phần của cửa sổ, giống như trình duyệt lưu giữ các tab, sau mygo của `ui.Router`. Một trang là một đường dẫn, dưới dạng `/notes/42`, mà view phù hợp để xây dựng trang được hiển thị:

```zig
const Notes = struct {
    router: ui.Router = .init("/notes"),

    fn view(s: *Notes, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        ui.row(c, .{ .gap = 8, .padding = .all(4), .align_items = .center });
        _ = s.router.historyButtons(c);
        ui.text(c, s.router.title(), .{ .weight = .semibold });
        ui.end(c);

        var pages = s.router.pages(c, .{});
        while (pages.next()) |r| {
            defer r.end();
            if (r.match("/notes")) {
                r.title("Notes");
                if (ui.button(c, "Open 42", .{}).clicked) s.router.push("/notes/42");
            } else if (r.match("/notes/{id}")) {
                r.title("Note");
                ui.text(c, c.print("Note {s}", .{r.param("id")}), .{});
            } else ui.text(c, "Not found", .{});
        }
        pages.end();
    }
};
```

`Router.pages(c, opts)` mở hộp của bộ định tuyến, nơi hiển thị các trang của nó (theo mặc định, tất cả dung lượng được cung cấp). `next()` trả về `*ui.Route` cho mỗi trang cần xây dựng: trang được hiển thị và trong khi quá trình chuyển đổi chạy, trang sẽ biến mất, được vẽ nhưng không lấy con trỏ hay Tab (`r.leaving` là true cho trang đó). Xây dựng nội dung từng trang rồi `r.end()`; sau cái cuối cùng, `pages.end()`.

<a id="matching-paths"></a>

### Đường dẫn phù hợp

`Route.match(pattern)` là true khi đường dẫn của trang khớp với `pattern`, có các phần giữa các dấu gạch chéo là phần riêng của đường dẫn hoặc ký tự đại diện: `{name}` chiếm một phần, `{name...}` (ở cuối) phần còn lại, có thể trống. Một dấu gạch chéo ở cuối không tạo ra sự khác biệt. `param(name)` là giá trị mà ký tự đại diện của trận đấu cuối cùng lấy (`""` nếu không có) và `query(name)` giá trị của tham số truy vấn (`/notes/42?tab=info`).

`title(t)` đặt tên cho trang, cho danh sách lịch sử và `Router.title()`.

`nested()` trả về lộ trình của phần còn lại của đường dẫn mà `{name...}` của trận đấu cuối cùng đã đi, để có bố cục xung quanh các trang của chính nó: `/fonts` của `/settings/fonts` sau `match("/settings/{section...}")`:

```zig
} else if (r.match("/settings/{section...}")) {
    s.settingsSidebar(c);
    var inner = r.nested();
    if (inner.match("/fonts")) s.fonts(c) else s.general(c);
}
```

<a id="going-places"></a>

### Đi nhiều nơi

- `push(target)` đi đến một trang sau trang được hiển thị, quên mất các trang sau đó. Đi đến trang hiển thị không có gì.
- `replace(target)` hiển thị một trang thay cho trang được hiển thị: quay lại không quay lại trang được thay thế.
- `back()`, `forward()` và `go(n)` xuyên suốt lịch sử; `canGoBack()` và `canGoForward()` cho biết liệu họ có thể làm được hay không.

Các mục tiêu liên quan đến trang được hiển thị sẽ phân giải dưới dạng liên kết trong một trang web: `push("edit")` từ `/notes/42` chuyển đến `/notes/edit`, `push("..")` tăng cấp và `push("?tab=info")` chỉ thay đổi truy vấn. Một đường dẫn với một truy vấn khác là cùng một trang, giữ nguyên trạng thái của nó.

`path()` là đường dẫn của trang được hiển thị, `location()` đường dẫn và truy vấn của nó (`push` và `replace` lấy những gì để hiển thị lại khi ứng dụng khởi động), `query(name)` tham số truy vấn của nó và `entry(n)` mục nhập `n` trang quay lại (phủ định) hoặc chuyển tiếp, để biết danh sách các trang cần truy cập theo tiêu đề của chúng. Lịch sử giữ 50 mục cuối cùng, vị trí lên tới 256 byte.

Một trang sẽ giữ trạng thái của các hộp của nó (độ lệch cuộn, văn bản đang được chỉnh sửa, hình động) khi nó ở trong lịch sử và tiêu điểm bàn phím mà nó có sẽ được trả lại khi nó hiển thị lại.

<a id="transitions-and-keys"></a>

### Chuyển tiếp và phím

Một trang sâu hơn trong các đường dẫn (`/notes/42` sau `/notes`) trượt vào từ cuối trang mà nó rời đi và quay lại; một số khác mờ dần. Với ít chuyển động được yêu cầu hơn (xem [Chuyển động](motion.md)), tất cả đều mờ dần. Các trường của bộ định tuyến `transition` (`.auto`, `.fade` hoặc `.none`), `slide_seconds` (0,25), `fade_seconds` (0,15) và `ease` thay đổi điều đó.

Cmd+[ và Cmd+] trên macOS, Alt+Left và Alt+Right ở nơi khác để quay lại và tiến lên. `ui.RouterOptions` có `style`, hộp của bộ định tuyến và `keys` (true): bộ định tuyến bên trong một trang của một trang khác để lại khóa cho trang bên ngoài với `.keys = false`.

<a id="back-and-forward-buttons"></a>

## Nút quay lại và chuyển tiếp

`Router.historyButtons(c)` vẽ nút quay lại và chuyển tiếp cho bộ định tuyến, bị tắt ở cuối lịch sử và trả về true khi họ di chuyển nó. Để biết lịch sử của riêng bạn, `ui.historyButtons(c, opts)` vẽ chúng và trả về `ui.HistoryAction` (`.none`, `.back` hoặc `.forward`):

```zig
switch (ui.historyButtons(c, .{ .can_back = s.at > 0, .can_forward = s.at + 1 < s.visited.len })) {
    .back => s.at -= 1,
    .forward => s.at += 1,
    .none => {},
}
```

`ui.HistoryOptions` có `can_back`, `can_forward` và `shortcuts` (true: nó cũng lấy các phím quay lại và tiến lên).

<a id="actions"></a>

## Hành động

`ui.Actions(E)` đặt tên các lệnh của ứng dụng một lần, mỗi lệnh cho mỗi thẻ của enum `E`, cùng với tiêu đề, tổ hợp phím, biểu tượng và trạng thái, đồng thời cung cấp chúng ở bất cứ nơi nào chúng hiển thị: dưới dạng tổ hợp phím, mục menu (với phím tắt được hiển thị và chuyển sang màu xám khi bị tắt) và các nút. Điều gì đã chọn một hành động không quan trọng đối với ứng dụng, ứng dụng sẽ trả lời một `switch`:

```zig
const Cmd = enum { new, save, wrap };

const Editor = struct {
    acts: ui.Actions(Cmd) = .init(.{
        .new = .{ .title = "New", .shortcut = .{ .key = 'n', .cmd = true } },
        .save = .{ .title = "Save", .shortcut = .{ .key = 's', .cmd = true } },
        .wrap = .{ .title = "Wrap Lines", .checked = false },
    }),
    file_menu: ui.Menu = .{},
    dirty: bool = false,
    wrap: bool = false,

    fn run(s: *Editor, cmd: Cmd) void {
        switch (cmd) {
            .new => s.newDocument(),
            .save => s.save(),
            .wrap => s.wrap = !s.wrap,
        }
    }

    fn view(s: *Editor, c: *ui.Context) void {
        s.acts.setEnabled(.save, s.dirty);
        s.acts.setChecked(.wrap, s.wrap);
        if (s.acts.button(c, .save, .{})) s.run(.save);
        if (ui.menuButton(c, "File", &s.file_menu, .{})) |m| {
            defer m.end();
            inline for (.{ Cmd.new, Cmd.save, Cmd.wrap }) |cmd| if (s.acts.menuItem(m, cmd)) s.run(cmd);
        }
        if (s.acts.shortcuts(c)) |cmd| s.run(cmd);
    }
};
```

`ui.Action` có `title`, `shortcut` (a `ui.Shortcut`, hoặc null), `icon`, `enabled` (true) và `checked` (null: không có dấu kiểm; true hoặc false: a dấu kiểm hoặc chỗ trống cho một mục trong menu).

- `shortcuts(c)` trả về hành động đã bật có tổ hợp phím là sự kiện này và thực hiện hành động đó. Gọi nó theo tên các widget lấy khóa (⌘A của trường tập trung xuất hiện trước).
- `menuItem(panel, e)` thêm mục của hành động vào một menu đang mở, với tổ hợp phím được hiển thị, true trong khung được chọn.
- `button(c, e, opts)` là một nút dành cho nó, bị vô hiệu hóa cùng với nó, có biểu tượng của nó trừ khi `opts` đưa ra một nút.
- `get(e)` trả về `*Action`; `setEnabled(e, on)` và `setChecked(e, on)` thay đổi trạng thái cho mọi vị trí mà nó hiển thị. `last` là hành động được chọn cuối cùng.

Thanh menu của ứng dụng là của hệ thống, được xây dựng từ các mẫu (xem [Menus](../menus.md)); các hành động dành cho các menu, nút và phím được vẽ trong cửa sổ.

<a id="key-combinations"></a>

## Tổ hợp phím

`c.shortcut(.{ .key = 'k', .cmd = true })` là true khi sự kiện này là sự kết hợp đó và nhận nó, vì vậy không có gì được xây dựng sau này nhìn thấy nó. `ui.Shortcut` có `key` (điểm mã: `'k'`, hoặc `ui.Shortcut.up`, `.down`, `.left`, `.right`, `.escape`, `.tab`, `.enter`) và các công cụ sửa đổi `cmd`, `ctrl`, `alt` và `shift`. Viết các phím tắt Lệnh bằng `cmd`: chúng là các phím tắt Điều khiển trên Linux, Windows và trong các trình duyệt không có phím Lệnh (`Shortcut.native()`).

Để hiển thị một tổ hợp khi nền tảng ghi nó, `ui.shortcutLabel(c, shortcut)` ghi `ui.Shortcut` (`⇧⌘S` trên máy Mac, `Ctrl+Shift+S` ở nơi khác) vào bộ nhớ của khung và `ui.keys.label("⇧⌘S")` thực hiện tương tự tại thời điểm biên dịch cho một chuỗi được viết bằng các ký hiệu của máy Mac. `ui.keys.mac` là true trong đó phím lệnh là Command.

<a id="the-keyboard-s-focus"></a>

## Trọng tâm của bàn phím

Các điều khiển lấy tiêu điểm sẽ thực hiện việc này khi được nhấn và với Tab, theo thứ tự chúng được tạo; Shift+Tab quay lại. Điều khiển lấy nét sẽ vẽ một vòng có màu nhấn khi tiêu điểm đến từ bàn phím chứ không phải từ thao tác nhấn (`c.focus_visible`). `c.focus` là id của hộp tập trung (0 cho không) và `Interaction` của `focused` cho widget biết liệu nó có hay không. Lối thoát trong hộp thoại hoặc cửa sổ bật lên sẽ chuyển đến nội dung bên trong trước tiên và tiêu điểm sẽ quay lại nội dung đã mở khi chúng đóng.

<a id="focus-groups"></a>

### Nhóm tập trung

`ui.focusGroup(c, style, opts)` làm cho các điều khiển bên trong hộp của nó trở thành một điểm dừng của Tab, giống như thanh công cụ, nhóm radio hoặc danh sách tab. Tab đi vào nhóm tới điều khiển có tiêu điểm cuối cùng ở đó (nếu không thì có tên `entry`, nếu không thì là tên đầu tiên) và ra khỏi nhóm đó; các mũi tên định hướng của nó di chuyển tiêu điểm giữa các điều khiển của nó, xung quanh từ cuối cùng đến đầu tiên, và Home và End đến đầu tiên và cuối cùng (tiêu điểm lưu động). Phải sang trái, Trái đi tới cái tiếp theo.

```zig
var g = ui.focusGroup(c, .{ .direction = .row, .gap = 4 }, .{});
if (ui.button(c, "Bold", .{}).clicked) s.bold = !s.bold;
if (ui.button(c, "Italic", .{}).clicked) s.italic = !s.italic;
if (ui.button(c, "Underline", .{}).clicked) s.underline = !s.underline;
_ = g.end();
```

`ui.FocusGroupOptions` có `orientation` (`.horizontal`, `.vertical` hoặc `.both`), `entry` (Tab điều khiển được đưa vào khi chưa có tab nào có tiêu điểm, theo vị trí của nó trong nhóm) và `wrap` (true). `end()` trả về `ui.FocusGroupResult`: `moved`, điều khiển các mũi tên đã di chuyển tiêu điểm đến trong khung này (một nhóm radio chọn nó), `focused`, điều khiển có tiêu điểm và `count`. Một điều khiển bên trong sẽ lấy chính các mũi tên (trường văn bản) lấy chúng trước.

<a id="handles"></a>

### Tay cầm

`ui.Handle` là một điều khiển mà ứng dụng biết đến trên các khung, để di chuyển tiêu điểm đến nó từ mã: trường tìm kiếm được tập trung bởi ⌘F, trường đầu tiên của biểu mẫu mở ra. Liên kết nó với sự tương tác của điều khiển ở mọi frame; một yêu cầu được thực hiện trước khi điều khiển hiển thị đang chờ nó:

```zig
// In the app's state: search: ui.Handle = .{},

const it = ui.button(c, "Find", .{});
s.search.bind(c, it);
if (c.shortcut(.{ .key = 'f', .cmd = true })) s.search.focus();
```

`bindId(c, id)` liên kết một hộp theo id của nó, `cancelFocus()` loại bỏ một yêu cầu chưa được trả lời, `focused(c)` cho biết liệu điều khiển có tiêu điểm hay không và `shown(c)` liệu nó có được tạo trong khung cuối cùng hay không. Trường `visible` của bộ điều khiển (true) vẽ vòng tiêu điểm, giống như Tab.
