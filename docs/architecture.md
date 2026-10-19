# myzig architecture

This guide describes how myzig is put together: its layers, how it picks a
platform, its threading model, how it calls native code without C, and the
rules every file follows. Read it before changing code. Three companion
pages go deeper:

- [IPC and TypeScript generation](architecture-ipc.md): the wire protocol
  between a page's runtime (`src/bridge.js`) and Zig, the outbox, channels,
  the app's schemes, and the client generated from Zig types.
- [Rendering](architecture-rendering.md): native UI's pipeline (context,
  layout, paint, frame), the renderers (Metal, Direct3D 11, OpenGL,
  WebGL 2 and the CPU), the CPU twin that proves them, text, atlases and
  each platform's surface.
- [Testing, binary size and adding a feature](architecture-testing.md):
  `ui.Tester`, the `--myzig-*` flags, the build's test steps, the Linux
  container and the Wine images, the hill climb, and the checklist for a
  new feature.

## Goals and constraints

- **One Zig program per app.** An app is a single binary (about 0.7 MB for
  the counter in `ReleaseSmall`) with no runtime to install beyond what
  the system has: AppKit and WebKit on macOS, GTK 3 (and WebKitGTK for
  pages) on Linux, Win32 (and the WebView2 Runtime for pages) on Windows,
  a browser for the web target.
- **No C.** No `@cImport`, no `.c` or `.m` files, no shims. Native code is
  declared in Zig (`extern`) or loaded at run time (`dlopen`/`dlsym`,
  `GetProcAddress`), so Linux and Windows build from any machine with
  `-Dtarget=...` (macOS links its frameworks from the SDK).
- **Nothing polls.** Frames are drawn on input, on resize, or while an
  animation runs; replies and events reach pages in one batch per turn of
  the main loop; an idle app uses no CPU.
- **Zig 0.17.** `build.zig.zon` says `minimum_zig_version = "0.17.0"`;
  code uses its APIs (`std.process.Init`, `std.Io`, `std.lang.Type`'s
  `field_names`, `field_types` and `decl_names`).
- **Every file is at most 600 lines**, sources, scripts, shaders and these
  docs alike. `zig build lines` (`tools/lines.zig`) checks it. A file that
  would grow past the limit is split by responsibility first: a widget
  set, a backend concern, a layout pass. The only exception is upstream
  license text kept verbatim in `third_party/licenses/`.

## Layers

From the app down:

1. **The public API**, `src/myzig.zig`. It re-exports what apps use:
   `App`, `Window` and their options, `ui`, `i18n`, `l10n`, `Call`,
   `Event`, `Channel`, `page`, menus, trays, dialogs, the clipboard and
   shell, `system`, `secrets`, `Documents`, `audio`, `transfer`,
   `file_watch`, and so on. It holds no behavior of its own.
2. **Shared, platform-free code.** What every backend does the same way
   lives in files named after the concern, with no OS calls:
   `app_types.zig` and `app_common.zig` (options, handlers, the launch's
   arguments), `window_types.zig` (window and page options, `Asset`,
   events, title bars), `page_types.zig`, `page_core.zig`,
   `page_channel.zig`, `page_serve.zig` and `page_find.zig` (what pages
   share: trust, evaluation, channels, serving schemes, finding),
   `ipc.zig`, `bindings.zig`, `channel.zig` and `tsgen.zig` (typed IPC),
   `menu_types.zig`, `dialog_types.zig`, `tray_types.zig`,
   `documents.zig` and the `document_*.zig` files, `transfer.zig`,
   `window_state.zig`, `paths.zig`, `i18n/`, `l10n/` and `audio/`'s mixer.
3. **Native UI**, `src/ui/`. Views, the box tree, layout, paint and the
   renderers. It knows nothing of windows: a frame is built from a
   `ui.View`, a size, a scale and a theme (`ui/frame.zig`), and the same
   function serves windows and the headless `ui.Tester`.
