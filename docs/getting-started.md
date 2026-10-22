# Getting started

myzig builds desktop apps in Zig. A window shows either native UI that
myzig draws itself, written in Zig alone, or a web page in the system's
webview whose frontend calls your Zig code through a generated client.
This page installs the tools, makes an app, runs it and builds its
release, then tours the examples.

## Install

You need **Zig 0.17.0** or later (`minimum_zig_version` in
`build.zig.zon`). myzig loads what Linux and Windows have when the app
starts instead of linking it, so their apps build from any machine
(`-Dtarget=...`) with nothing else; macOS apps link Apple's frameworks,
so they build where the macOS SDK is.

What the app needs to run:

| | to build | to run |
|---|---|---|
| macOS | the macOS SDK (Xcode or the Command Line Tools) | nothing |
| Linux | nothing | GTK 3; WebKitGTK (`libwebkit2gtk-4.1` or `-4.0`) for pages |
| Windows | nothing | the WebView2 Runtime for pages (Windows 11 has it) |
| browsers | nothing | a browser with WebGL 2 (see [Browsers](browsers.md)) |

Get myzig, and build the command line tool:

```sh
git clone https://github.com/hunghg255/myzig
cd myzig/cli
zig build -Doptimize=ReleaseSmall    # zig-out/bin/myzig
```

Put `cli/zig-out/bin` on your `PATH`, or run the tool from the checkout
with `zig build run -- <command>` in `cli/`. `myzig doctor` checks that the
machine can build and run apps: Zig, the platform's SDK and libraries (the
macOS SDK; GTK 3 and WebKitGTK; the WebView2 Runtime).

myzig was called nanoui. The module, its flags (`--myzig-*`), the page
runtime (`window.myzig`) and the URL scheme (`myzig://`) carry the new
name; the build still exports the module as `nanoui` too, for apps that
import the old name.

## Create an app

```sh
myzig init hello                  # native UI (the default template)
myzig init hello --template web   # a web page calling Zig
```

`init` makes an app in a new or empty directory. It is a Zig package
whose `build.zig.zon` depends on myzig:

```
hello/
  build.zig          the app's build: `zig build run`, `zig build test`
  build.zig.zon      depends on myzig
  myzig.zon          the app, for the CLI: name, identifier, icon, frontend
  src/main.zig       the app
  resources/icon.png its icon (myzig's default one)
  frontend/          the web template's pages (index.html, main.js, style.css)
  .gitignore
```

Where myzig comes from: `--myzig PATH` names a checkout, which becomes a
path dependency; `--myzig URL` names what `zig fetch` fetches. Without it,
`init` uses the checkout `MYZIG_ROOT` names, else the myzig repository.
`--name` gives the app a name other than its directory's. The web
template is built once after it is made, to write the frontend's
generated client (`--skip-generate` leaves that to the first `myzig dev`).

### Native UI

The native template's `src/main.zig` is a counter:

```zig
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const Counter = struct {
    n: i64 = 0,

    fn view(s: *Counter, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 16 });
        defer ui.end(c);
        ui.textf(c, .{ .size = 56, .weight = .bold }, "{d}", .{s.n});
        if (ui.button(c, "Increment", .{ .variant = .primary, .size = 16 }).clicked) s.n += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Hello" });
    defer app.destroy();
    var state: Counter = .{};
    _ = try app.newWindow(.{
        .title = "Hello",
        .width = 420,
        .height = 300,
        .content = .{ .view = .init(&state, Counter.view) },
    });
    try app.run();
}

test "the button counts" {
    var state: Counter = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, Counter.view), .{});
    defer t.deinit();
    try t.clickText("Increment");
    try std.testing.expectEqual(@as(i64, 1), state.n);
}
```

The view is a function of the app's state, run for every frame. A widget
answers what happened to it in the previous frame (`.clicked`); when that
changes the state, the frame is built again before it is drawn. The test
runs the same view in a `ui.Tester`, without a window. See
[Native UI](ui/README.md).

### A web page

The web template binds a service and shows `frontend/` in a window:

```zig
const std = @import("std");
const myzig = @import("myzig");
const assets = @import("assets");

const Greeter = struct {
    pub const myzig_params = .{ .greet = .{"name"} };

    /// Returns a greeting.
    pub fn greet(_: *Greeter, call: *myzig.Call, name: []const u8) ![]const u8 {
        const who = std.mem.trim(u8, name, " ");
        return std.fmt.allocPrint(call.arena, "Hello, {s}!", .{if (who.len == 0) "stranger" else who});
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Hello" });
    defer app.destroy();
    var greeter: Greeter = .{};
    try app.bind(&greeter);
    // `myzig dev` points the window at the dev server, when there is one.
    const url = init.environ_map.get("MYZIG_DEV_URL") orelse "/";
    _ = try app.newWindow(.{
        .title = "Hello",
        .width = 720,
        .height = 520,
        .content = .{ .page = .{ .url = url, .assets = &assets.files } },
    });
    try app.run();
}
```

```js
// frontend/main.js
import { Greeter } from "/myzig.js";

document.getElementById("greeting").textContent = await Greeter.greet("Ada");
```

