<a id="navigation-actions-and-focus"></a>

# Điều hướng, action và focus

Cách người dùng đi lại trong một app dùng UI native:

- các trang có lịch sử (router), cùng nút back và forward;
- các lệnh của app, cùng lúc là tổ hợp phím, mục menu và nút (action);
- focus bàn phím: Tab, focus group, và handle để chuyển focus từ code.

<a id="the-router"></a>

## Router

`ui.Router` giữ lịch sử các trang của một cửa sổ, hoặc của một phần cửa sổ, như trình duyệt giữ lịch sử của một tab. Nó theo `ui.Router` của mygo. Mỗi trang là một đường dẫn, ví dụ `/notes/42`, và view so khớp đường dẫn đó để dựng trang:

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

- `Router.pages(c, opts)` mở box của router, nơi các trang hiện ra.
- `next()` trả về một `*ui.Route` cho mỗi trang cần dựng: trang đang hiện, và trang đang rời đi khi transition còn chạy.
- Trang đang rời đi vẫn được vẽ nhưng không nhận con trỏ hay Tab (`r.leaving`).
- Kết thúc mỗi trang bằng `r.end()`, và sau trang cuối thì gọi `pages.end()`.

<a id="matching-paths"></a>

### So khớp đường dẫn

`Route.match(pattern)` là true khi đường dẫn của trang khớp `pattern`, từng phần giữa các dấu gạch chéo:

| Phần | Khớp với |
|---|---|
| `notes` | đúng phần đó của đường dẫn |
| `{name}` | một phần |
| `{name...}` | ở cuối: phần còn lại, có thể rỗng |

- Dấu gạch chéo ở cuối không ảnh hưởng gì.
- `param(name)` là phần mà một wildcard của lần khớp gần nhất đã lấy, `""` nếu không có.
- `query(name)` là giá trị của một tham số query, như trong `/notes/42?tab=info`.
- `title(t)` đặt tên cho trang, dùng cho danh sách lịch sử và `Router.title()`.

`nested()` trả về route của phần còn lại mà `{name...}` của lần khớp gần nhất đã lấy, để dựng một layout bao quanh các trang con của nó. Sau `match("/settings/{section...}")`, `/settings/fonts` cho route con là `/fonts`:

```zig
} else if (r.match("/settings/{section...}")) {
    s.settingsSidebar(c);
    var inner = r.nested();
    if (inner.match("/fonts")) s.fonts(c) else s.general(c);
}
```

<a id="going-places"></a>

### Chuyển trang

| Hàm | |
|---|---|
| `push(target)` | sang một trang sau trang đang hiện, bỏ các trang phía sau nó; push tới chính trang đang hiện thì không làm gì |
| `replace(target)` | thay trang đang hiện; back không quay lại trang bị thay |
| `back()`, `forward()`, `go(n)` | đi trong lịch sử, trong giới hạn của nó |
| `canGoBack()`, `canGoForward()` | có đi được không |

Đích tương đối được hiểu như link trong một trang web:

- `push("edit")` từ `/notes/42` sang `/notes/edit`;
- `push("..")` lên một cấp;
- `push("?tab=info")` chỉ đổi query.

Cùng đường dẫn mà khác query vẫn là cùng một trang, và trang đó giữ nguyên state.

| Đọc | |
|---|---|
| `path()` | đường dẫn của trang đang hiện |
| `location()` | đường dẫn và query của nó, để `push` hoặc `replace` khi app chạy lại |
| `query(name)` | một tham số trong query của nó |
| `entry(n)` | mục cách `n` trang về trước (âm) hoặc về sau, để làm danh sách trang theo tiêu đề |

- Lịch sử giữ 50 mục gần nhất, mỗi location dài tối đa 256 byte.
- Trang nằm trong lịch sử giữ nguyên state của các box: vị trí scroll, văn bản đang sửa, animation. Khi hiện lại, nó lấy lại focus bàn phím đã có.

<a id="transitions-and-keys"></a>

### Transition và phím

