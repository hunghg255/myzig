# AGENTS.md

myzig is a desktop application framework in Zig 0.17, after
[mygo](https://github.com/egoist/mygo). Windows show either a web page in the
system webview (WKWebView on macOS, WebKitGTK on Linux, WebView2 on Windows)
with typed Zig ↔ TypeScript IPC, or native UI that myzig draws itself, in the
manner of GPUI: with Metal and CoreText on macOS; on Linux (GTK 3, loaded
with dlopen) with OpenGL, on Windows (Win32) with Direct3D 11, and in
browsers (`wasm32-wasi`, `src/web/`) with WebGL 2, all three with myzig's
own TrueType text (`src/ui/tt/`). The CPU renderer (`src/ui/raster.zig`) is
the fallback everywhere and the twin every GPU renderer is tested against.
Linux and Windows build from any machine (`-Dtarget=...`); macOS links its
frameworks from the SDK.

**Read [docs/architecture.md](docs/architecture.md) before changing code**
(and its pages on IPC, rendering and testing). The user documentation is in
[docs/](docs/README.md); keep it current with the API you change.

## Hard rules

- **Every file is at most 600 lines.** Source, scripts, shaders, docs: no
  exceptions. When a file would grow past 600 lines, split it by
  responsibility (a widget set, a backend concern, a layout pass) before
  adding to it. `zig build lines` checks it and must pass. The one
  exception: upstream license texts kept verbatim in `third_party/licenses/`,
  which must not be split or edited.
- **Zig 0.17.0.** Use its APIs (`std.process.Init`, `std.Io`, `@Fn`,
  `std.lang.Type`'s `field_names`/`field_types`/`decl_names`), not older idioms.
- **No C shims.** Native code is called directly: the Objective-C runtime
  through `src/objc.zig` (`objc.msg` builds each `objc_msgSend` prototype at
  comptime), C frameworks (CoreText, CoreGraphics, Metal, ImageIO,
  libdispatch) and Win32 through `extern` declarations, COM (Direct3D 11,
  WebView2, UI Automation, OLE) through vtables (`src/windows/com.zig`),
  GTK, WebKitGTK, libepoxy and the other Linux libraries through
  `dlopen`/`dlsym` (`src/linux/gtk.zig`, `webkit.zig`), browsers through
  WebAssembly imports (`src/web/js.zig`). No `@cImport`, no `.c`/`.m`.
- **Every platform keeps building.** After a change, build for Linux and
  Windows too (`zig build -Dtarget=aarch64-linux-gnu --prefix zig-out/linux`,
  `-Dtarget=x86_64-windows-gnu`) and for browsers (`zig build web`), and run
  the Linux tests in the container (`tools/linux.Dockerfile`, `zig build
  test-bin`). A feature is implemented in every backend (macOS, `linux/`,
  `windows/`, `web/`); where a platform can't, the same declaration does
  nothing or returns `null`/`error.Unsupported`, so apps compile everywhere.
- **Never show windows on the developer's screen** while working: no
  running examples or benchmark apps windowed, nothing that activates an
  app or takes focus (nanoterm may be shown when asked). Live apps are
  checked headlessly with `--myzig-snapshot` and `--myzig-wait`. Measure with the headless hill-climb app
  (`hillclimb/`), verify with `ui.Tester` and the `--myzig-*` flags.
- **Never drive the real screen.** No synthetic mouse or keyboard events
  (CGEventPost, AppleScript clicks), no full-screen captures: the user's
  other windows are theirs. Test native UI with `ui.Tester` (in process,
  rendered offscreen), apps with `--myzig-snapshot`/`--myzig-script`, and
  pages with `--myzig-eval`, all of which keep windows hidden. Tests never
  touch the user's state either: no system clipboard (the Tester has its
  own), no files outside temporary directories, no defaults.
- **Threading.** The event loop, the webviews, bound methods and the UI
  run on the main thread. Work from other threads reaches it through the
  platform's queue (`objc.dispatchMain` on macOS, the `mainthread` plugin
  everywhere, `Event.emit`, which is safe from any thread); never block the main
  thread waiting on work that needs it.
