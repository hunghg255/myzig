# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

myzig is a desktop app framework in Zig 0.17.0, a port of
[mygo](https://github.com/egoist/mygo). A window shows either a web page in
the system webview (WKWebView, WebKitGTK, WebView2) with typed Zig ↔
TypeScript IPC, or native UI that myzig draws itself (`src/ui/`).

**[AGENTS.md](AGENTS.md) holds the hard rules, the source layout and the
full command list; read it first.** Read
[docs/architecture.md](docs/architecture.md) (and its `-ipc`, `-rendering`
and `-testing` pages) before changing code. The rules that most often bite:

- Every file is at most 600 lines (`zig build lines`): split by
  responsibility before growing a file.
- Zig 0.17.0 APIs only (`std.process.Init`, `std.Io`, `@Fn`,
  `std.lang.Type`'s `field_names`/`field_types`/`decl_names`), not older
  idioms.
- No C: no `@cImport`, no `.c`/`.m`. Native code is `extern` declarations,
  `dlopen`/`dlsym` (Linux), `GetProcAddress`/COM vtables (Windows), the
  Objective-C runtime through `src/objc.zig` (macOS).
- Never show windows, take focus, synthesize input or capture the screen.
  Check apps headlessly (`--myzig-snapshot`, `--myzig-script`,
  `--myzig-eval`) and views with `ui.Tester`. Tests never touch the
  system clipboard or files outside temporary directories.
- A feature exists in every backend (macOS, `linux/`, `windows/`, `web/`);
  where a platform can't, the same declaration does nothing or returns
  `null`/`error.Unsupported`.
- Apps pay only for what they use: measure `counter` and `hello` with
  `-Doptimize=ReleaseSmall` before and after a core change.
- Never build with `-fno-llvm`/`-fno-lld`; one heavy build at a time.

## Commands

```sh
zig build                     # every example into zig-out/bin
zig build test                # unit and widget tests (offscreen)
zig build test -Dportable=true   # same, with myzig's own text and CPU renderer (the non-macOS path)
zig build lines               # the 600-line check
zig build web && zig build test-web    # native UI for browsers, tested headless under Node
zig build test-pages          # pages through the real webview, hidden
zig build -Dtarget=x86_64-linux-gnu    # Linux and Windows build from any machine
zig build -Dtarget=x86_64-windows-gnu
cd cli && zig build test      # the CLI (its own package); `zig build e2e` for apps made by `myzig init`
cd plugins/<name> && zig build test    # each plugin is its own package
cd hillclimb && zig build run -Doptimize=ReleaseFast -- --label "change"   # benchmarks against mygo
cd docs && npm install && npm run dev  # the VitePress docs site; `npm run build` fails on dead links
```

`zig build test` has no filter option. To run one test, compile the module
directly with `--test-filter` (a `build_options` module must be supplied;
write one with `pub const portable: bool = false; pub const inspector: bool = false;`):

```sh
zig test -lc --dep build_options -Mroot=src/myzig.zig -Mbuild_options=/path/to/bo.zig \
  --test-filter "part of the test name"
```

On macOS also pass `-lobjc` and `-framework <name>` for each entry of
`frameworks` at the top of `build.zig`.

Headless checks of a built app (no window is shown):

```sh
zig-out/bin/gallery --myzig-snapshot=/tmp/g.png --myzig-script="click:Tasks;type:Hi;key:enter"
zig-out/bin/hello --myzig-eval='myzig.call("Greeter.greet","Ada").then(v=>{myzig.log(v);myzig.window.close()})'
```

Linux tests run in the container: `zig build test-bin
-Dtarget=x86_64-linux-gnu --prefix zig-out/x86_64-linux-gnu`, then run
`zig-out/x86_64-linux-gnu/bin/myzig-tests` under `xvfb-run -a` in the
image built from `tools/linux.Dockerfile`, with the repository mounted at
`/work`. macOS cannot be linked from another OS (it needs the SDK); there,
`zig build-obj -target aarch64-macos` still type-checks.

## Architecture

- **One API, the backend chosen at compile time.** `src/myzig.zig`
  switches on `builtin.os.tag` to the macOS files at the top of `src/`,
  `src/linux/`, `src/windows/` or `src/web/` (wasm32-wasi). Every
  backend's `App`/`Window` take the same option types from
  `app_types.zig`/`window_types.zig`, so `myzig.App` is a concrete type and
  the linker drops what an app never calls. Shared behavior lives in
  platform-free files (`page_core.zig`, `ipc.zig`, `documents.zig`, ...);
  backends only translate to native calls.
- **Threading.** The event loop, webviews, bound methods and the UI run on
  the main thread. Other threads reach it through the platform's queue
  (`Event.emit` is safe from any thread, the `mainthread` plugin); never
  block the main thread on work that needs it. Nothing polls: frames are
  drawn on input, resize or a running animation.
- **IPC.** Bound Zig structs (`app.bind`) get a JavaScript client and
  TypeScript declarations generated at comptime (`src/tsgen.zig`); the page
  runtime is `src/bridge.js` (`window.myzig`). Replies and events reach a
  page in one batch per main-loop turn (the outbox). Keep
  `examples/hello/frontend/myzig.d.ts` current with `zig build gen`.
- **Native UI pipeline.** A view is a function of app state run every
  event (immediate mode); widgets answer from the previous frame's layout,
  and a widget that changes state sets `c.changed` so the frame is built
  again. Context (box tree) → `layout.zig` → `paint.zig` → instances
  (`gpu.zig`) → one renderer: Metal (macOS), Direct3D 11 (Windows), OpenGL
  (Linux), WebGL 2 (browsers), or the CPU (`raster*.zig`). `ui/frame.zig`
  builds a frame for both windows and `ui.Tester`. Only damaged regions are
  redrawn (`damage.zig`).
- **The CPU renderer is the twin.** Every GPU shader computes per pixel
  what `raster.zig` computes, and tests compare them (`gpu_fx_test.zig`,
  `d3d11_test.zig`, `gl_test.zig`). Off macOS, text is myzig's own TrueType
  reader (`ui/tt/`) and the Tester renders on the CPU. CPU fast paths must
  give exactly the general path's pixels.
- **Performance work is hill-climbed.** Run `hillclimb` before and after,
  keep changes that climb, label the run (it appends to
  `hillclimb/history.jsonl`; results worth keeping go in
  `hillclimb/notes/`). A renderer change must leave `--hash` output
  unchanged for the same `--frames`, both with and without `--whole`.
  `hillclimb/.mygo` is a clone of mygo used as the comparison twin.

## Conventions

- Every widget behavior gets a test (`src/ui/tests*.zig`, registered in
  `ui.zig`'s test block); new IPC type mappings get one in `src/tsgen.zig`;
  page behavior gets a check in `examples/pages`.
- Keep `docs/` current with the API; a new page also gets a place in the
  sidebar in `docs/.vitepress/config.mts`. Pages stay plain Markdown that
  reads the same on GitHub; links out of `docs/` become repository links
  on the site. Node is only for the docs site.
- Version `0.1.x` is set in `build.zig.zon`, `src/myzig.zig`,
  `src/bridge.js`, `cli/build.zig(.zon)` and every `plugins/*/build.zig.zon`;
  apps made by the CLI default to their own `0.1.0`.
- `THIRD_PARTY_NOTICES.md` records which mygo commit the port is current
  with; update it when porting more of mygo.
