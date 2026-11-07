# terminal

A terminal for native UI: a view that runs the user's shell, or any
program, in a pseudo-terminal. The emulator is
[Ghostty](https://ghostty.org)'s libghostty-vt, loaded at run time
(LoadLibrary on Windows, dlopen elsewhere). Nothing is linked and no C is
compiled.

The package is `plugins/terminal` (module `terminal`). It depends on
[mainthread](mainthread.md). See [Plugins](../plugins.md) for adding it to
an app.

## A terminal window

`example/main.zig` is the whole app: a window running the shell, titled by
it, closed when it exits.

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

`terminal.view(c, term, opts)` draws the terminal and takes its input.
`ViewOptions` are:

- `padding`: 4 points around the grid;
- `autofocus`: take the keyboard focus when nothing has it.

## Options

`terminal.Options`, for `Terminal.create(gpa, io, options)`:

| field | default | |
|---|---|---|
| `command` | the shell | the program and its arguments, kept by the caller until it starts |
| `dir` | this process's | the working directory |
| `env` | none | `"KEY=value"`s added over `TERM`, `COLORTERM` and `LANG`, which the terminal sets |
| `no_program` | false | no program: the terminal shows what `feed` gives it |
| `theme`, `dark_theme` | the window's colors | the colors in light and dark windows |
| `cursor` | `.block` | `.block`, `.bar` or `.underline` |
| `scrollback` | 10 MB | about how many bytes of output to keep above the screen |
| `font_size` | 13 | in points |
| `font_family` | null | a family of its own; the theme's monospaced one when null |
| `font_features` | `""` | OpenType features, as `ui.TextStyle.features` takes them (`"calt=0"`) |
| `font_weight` | 0 | 100 to 900, bold three hundred heavier; 0 for regular and bold |
| `on_event` | null | `.{ .ctx, .func }`, called on the main thread (below) |
| `open_link` | null | opens a link Ctrl+click chose (a hyperlink, a URL, a file path); otherwise the system opens URLs |
| `copy_on_select` | false | copies what a drag, a double or a triple click selects as the pointer lets go |
| `scroll_multiplier` | `.{ .precision = 1, .discrete = 3 }` | scales scrolling, as Ghostty's `mouse-scroll-multiplier` (below) |
| `read_clipboard` | null | reads the clipboard's text for a paste; the system's when null |

`on_event` gets these events, on the main thread:

- `.output`: redraw.
- `.title`: the title changed.
- `.bell`.
- `.exit`: the program ended.
- `.notify`: a desktop notification a program asked for with OSC 9 or
  OSC 777. `t.notification()` is its title and body.

`scroll_multiplier` has two fields. `term.opts.scroll_multiplier` may
change while the terminal shows.

- `precision` scales a touchpad's distance.
- `discrete` is about the rows a wheel's notch scrolls. 3 is the system's
  notch.

A `Terminal` also has these, for tests and tools:

| method | |
|---|---|
| `send(bytes)` | types into the program |
| `paste(data)` | pastes |
| `feed(bytes)` | shows bytes as if the program wrote them |
| `resize(cols, rows, cell_w, cell_h)` | |
| `start()` | |
| `title(gpa)` | |
| `text(gpa)` | the screen's text |
| `snapshot(gpa)` | escape sequences that restore the screen |
| `exitCode()`, `waitOutput(seen)` | |

## What it does

**The program**

- It runs in a pseudo-terminal. On Windows that is the Windows Terminal
  team's ConPTY (`conpty.dll` with `OpenConsole.exe`, as mygo ships it),
  else Windows' own. Elsewhere it is `/dev/ptmx` through libc.
- The shell is `$SHELL`, else `/bin/zsh` on macOS and `/bin/sh`
  elsewhere. On Windows it is PowerShell.
- `TERM=xterm-256color` and `COLORTERM=truecolor` are set.
- It starts at the size the view's first frame gives it.
- A reader thread feeds its output to the emulator. A writer thread types
  into it in order.
- Events reach the app on the main thread. Nothing polls.

**The screen**

- Colors (16, 256, 24-bit), bold, italic, faint, inverse, invisible.
- Underlines in their own colors, lines through and over.
- The scrollback and the alternate screen.
- The cursor, hollow while the view is not focused.
- The selection, and a scrollbar while the scrollback shows.
- Text is myzig's monospace font, in runs of one style placed on the
  grid.

**Keys**

- Keys go as programs ask: legacy sequences, xterm's modifyOtherKeys or
  the Kitty keyboard protocol (Ghostty's key encoder).
- That covers arrows, function keys, Ctrl and Alt. Typed text goes by its
  key, IME text as it comes.
- Ctrl+Shift+C, V and A (Command on macOS) copy, paste and select all.
- On Windows, Ctrl+C copies when something is selected and interrupts
  otherwise. Ctrl+V pastes.
- Shift+Page Up and Down scroll by pages.

**The pointer**

- Programs that take the mouse get reports: X10, normal, button,
  any-motion, in SGR and the other encodings. Shift selects instead.
- A drag selects cells, a double click words, a triple click lines.
- A Shift-click extends or shrinks a selection from where it started,
  across lines too.
- The wheel scrolls the scrollback. On a full-screen program's screen it
  sends arrows (alternate scroll), or wheel reports.

**The rest**

- **Pastes** are bracketed when the program asks (mode 2004), and focus
  reports (mode 1004) are sent.
- **Titles** (OSC 0 and 2) come as `.title` events; `title()` reads them.
- **Links**: Ctrl+click (Command+click on macOS) opens a hyperlink
  (OSC 8), a URL printed as text, or a file path. It goes through
  `open_link`. Without it, the system opens URLs and absolute paths.
- Paths it finds: `/abs/path`, `~/notes.md`, `./a.go`,
  `src/app.go:12:3`, `main.go:250`, and `notes.md` (a file name with an
  extension, not a number such as 1.2.3).
- On Windows also `C:\dir\file`, `C:/dir/file`, `dir\file` and `.\file`.
- **Themes**: VS Code's palettes on myzig's window colors, following the
  window's appearance.
- The 617 themes Ghostty ships, by name
  (`terminal.ghosttyTheme("Dracula")`, `ghosttyThemeCount`,
  `ghosttyThemeName(i)`).
- Theme files in Ghostty's format (`terminal.Theme.parse`).

## The libraries

`src/myzig-plugin.json` names the builds the plugin binds, for each
platform, with their SHA-256 and download URL. They are mygo's releases
of libghostty-vt (Ghostty `befcdfd2c3a1`) and of ConPTY 1.25.260930003.
The plugin looks for them:

1. in the file `$MYZIG_GHOSTTY_VT` names (`$MYZIG_CONPTY`,
   `$MYZIG_OPENCONSOLE`; mygo's `$MYGO_...` too);
2. next to the executable, where an app ships them;
3. in `<cache>/myzig/natives/<sha256>/`, then mygo's
   `<cache>/mygo/natives/<sha256>/` (the cache being `%LOCALAPPDATA%`,
   `~/Library/Caches`, `$XDG_CACHE_HOME` or `~/.cache`).

- `terminal.download.fetchAll(gpa, io)` downloads what is missing into
  the cache and checks the SHA-256, as the example does.
- An app that never calls it carries no HTTP client.
- The structs the plugin passes are checked against the layouts the
  library reports as it loads. A library of another version fails to
  load rather than corrupt memory.

To ship the libraries with an app, put them in its `resources/` directory
(see [Distribution](../distribution.md)). On Windows and Linux they land
next to the executable. The CLI does not yet put them in a macOS bundle's
`Contents/MacOS`.

## Tests

```sh
cd plugins/terminal
zig build test                              # libghostty-vt, ConPTY or a pty, ui.Tester (skipped without the library)
zig build check -Dtarget=x86_64-linux-gnu   # type-check another platform
zig build snapshot                          # the example's first second, offscreen
zig build run                               # the example, in a window
```
