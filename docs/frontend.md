# The frontend

A page's frontend is HTML, CSS and JavaScript, written by hand or built
with any tool (Vite, esbuild, a framework's own). myzig asks nothing of it
beyond what it serves: the files, and the generated client at
`/myzig.js`. This page is about the frontend's side of a page: the page
runtime, how a frontend gets into the app, dev servers, title bars, and
the inspector. What the app does with a page is in [Pages](pages.md), and
calling Zig in [Bindings](bindings.md).

## The page runtime

Every document of the page's main frame gets the bridge (`src/bridge.js`)
before its own scripts run. It defines `window.myzig`:

| | |
|---|---|
| `myzig.call(method, ...args)` | calls `"Service.method"`; a promise of the result ([Bindings](bindings.md)) |
| `myzig.on(event, fn)` | listens to an event; returns a function that stops listening |
| `myzig.once(event, fn)` | the same, for the next one only |
| `myzig.Channel` | `new myzig.Channel(onmessage?)` makes a channel to pass to a method |
| `myzig.onChannel(kind, fn)` | gets the channels of a kind Zig opens |
| `myzig.log(...values)` | prints `page: ...` to the app's stderr (strings as they are, the rest as JSON) |
| `myzig.window.close()`, `.minimize()`, `.toggleMaximize()`, `.setTitle(title)` | the page's window |
| `myzig.platform` | `"macos"`, `"linux"` or `"windows"` |
| `myzig.version` | myzig's version |

`window.myzig` is frozen and can't be replaced. The generated client
re-exports it (`import { myzig, Channel } from "/myzig.js"`) next to the
services, events and channel kinds of the app, so a module needs nothing
else. `myzig.d.ts` declares all of it.

The bridge also tells the app when the DOM is ready (`dom_ready`, after
which held events arrive), finds text for `Page.findInPage`, settles
`evalResult`'s scripts, and moves frameless windows by their
[drag regions](#title-bars).

Pages of the app can tell which platform they're on, for what differs:
the app's schemes are `myzig://localhost/` on macOS and Linux and
`http://myzig.localhost/` on Windows ([Pages](pages.md#schemes-of-the-app)).
Relative URLs work everywhere and are the simplest.

## A frontend of plain files

The smallest frontend is files embedded in the binary, as
`examples/hello` does:

```zig
const assets = [_]myzig.Asset{
    .{ .path = "/index.html", .data = @embedFile("frontend/index.html") },
    .{ .path = "/main.js", .data = @embedFile("frontend/main.js") },
    .{ .path = "/style.css", .data = @embedFile("frontend/style.css") },
};

_ = try app.newWindow(.{ .title = "Hello", .content = .{ .page = .{ .url = "/", .assets = &assets } } });
```

```html
<script type="module" src="/main.js"></script>
```

```js
import { Greeter } from "/myzig.js";
```

The app serves `/myzig.js` itself, so it is not an asset. Browsers'
module imports, `fetch`, workers and WebAssembly all work against the
app's scheme, which is a secure origin.

## A built frontend

An app made with `myzig init --template web` ([Getting started](getting-started.md))
embeds a whole directory: its `build.zig` imports a module, `assets`,
from `<frontend>/myzig_assets.zig`, which lists every file of the
directory with `@embedFile`, and the app passes `&assets.files`:

```zig
const assets = @import("assets");

// `myzig dev` points the window at the dev server, when there is one.
const url = init.environ_map.get("MYZIG_DEV_URL") orelse "/";
_ = try app.newWindow(.{
    .title = "My App",
    .content = .{ .page = .{ .url = url, .assets = &assets.files } },
});
```

The CLI writes `myzig_assets.zig` whenever the files change (`myzig
generate`, `dev` and `build`), so adding a file to the frontend needs no
Zig. It leaves out the module itself, the generated client, dot files and
`node_modules`.

With a build tool, the app's `myzig.zon` says where the frontend's
sources are, where its build goes, and how to run both:

```zig
.{
    .name = "My App",
    .frontend = "frontend",            // the sources (the client is written here)
    .frontend_dist = "frontend/dist",  // what build.zig embeds (-Dfrontend=...)
    .dev_url = "http://localhost:5173",
    .dev_command = "bun run dev",
    .build_command = "bun run build",
}
```

`myzig build` runs `build_command` first, then embeds `frontend_dist`.
The fields are described in [Configuration](configuration.md).

Single-page apps with client-side routing work as they are: a path
without an extension that is no file (`/settings/profile`) is answered
with `/index.html`. Use absolute paths for assets (`/assets/app.js`), or
the bundler's base of `/`.

## Dev servers

While you work on the frontend, a dev server reloads it as you edit. A
page with a dev server loads the frontend's paths from it: `"/"` is the
server's root and `"/settings"` its `/settings`, while absolute URLs
still load as they are. The dev server comes from:

- the `MYZIG_DEV_URL` environment variable, which `myzig dev` sets from
  `dev_url` after starting `dev_command` and waiting for the server to
  answer;
- else `PageOptions.dev_url`.

The dev server's origin is [trusted](pages.md#trust), so its pages call
bound services as the app's own do. Its modules import the client as
`/myzig.js` too: `myzig dev` writes it into `frontend`, where the server
serves it. With a dev server, `myzig dev` leaves the frontend's files to
it, and rebuilds and restarts the app only when Zig changes
([CLI](cli.md)).

Without a server, `MYZIG_ASSETS_DIR` (or `PageOptions.assets_dir`) serves
a directory of the disk before the embedded assets, so a reload of the
page picks up edited files without building the app again.

## Title bars

A window with `.title_bar = .hidden` lets the page fill the window, under
the system's window controls; one with `.title_bar = .frameless` has no
title bar and no controls at all ([Windows](windows.md)). Either way, the
page draws its own title bar and says which parts of it move the window
with the CSS custom property `--app-region`:

```css
header { --app-region: drag; height: 38px; padding-left: 80px; /* clear of macOS's traffic lights */ }
header button, header input { --app-region: no-drag; }
```

A press of the primary button on an element whose nearest ancestor (or
itself) with `--app-region` says `drag` moves the window, and a double
click zooms it as the title bar would; `no-drag` keeps controls inside a
drag region clickable. Custom properties inherit, so one rule covers a
whole bar.

A frameless window's own buttons call the runtime:

```html
<button onclick="myzig.window.minimize()">–</button>
<button onclick="myzig.window.toggleMaximize()">□</button>
<button onclick="myzig.window.close()">×</button>
```

`myzig.window.setTitle(title)` sets the window's title (what the Dock, the
taskbar and window switchers show), and so does the document's `<title>`
through the `title_changed` event when the app listens to it.

## Appearance

Webviews follow the system's light or dark appearance: declare
`color-scheme: light dark` and use `prefers-color-scheme` media queries,
and the page changes with the system. The app can read it with
`myzig.isDark()` and the accent color with `myzig.accentColor()`
([System](system.md)), and pass them on in an event.

## Links and new windows

`window.open` and links with `target="_blank"` reach the app as the
`new_window` page event. Unless a listener handles it, `http` and `https`
URLs open in the system's browser, which is what most apps want for
external links. A listener can open a window of its own instead, or
cancel navigations of the page itself with `will_navigate`
([Pages](pages.md#page-events)).

## Scripts of the app

`PageOptions.user_scripts` and `Page.addUserScript` add scripts every
document runs, after the bridge and before the document's own scripts (or
once its DOM is ready, with `at_document_end`): for styles injected into a
remote page, or globals the frontend expects.

## The web inspector

Pages are inspectable unless `PageOptions.inspectable` is false: right
click > Inspect Element opens the engine's inspector (Web Inspector on
macOS, WebKit's on Linux, Edge DevTools on Windows), and
`page.openDevTools()` opens it from Zig. On macOS that goes through a
private API of WebKit's, which may go away. Turn it off in releases that
shouldn't have it.

`console.log` goes to the inspector; `myzig.log` goes to the app's
stderr, where tests read it.

## Testing the frontend

Run the app with `--myzig-eval=JS`: each page evaluates `JS` once its DOM
is ready, without a window on the screen, and the run ends when the page
calls `myzig.window.close()`.

```sh
zig-out/bin/hello --myzig-eval='import("/myzig.js").then(async ({ Greeter }) => { myzig.log(await Greeter.greet("Ada")); myzig.window.close() })'
```

`zig build test-pages` runs `examples/hello` this way and
`examples/pages` with `--myzig-hidden`, each checking for `page: ok` in
stderr ([Pages](pages.md#testing-pages)).
