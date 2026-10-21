# terminal

Thiết bị đầu cuối dành cho giao diện native: view chạy shell của người dùng hoặc bất kỳ chương trình nào trong terminal giả, với trình mô phỏng terminal của [Ghostty](https://ghostty.org), libghostty-vt, được tải trong thời gian chạy (LoadLibrary trên Windows, dlopen ở nơi khác): không có gì được liên kết và không có C nào được biên dịch.

Gói này là `plugins/terminal` (mô-đun `terminal`); nó phụ thuộc vào [mainthread](mainthread.md). Xem [Plugin](../plugins.md) để thêm plugin vào ứng dụng.

<a id="a-terminal-window"></a>

## Một cửa sổ đầu cuối

`example/main.zig` là toàn bộ ứng dụng: một cửa sổ chạy shell, được đặt tên theo nó, đóng khi nó thoát.

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

`terminal.view(c, term, opts)` rút terminal và lấy đầu vào của nó; `ViewOptions` là `padding` (4 điểm xung quanh lưới) và `autofocus` (lấy tiêu điểm bàn phím khi không có gì).

<a id="options"></a>

## Tùy chọn

`terminal.Options`, cho `Terminal.create(gpa, io, options)`:

| lĩnh vực | mặc định | |
|---|---|---|
| `command` | shell | chương trình và các đối số của nó, được người gọi giữ cho đến khi nó bắt đầu |
| `dir` | quá trình này | thư mục làm việc |
| `env` | không có | `"KEY=value"` được thêm vào trên `TERM`, `COLORTERM` và `LANG` mà terminal đặt |
| `no_program` | false | không có chương trình: terminal hiển thị những gì `feed` cung cấp cho nó |
| `theme`, `dark_theme` | màu sắc của cửa sổ | màu sắc trong cửa sổ sáng và tối |
| `cursor` | `.block` | `.block`, `.bar` hoặc `.underline` |
| `scrollback` | 10MB | về số byte đầu ra cần giữ phía trên màn hình |
| `font_size` | 13 | tính bằng điểm |
| `font_family` | null | một gia đình của riêng mình; chủ đề đơn cách khi null |
| `font_features` | `""` | Các tính năng của OpenType, như `ui.TextStyle.features` sử dụng chúng (`"calt=0"`) |
| `font_weight` | 0 | 100 đến 900, nặng hơn ba trăm; 0 cho thường xuyên và in đậm |
| `on_event` | null | `.{ .ctx, .func }`: `.output` (vẽ lại), `.title`, `.bell`, `.exit`, và `.notify` (thông báo trên màn hình mà một chương trình được yêu cầu với OSC 9 hoặc OSC 777; `t.notification()` là tiêu đề và nội dung của nó), trên luồng chính |
| `open_link` | null | mở một liên kết Ctrl+click đã chọn (siêu liên kết, URL, đường dẫn tệp); nếu không thì hệ thống sẽ mở URL |
| `copy_on_select` | false | sao chép những gì thao tác kéo, nhấp đúp hoặc nhấp ba lần sẽ chọn khi con trỏ buông ra |
| `read_clipboard` | null | đọc văn bản của clipboard để dán; hệ thống khi null |

`Terminal` cũng có `send(bytes)` (nhập vào chương trình), `paste(data)`, `feed(bytes)` (hiển thị byte như thể chương trình đã ghi chúng), `resize(cols, rows, cell_w, cell_h)`, `start()`, `title(gpa)`, `text(gpa)` (văn bản của màn hình), `snapshot(gpa)` (các chuỗi thoát để khôi phục màn hình), `exitCode()` và `waitOutput(seen)` (dành cho các bài kiểm tra và công cụ).

<a id="what-it-does"></a>

## Nó làm gì

- **Chương trình** chạy trong một terminal giả: trên Windows Windows ConPTY của nhóm terminal (`conpty.dll` với `OpenConsole.exe`, do mygo vận chuyển nó), nếu không thì Windows' sở hữu; ở nơi khác `/dev/ptmx` thông qua libc. Shell là `$SHELL` (khác là `/bin/zsh` trên macOS, `/bin/sh` ở nơi khác) và PowerShell trên Windows; `TERM=xterm-256color` và `COLORTERM=truecolor` được đặt. Nó bắt đầu ở kích thước mà frame đầu tiên của view cung cấp cho nó. Một luồng trình đọc cung cấp đầu ra của nó cho trình mô phỏng, một luồng trình ghi nhập vào đó theo thứ tự và các sự kiện sẽ đến ứng dụng trên luồng chính: không có polling ý kiến ​​nào.
- **Màn hình**: màu sắc (16, 256, 24-bit), in đậm, in nghiêng, mờ, đảo ngược, vô hình, gạch chân (bằng màu riêng của chúng), các dòng xuyên qua, cuộn lùi và màn hình thay thế, con trỏ (rỗng trong khi view không được tập trung), vùng chọn và thanh cuộn trong khi cuộn lùi hiển thị. Văn bản là phông chữ đơn cách của myzig, theo một kiểu được đặt trên lưới.
- **Phím** như các chương trình yêu cầu: chuỗi kế thừa, ModifyOtherKeys của xterm hoặc giao thức bàn phím Kitty (bộ mã hóa khóa của Ghostty), với các mũi tên, phím chức năng, Ctrl và Alt; văn bản đã nhập sẽ đi theo khóa của nó, văn bản IME khi nó xuất hiện. Ctrl+Shift+C, V và A (Lệnh trên macOS) sao chép, dán và chọn tất cả; trên Windows Ctrl+C sao chép khi nội dung nào đó được chọn (và ngắt nếu không) và dán Ctrl+V; Shift+Trang Up và Down cuộn theo trang.
- **Con trỏ**: báo cáo (X10, bình thường, nút, bất kỳ chuyển động nào; SGR và các mã hóa khác) cho các chương trình sử dụng chuột, thay vào đó là chọn Shift; kéo để chọn ô, nhấp đúp vào từ, nhấp ba lần vào dòng; bánh xe cuộn cuộn lùi hoặc gửi mũi tên trên màn hình của chương trình toàn màn hình (cuộn thay thế) hoặc báo cáo bánh xe.
- **Dán** được đặt trong ngoặc khi chương trình yêu cầu (chế độ 2004) và báo cáo tiêu điểm (chế độ 1004) được gửi.
- **Tiêu đề** (OSC 0 và 2) xuất hiện dưới dạng sự kiện `.title`; `title()` đọc chúng.
- **Liên kết**: Ctrl+nhấp chuột (Lệnh+nhấp vào macOS) mở siêu liên kết (OSC 8), URL được in dưới dạng văn bản hoặc đường dẫn tệp thông qua `open_link` (các URL tuyệt đối có trong hệ thống không có nó): `/abs/path`, `~/notes.md`, `./a.go`, `src/app.go:12:3`, `main.go:250` và trên Windows `C:\dir\file`, `C:/dir/file`, `dir\file` và `.\file`.
- **Chủ đề**: Bảng màu của VS Code trên các màu cửa sổ của myzig, theo giao diện của cửa sổ; 617 chủ đề mà Ghostty gửi đến, theo tên (`terminal.ghosttyTheme("Dracula")`, `ghosttyThemeCount`, `ghosttyThemeName(i)`) và các tệp chủ đề ở định dạng của Ghostty (`terminal.Theme.parse`).

<a id="the-libraries"></a>

## Các thư viện

`src/myzig-plugin.json` đặt tên cho các bản dựng mà plugin liên kết, cho mỗi nền tảng bằng SHA-256 và URL tải xuống: các bản phát hành libghostty-vt (Ghostty `befcdfd2c3a1`) và ConPTY 1.25.260930003 của mygo. Plugin tìm kiếm chúng:

1. trong các tên tệp `$MYZIG_GHOSTTY_VT` (`$MYZIG_CONPTY`, `$MYZIG_OPENCONSOLE`; mygo's `$MYGO_...` nữa);
2. bên cạnh tệp thực thi, nơi ứng dụng gửi chúng;
3. trong `<cache>/myzig/natives/<sha256>/`, sau đó là `<cache>/mygo/natives/<sha256>/` của mygo (bộ đệm là `%LOCALAPPDATA%`, `~/Library/Caches`, `$XDG_CACHE_HOME` hoặc `~/.cache`).

`terminal.download.fetchAll(gpa, io)` tải xuống những gì còn thiếu vào bộ đệm, kiểm tra SHA-256, như ví dụ; một ứng dụng không bao giờ gọi nó không có client HTTP. Cấu trúc mà plugin chuyển đi được kiểm tra dựa trên bố cục mà thư viện báo cáo khi nó tải, do đó, thư viện của phiên bản khác không tải được thay vì bộ nhớ bị hỏng.

Để gửi các thư viện cùng với một ứng dụng, hãy đặt chúng vào thư mục `resources/` của nó (xem [Distribution](../distribution.md)): trên Windows và Linux chúng nằm cạnh tệp thực thi. CLI chưa đặt chúng vào macOS của gói `Contents/MacOS`.

<a id="tests"></a>

## Kiểm tra

```sh
cd plugins/terminal
zig build test                              # libghostty-vt, ConPTY or a pty, ui.Tester (skipped without the library)
zig build check -Dtarget=x86_64-linux-gnu   # type-check another platform
zig build snapshot                          # the example's first second, offscreen
zig build run                               # the example, in a window
```
