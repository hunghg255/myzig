# Testing, binary size and adding a feature

How myzig is tested without ever showing a window or driving the screen,
how apps are kept small, and the checklist for adding a feature. Back to
[the overview](architecture.md); for testing an app's own views, see
[testing native UI](ui/testing.md).

## The rules

- **Never show windows on the developer's screen**, never take focus,
  never synthesize mouse or keyboard events, never capture the screen.
  Native UI is tested with `ui.Tester` (in process, rendered offscreen),
  apps with `--myzig-snapshot` and `--myzig-script`, pages with
  `--myzig-eval` or `--myzig-hidden`: all keep windows hidden.
- **Tests never touch the user's state**: no system clipboard (the Tester
  has its own), no files outside temporary directories, no defaults or
  registry keys of the user's.
- **Tests never depend on wall-clock time.** Advance the Tester's clock
  (`t.advance(seconds)`, `t.settle(max)`), and wait for conditions, not
  durations. Only `live:` steps and `myzig.runFor` run the real event
  loop, for replies and processes, never to make an assertion pass.

## ui.Tester

`ui.Tester` (`src/ui/tester.zig`) runs a `ui.View` with no window, through
the same `frame.run` windows use, and renders it offscreen: with Metal on
macOS, with the CPU renderer elsewhere and with `-Dportable=true`.

```zig
var t: ui.Tester = undefined;
try t.init(std.testing.allocator, .init(&state, Counter.view), .{ .width = 480, .height = 360 });
defer t.deinit();
try t.clickText("Increment");
try std.testing.expect(t.hasText("1"));
t.advance(0.3); // animations move by simulated time
try t.screenshot("/tmp/counter.png");
```

It offers pointer input (`moveTo`, `click`, `doubleClick`, `rightClick`, `middleClick`,
`drag`, `scroll`, `wheel`, `clickText`), keys (`key`, `keyEdge`, `shortcut`,
`typeText`, `textOps`), time (`frame`, `advance`, `settle`, with `dt`
seconds a frame), `resize`, queries (`findText`, `hasText`,
`containsText`), and pixels (`render`, `rasterize`, `screenshot`,
`pixelSize`). Its `clipboard` is a buffer of its own. `runScript` runs
the steps the `--myzig-script` flag takes: `click:TEXT`, `rclick:TEXT`,
`move:TEXT`, `visible:TEXT` (fails unless the text shows whole in the
window), `type:TEXT`, `key:enter|backspace|tab|escape|left|right`,
`shortcut:ctrl+shift+p` (a key combination, to the menu bar's
accelerators and the view as a window gives it), `scroll:DY`,
`wheel:DY` (notches, gliding), `drag:FROM>TO`, `wait:SECONDS`
(simulated), `frames:N`, `live:SECONDS` (the real loop) and
`resize:WxH`.

Every widget behavior has a test through the Tester in `src/ui/tests*.zig`
(`tests_overlays_menu.zig`, `tests_controls_date.zig`,
`tests_richtext.zig`, ...), registered in `ui.zig`'s test block.

## Headless flags

`src/dev.zig` reads flags every app accepts, for trying and testing it
without touching the screen:

| flag | does |
|---|---|
| `--myzig-generate=DIR` | write the generated client (`myzig.js`, `myzig.d.ts`) and exit |
| `--myzig-snapshot=PNG` | render the first native UI window offscreen to PNG and exit |
| `--myzig-script=STEPS` | with `--myzig-snapshot`: run these Tester steps first |
| `--myzig-dark` | with `--myzig-snapshot`: the dark appearance |
| `--myzig-wait=SECONDS` | with `--myzig-snapshot`: run the event loop that long first |
| `--myzig-hidden` | never show windows |
| `--myzig-eval=JS` | evaluate JS in each page once its DOM is ready (implies hidden) |

A page under `--myzig-eval` reports with `myzig.log(...)` (printed as
`page: ...` on stderr) and ends the app with `myzig.window.close()`.
`MYZIG_DEBUG=1` makes apps log their windows and frames for tools.