- **Nothing polls.** Frames are drawn on input, resize, or while an
  animation runs; an idle app uses no CPU.
- **Apps pay only for what they use.** A feature an app doesn't call must
  not grow it: keep heavy code behind functions only that feature reaches,
  and opt-in libraries in `plugins/`. Measure the counter and hello before
  and after a change to the core (`-Doptimize=ReleaseSmall`).
- **Objective-C memory:** `alloc`/`new` objects are owned and must be
  released; wrap code that makes temporary objects in `objc.Pool`. Objects
  a callback may still reach after teardown (a scheduled flush or frame)
  free themselves when it runs (`dead` flags in `Page` and `Surface`).
- **Heavy builds:** never build with Zig's self-hosted backend
  (`-fno-llvm`/`-fno-lld`); one heavy build at a time.

## Layout

```
src/myzig.zig         the public API; picks the platform's files at compile time
src/platform.zig      what differs by OS below the UI (event loop, clipboard, runFor)
src/objc.zig          Objective-C runtime, runtime classes, blocks, libdispatch
src/app.zig           macOS: lifecycle, menu bar, trays, services (app_extras_mac.zig)
src/app_types.zig, app_common.zig, launch.zig  options, handlers, launches, shared by every backend
src/window.zig        macOS: NSWindow showing a page or native UI (window_extras_mac, window_mac_events)
src/window_types.zig, window_state.zig, titlebar.zig, flyout.zig  window options and events, remembered frames, title bar drags, flyouts
src/dev.zig           --myzig-* flags: generate, snapshot, script, eval, wait, dark, hidden
src/page.zig          macOS: WKWebView (page_mac_delegate, page_mac_extra)
src/page_types.zig, page_core.zig, page_serve.zig, page_channel.zig, page_find.zig  pages on every platform: options, trust, schemes, channels, find
src/ipc.zig, bindings.zig, channel.zig  bound services, calls, typed events, channels
src/tsgen.zig         comptime TypeScript declarations and JS client
src/bridge.js         the page runtime (window.myzig)
src/menu.zig, menu_types.zig, menu_accel.zig  menus from templates; as accelerators off macOS
src/tray.zig, tray_types.zig, tray_none.zig   status bar icons
src/dialog.zig, dialog_types.zig  open/save panels, message boxes
src/desktop.zig       clipboard, shell (open, reveal, trash), paths, appearance
src/hotkeys.zig, hotkey_mac.zig    global shortcuts
src/notify_mac.zig, network*.zig, signal_unix.zig, instance_unix.zig  notifications, network status, signals, single instance
src/system*.zig, recent.zig, paths.zig, secrets*.zig  locale, recents, login items, schemes, power; app directories; secrets
src/document*.zig, documents.zig   document-based apps: windows, saving, autosave, recovery, the File menu
src/file_watch*.zig, fdwatch.zig   files changed by other apps, descriptors in the event loop
src/transfer.zig      typed drag and clipboard data
src/audio/            WAV, players, the mixer; output through AudioQueue, PulseAudio, WASAPI
src/i18n/             catalogs, ICU messages, plurals, numbers, dates, CLDR data; gen/ writes the data
src/l10n/             myzig's own strings and their translations
src/linux/            GTK 3 backend: app, window, surface, pages (WebKitGTK), menus, trays,
                      dialogs, D-Bus (notifications, secrets, AT-SPI), hotkeys, network
src/windows/          Win32 backend: app, window, caption, surface, pages (WebView2), menu bar,
                      trays, dialogs, jump lists, taskbar, OLE drag, UI Automation, registry
src/web/              browsers (wasm32-wasi): app, window, surface, input, host.js/host_gl.js,
                      build.zig (web.addSite), site.zig, the Node and browser tests
src/ui/ui.zig         native UI's public API and View
src/ui/context.zig    per-frame box tree, ids, input, hit testing, animation (context_events.zig)
src/ui/input.zig, keys.zig  keys, shortcuts, text operations, one event's input
src/ui/layout.zig, grid_layout.zig  flexbox (measure, arrange, grow, shrink, absolute, scroll) and grids
src/ui/paint.zig      tree → GPU instances, clipping, culling, scrollbars (paint_xf, paint_motion)
src/ui/frame.zig      one frame, shared by windows and the Tester; frame stats
src/ui/gpu.zig        the instances every renderer draws
src/ui/widgets.zig, div.zig  boxes, text, icons, buttons, toggles, sliders; ui.div(c).row().gap(8)…
src/ui/controls_*.zig choices, ranges, fields, dates, times, colors, forms
src/ui/overlay_base.zig, popover, dialog, toast, menu, select, combobox, listbox  overlays
src/ui/tabs, collapsible, split, sidebar, toolbar, breadcrumbs, structure  structures
src/ui/list, tree, outline, table, gridview, grid  lists, tables, grid views, the grid layout
src/ui/router*.zig, actions.zig, focusgroup.zig, handle.zig  navigation, actions, focus
src/ui/textfield.zig, textinput.zig  the text field; NSTextInputClient (IME, key bindings)
src/ui/textarea*.zig, textdoc.zig, rope.zig  multi-line text on a rope
src/ui/editor/        the code editor: syntax, indentation, find bar, regex
src/ui/diff*.zig      diffs and the diff viewer
src/ui/richtext/      the rich text editor: model, layout, commands, history, Markdown in and out
src/ui/markdown/      CommonMark and GFM: parser, streaming, the view, highlighting
src/ui/canvas*.zig, path*.zig, svg*.zig, chart/  drawing: paths, paints, SVG, charts
src/ui/motion*.zig, transform.zig, gradient.zig, effect.zig, backdrop.zig  motion, transforms, effects
src/ui/shader/        ZSL: shaders apps write once, compiled for every renderer and the CPU
src/ui/access*.zig    what assistive technology reads (mac, AT-SPI and UIA are in the backends)
src/ui/direction.zig  right to left
src/ui/inspector*.zig the inspector (F12, -Dinspector)
src/ui/theme.zig, themes.zig, preferences*.zig, oklch.zig  themes, the desktop's preferences, colors
src/ui/dragdrop.zig   drag and drop within a window, and out of it
src/ui/text.zig       fonts, shaping, cached layouts, wrapping (text_mac.zig: CoreText)
src/ui/shaper.zig     the exact fast path for printable ASCII
src/ui/text_tt.zig, rich_tt.zig, tt/  text myzig shapes itself: TrueType files, installed fonts, outlines
src/ui/atlas.zig, atlas_tt.zig, icons.zig  the glyph atlases; line icons off macOS
src/ui/metal.zig, shader.metal, metal_fx.*  Metal renderer (macOS)
src/ui/d3d11*.zig, d3d11*.hlsl, d3d11.cso  Direct3D 11 renderer (Windows); d3d11_gen.zig compiles the shader
src/ui/gl*.zig, gl*.glsl                   OpenGL renderer (Linux, GtkGLArea; gl_offscreen for tests)
src/ui/webgl*.zig                          WebGL 2 renderer (browsers)
src/ui/raster*.zig    the CPU renderer and twin of the others, in bands on cores
src/ui/gpu_fx_test.zig, *_test.zig  every renderer against the CPU
src/ui/surface.zig    macOS: the NSView: events, display link, occlusion, resize
src/ui/images.zig, png.zig, png_decode.zig  pictures in a BGRA atlas; PNG out and in
src/ui/tester.zig     views without a window: input, time, PNG snapshots
src/ui/tests*.zig     widget tests through the Tester
cli/                  the myzig CLI (its own package): init, dev, build, generate, icon, doctor
plugins/              official plugins, each its own package with tests and an example:
                      fetch, websocket, sqlite, watch, updater, terminal, glass, game, mainthread
examples/             hello, todo, pages, native (pages); counter, gallery and the rest (native UI)
docs/                 the user documentation (docs/README.md) and the architecture guide; a VitePress site (docs/.vitepress)
hillclimb/            headless benchmarks against mygo (its own package); notes/ keeps results
apps/nanoterm/        the first app: a Warp-like terminal with ACP agents
apps/nanomon/         a small activity monitor (libproc, Mach, /proc)
tools/*.Dockerfile    Linux (GTK, WebKitGTK, Xvfb) and Windows (Wine) test images
tools/lines.zig       the 600-line check
tools/inputlatency/   input-to-screen latency of native UI (its own package; shows a window: people run it)
```

