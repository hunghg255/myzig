# terminal

A terminal for myzig apps of native UI, after mygo's
[terminal plugin](../../../mygo/docs/plugins/terminal.md): a view that runs
the user's shell, or any program, in a pseudo-terminal, with
[Ghostty](https://ghostty.org)'s terminal emulator, libghostty-vt, loaded at
run time (LoadLibrary, dlopen): nothing is linked, no C is compiled.

```zig
const terminal = @import("terminal");

const term = try terminal.Terminal.create(gpa, app.io, .{
    .dark_theme = terminal.ghosttyTheme("Catppuccin Mocha"),
    .on_event = .{ .ctx = &state, .func = onEvent }, // .output: redraw, .title, .bell, .exit
});
defer term.destroy();

fn view(s: *State, c: *ui.Context) void {
    terminal.view(c, s.term, .{ .autofocus = true });
}
```

`example/` is the app: a window running the shell, titled by it, closed
when it exits.

## What it does

- **The program** runs in a pseudo-terminal: on Windows the Windows
  Terminal team's ConPTY (conpty.dll with OpenConsole.exe, as mygo ships
  it), else Windows' own; elsewhere `/dev/ptmx` through libc. The shell is
  `$SHELL` (else `/bin/zsh` on macOS, `/bin/sh` elsewhere), PowerShell on
  Windows; `command` runs another program, with `dir` and `env`
  (`TERM=xterm-256color`, `COLORTERM=truecolor` are set). It starts at the
  size the view's first frame gives it. A reader thread feeds its output to
  the emulator, a writer thread types into it in order, and events reach
  the app on the main thread through the mainthread plugin: nothing polls.
- **The screen**: colors (16, 256, 24-bit), bold, italic, faint, inverse,
  invisible, underlines (in their own colors), lines through and over, the
  scrollback (10 MB of output by default) and the alternate screen, the
  cursor (block, bar, underline; hollow while the view is not focused), the
  selection, and a scrollbar while the scrollback shows. Text is myzig's
  mono font, in runs of one style placed on the grid.
- **Keys** as programs ask: legacy sequences, xterm's modifyOtherKeys or the
  Kitty keyboard protocol (Ghostty's key encoder), with arrows, function
  keys, Ctrl and Alt; typed text goes by its key, IME text as it comes.
  Ctrl+Shift+C, V and A (Command on macOS) copy, paste and select all;
  on Windows Ctrl+C copies when something is selected (it interrupts
  otherwise) and Ctrl+V pastes; Shift+Page Up/Down scroll by pages.
- **The pointer**: reports (X10, normal, button, any-motion; SGR and the
  other formats) to programs that take the mouse, Shift selects instead; a
  drag selects cells, a double click words, a triple click lines; the wheel
  scrolls the scrollback, or sends arrows on a full-screen program's screen
  (alternate scroll), or wheel reports.
- **Pastes** are bracketed when the program asks (mode 2004), and focus
  reports (mode 1004) are sent.
- **Titles** (OSC 0, 2) come as `.title` events; `title()` reads them.
- **Links**: while Ctrl (Command on macOS) is held, the link under the
  pointer is underlined, with a hand; a click opens a hyperlink (OSC 8),
  a URL printed as text, or a file path through `open_link` (absolute ones
  with the system without it): `/abs/path`, `~/notes.md`, `./a.go`,
  `src/app.go:12:3`, `main.go:250`, and on Windows `C:\dir\file`,
  `C:/dir/file`, `dir\file` and `.\file`, as mygo finds them.
- **Themes**: VS Code's palettes on myzig's window colors, following the
  window's appearance; the 617 themes Ghostty ships by name
  (`ghosttyTheme`), and theme files in Ghostty's format (`Theme.parse`).

`text()`, `snapshot()` (escape sequences that restore the screen),
`send()`, `paste()`, `feed()` (show bytes as if the program wrote them; a
terminal with `no_program` shows only those) and `resize()` are there too.

## The libraries

`src/myzig-plugin.json` names the builds the plugin binds, by platform with
their SHA-256: mygo's releases of libghostty-vt (Ghostty befcdfd2c3a1) and
of ConPTY 1.25.260930003. They are looked for in `$MYZIG_GHOSTTY_VT`
(`$MYZIG_CONPTY`; mygo's `$MYGO_…` too), next to the executable (where an
app ships them), then in `<cache>/myzig/natives/<sha256>/` and mygo's
`<cache>/mygo/natives/<sha256>/` (`%LOCALAPPDATA%`, `~/Library/Caches`,
`$XDG_CACHE_HOME` or `~/.cache`). `download.fetchAll` downloads what is
missing into the cache, checking the SHA-256, as the example does: an app
that never calls it carries no HTTP client. The structs the plugin passes
are checked against the layouts the library reports as it loads, so a
library of another version fails to load rather than corrupt memory.

```sh
zig build test                              # libghostty-vt, ConPTY or a pty, ui.Tester (tests skip without the library)
zig build check -Dtarget=x86_64-linux-gnu   # type-check another platform
zig build snapshot                          # the example's first second, offscreen
```
