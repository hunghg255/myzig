# Plugins

A plugin is a Zig package that adds a feature myzig's core leaves out, so
that apps which don't use it don't grow. Plugins for pages come in two
halves, as mygo's do: a Zig service the app binds, and a JavaScript module
(served by the app, never fetched from npm) whose functions call it. Plugins
for native UI are Zig alone.

Every official plugin lives in `plugins/<name>` of the myzig repository, a
package of its own with a `build.zig`, a `build.zig.zon` (depending on
myzig, and on `mainthread` when it works off the main thread), its sources
in `src/`, an `example/` app and its tests.

## Official plugins

- [fetch](plugins/fetch.md): a `fetch` for pages whose requests Zig makes,
  with no CORS, any header, streamed bodies and cancelation; and
  `fetch.perform` from Zig.
- [websocket](plugins/websocket.md): a `WebSocket` for pages whose
  connections Zig makes, with headers on the handshake; and `Conn`, an
  RFC 6455 client in Zig.
- [sqlite](plugins/sqlite.md): SQLite from Zig and from pages, with the
  system's library loaded at run time.
- [watch](plugins/watch.md): changes to files, in the roots the app names,
  from Zig and from pages.
- [updater](plugins/updater.md): checks a manifest, downloads the new
  executable verifying its SHA-256 and puts it in place; a service for an
  update banner in a page.
- [terminal](plugins/terminal.md): a terminal view for native UI, running
  the shell in a pseudo-terminal with Ghostty's emulator, libghostty-vt,
  loaded at run time.
- [glass](plugins/glass.md): Liquid Glass panes and backdrop blurs for
  native UI, drawn by every renderer with a CPU twin.
- [game](plugins/game.md): a game loop in fixed steps, a camera, and
  gamepads, for native UI.
- [mainthread](plugins/mainthread.md): work handed to the main thread from
  any other; the other plugins build on it.

| plugin | modules | pages | native UI | Zig only |
|---|---|:-:|:-:|:-:|
| fetch | `fetch` | yes | | `fetch.perform` |
| websocket | `websocket` | yes | | `Conn` |
| sqlite | `sqlite` | yes | | `Db` |
| watch | `watch` | yes | | `Watcher` |
| updater | `updater` | yes | | `Updater` |
| terminal | `terminal` | | yes | |
| glass | `glass` | | yes | |
| game | `game`, `gamepad` | | yes | `gamepad` |
| mainthread | `mainthread` | | | yes |

## Using a plugin

A plugin is a dependency of the app's package. Add it next to myzig in
`build.zig.zon`, as a path into a checkout of myzig (the plugins depend on
the myzig two directories up, `../..`, so the app and the plugin share one
myzig):

```zig
.dependencies = .{
    .myzig = .{ .path = "../myzig" },
    .myzig_fetch = .{ .path = "../myzig/plugins/fetch" },
},
```

and give its module to the app in `build.zig`, as `examples/farm` does with
the game plugin:

```zig
const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize }).module("myzig");
const fetch = b.dependency("myzig_fetch", .{ .target = target, .optimize = optimize }).module("fetch");
const root = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "myzig", .module = myzig },
        .{ .name = "fetch", .module = fetch },
    },
});
```

Pass the same `target` and `optimize` to both dependencies: Zig then builds
one myzig for the app and the plugin.

### Plugins for pages

The Zig half is a service: initialize it on the main thread, bind it, and
register the event its results come back as. The JavaScript half is an
`Asset` the plugin exports (`fetch.asset` is served at
`/plugins/fetch.js`): add it to the page's assets.

```zig
const std = @import("std");
const myzig = @import("myzig");
const fetch = @import("fetch");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const app = try myzig.App.create(init, .{ .name = "Feeds" });
    defer app.destroy();

    var service: fetch.Service = try .init(gpa, app.io, .{});
    defer service.deinit();
    try app.bind(&service);
    try app.registerEvent(fetch.PartEvent);

    const index: myzig.Asset = .{ .path = "/index.html", .data = @embedFile("index.html") };
    _ = try app.newWindow(.{ .title = "Feeds", .content = .{ .page = .{ .url = "/", .assets = &.{ index, fetch.asset } } } });
    try app.run();
}
```

```js
import { fetch } from "/plugins/fetch.js";

const res = await fetch("https://api.example.com/me", { headers: { authorization: `Bearer ${token}` } });
```