## Commands

```sh
zig build                 # build every example into zig-out/bin
zig build test            # unit and widget tests (offscreen, the platform's renderer and the CPU)
zig build test -Dportable=true   # the same with myzig's own text and CPU renderer
zig build test-pages      # pages hidden: hello calling Zig, and examples/pages (schemes, channels, ...)
zig build web             # counter and gallery for browsers, in zig-out/web/<name>
zig build test-web        # those, headless under Node
zig build test-bin -Dtarget=aarch64-linux-gnu --prefix zig-out/linux   # Linux tests, run in the container
zig build lines           # enforce the 600-line limit
zig build run-hello       # webview + typed IPC
zig build run-counter     # native UI
zig build run-gallery     # native UI widgets
zig build gen             # write examples/hello/frontend/myzig.{js,d.ts}
cd cli && zig build test  # the CLI's unit tests
cd cli && zig build e2e   # apps made by `myzig init`, built against this checkout
cd plugins/<name> && zig build test   # a plugin's tests (and `check` for any -Dtarget, `run` its example)
cd examples/farm && zig build run     # the game plugin's example
cd hillclimb && zig build run -- --label "change"   # climb: compare with mygo and history
cd docs && npm install && npm run dev   # the documentation site, live (npm run build checks every link)
cd tools/inputlatency && zig build test   # its statistics and plans; `zig build run` measures (shows a window, synthesizes input into it: a person runs it, never an agent)
cd apps/nanomon && zig build test --fork=../..     # an app (a submodule) against this myzig, not its pinned one

# Headless checks of the real apps (no window is shown):
zig-out/bin/gallery --myzig-snapshot=/tmp/g.png --myzig-script="click:Tasks;type:Hi;key:enter"
zig-out/bin/hello --myzig-eval='myzig.call("Greeter.greet","Ada").then(v=>{myzig.log(v);myzig.window.close()})'
```