4. **The platform backends**, which translate the shared types into
   native calls:
   - macOS: files at the top of `src/` (`app.zig`, `window.zig`,
     `page.zig`, `menu.zig`, `tray.zig`, `dialog.zig`, `desktop.zig`,
     `*_mac.zig`) and `ui/surface.zig`, `ui/metal.zig`, `ui/text_mac.zig`,
     `ui/access_mac.zig`.
   - Linux: `src/linux/` (GTK 3, WebKitGTK, D-Bus, AT-SPI, xdg).
   - Windows: `src/windows/` (Win32, COM, WebView2, UI Automation, OLE
     drag and drop, the registry, jump lists).
   - Browsers: `src/web/` (wasm32-wasi; the page's host in `host.js`).
   - `platform.zig` holds the few things below the UI that differ by OS
     (running the loop for a while, the clipboard for the Tester's peers).
5. **Plugins**, `plugins/<name>`: packages of their own (`build.zig.zon`
   depending on myzig) that use only the public API: fetch, websocket,
   sqlite, watch, updater, terminal, glass, game and mainthread. See
   [plugins](plugins.md).
6. **The CLI**, `cli/`: `myzig init`, `dev`, `build`, `generate`, `icon`,
   `doctor`, a program of its own. See [the CLI](cli.md).

New behavior goes into the shared layer first; a backend only does what
must be native. A feature that exists on one platform gets a declaration
on the others too (doing nothing, or returning `null` or `false`), so
apps compile everywhere.

### Choosing the platform

`myzig.zig` picks the backend at compile time from `builtin.os.tag`:

```zig
const plat = switch (builtin.os.tag) {
    .macos => struct {
        pub const app = @import("app.zig");
        pub const window = @import("window.zig");
        // menu, tray, dialog, desktop, fdwatch
    },
    .linux => struct {
        pub const app = @import("linux/app.zig");
        pub const window = @import("linux/window.zig");
        pub const menu = @import("menu_accel.zig");
        // ...
    },
    .windows => struct { pub const app = @import("windows/app.zig"); ... },
    .wasi => struct { pub const app = @import("web/app.zig"); ... },
    else => @compileError("myzig runs on macOS, Linux, Windows and in browsers (wasm32-wasi)"),
};

pub const App = plat.app.App;
pub const Window = plat.window.Window;
```

Each backend's `App` and `Window` therefore have the same public methods
and the same options types (they come from `app_types.zig` and
`window_types.zig`), and `myzig.App` is a concrete type, not an
interface: calls are direct and the linker drops what an app never calls.
Where a backend lacks a part, the public API says so in its type:
`myzig.FlyoutOptions` is `void` where `App` has no `FlyoutOptions`;
`myzig.systemDrag(win)` returns `null` where there is no system drag
source; `myzig.objc` is an empty struct off macOS.

Native UI chooses its text and renderer the same way. `ui/text.zig` sets

```zig
pub const portable = options.portable or builtin.os.tag != .macos;
```

so macOS uses CoreText and Metal, and everything else (and macOS built
with `-Dportable=true`) uses myzig's TrueType reader (`ui/tt/`), the
glyph atlas in memory (`ui/atlas_tt.zig`) and line icons
(`ui/icons.zig`). The build option `inspector` (on in Debug) decides
whether the native UI inspector is compiled in at all.

## Threading model

AppKit, WebKit, GTK, Win32 windows and the native UI all run on **the main
thread**, and so does everything myzig calls on the app's behalf: bound
service methods, event and window callbacks, menu clicks, views. App state
needs no locks as long as other threads hand their results to the main
thread rather than touching it.

What crosses threads:

- `Event.emit(window, payload)` is safe from any thread. It encodes the
  payload where it is called and posts it to the window's thread:
  `objc.dispatchMain` on macOS, `g_idle_add` on Linux, `PostMessageW` to
  the window on Windows (`Window.sendOwned`). `Event.broadcast` and
  `Channel` are main thread only.
- The `mainthread` plugin gives plugins and apps one queue onto the main
  thread from anywhere (`mainthread.post(job, Job.run)`): libdispatch's
  main queue, GLib's default context, or a message-only window. Jobs run
  in order; nothing polls. The fetch, websocket, sqlite and watch plugins
  deliver their threads' results through it.
- Audio output runs on the system's audio thread (AudioQueue, PulseAudio,
  WASAPI); `audio/mixer.zig` is what crosses between it and the app.

Never block the main thread waiting for work that needs it: a bound
method that has to wait (an HTTP response, a child process) returns at
once and answers through an event or a channel later.

Objects a callback may still reach after they are torn down free
themselves when that callback runs: a page with a flush scheduled sets
`dead` and is destroyed by the flush (`page.zig`), and a `Surface` with a
frame in flight does the same.

`myzig.runFor(seconds)` runs the platform's loop for a while
(`CFRunLoopRunInMode`, `g_main_context_iteration`, `PeekMessageW`): headless
tests use it between frames so replies, timers and processes are handled.

## Native interop without C

### macOS: the Objective-C runtime, called directly

`src/objc.zig` declares the runtime's functions (`objc_getClass`,
`sel_registerName`, `objc_msgSend`, `objc_allocateClassPair`,
`class_addMethod`, `class_addIvar`, autorelease pools) as `extern "c"`
and builds on them:

- `objc.msg(R, target, "selector:with:", .{ a, b })` sends a message. The
  exact function type of each call is built at compile time from the
  return type and the argument tuple and `objc_msgSend` is cast to it,
  because arm64 requires calling it with the callee's real signature
  (variadic calls pass arguments in the wrong registers).
- `objc.defineClass(.{ ... })` registers a class at run time whose methods
  are Zig functions: window, application and web view delegates, the
  native view of native UI, the text input client. One pointer ivar ties
  each instance to its Zig object (`objc.setZig`, `objc.getZig`).
- `objc.Block(Ctx, Args)` makes blocks for APIs that take them
  (completion handlers), laid out as the block ABI says.
- `objc.dispatchMain` and `objc.dispatchAfter` call libdispatch
  (`dispatch_async_f`, `dispatch_after_f`) with a context pointer and a
  `callconv(.c)` function.
- `objc.Pool` wraps `objc_autoreleasePoolPush`/`Pop`.

