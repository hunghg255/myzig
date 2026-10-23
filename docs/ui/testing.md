# Testing

myzig tests native UI without a window, and apps without showing one.
Nothing reaches the screen, the mouse, the keyboard or the system's
clipboard: a test cannot disturb the person at the computer, and reads the
same on a busy machine as on an idle one.

- **Views** run in a `ui.Tester`: the same frames a window runs, input
  simulated in process, time advanced by hand, frames rendered offscreen
  to PNG files.
- **Apps** run headless with the `--myzig-*` flags: a snapshot of their
  first native window after a script of steps, or JavaScript evaluated in
  their pages.
- **Renderers** are tested against the CPU renderer, pixel for pixel to
  rounding (see [Rendering](rendering.md)).

## ui.Tester

```zig
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const Counter = struct {
    n: i64 = 0,
    fn view(s: *Counter, c: *ui.Context) void {
        const col = ui.div(c).column().sizeFull().center().gap(16);
        defer col.end();
        ui.textf(c, .{ .size = 56, .weight = .bold }, "{d}", .{s.n});
        if (ui.button(c, "Increment", .{ .variant = .primary }).clicked) s.n += 1;
    }
};

test "the counter counts" {
    var state: Counter = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, Counter.view), .{ .width = 320, .height = 240 });
    defer t.deinit();
    try t.clickText("Increment");
    try std.testing.expectEqual(@as(i64, 1), state.n);
    try std.testing.expect(t.hasText("1"));
}
```

A Tester is initialized in place (its context points into it) and runs
the first frame. `ui.TesterOptions` has `width` and `height` in points
(480 × 360 by default), `scale` (2), `dark`, and `theme`, colors of its
own as a window's `theme` option gives.

### Input