## Conventions

- New widgets are made of boxes (`Context.open`/`leaf`) styled from the
  theme and animated with `Context.animate`; a widget whose interaction
  changes app state sets `c.changed` so the frame is built again.
- Interactions read the previous frame's layout; keep ids stable with
  `ui.key` for list items.
- Every widget behavior gets a test (`src/ui/tests*.zig`, registered in
  `ui.zig`'s test block); every new IPC type mapping gets one in
  `src/tsgen.zig`; page behavior gets a check in `examples/pages`
  (`zig build test-pages`).
- Keep `examples/hello/frontend/myzig.d.ts` current (`zig build gen`).
- Renderers are twins: a GPU shader computes what `raster.zig` computes,
  and a test compares them (`gpu_fx_test.zig`, `d3d11_test.zig`,
  `gl_test.zig`).
- Keep `docs/` current: a new API gets its page (or a section of one),
  with code that compiles against it, and a place in the site's sidebar
  (`docs/.vitepress/config.mts`). Pages stay plain Markdown that reads the
  same on GitHub; links out of `docs/` become links to the repository.
  Node is only for building the site: nothing in myzig or its apps needs it.
- Performance work is hill-climbed: run `hillclimb` before and after, keep
  changes that climb, label runs. Never trade correctness for speed: fast
  paths come with tests proving they match the slow path (`shaper.zig`).