- Trang sâu hơn (`/notes/42` sau `/notes`) trượt vào từ cuối, đè lên trang nó rời, và trượt ra khi quay lại. Các trang khác thì hiện dần.
- Khi hệ thống yêu cầu giảm chuyển động, tất cả đều hiện dần (xem [Motion](motion.md)).
- Cmd+[ và Cmd+] trên macOS, Alt+Left và Alt+Right ở nơi khác, để back và forward.

| Trường của `ui.Router` | Mặc định | |
|---|---|---|
| `transition` | `.auto` | `.auto`, `.fade` hoặc `.none` |
| `slide_seconds` | 0.25 | |
| `fade_seconds` | 0.15 | |
| `ease` | `.ease_out` | đường cong |

| `ui.RouterOptions` | Mặc định | |
|---|---|---|
| `style` | lấp đầy chỗ trống | box của router |
| `keys` | `true` | nhận phím back và forward; `false` cho router nằm trong trang của router khác |

<a id="back-and-forward-buttons"></a>

## Nút back và forward

`Router.historyButtons(c)` vẽ một nút back và một nút forward, bị tắt ở hai đầu lịch sử. Nó trả về true khi các nút này đã chuyển router.

Với lịch sử do bạn tự quản lý, `ui.historyButtons(c, opts)` vẽ hai nút và trả về một `ui.HistoryAction`: `.none`, `.back` hoặc `.forward`.

```zig
switch (ui.historyButtons(c, .{ .can_back = s.at > 0, .can_forward = s.at + 1 < s.visited.len })) {
    .back => s.at -= 1,
    .forward => s.at += 1,
    .none => {},
}
```

| `ui.HistoryOptions` | Mặc định | |
|---|---|---|
| `can_back`, `can_forward` | | nút nào được bật |
| `shortcuts` | `true` | nhận luôn các phím back và forward |

<a id="actions"></a>

## Action

`ui.Actions(E)` đặt tên các lệnh của app một lần, mỗi tag của enum `E` là một lệnh, kèm tiêu đề, tổ hợp phím, icon và state. Chúng hiện ra dưới dạng tổ hợp phím, mục menu và nút. Dù action được chọn từ đâu, app chỉ cần một `switch`:

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

| `ui.Action` | Mặc định | |
|---|---|---|
| `title` | | |
| `shortcut` | `null` | một `ui.Shortcut` |
| `icon` | `""` | cho mục menu và nút của nó |
| `enabled` | `true` | |
| `checked` | `null` | không có dấu tick; true hoặc false: có dấu tick, hoặc chừa chỗ cho nó, trong menu |

| Hàm | |
|---|---|
| `shortcuts(c)` | trả về action đang bật có tổ hợp phím trùng event này, và nhận luôn event |
| `menuItem(panel, e)` | thêm mục của action vào một menu đang mở, kèm phím tắt, mờ đi khi bị tắt; true trong frame nó được chọn |
| `button(c, e, opts)` | một nút cho action, bị tắt theo action, có icon của nó trừ khi `opts` cho icon khác |
| `get(e)` | `*Action` |
| `setEnabled(e, on)`, `setChecked(e, on)` | đổi state của nó ở mọi chỗ nó hiện |
| `last` | action được chọn gần nhất |

Gọi `shortcuts(c)` sau các widget nhận phím: ⌘A của một ô nhập đang có focus được ưu tiên trước.

Action dành cho menu, nút và phím được vẽ trong cửa sổ. Thanh menu của app là của hệ thống, dựng từ template (xem [Menus](../menus.md)).

<a id="key-combinations"></a>

## Tổ hợp phím

`c.shortcut(.{ .key = 'k', .cmd = true })` là true khi event này đúng tổ hợp đó. Nó nhận luôn event, nên những gì dựng sau không thấy nữa.

| `ui.Shortcut` | |
|---|---|
| `key` | một code point: `'k'`, hoặc `ui.Shortcut.up`, `.down`, `.left`, `.right`, `.escape`, `.tab`, `.enter` |
| `cmd`, `ctrl`, `alt`, `shift` | các phím bổ trợ |