| Call | What it does |
|---|---|
| `click(x, y)`, `clickText(s)` | presses and releases at a point, or at the middle of the text `s` (`error.TextNotFound` when no text is `s`) |
| `doubleClick(x, y)` | two clicks, the second counted as a double click |
| `rightClick(x, y)` | a press of the secondary button, which opens a context menu |
| `middleClick(x, y)` | a press of the middle button (`c.input.middle_pressed`), which closes a browser's tab |
| `moveTo(x, y)` | moves the pointer: hover |
| `pinch(x, y, scale)` | offers a multiplicative zoom to the handler under the point; returns whether it was taken |
| `drag(x1, y1, x2, y2)` | presses, moves in eight steps, releases |
| `scroll(x, y, dy)` | scrolls the box under the point at once, as a touchpad does, or hands the wheel to a view that takes it (`c.wants_wheel`) |
| `wheel(x, y, dy)` | a notch of a mouse wheel: the box glides there as the clock advances (`advance`), the box around one at its end taking it |
| `typeText(s)` | types text into the focused field |
| `textOps(ops)` | sends text input operations (`ui.TextOp`), as an input method or AppKit's key bindings would: insertions, commands, compositions |
| `key(k)` | presses a key (`ui.Context`'s `Key`: `.enter`, `.tab`, `.escape`, `.left`, `.f12`, ...) |
| `shortcut(s)` | offers a key combination (`ui.Shortcut{ .key = 's', .cmd = true }`), as a window does before text editing; true if the view took it |
| `keyEdge(code, down)` | a key going down or up, for views that follow keys (`c.wants_keys`): games |
| `resize(w, h)` | resizes the window and runs a frame |

### What it shows

`findText(s)` returns the rectangle of the text `s` in the last frame,
`hasText(s)` whether it is there, and `containsText(s)` whether a text
drawn contains `s` (a terminal's row, a paragraph). `t.ctx` is the view's
`ui.Context`, for what a test reads of it: the focus, the boxes and their
rectangles (`t.ctx.nodes`, `t.ctx.rects`), the frame's stats. What copy
and cut wrote is in `t.clipboard`: tests never touch the system's.

What assistive technology sees is tested through the Tester too: see
[Accessibility](accessibility.md#testing-it).

### Time

A Tester has a clock of its own, `t.time`, advanced by `t.dt` (1/60 of a
second) each frame. Animations, double clicks, the caret's blinking,
tooltips, toasts and `c.time` follow it, never the wall clock.

```zig
try t.clickText("More");
t.advance(0.1);   // a tenth of a second of frames: half way through an animation
t.settle(2);      // frames until nothing animates, at most two seconds of them
try std.testing.expect(!t.ctx.animating);
```

`t.frame()` runs one frame, for what changed outside the view;
`t.advance(seconds)` runs the frames of that much time; `t.settle(max)`
runs frames until animations settle. Never sleep in a test to let
something happen: advance the clock.

`t.pinch(x, y, scale)` offers a touchpad zoom to a
[`handleInput` callback](gestures.md), and returns whether it was taken.
`t.scroll` and `t.wheel` offer scroll events to those handlers before
scrolling the surrounding containers.

### Pictures

`t.screenshot(path)` renders the last frame offscreen and writes a PNG:
with Metal on macOS, with the CPU renderer where text is myzig's own
(Linux, Windows, browsers, and macOS built with `-Dportable=true`).
`t.render(gpa)` returns the pixels instead (`gpu.Pixels`: BGRA,
premultiplied; free with `deinit`), for comparing them, and
`t.rasterize(bytes)` draws into memory of `t.pixelSize()` with the CPU
renderer.

```zig
const px = try t.render(std.testing.allocator);
defer px.deinit(std.testing.allocator);
// px.bytes[(y * px.width + x) * 4 ..][0..4] is B, G, R, A
```

### Scripts

`t.runScript(steps)` runs steps separated by `;`, each followed by frames
until animations settle:

| Step | What it does |
|---|---|
| `click:TEXT`, `move:TEXT` | clicks or hovers the middle of a text |
| `visible:TEXT` | fails unless the text shows whole within the window (`move:` finds it outside too) |
| `rclick:TEXT` | right-clicks the middle of a text (or `X,Y` in points), as for its context menu |
| `type:TEXT` | types text |
| `key:NAME` | presses a key: `enter`, `backspace`, `tab`, `escape`, `left`, `right`, `up`, `down`, ... |
| `shortcut:KEYS` | a key combination such as `ctrl+shift+p` (`cmd`, `ctrl`, `alt`, `shift`, then a character, an arrow, `enter`, `tab`, `escape` or `f1` to `f12`) |
| `scroll:DY` | scrolls at the pointer |
| `wheel:DY` | scrolls at the pointer as a mouse wheel's notches do, gliding (`frames:N` to watch it) |
| `drag:FROM>TO` | drags from one text (or `X,Y`) to another |
| `wait:SECONDS` | advances the simulated clock |
| `frames:N` | runs N frames, then no settling: a snapshot mid-animation |
| `live:SECONDS` | runs the real event loop meanwhile: replies, processes, timers |
| `resize:WxH` | resizes the window |

Scripts are what `--myzig-script` runs in a real app.

## Apps, headless

Every app made with `myzig.App` reads these flags (`src/dev.zig`):

| Flag | What it does |
|---|---|
| `--myzig-snapshot=PNG` | renders the first window of native UI offscreen to PNG, and exits |
| `--myzig-script=STEPS` | with a snapshot: steps run first, as `runScript` |
| `--myzig-dark` | with a snapshot: the dark appearance |
| `--myzig-wait=SECONDS` | with a snapshot: runs the event loop that long first, so that processes, timers and replies the app waits for arrive |
| `--myzig-eval=JS` | evaluates JavaScript in each page once its DOM is ready; pages report with `myzig.log()` and finish with `myzig.window.close()` |
| `--myzig-hidden` | never shows windows; the app's directories are temporary (headless) |
| `--myzig-generate=DIR` | writes the generated client (`myzig.js`, `myzig.d.ts`) and exits |

A snapshot, an evaluation or a generation implies hidden windows.

```sh
zig-out/bin/gallery --myzig-snapshot=/tmp/g.png --myzig-script="click:Tasks;type:Hi;key:enter"
zig-out/bin/hello --myzig-eval='myzig.call("Greeter.greet","Ada").then(v=>{myzig.log(v);myzig.window.close()})'
```

## Pages

`zig build test-pages` runs pages hidden, through the real webview and
bridge of the platform: the hello example calling Zig (calls, errors, an
event, the generated client), and the pages example (`examples/pages`),
where a hidden page and Zig check each other: schemes, channels, events,
permissions, downloads, eval, find, PDF, cookies and trust. Each passes
when the page logs `page: ok`.

## Examples with tests

An example may hold `test` blocks of its own, run by `zig build test`
(the list `tested_examples` of `build.zig`: blackhole, chat-glow, wind,
effort-slider, mayoi and loading): their views through a Tester, their shaders
drawn on the CPU and checked for what they must draw.
`zig build test-loading -j1` runs just the loading plugin and gallery,
including duration, independent clocks, repeated builds and reduced motion.

## Browsers

`zig build test-web` builds counter, gallery and gestures for browsers and runs them
headless under Node (`src/web/test_node.mjs`): a frame draws, nothing
draws while idle, clicking a text shows another, and pinch and pan change
the gesture example. It needs `node`.
`src/web/test_browser_run.mjs` runs the same check in a headless Chromium
(Chrome or Edge, hidden), with WebGL 2 against the CPU renderer's pixels,
and `src/web/test_wasm.mjs` runs myzig's unit tests compiled for
wasm32-wasi. See [Browsers](../browsers.md).

To also check the host's real DOM `WheelEvent` listener:

```sh
zig build test-web -j1 -Dweb-browser="/path/to/chrome-or-edge"
```

On Windows, for example, use
`-Dweb-browser="C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"`.
The browser runs headlessly. These tests cover pixel, line and page deltas,
Ctrl-pinch and preventing defaults only when the view handles the event.

## Other platforms

Linux and Windows build from any machine. Linux's tests run in a container
with GTK 3, WebKitGTK, fonts, Mesa and a virtual display
(`tools/linux.Dockerfile`):

```sh
zig build test-bin -Dtarget=aarch64-linux-gnu --prefix zig-out/linux
docker build -t myzig-linux -f tools/linux.Dockerfile tools
docker run --rm -v "$PWD/zig-out/linux:/work" myzig-linux xvfb-run ./bin/myzig-tests
```

Windows programs run under Wine on a virtual display
(`tools/wine.Dockerfile` for arm64 builds, `tools/wine-amd64.Dockerfile`
for x86_64 builds on an arm64 Mac). `zig build test -Dportable=true`
runs, on a Mac, the text and CPU renderer of Linux and Windows.

## Documentation images

The UI guides use PNGs of running widgets, rendered offscreen by `ui.Tester`.
From the repository root, regenerate them with:

```sh
cd docs
npm run images:ui
npm run build
```

`images:ui` runs `zig build docs-ui -Doptimize=ReleaseFast -j1`, then
losslessly compresses the PNG data into `docs/images/ui/`. It needs Zig 0.17
and Node, with no additional image tools. The English and Vietnamese pages
share the images; their labels follow the English Gallery example.

To update only selected images after rendering, run from the repository root:

```sh
node docs/scripts/ui-images.mjs items.png input-groups.png pagination.png
```

[The snapshot runner](../../examples/gallery/snapshots.zig) reuses Gallery
views, frames each card from its computed layout and opens menus and dialogs
with in-process Tester input. [The foundation scenes](../../examples/gallery/snapshot_foundations.zig)
illustrate layout, grid, direction and the guide's shader. No window is shown
and no desktop pixels are captured. The committed images were generated on
Windows with the CPU renderer and system fonts; font metrics can differ on
other platforms. Motion images are still frames, and embedded system webviews
are not captured by this tool.

After changing a pictured widget, regenerate the images, inspect them for
clipped content and check them in alongside the docs. `npm run build` checks
that the images resolve on the documentation site.

## Rules

- Tests never pass or fail on wall-clock time: advance a Tester's clock,
  wait for a condition with the event loop (`myzig.runFor`), measure work
  by counts.
- Tests never touch the user's state: no system clipboard, no files
  outside temporary directories, no defaults.
- Every widget behavior gets a test (`src/ui/tests*.zig`); see the
  [architecture guide](../architecture-testing.md).
