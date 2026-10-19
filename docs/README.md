# myzig documentation

myzig builds desktop apps in Zig. Each window shows one of two kinds of
interface, and one app can have windows of both:

- **A web page**, in the webview of the operating system (WKWebView on
  macOS, WebKitGTK on Linux, WebView2 on Windows) instead of a bundled
  browser. The frontend is HTML, CSS and JavaScript built with any tools,
  and calls your Zig code through a JavaScript client that myzig generates
  from your Zig types at compile time, with TypeScript declarations.
- **Native UI**, which myzig draws itself, written in Zig alone with
  `myzig.ui`: no HTML, no JavaScript and no webview to start, so the window
  opens at once and takes little memory. It is drawn with Metal on macOS,
  Direct3D 11 on Windows, OpenGL on Linux and WebGL 2 in browsers, and with
  myzig's own CPU renderer (the same pixels) wherever a GPU is missing.

Windows of both kinds share the window options and events, the menus and
the desktop APIs, and an app is a single Zig program of well under a
megabyte. Native UI also runs in browsers, built for `wasm32-wasi`.

A window with a web page, whose frontend calls a Zig service:

```zig
const Greeter = struct {
    pub const myzig_params = .{ .greet = .{"name"} };

    /// Returns a greeting.
    pub fn greet(_: *Greeter, call: *myzig.Call, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(call.arena, "Hello, {s}!", .{name});
    }
};

const assets = [_]myzig.Asset{
    .{ .path = "/index.html", .data = @embedFile("frontend/index.html") },
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Hello" });
    defer app.destroy();
    var greeter: Greeter = .{};
    try app.bind(&greeter);
    _ = try app.newWindow(.{ .title = "Hello", .content = .{ .page = .{ .url = "/", .assets = &assets } } });
    try app.run();
}
```

```js
import { Greeter } from "/myzig.js"; // generated, served by the app

document.body.textContent = await Greeter.greet("Ada");
```

A window with native UI, whose view is a Zig function of the app's state:

```zig
const Counter = struct {
    n: i64 = 0,

    fn view(s: *Counter, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 16 });
        defer ui.end(c);
        ui.textf(c, .{ .size = 56, .weight = .bold }, "{d}", .{s.n});
        if (ui.button(c, "Increment", .{ .variant = .primary }).clicked) s.n += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Counter" });
    defer app.destroy();
    var state: Counter = .{};
    _ = try app.newWindow(.{ .title = "Counter", .content = .{ .view = .init(&state, Counter.view) } });
    try app.run();
}
```

## Guides

Start here:

- [Getting started](getting-started.md): Zig 0.17, the CLI, `myzig init`,
  building and running, every example.

The app and the desktop:

- [The application](app.md): creating and running the app, its options and
  handlers, threads, quitting and signals, single instance, deep links,
  notifications, network status, start at login.
- [Windows](windows.md): every window option, method and event, remembered
  state, closing, title bars and frameless windows, materials, flyouts,
  progress, files dropped on windows.
- [Menus, trays and global shortcuts](menus.md): menu templates, roles,
  accelerators, the menu bar on each platform, tray icons, global hotkeys.
- [The system around the app](system.md): dialogs, the shell, the app's
  directories, appearance, locale, recent documents, open at login, URL
  schemes and file types, keeping awake, secrets, file and descriptor
  watching.
- [Documents](documents.md): document-based apps with `myzig.Documents`:
  a window per document, saving, autosave, recovery, the File menu.
- [Audio](audio.md): sounds, streams and players, mixing, the system's
  output.
- [Clipboard and drag data](data-transfer.md): the clipboard, typed drag
  data, drags leaving the window.

Web pages:

- [Pages](pages.md): page options, the `myzig://` scheme, the app's own
  schemes, eval, page events, permissions, downloads, trust, find, PDF,
  cookies, headless page tests.
- [Bindings](bindings.md): bound services, `myzig.Call`, errors, typed
  events, channels, the generated client and its type mapping.
- [The frontend](frontend.md): the `window.myzig` runtime, built frontends,
  dev servers, draggable regions, user scripts, the web inspector.

Native UI:

- [Native UI](ui/README.md): the guide to `myzig.ui`, with an index of its
  pages: views, layout, styling, text, every widget family, overlays,
  structures, lists, motion, transforms, drawing, charts, Markdown, the
  text area, the code editor, rich text, shaders, accessibility, right to
  left, the inspector, testing, rendering and performance.
- [Native UI in browsers](browsers.md): the `wasm32-wasi` target, static
  sites, what works in browsers.

Everything else:

- [Languages](i18n.md): message catalogs, plurals, numbers and dates,
  right to left, myzig's own strings, translated pages.
- [Plugins](plugins.md): using and writing plugins, and the official ones:
  [fetch](plugins/fetch.md), [websocket](plugins/websocket.md),
  [sqlite](plugins/sqlite.md), [watch](plugins/watch.md),
  [updater](plugins/updater.md), [terminal](plugins/terminal.md),
  [glass](plugins/glass.md), [game](plugins/game.md) and
  [mainthread](plugins/mainthread.md).
- [The myzig CLI](cli.md): `init`, `dev`, `build`, `generate`, `icon`,
  `keygen`, `doctor`, `version`, and the apps' `--myzig-*` flags.
- [Configuration](configuration.md): every field of `myzig.zon`.
- [Building and distributing](distribution.md): what `myzig build` makes
  on each platform (`.app` and `.dmg`, `.exe`, `.zip` and an NSIS
  installer, `.tar.gz` and `.deb`), signing, cross-building.
- [Updates](updates.md): signed updates with `myzig keygen`, `myzig build`
  and `--upload` (GitHub, S3), for the updater plugin.

How myzig works, for contributors:

- [Architecture](architecture.md): the layers, choosing the platform at
  compile time, threading, native code without C.
- [IPC and TypeScript generation](architecture-ipc.md): the wire protocol
  between pages and Zig, the outbox, channels, schemes, `tsgen`.
- [Rendering native UI](architecture-rendering.md): one frame, the
  instances, the five renderers and the CPU twin, text and atlases,
  surfaces.
- [Testing, binary size and adding a feature](architecture-testing.md):
  every test step, the Linux container and Wine, the hill climb, and the
  checklist for a new feature.

The rules for changing myzig, by hand or with an agent, are in
[AGENTS.md](../AGENTS.md).

## This documentation as a site

These pages are also a [VitePress](https://vitepress.dev) site, with a
sidebar, search and dark mode. With Node installed:

```sh
cd docs
npm install
npm run dev       # serves the site at http://localhost:5173, live
npm run build     # writes it to docs/.vitepress/dist, failing on any dead link
npm run preview   # serves what build wrote
```

`docs/.vitepress/config.mts` holds the navigation and the sidebar: a new
page gets its place there. Pages stay plain Markdown, read the same on
GitHub; links out of `docs/` (to `AGENTS.md`, sources, benchmark notes)
become links to the repository on the site.
