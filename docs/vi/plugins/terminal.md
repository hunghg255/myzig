# terminal

Một terminal cho native UI: một view chạy shell của người dùng, hoặc chương trình bất kỳ, trong một pseudo-terminal. Bộ giả lập là libghostty-vt của [Ghostty](https://ghostty.org), được nạp lúc chạy (LoadLibrary trên Windows, dlopen ở nơi khác). Không link gì cả và không compile dòng C nào.

Package là `plugins/terminal` (module `terminal`). Nó phụ thuộc vào [mainthread](mainthread.md). Xem [Plugin](../plugins.md) để biết cách thêm nó vào app.

<a id="a-terminal-window"></a>

## Một cửa sổ terminal

`example/main.zig` là toàn bộ app: một cửa sổ chạy shell, lấy tiêu đề theo shell, và đóng khi shell thoát.

```zig
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const terminal = @import("terminal");

const State = struct {
    term: *terminal.Terminal = undefined,
    win: ?*myzig.Window = null,
    gpa: std.mem.Allocator,

    fn view(s: *State, c: *ui.Context) void {
        terminal.view(c, s.term, .{ .autofocus = true });
    }

    fn onEvent(ctx: ?*anyopaque, t: *terminal.Terminal, ev: terminal.Event) void {
        const s: *State = @ptrCast(@alignCast(ctx.?));
        const win = s.win orelse return;
        switch (ev) {
            .output => win.redraw(),
            .title => {
                const title = t.title(s.gpa) catch return;
                defer s.gpa.free(title);
                win.setTitle(if (title.len > 0) title else "Terminal");
            },
            .bell, .notify => {},
            .exit => win.close(),
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Terminal" });
    defer app.destroy();
    // Downloads libghostty-vt (and ConPTY on Windows) into the user's cache, once.
    terminal.download.fetchAll(app.gpa, app.io) catch |err| std.log.warn("terminal: {s}", .{@errorName(err)});
    var state: State = .{ .gpa = app.gpa };
    state.term = try terminal.Terminal.create(app.gpa, app.io, .{
        .dark_theme = terminal.ghosttyTheme("Catppuccin Mocha"),
        .on_event = .{ .ctx = &state, .func = State.onEvent },
    });
    defer state.term.destroy();
    state.win = try app.newWindow(.{ .title = "Terminal", .width = 760, .height = 460, .content = .{ .view = .init(&state, State.view) } });
    try app.run();
}
```

`terminal.view(c, term, opts)` vẽ terminal và nhận input cho nó. `ViewOptions` gồm:

- `padding`: 4 điểm quanh lưới ký tự;
- `autofocus`: lấy focus bàn phím khi chưa có gì giữ focus.

<a id="options"></a>

## Tùy chọn

`terminal.Options`, cho `Terminal.create(gpa, io, options)`:

| trường | mặc định | |
|---|---|---|
| `command` | shell | chương trình và tham số của nó; bên gọi phải giữ chúng cho tới khi chương trình khởi động |
| `dir` | của tiến trình này | thư mục làm việc |
| `env` | không có | các `"KEY=value"` thêm vào trên `TERM`, `COLORTERM` và `LANG` mà terminal tự đặt |
| `no_program` | false | không chạy chương trình nào: terminal hiện những gì `feed` đưa vào |
| `theme`, `dark_theme` | màu của cửa sổ | màu trong cửa sổ sáng và tối |
| `cursor` | `.block` | `.block`, `.bar` hoặc `.underline` |
| `scrollback` | 10 MB | khoảng bao nhiêu byte output được giữ lại phía trên màn hình |
| `font_size` | 13 | tính bằng điểm |
| `font_family` | null | một họ font riêng; null thì dùng font monospace của theme |
| `font_features` | `""` | các OpenType feature, theo cách `ui.TextStyle.features` nhận (`"calt=0"`) |
| `font_weight` | 0 | từ 100 tới 900, chữ đậm nặng hơn ba trăm; 0 cho chữ thường và đậm mặc định |
| `on_event` | null | `.{ .ctx, .func }`, được gọi trên main thread (xem bên dưới) |
| `open_link` | null | mở link mà Ctrl+bấm đã chọn (hyperlink, URL, đường dẫn file); không có thì hệ thống mở URL |
| `copy_on_select` | false | copy những gì vừa được chọn bằng kéo, bấm đúp hay bấm ba lần, ngay khi thả con trỏ |
| `scroll_multiplier` | `.{ .precision = 1, .discrete = 3 }` | hệ số scroll, như `mouse-scroll-multiplier` của Ghostty (xem bên dưới) |
| `read_clipboard` | null | đọc chữ trong clipboard khi paste; null thì dùng clipboard của hệ thống |

`on_event` nhận các event sau, trên main thread:

- `.output`: cần vẽ lại.
- `.title`: tiêu đề đã đổi.
- `.bell`.
- `.exit`: chương trình đã kết thúc.
- `.notify`: một thông báo desktop mà chương trình yêu cầu bằng OSC 9 hoặc OSC 777. `t.notification()` trả về tiêu đề và nội dung của nó.

`scroll_multiplier` có hai trường. `term.opts.scroll_multiplier` có thể đổi trong lúc terminal đang hiện.

- `precision` nhân quãng đường của touchpad.
- `discrete` là khoảng số hàng mà một nấc con lăn scroll. 3 là một nấc của hệ thống.

Một `Terminal` còn có các method sau, dùng cho test và công cụ:

| method | |
|---|---|
| `send(bytes)` | gõ vào chương trình |
| `paste(data)` | paste |
| `feed(bytes)` | hiện các byte như thể chương trình đã ghi ra |
| `resize(cols, rows, cell_w, cell_h)` | |
| `start()` | |
| `title(gpa)` | |
| `text(gpa)` | chữ trên màn hình |
| `snapshot(gpa)` | các escape sequence để khôi phục màn hình |
| `exitCode()`, `waitOutput(seen)` | |

<a id="what-it-does"></a>

## Nó làm được gì

**Chương trình**

- Chạy trong một pseudo-terminal. Trên Windows là ConPTY của nhóm Windows Terminal (`conpty.dll` cùng `OpenConsole.exe`, như mygo đóng gói), nếu không có thì dùng ConPTY sẵn của Windows. Ở nơi khác là `/dev/ptmx` qua libc.
- Shell là `$SHELL`, nếu không có thì `/bin/zsh` trên macOS và `/bin/sh` ở nơi khác. Trên Windows là PowerShell.
- `TERM=xterm-256color` và `COLORTERM=truecolor` được đặt sẵn.
- Nó khởi động với kích thước mà frame đầu tiên của view đưa cho.
- Một thread đọc chuyển output của nó vào bộ giả lập. Một thread ghi gõ vào nó theo đúng thứ tự.
- Event tới app trên main thread. Không có gì phải poll.

**Màn hình**

- Màu (16, 256, 24-bit), đậm, nghiêng, mờ, đảo màu, ẩn.
- Gạch chân với màu riêng, gạch ngang giữa và gạch trên.
- Scrollback và màn hình phụ (alternate screen).
- Con trỏ nhập, rỗng ruột khi view không có focus.
- Vùng chọn, và thanh scroll khi đang xem scrollback.
- Chữ dùng font monospace của myzig, thành từng đoạn cùng style đặt trên lưới.

**Phím**

- Phím được gửi theo cách chương trình yêu cầu: chuỗi kiểu cũ, modifyOtherKeys của xterm hoặc giao thức bàn phím của Kitty (bộ mã hóa phím của Ghostty).
- Bao gồm phím mũi tên, phím chức năng, Ctrl và Alt. Chữ gõ được gửi theo phím, chữ từ bộ gõ được gửi nguyên như nó tới.
- Ctrl+Shift+C, V và A (Command trên macOS) để copy, paste và chọn tất cả.
- Trên Windows, Ctrl+C copy khi đang có vùng chọn, nếu không thì ngắt chương trình. Ctrl+V để paste.
- Shift+Page Up và Page Down scroll theo trang.

**Con trỏ**

- Chương trình nào nhận chuột thì nhận các report: X10, normal, button, any-motion, theo SGR và các kiểu mã hóa khác. Giữ Shift thì chọn chữ thay vì gửi report.
- Kéo để chọn ô, bấm đúp chọn từ, bấm ba lần chọn dòng.
- Shift-bấm mở rộng hoặc thu hẹp vùng chọn tính từ chỗ bắt đầu, kể cả qua nhiều dòng.
- Con lăn scroll scrollback. Trên màn hình của chương trình toàn màn hình, nó gửi phím mũi tên (alternate scroll), hoặc gửi report con lăn.

**Phần còn lại**

- **Paste** được bọc trong bracketed paste khi chương trình yêu cầu (mode 2004), và report focus (mode 1004) được gửi đi.
- **Tiêu đề** (OSC 0 và 2) tới dưới dạng event `.title`; `title()` đọc chúng.
- **Link**: Ctrl+bấm (Command+bấm trên macOS) mở một hyperlink (OSC 8), một URL in ra dạng chữ, hoặc một đường dẫn file. Việc mở đi qua `open_link`. Không có nó thì hệ thống mở URL và đường dẫn tuyệt đối.
- Các đường dẫn nó nhận ra: `/abs/path`, `~/notes.md`, `./a.go`, `src/app.go:12:3`, `main.go:250`, và `notes.md` (tên file có phần mở rộng, không phải một con số như 1.2.3).
- Trên Windows còn có `C:\dir\file`, `C:/dir/file`, `dir\file` và `.\file`.
- **Theme**: bảng màu của VS Code đặt trên màu cửa sổ của myzig, theo giao diện sáng/tối của cửa sổ.
- 617 theme mà Ghostty kèm theo, gọi theo tên (`terminal.ghosttyTheme("Dracula")`, `ghosttyThemeCount`, `ghosttyThemeName(i)`).
- File theme theo định dạng của Ghostty (`terminal.Theme.parse`).

<a id="the-libraries"></a>

## Các thư viện

`src/myzig-plugin.json` ghi các bản build mà plugin bind, cho từng nền tảng, kèm SHA-256 và URL tải về. Đó là các bản phát hành của mygo cho libghostty-vt (Ghostty `befcdfd2c3a1`) và ConPTY 1.25.260930003. Plugin tìm chúng theo thứ tự:

1. trong file mà `$MYZIG_GHOSTTY_VT` chỉ tới (`$MYZIG_CONPTY`, `$MYZIG_OPENCONSOLE`; cả `$MYGO_...` của mygo);
2. cạnh file thực thi, nơi app đóng gói chúng;
3. trong `<cache>/myzig/natives/<sha256>/`, rồi `<cache>/mygo/natives/<sha256>/` của mygo (cache là `%LOCALAPPDATA%`, `~/Library/Caches`, `$XDG_CACHE_HOME` hoặc `~/.cache`).

- `terminal.download.fetchAll(gpa, io)` tải những gì còn thiếu vào cache và kiểm tra SHA-256, như ví dụ đã làm.
- App không bao giờ gọi nó thì không mang theo HTTP client nào.
- Các struct mà plugin truyền đi được đối chiếu với layout mà thư viện báo về lúc nạp. Thư viện khác phiên bản sẽ không nạp được, thay vì làm hỏng bộ nhớ.

Để đóng gói các thư viện cùng app, đặt chúng vào thư mục `resources/` của app (xem [Phân phối](../distribution.md)). Trên Windows và Linux, chúng nằm cạnh file thực thi. CLI chưa đặt chúng vào `Contents/MacOS` của bundle macOS.

<a id="tests"></a>

## Test

```sh
cd plugins/terminal
zig build test                              # libghostty-vt, ConPTY hoặc pty, ui.Tester (bỏ qua nếu thiếu thư viện)
zig build check -Dtarget=x86_64-linux-gnu   # kiểm tra kiểu cho nền tảng khác
zig build snapshot                          # giây đầu tiên của ví dụ, offscreen
zig build run                               # chạy ví dụ trong cửa sổ
```