`assets` is `frontend/myzig_assets.zig`, which the CLI writes: the
frontend's files embedded into the app and served at
`myzig://localhost/`. `/myzig.js` is the client generated from the bound
services, typed by `frontend/myzig.d.ts`. See [Pages](pages.md) and
[Bindings](bindings.md).

## Develop

```sh
cd hello
myzig dev            # build, run, and rebuild and restart as files change
zig build run        # or with Zig alone
zig build test       # the app's tests
```

`myzig dev` watches the app's files through the system (nothing polls),
writes the web template's client again when the services change, and,
with a `dev_command` and `dev_url` in `myzig.zon`, runs a dev server
(Vite, ...) first and points the app at it through `MYZIG_DEV_URL`.
Arguments after `--` go to the app. See [The CLI](cli.md) and
[Configuration](configuration.md).

## Check an app without a window

Apps take flags that run them hidden, which tests and agents use instead
of showing windows:

```sh
zig-out/bin/hello --myzig-snapshot=shot.png                 # draw the first native UI window to a PNG
zig-out/bin/hello --myzig-snapshot=shot.png --myzig-script="click:Increment" --myzig-dark
zig-out/bin/hello --myzig-snapshot=shot.png --myzig-wait=1  # run the loop for a second first
zig-out/bin/hello --myzig-eval='myzig.call("Greeter.greet","Ada").then(v => { myzig.log(v); myzig.window.close() })'
zig-out/bin/hello --myzig-generate=frontend                 # write myzig.js and myzig.d.ts, and exit
zig-out/bin/hello --myzig-hidden                            # run, never showing a window
```

`--myzig-eval` runs a script in each page once its DOM is ready; the page
reports with `myzig.log()` and ends the run with `myzig.window.close()`.
Snapshots, scripts and the Tester are in [Testing](ui/testing.md).

## Build the release

```sh
myzig build                        # this platform and architecture
myzig build --platform windows     # from any machine
myzig build --platform linux --arch aarch64
myzig build --platform web         # a static site (native UI only)
```

`build` compiles a stripped `ReleaseSmall` binary (`--optimize fast` or
`safe` for the others) and packages it in `dist/<platform>-<arch>`: a
`.app` and a `.dmg` on macOS, an `.exe` with its icon and version
resources and a `.zip` (and an installer, with NSIS) for Windows, a
directory, a `.tar.gz` and a `.deb` for Linux. A counter is about 0.7 MB.
See [Distribution](distribution.md).

## The examples

The repository's examples build with `zig build` from its root, into
`zig-out/bin`, and each runs with `zig build run-<name>`:

| example | what it shows |
|---|---|
| `counter` | the smallest native UI app: a view as a function of the state |
| `gallery` | a tour of the native UI toolkit: layout, text, every widget, overlays, drawing, motion, drag and drop |
| `hello` | a web page calling Zig: bound services, typed events, the generated client |
| `todo` | a small complete web app: typed services and events, persistence, dialogs, menus, windows kept in sync |
| `native` | the desktop from a page: the menu bar, a tray icon, dialogs, notifications, the clipboard |
| `pages` | the pages test: schemes, channels, events, permissions, downloads, eval, find, PDF, cookies, trust |
| `documents` | a notes editor on `myzig.Documents`: the File menu, a window per note, autosave, recovery |
| `notes` | notes edited as rich text, with a toolbar, links and Markdown shortcuts |
| `markdown-chat` | replies streaming in as Markdown |
| `code-editor` | the code editor, the diff viewer and the text area |
| `text-buffer` | 100 000 lines in a rope, laid out only in view |
| `text-input` | a text field built from the text-input primitives |
| `clipboard` | one data model copied and dragged as text, HTML and JSON |
| `drag-drop` | drags within and between windows, out to other apps, files dropped in |
| `chart-streaming` | rolling waveforms of 15 000 samples, 1 000 new a second |
| `confetti` | canvas-confetti's demos in native UI |
| `piano` | a synthesized piano played with `myzig.audio` |
| `timeline` | several tweens on one playhead (`ui.motion.timeline`) |
| `blackhole` | a black hole ray traced in a shader written once |
| `chat-glow` | a chat that glows, with shaders for the orb, ring and shimmer |
| `wind` | a pane of characters stirred by a wind shader |
| `effort-slider` | the "galaxy brain" slider, with shaders and motion |
| `mayoi` | a small game drawn as one shader |
| `loading` | loading.dev's 29 native loading indicators, with size, color, easing, stroke caps and pause controls |
| `farm` | a farming game on the game plugin: `cd examples/farm && zig build run` |

The plugins have examples of their own (`plugins/<name>/example`).

Other steps of the root build:

```sh
zig build test                    # unit and widget tests
zig build test -Dportable=true    # the same with myzig's own text and CPU renderer
zig build test-pages              # pages run hidden: hello calling Zig, and examples/pages
zig build web                     # counter and gallery for browsers, in zig-out/web/<name>
zig build test-web                # those run headless under Node
zig build gen                     # write the hello example's generated client
zig build lines                   # every file at most 600 lines
```

## Next steps

- [The application](app.md): its lifecycle, a single instance, deep links,
  notifications.
- [Windows](windows.md): options, events, title bars, flyouts.
- [Menus, trays and global shortcuts](menus.md).
- [Native UI](ui/README.md) or [Pages](pages.md), whichever your windows
  show.