Each service has `Options`, such as an `allow` function that decides which
requests, connections or watches pages may make; each plugin's page lists
them.

### Plugins for native UI

They are functions of views, as myzig's own widgets are:

```zig
const glass = @import("glass");

fn view(s: *State, c: *ui.Context) void {
    // ... the content ...
    _ = glass.pane(c, .{ .radius = 16 }, .{ .padding = .all(12) });
    ui.text(c, "On glass", .{});
    c.end();
}
```

## Building and testing a plugin

Every plugin's package has the same steps:

```sh
cd plugins/fetch
zig build test                              # its tests; pages' tests run the example hidden
zig build test -Dpage=false                 # plugins for pages: without the page (no webview)
zig build test-page                         # plugins for pages: the example's page alone, hidden
zig build check -Dtarget=x86_64-linux-gnu   # compile the tests for another platform without running them
zig build run                               # the example, in a window
zig build test -Dtest-filter=redirect       # only the tests whose names contain this
```

The page tests run the example with `--myzig-eval`, which keeps its window
hidden, and pass when the page logs `ok` (`page: ok`).

## Writing a plugin

A plugin is a Zig package like the official ones. For pages, its parts are:

- **A service**: a struct whose public methods pages call, bound with
  `app.bind`. `myzig_name` names it to pages (otherwise its type's name),
  `myzig_params` names each method's parameters for the generated client,
  and methods that take a `*myzig.Call` learn which window called
  (`call.window`) and get an arena for their result (`call.arena`). See
  [Bindings](bindings.md).
- **An event** for what comes back later: `myzig.Event("myzig-<name>",
  Payload)`, sent to one window with `Event.emit(window, payload)` or to
  all with `Event.broadcast(app, payload)`. The app registers it with
  `app.registerEvent`.
- **The JavaScript module**, embedded with `@embedFile` and exported as an
  `Asset` under `/plugins/<name>.js`. It calls the service with
  `myzig.call("Name.method", ...)` and listens with `myzig.on("myzig-<name>",
  ...)` (the page runtime, `window.myzig`; see [Frontend](frontend.md)).

```zig
//! A counter for pages: `bump()`, and the new count sent to every window.
const myzig = @import("myzig");

pub const CountEvent = myzig.Event("myzig-counter", struct { n: u64 });
pub const asset: myzig.Asset = .{ .path = "/plugins/counter.js", .data = @embedFile("js/counter.js") };

pub const Service = struct {
    pub const myzig_name = "Counter";
    app: *myzig.App,
    n: u64 = 0,

    pub fn bump(s: *Service) u64 {
        s.n += 1;
        CountEvent.broadcast(s.app, .{ .n = s.n });
        return s.n;
    }
};
```

```js
// js/counter.js
export const bump = () => myzig.call("Counter.bump");
export const onCount = (f) => myzig.on("myzig-counter", f);
```

Rules the official plugins keep, and yours should too:

- **Bound methods run on the main thread.** Work that blocks (the network,
  files, a long query) runs on a task of the app's `Io` (`io.concurrent`)
  or a thread, and hands its result to the main thread with
  [`mainthread.post`](plugins/mainthread.md); only there may it emit
  events or touch windows. Check that the window is still open before
  emitting (`app.windows`), and drop the work of windows that closed.
- **Backpressure.** Streams wait while the page has more than a window of
  bytes unread (the page acknowledges what it read, `ack`), so a fast
  source never piles up in the page.
- **Pages name things, never paths.** File names in the app's data
  directory (sqlite), roots the app named (watch): a page can't reach
  further than the app allowed.
- **Native libraries are loaded, not linked**, with `std.DynLib` or the
  platform's loader, and checked (sqlite tries the system's library;
  terminal checks the SHA-256 of what it downloads and the layouts of the
  structs it passes). No `@cImport`, no C files.
- **Nothing polls**, and tests never wait on wall-clock time: they wait for
  the event they expect, or advance a `ui.Tester`'s clock.
- **At most 600 lines a file**, as everywhere in myzig.

## Not yet

mygo's plugins are registered with `mygo.Use`, which installs their
services and scripts at once, and their JavaScript halves are npm packages.
myzig has neither: an app binds a plugin's service and adds its asset
itself, and the CLI does not yet put plugins' native libraries into apps
(the terminal plugin downloads them into the user's cache, or finds them
next to the executable).