The C frameworks (CoreText, CoreGraphics, CoreFoundation in `ui/cf.zig`,
Metal through `objc.msg`, ImageIO) are `extern` declarations next to the
code that uses them. `build.zig` links the frameworks and `libobjc` for
macOS targets; the macOS SDK is needed to link there, nothing else.
Frameworks only some apps need are opened with `dlopen` when first used,
so they cost the others nothing: Security for the Keychain
(`secrets_mac.zig`), UserNotifications (`notify_mac.zig`).

Memory follows Cocoa's rules: objects from `alloc`/`new` are owned and
must be released (`objc.release`); code that makes temporary objects runs
inside an `objc.Pool`.

### Linux: dlopen

Nothing is linked on Linux but libc. GTK 3 is loaded when the app starts:
`linux/gtk.zig`'s `load()` opens `libgtk-3.so.0` with `std.c.dlopen` and
fills a struct of function pointers by name with `dlsym`; `linux/gtk_more.zig`,
`gtkmenu.zig` and `window_extras.zig` load more of it the same way.
Other libraries come the same way, each only when a feature first needs
it, and each missing one turns its feature off instead of failing the
app:

| library | for |
|---|---|
| `libwebkit2gtk-4.1.so.0` or `-4.0.so.37` | pages (`linux/webkit.zig`) |
| `libepoxy.so.0` | OpenGL for native UI (`ui/gl_api.zig`) |
| `libayatana-appindicator3.so.1` or `libappindicator3.so.1` | trays |
| `libsecret-1.so.0` | secrets |
| `libgio-2.0.so.0` | network status |
| `libX11.so.6` | global hotkeys |

D-Bus (notifications, single instance, the AT-SPI accessibility bus, the
launcher entry) is spoken by myzig itself over the session bus's socket
(`linux/dbus.zig`, `dbus_conn.zig`, `atspi_proto.zig`), not through
libdbus. Callbacks GTK calls are `callconv(.c)` Zig functions passed with
`gtk.connect(instance, "signal", handler, data)`.

Zig's own x86_64 backend miscompiles calls into WebKitGTK's
JavaScriptCore, so `build.zig` builds Linux examples with LLVM
(`.use_llvm = true`).

### Windows: extern and COM

Win32 functions are `extern "user32"`, `"kernel32"`, `"gdi32"` and so on,
`callconv(.winapi)`, declared in `windows/win32.zig` and next to their
users. COM needs no headers either: `windows/com.zig` calls an object's
methods through its vtable by index, parses GUIDs at compile time
(`GUID.parse("...")`), and makes the handler objects WebView2 takes for
its events and completions (IUnknown plus one `Invoke`). Direct3D 11
(`ui/d3d11_api.zig`), UI Automation (`windows/uia*.zig`), OLE drag and
drop (`windows/oledrag.zig`), the Credential Manager, jump lists and the
taskbar are COM or flat APIs declared this way.

WebView2 is found the way `WebView2Loader.dll` finds it, without that DLL:
`windows/webview2.zig` reads the installed runtime's location
(`WEBVIEW2_BROWSER_EXECUTABLE_FOLDER`, else the Stable, Beta, Dev and
Canary channels in the registry), loads its client DLL and creates one
environment for every page, on first use. Without the runtime, pages log
where to download it.

Examples embed `windows/myzig.manifest`, which declares Windows 8 and
later: the caption buttons of hidden title bars are layered child windows,
which need it, and Windows then reports its real version to the app.

### Browsers: WebAssembly imports

Built for `wasm32-wasi`, myzig has no libc: Zig's standard library talks
WASI, which `web/host_wasi.js` answers. What the page does for the app is
a set of functions imported from the module `"myzig"`
(`extern "myzig" fn window_open(...)` in `web/js.zig`), and what the app
does for the page is a set of exports (`web/exports.zig`): the browser's
events for a window, timers and the appearance. Strings cross as a
pointer and a length into the module's memory. See [browsers](browsers.md).

## Conventions that keep this working

- Implement a platform method in every backend: macOS, `linux/`,
  `windows/`, `web/`. `myzig.zig`'s test block calls
  `std.testing.refAllDecls` on each backend's modules and on every page
  method, so a method that compiles on one platform and not another is
  caught by `zig build test` and by building for the other targets.
- Keep the public API concrete and comptime-driven: bound services,
  events and channels are typed at compile time (`tsgen.zig`), handlers
  are `myzig.Handler(T).of(&state, State.method)` pairs of a pointer and
  a function, never interfaces resolved at run time.
- Widgets are made of boxes (`Context.open`/`leaf`), styled from the
  theme and animated with `Context.animate`; one whose interaction
  changes app state sets `c.changed`, so the frame is built again.
- Every behavior gets a test: widgets in `src/ui/tests*.zig` through the
  Tester, IPC type mappings in `tsgen.zig`, renderers against the CPU
  renderer.
- What an app does not use must not grow it: features are reached through
  the functions an app calls, so the linker drops the rest. See
  [binary size](architecture-testing.md#binary-size).