```sh
zig-out/bin/gallery --myzig-snapshot=/tmp/g.png --myzig-script="click:Tasks;type:Hi;key:enter"
zig-out/bin/hello --myzig-eval='myzig.call("Greeter.greet","Ada").then(v=>{myzig.log(v);myzig.window.close()})'
```

## The build's test steps

| command | runs |
|---|---|
| `zig build test` | the unit and widget tests of `src/myzig.zig`'s test block, plus the Tester tests of the examples with their own (`blackhole`, `chat-glow`, `wind`, `effort-slider`, `mayoi`) |
| `zig build test -Dportable=true` | the same with myzig's TrueType text and CPU renderer (the Linux and Windows path, on a Mac) |
| `zig build test-pages` | pages hidden in the real web view: hello's page calling Zig (calls, errors, unknown services, an event, the generated client), and `examples/pages` (schemes, channels, events, permissions, downloads, eval, find, PDF, cookies, trust), each expecting `page: ok` on stderr |
| `zig build test-web` | counter and gallery built for browsers, run headless under Node (`src/web/test_node.mjs`): a frame draws, clicking a text changes the view |
| `zig build test-bin` | installs the unit tests as `zig-out/bin/myzig-tests` (`.exe` on Windows), to run on another machine |
| `zig build lines` | every file at most 600 lines |
| `cd cli && zig build test` | the CLI's unit tests: configuration, bundles, archives, resources |
| `cd cli && zig build e2e` | `myzig init` makes apps that `zig build` compiles against this checkout |
| `cd plugins/<name> && zig build test` | a plugin's tests |

The test block of `myzig.zig` also analyzes every declaration of every
backend module and every page method (`std.testing.refAllDecls`), so code
no example calls still has to compile on the platform the tests run on.

### Renderers against the CPU

