# Native UI in browsers

An app of native UI also runs in a browser, compiled to WebAssembly for
`wasm32-wasi`: its windows show on canvases of a page, drawn with WebGL 2
by the same shader as on Linux. Nothing changes in the app: the counter
example builds for browsers as it is.

```zig
pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Counter" });
    defer app.destroy();
    var state: Counter = .{};
    _ = try app.newWindow(.{ .title = "Counter", .content = .{ .view = .init(&state, Counter.view) } });
    try app.run();
}
```

There is no libc in a browser: Zig's standard library talks WASI, which the
page's host answers in JavaScript (`src/web/host_wasi.js`), with a file
system in memory. The browser backend is `src/web/`, chosen by
`src/myzig.zig` for `.wasi` as the others are for their systems.

## Building

With the CLI, `myzig build --platform web` builds the app (ReleaseSmall
unless `--optimize` says otherwise) into `<out>/web`, a static site to
serve from anywhere (see [the CLI](cli.md)):

```
index.html  host.js  host_gl.js  host_wasi.js   the page and its host
app.wasm                                        the app
fonts/fonts.json  fonts/*.ttf                   the fonts it draws text with
```

The app's `build.zig` (as `myzig init` writes it) exports the functions
the host calls with `if (target.result.os.tag == .wasi) exe.rdynamic = true;`.

Without the CLI, `addSite` of myzig's `build.zig` makes the same site from
an app's build:

```zig
const std = @import("std");
const myzig_build = @import("myzig");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("myzig", .{});
    const site = myzig_build.web.addSite(b, .{
        .name = "counter",
        .main = b.path("src/main.zig"),
        .myzig = dep.path("src"),
        // .fonts = "fonts",            // a directory of .ttf/.ttc files to bundle
        // .optimize = .ReleaseSmall,   // the default
    });
    b.step("web", "Build the app for browsers").dependOn(site.step);
}
```

The site is installed into `zig-out/web/<name>` (`install_subdir` changes
it); `site.dir` is its directory before installation and `site.wasm` the
compile step. In myzig's own repository:

```sh
zig build web                    # counter, gallery, gestures into zig-out/web/<name>
zig build web -Dweb-fonts=DIR    # with the fonts of DIR
zig build test-web               # run headless under Node
zig build test-web -Dweb-browser="/path/to/chrome-or-edge" # also test DOM wheel/pinch headlessly
```

Serve the directory over HTTP, with WebAssembly as `application/wasm`, as
most servers do. `index.html` starts the app:

```html
<script type="module">
  import { start } from "./host.js";
  start({ wasm: "app.wasm", fonts: "fonts/" });
</script>
```

`start` also takes `container` (the element the windows go in), `args` and
`env` (the app's command line and environment), and `webgl: false` to draw
on the CPU.

## Fonts

Text is myzig's own TrueType, drawn from fonts the site bundles: the host
fetches those `fonts/fonts.json` lists into the WASI file system
(`/usr/share/fonts`), where the font database finds them. They come from
the `fonts` option (with the CLI, the app's `fonts/` directory), else from
the first set found of the families `src/web/site.zig` lists in the
system's font folders: Inter, DejaVu Sans or Liberation Sans on Linux,
Segoe UI on Windows, Arial on macOS. Check their licenses before
publishing a site with them. A build with no fonts to bundle warns: text
does not draw.

## What works

- **Drawing.** Frames draw with WebGL 2 at the device pixel ratio, in the
  browser's next animation frame after something changed, again while
  something animates; idle, nothing runs. Backdrop effects, blurred layers
  and [shaders](ui/shaders.md) draw as on the desktop. Where the browser has
  no WebGL 2, frames are drawn by the CPU renderer and shown through a 2D
  canvas. A lost WebGL context draws again once the browser restores it.
- **Windows.** Each window is a canvas in the element with the ID `myzig`,
  else the body, filling it; a window opened later covers the earlier
  ones. The page sets the window's size, so the size, position and title
  bar options do nothing, and the title of the window shown last is the
  page's.
- **Input**: the pointer with its clicks counted, the wheel and touchpads,
  keys (by `KeyboardEvent.key`), and input methods, which compose in a
  text area kept out of sight at the caret. On a Mac, ⌘ is Control for the
  view's shortcuts, which take a browser for a system other than macOS.
  The menus' accelerators work, though no menu bar shows.
- **The clipboard**: copied text goes to the browser's clipboard
  (`navigator.clipboard`), and pasting brings the system's. Reading the
  clipboard from code returns what the app copied last, as a browser
  hands its clipboard only to a paste.
- **Appearance**: dark mode follows the browser's `prefers-color-scheme`
  and changes with it. A page chooses the appearance itself with
  `data-myzig-theme="dark"` or `"light"` on its root element.
- **The desktop**: `myzig.shell.openUrl` opens a tab;
  `myzig.dialog.message` asks with `alert` and `confirm`;
  `myzig.system.locale` and `languages` are `navigator.languages`; the
  app's directories (`myzig.path`) are in the WASI file system, for the
  page's life: `/home`, `/tmp`, and the app's own under
  `/home/.local/share`. Timers are the browser's.
- **Headless runs** (`--myzig-snapshot`, `--myzig-generate`) work as on
  desktops, under a WASI runtime.

## What does not

Windows of web pages (`.page` content), trays, notifications, file
dialogs, secrets, watching file descriptors and processes, sound output,
and drag and drop out of the window have nothing in a browser to stand
for them: they return `error.Unsupported`, return nothing, or do nothing.
A single instance is always the first. Assistive technology does not see
the content yet: a canvas is all it reads.

## Testing

- `zig build test-web` runs counter, gallery and gestures under Node
  (`src/web/test_node.mjs`), with the host's WASI and fonts and the page's
  functions stubbed (no WebGL: frames are drawn on the CPU): a frame
  draws, nothing draws while idle, and clicking a text shows another.
  The gestures example also checks pinch and horizontal/vertical pan.
- Add `-Dweb-browser="/path/to/chrome-or-edge"` to that command to run the
  Node checks and real DOM `WheelEvent` tests in a headless browser. These
  check pixel/line/page deltas, Ctrl-pinch, Ctrl-line scrolling and leaving
  browser defaults alone outside the view's handler.
- `src/web/test_browser_run.mjs BROWSER SITE_DIR "click=Increment&expect=1"`
  serves a site and runs `test_browser.js` in a headless Chromium (Chrome
  or Edge, hidden): frames draw with WebGL 2 and match the CPU renderer's
  pixels, nothing draws while idle, and DOM pointer events on the canvas
  change the view. `index` loads the site's own page and checks the app
  started there.
- `src/web/test_wasm.mjs` runs myzig's unit tests compiled for
  wasm32-wasi (`zig test -target wasm32-wasi --test-no-exec`) under Node.

## Under the hood

`main` makes the app and its windows, and `App.run` hands the app to the
browser: it ends `main` with its stack kept, and from then on the
browser's events drive the app through the functions it exports
(`src/web/exports.zig`: `myzig_web_pointer`, `myzig_web_key`,
`myzig_web_text`, `myzig_web_resize`, `myzig_web_animation_frame`,
`myzig_web_timer`, ...). Each event runs a frame when it changes
something and tells the host whether the view took it, so that the
browser's default is prevented only then. The app calls the page through
the functions it imports from the module `"myzig"` (`src/web/js.zig`):
opening windows, asking for an animation frame, the cursor, the caret's
place for the input method, timers, the clipboard, URLs, messages, the
appearance and the languages. Text goes through a shared buffer in the
WebAssembly memory. The architecture guide's
[rendering page](architecture-rendering.md) has the renderers.