Viết phím tắt Command bằng `cmd`. Linux, Windows và trình duyệt không có phím Command, nên ở đó chúng thành phím Control (`Shortcut.native()`).

Để hiện một tổ hợp phím theo cách nền tảng viết:

- `ui.shortcutLabel(c, shortcut)` viết một `ui.Shortcut` vào bộ nhớ của frame: `⇧⌘S` trên Mac, `Ctrl+Shift+S` ở nơi khác.
- `ui.keys.label("⇧⌘S")` làm điều tương tự lúc biên dịch, cho chuỗi viết bằng ký hiệu của Mac.
- `ui.keys.mac` là true ở nơi phím lệnh là Command.

<a id="the-keyboard-s-focus"></a>

## Focus bàn phím

- Control nhận focus khi được bấm, và theo Tab, theo thứ tự chúng được dựng. Shift+Tab đi ngược lại.
- Control đang có focus vẽ một vòng màu accent khi focus đến từ bàn phím, không phải từ cú bấm (`c.focus_visible`).
- `c.focus` là id của box đang có focus, 0 nếu không có. Trường `focused` của một `Interaction` cho widget biết nó có focus hay không.
- Escape trong dialog hay popover đến những gì bên trong trước. Khi chúng đóng, focus trở lại thứ đã mở chúng.

<a id="focus-groups"></a>

### Focus group

```zig
var g = ui.focusGroup(c, .{ .direction = .row, .gap = 4 }, .{});
if (ui.button(c, "Bold", .{}).clicked) s.bold = !s.bold;
if (ui.button(c, "Italic", .{}).clicked) s.italic = !s.italic;
if (ui.button(c, "Underline", .{}).clicked) s.underline = !s.underline;
_ = g.end();
```

`ui.focusGroup(c, style, opts)` gộp các control trong box của nó thành một điểm dừng của Tab, như trong toolbar, nhóm radio hay danh sách tab (roving focus):

- Tab vào group ở control có focus gần nhất trong đó, nếu không thì ở `entry`, nếu không nữa thì ở control đầu tiên. Tab tiếp theo rời group.
- Các phím mũi tên theo hướng của group chuyển focus giữa các control, vòng từ cái cuối về cái đầu.
- Home và End đến cái đầu và cái cuối.
- Khi viết từ phải sang trái, Left đến control kế tiếp.
- Control bên trong tự nhận phím mũi tên, như ô nhập văn bản, được ưu tiên trước.

| `ui.FocusGroupOptions` | Mặc định | |
|---|---|---|
| `orientation` | `.horizontal` | `.horizontal`, `.vertical` hoặc `.both` |
| `entry` | `null` | chỗ Tab vào khi chưa control nào có focus, theo vị trí trong group |
| `wrap` | `true` | phím mũi tên đi vòng |

`end()` trả về một `ui.FocusGroupResult`:

| Trường | |
|---|---|
| `moved` | control mà phím mũi tên chuyển focus đến trong frame này; nhóm radio chọn luôn nó |
| `focused` | control đang có focus |
| `count` | số control nhận focus trong group |

<a id="handles"></a>

### Handle

`ui.Handle` đặt tên cho một control qua các frame, để focus nó từ code: ô tìm kiếm khi bấm ⌘F, ô đầu tiên của một form vừa mở.

```zig
// Trong state của app: search: ui.Handle = .{},

const it = ui.button(c, "Find", .{});
s.search.bind(c, it);
if (c.shortcut(.{ .key = 'f', .cmd = true })) s.search.focus();
```

Bind nó vào interaction của control mỗi frame. Yêu cầu focus gửi trước khi control hiện ra sẽ chờ đến lúc đó.

| Hàm | |
|---|---|
| `bindId(c, id)` | bind một box theo id của nó |
| `cancelFocus()` | bỏ yêu cầu chưa được đáp ứng |
| `focused(c)` | control có đang có focus không |
| `shown(c)` | control có được dựng ở frame trước không |
| `visible` | trường, `true`: vẽ vòng focus, như khi dùng Tab |