Every GPU renderer is tested against the CPU renderer, offscreen, and
skips where its API is missing: `tests_raster.zig` (Metal), `d3d11_test.zig`,
`gl_test.zig` (EGL surfaceless; Mesa's llvmpipe needs no GPU),
`gpu_fx_test.zig` (transforms, gradients, effects, layers) and
`shader/tests_gpu.zig` (app shaders and their CPU twins). See
[the CPU twin](architecture-rendering.md#the-cpu-twin).

### Browsers

Besides `test-web`, `src/web/test_wasm.mjs` runs the unit tests compiled
for `wasm32-wasi` under Node (`zig test -target wasm32-wasi
--test-no-exec`, then `node src/web/test_wasm.mjs tests.wasm FONT_DIR`),
and `src/web/test_browser_run.mjs` runs a built site in a hidden headless
Chromium (Chrome or Edge) with WebGL. See [browsers](browsers.md).

## Other platforms from one machine

Linux and Windows build from any machine, so tests for them run in
containers:

- **Linux**: `tools/linux.Dockerfile` is Ubuntu 24.04 with GTK 3,
  WebKitGTK 4.1, Mesa (EGL, GLES, llvmpipe), libepoxy, fonts and Xvfb.
  Build on the host, mount it, run under a virtual display:

  ```sh
  zig build test-bin -Dtarget=aarch64-linux-gnu --prefix zig-out/linux
  docker build -t myzig-linux -f tools/linux.Dockerfile tools
  docker run --rm -v "$PWD:/work" myzig-linux xvfb-run -a zig-out/linux/bin/myzig-tests
  ```

  Windows there are realized but never shown (`linux/window_tests.zig`:
  closing asks first, titles, frames, flyouts); `atspi_bus_test.zig` uses
  a real accessibility bus when there is one; `MYZIG_XVFB=1` enables the
  clipboard round trips through the virtual display.
- **Windows**: on Windows itself, `zig build test`. Windows are made but
  never shown, and the messages a user's actions bring are sent to their
  window procedures (`windows/window_tests.zig`); UI Automation is tested
  in process (`uia_test.zig`). From a Mac, `tools/wine.Dockerfile` runs
  arm64 builds (`-Dtarget=aarch64-windows-gnu`) under Wine 10 on Xvfb,
  and `tools/wine-amd64.Dockerfile` x86_64 builds under emulation.

## Benchmarks: the hill climb

Performance work is measured with `hillclimb/`, a terminal app built on
myzig as a library (its own package) that builds, lays out and paints
scenes frame after frame and renders them offscreen, against mygo's own
frames of the same scenes, without a window:

```sh
cd hillclimb
zig build run -- --label "what changed"         # every scene; recorded in history.jsonl
zig build run -- --scene text,list --only myzig --frames 600 --repeat 5
zig build run -- --only myzig --hash            # hashes of the CPU renderer's pixels
```

Scenes: boxes, text, scroll, list, dashboard, layout (cards of wrapping
text mostly as they were: what layout keeps across frames), and the
others in `hillclimb/README.md`. It reports frame CPU (build,
layout, paint), encode CPU, GPU time on macOS (Metal) or render CPU on
Linux and Windows, process CPU per frame and draw items, against mygo, the
previous run and the best one; changes within 5% are noise. A change that
makes the CPU renderer faster must leave `--hash` unchanged. Keep changes
that climb, label runs, and never trade correctness for speed: a fast path
comes with a test proving it matches the slow one (as `shaper.zig` and
`raster_lanes.zig` do). Results of particular machines are kept in
`hillclimb/notes/`.

## Binary size

The counter is about 0.7 MB in `ReleaseSmall` (1.14 MB `ReleaseFast` on
Windows); `myzig build` builds releases `ReleaseSmall` and stripped by
default. What keeps apps small:

- **The linker drops what is not called.** `myzig.App` and `Window` are
  concrete types, bound services and events are dispatched by code
  generated per type, and widgets are plain functions: an app pays for
  the methods and widgets it reaches. Keep features behind the calls that
  use them; do not register them from code every app runs (`App.create`,
  `run`, the default menus).
- **Libraries are loaded, not linked.** WebKitGTK, libepoxy, libsecret,
  appindicator, Security and UserNotifications are opened on first use,
  so an app without pages or secrets carries none of their code paths'
  data.
- **Debug tools are build options.** The native UI inspector compiles to
  nothing unless `-Dinspector=true` (on by default in Debug).
- **Data stays out of common paths.** Large tables (locale data in
  `i18n/data_*.zig`, the code editor's grammars, terminal themes) live in
  the modules that need them.

Measure before and after a change that touches what every app reaches:

```sh
zig build -Doptimize=ReleaseSmall
ls -l zig-out/bin/counter zig-out/bin/hello
```

## Adding a feature

1. **Design it in the shared layer first**: options and types in
   `app_types.zig`, `window_types.zig`, `page_types.zig` or a new file;
   behavior that does not need the OS in platform-free code. Mirror
   mygo's design where it has the feature, in idiomatic Zig.
2. **Implement it in every backend**: macOS (top of `src/`, `*_mac.zig`),
   `src/linux/`, `src/windows/`, and `src/web/` for what browsers can do.
   A platform without it gets the same declaration doing nothing, or
   returning `null`/`false`, so apps compile everywhere.
3. **Export it** from `src/myzig.zig` or `src/ui/ui.zig`.
4. **Keep it out of apps that don't use it** (above).
5. **Test it**: widgets through `ui.Tester` in `src/ui/tests_*.zig`; IPC
   type mappings in `tsgen.zig`; pages in `examples/pages` (run by
   `test-pages`); windows in the backends' `window_tests.zig`; renderers
   against the CPU. Register the test file in the test block of `ui.zig`
   or `myzig.zig`.
6. **Build every platform**: `zig build`, `zig build
   -Dtarget=x86_64-linux-gnu`, `zig build -Dtarget=x86_64-windows-gnu`,
   `zig build web`; run `zig build test` (and `-Dportable=true`), the
   Linux tests in the container, `zig build lines`.
7. **No C**: `extern` declarations, `dlopen`/`dlsym`, COM vtables; no
   `@cImport`, `.c` or `.m` files.
8. **Document it** in `docs/`, and add it to an example when it shows.
9. **Hill-climb** if it touches frames: run `hillclimb` before and after.
