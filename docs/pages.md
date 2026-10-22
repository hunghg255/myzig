# Pages

A window can show a web page instead of native UI. The page runs in the
webview of the operating system, not in a bundled browser:

| | macOS | Linux | Windows |
|---|---|---|---|
| engine | WKWebView | WebKitGTK (`libwebkit2gtk-4.1`, else `4.0`, loaded with `dlopen`) | WebView2 (the Microsoft Edge WebView2 Runtime) |
| the app's frontend | `myzig://localhost/` | `myzig://localhost/` | `http://myzig.localhost/` |
| web inspector | Web Inspector | WebKit's inspector | Edge DevTools |

Nothing is linked: WebKitGTK is loaded when the first page opens (an app
whose windows only show native UI never loads it), and WebView2 is found
the way `WebView2Loader.dll` finds it (a fixed version named by
`WEBVIEW2_BROWSER_EXECUTABLE_FOLDER`, else the installed channels, the most
stable first). A Linux machine without WebKitGTK logs that pages need it.

On Windows, pages whose host is hidden or minimized, and embedded pages
clipped out of native UI, request WebView2's low memory target after the
document loads. Showing or restoring them requests the normal target.
JavaScript, timers, IPC and network connections keep running; the page is
not suspended or reloaded. This is a best-effort reduction in resident
memory, not a memory limit. Older runtimes without the API keep their
normal memory target. See Microsoft's [memory usage target documentation](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2_19).

Primary page windows additionally disable controller rendering while their
host is hidden or minimized, and restore it when shown. JavaScript and IPC
continue, but the browser can throttle background timers and animations;
timer cadence while hidden is not guaranteed. Embedded web views retain
their layout-driven controller visibility. See Microsoft's
[controller visibility documentation](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2controller#get_isvisible).

Headless runs (`--myzig-hidden` and the flags that imply it) use a
temporary WebView2 profile. Regular launches keep
using `%LOCALAPPDATA%\<app name>\WebView2`.

This page covers what a page is and what the app can do with it. The
frontend's side (the page runtime, dev servers, title bars) is in
[The frontend](frontend.md), and calling Zig from the page in
[Bindings](bindings.md).

## A window with a page

```zig
const std = @import("std");
const myzig = @import("myzig");

const assets = [_]myzig.Asset{
    .{ .path = "/index.html", .data = @embedFile("frontend/index.html") },
    .{ .path = "/main.js", .data = @embedFile("frontend/main.js") },
    .{ .path = "/style.css", .data = @embedFile("frontend/style.css") },
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Hello" });
    defer app.destroy();
    _ = try app.newWindow(.{
        .title = "Hello",
        .width = 720,
        .height = 560,
        .content = .{ .page = .{ .url = "/", .assets = &assets } },
    });
    try app.run();
}
```

`WindowOptions.content` is a union: `.view` for native UI, `.page` for a
page, with its `myzig.PageOptions`. The window options themselves (size,
title bar, events) are the same for both: see [Windows](windows.md).

## How the frontend is served

A relative `url` (`"/"`, `"/settings"`) resolves against the app's own
scheme, `myzig://localhost/` (on Windows `http://myzig.localhost/`, since
WebView2 treats `*.localhost` as a secure origin; the app answers it all
the same). An absolute URL (`https://example.com`, `http://localhost:5173`)
loads as it is.

The app answers each request for `myzig://localhost/<path>` from:

1. `/myzig.js`: the client generated from the app's bound services and
   events ([Bindings](bindings.md)).
2. `assets_dir`, when it is set: a directory on disk, such as a built
   frontend or one being worked on. Paths with `..`, `.`, backslashes or
   drives are refused, so nothing outside the directory is read.
3. `assets`: the files embedded in the binary, a list of `myzig.Asset`
   (`path`, `data`, and an optional `mime`).

`/` is `/index.html`. A path without an extension that is no file (a
client-side route such as `/settings/profile`) gets `/index.html`, so
routers of single-page apps work. The content type comes from the
extension (`.html`, `.js`, `.mjs`, `.css`, `.json`, `.svg`, `.png`, `.jpg`,
`.woff2`, `.wasm`; else `application/octet-stream`) unless the asset names
its `mime`, and every answer says `Cache-Control: no-cache`. Anything else
is a 404.

The `MYZIG_ASSETS_DIR` environment variable overrides `assets_dir`, and
`MYZIG_DEV_URL` overrides `dev_url`, which loads the frontend's paths from
a dev server instead ([The frontend](frontend.md#dev-servers)).

## Page options

| field | default | |
|---|---|---|
| `url` | `"/"` | what the page loads first |
| `assets` | none | files served at `myzig://localhost/` |
| `assets_dir` | null | a directory served before `assets` |
| `dev_url` | null | a dev server loaded for the frontend's paths, and trusted |
| `trusted_origins` | none | origins besides the app's own that may call bound services ([trust](#trust)) |
| `schemes` | none | schemes the app serves, besides `myzig://` ([schemes](#schemes-of-the-app)) |
| `user_scripts` | none | scripts every document runs, after the bridge |
| `zoom` | 1 | the page's zoom factor |
| `user_agent` | null | the user agent, instead of the engine's |
| `user_agent_suffix` | "" | appended to the user agent after a space instead of replacing it, such as `"MyApp/1.2"`: to the engine's, or to `user_agent`; `setUserAgent` keeps it (an empty one restores the engine's, suffix and all); spaces around it are trimmed. `"Version/17.0 Safari/605.1.15"` makes a bare web view look like Safari to sites that serve it older pages |
| `safari_tab_focus` | false | leaves Tab to text fields and elements with a tabindex, as Safari does while the system's keyboard navigation is off (macOS); by default Tab reaches links, buttons, checkboxes and selects too, as in Chrome, Edge and WebKitGTK |
| `inspectable` | true | whether the web inspector may open (right click > Inspect Element) |
| `on_event` | null | hears the page's events and answers its questions ([events](#page-events)) |

## The page

A window that shows a page has it in `window.page`, a `?*Page` (null for a
window of native UI). The window has shortcuts for what most apps need:

```zig
win.loadUrl("/settings");          // load a URL, or a path of the frontend
win.eval("document.body.classList.add('ready')");   // run a script, without waiting
win.evalResult("document.title", cb);               // evaluate, and get the value
```

and the page itself has the rest, the same on every platform:

| method | |
|---|---|
| `load(url_or_path)` | loads a URL, or a path of the frontend (on the dev server while there is one) |
| `loadHtml(html, base_url)` | loads a document from a string; `base_url` (or `about:blank`) is its origin |
| `loadFile(path)` | loads an absolute path of the disk; files of its directory may load too |
| `reload()`, `stop()` | |
| `goBack()`, `goForward()`, `canGoBack()`, `canGoForward()` | the page's history |
| `isLoading()` | |
| `currentUrl(gpa)` (also `url`), `title(gpa)` | owned copies |
| `addUserScript(script)` → id, `removeUserScript(id)` | scripts later documents run |
| `setZoom(factor)`, `zoom()` | |
| `setUserAgent(ua)`, `userAgent(gpa)` | |
| `openDevTools()` | opens the web inspector, when `inspectable` |
| `eval(js)`, `evalResult(js, cb)` | [evaluating scripts](#evaluating-scripts) |
| `findInPage(text, opts, cb)`, `stopFind()` | [finding text](#finding-text) |
| `print()`, `printToPdf(opts, cb)` | [printing](#printing) |
| `listCookies`, `setCookie`, `deleteCookie`, `clearCookies` | [cookies](#cookies) |

Page methods run on the main thread, where bound methods and listeners
already run.

A `myzig.page.UserScript` has its `source` and `at_document_end`: false
(the default) runs it before the document's own scripts, true once its
DOM is ready. Scripts run in the main frame, after the bridge, so they can
use `window.myzig`.

## Evaluating scripts

`eval` runs a script and forgets it. `evalResult` evaluates an expression,
awaits it when it is a promise, and passes its value to a
`myzig.EvalCallback` as JSON, or the error's message:

```zig
fn gotTitle(_: ?*anyopaque, r: myzig.EvalResult) void {
    switch (r) {
        .ok => |json| std.log.info("title: {s}", .{json}), // "\"Hello\""
        .err => |msg| std.log.err("eval: {s}", .{msg}),
    }
}

win.evalResult("document.title", .{ .ctx = null, .func = gotTitle });
win.evalResult("fetch('/data.json').then((r) => r.json())", .{ .ctx = null, .func = gotTitle });
```

The value is `JSON.stringify` of the result (`null` for `undefined`), and
both strings live only while the callback runs. A thrown error, or a
rejected promise, comes as `.err`. Evaluations still waiting when the page
navigates or closes fail with "the page navigated" or "the page closed",
so every callback is called once. The result carries a token only this
page's bridge knows, so a script of the page cannot answer for it.

## Page events

`on_event` takes a `myzig.PageListener`, made with `.of(&state, func)`
where `func` is `fn (state: *State, window: *myzig.Window, event: myzig.PageEvent) void`.
Some events ask a question, which the listener answers in place:

```zig
fn onPage(s: *State, win: *myzig.Window, e: myzig.PageEvent) void {
    switch (e) {
        .title_changed => |t| win.setTitle(t),
        .will_navigate => |nav| {
            // Keep the page on the app's own frontend.
            if (!std.mem.startsWith(u8, nav.url, "myzig:")) nav.cancel = true;
        },
        .new_window => |req| {
            req.handled = true;
            s.openPopup(req.url);
        },
        .permission => |req| req.allow = s.allowsMedia(req.origin),
        .download_started => |d| if (!s.wantsDownloads) {
            d.cancel = true;
        },
        else => {},
    }
}

_ = try app.newWindow(.{ .content = .{ .page = .{ .url = "/", .assets = &assets, .on_event = .of(&state, onPage) } } });
```

| event | payload | |
|---|---|---|
| `will_navigate` | `*Navigate`: `url`, `user_initiated`, `cancel` | a navigation of the main frame is about to start |
| `load_started` | the URL | |
| `committed` | the URL | the document changed (after redirects) |
| `load_finished` | the URL | |
| `load_failed` | `LoadError`: `url`, `code`, `description` | |
| `title_changed` | the title | |
| `dom_ready` | | the bridge is in the page and its DOM is ready |
| `new_window` | `*NewWindow`: `url`, `handled` | `window.open`, `target=_blank` |
| `permission` | `*PermissionRequest`: `kinds`, `origin`, `allow` | camera, microphone, geolocation, notifications |
| `download_started` | `*DownloadStart`: `url`, `suggested_name`, `path`, `cancel` | |
| `download_progress` | `DownloadProgress`: `url`, `received`, `total` (0 when unknown) | |
| `download_done` | `DownloadDone`: `url`, `path`, `err` (null when it succeeded) | |

The types are in `myzig.page` (`myzig.page.Navigate`, ...). Strings live
while the listener runs.

What happens without an answer:

- **New windows.** Unless a listener sets `handled`, `http` and `https`
  URLs open in the system's browser; others are dropped. The page itself
  never opens a second webview window.
- **Permissions.** `allow` starts as whether the asking page is
  [trusted](#trust): the app's own pages get the camera, the microphone,
  the location and notifications (the system may still ask the user),
  and other pages don't. `kinds` lists what is asked together, as the
  camera and the microphone of a call.
- **Downloads.** A download goes to the user's Downloads directory, under
  its suggested name (only its last part: never a directory), numbered as
  `name (2).ext` when a file has it. A listener may set `path` elsewhere
  (the string is copied when the event returns) or `cancel` it.

## Schemes of the app

Besides `myzig://`, the app can serve schemes of its own, for data that is
neither a file of the frontend nor a call: images made on the fly, files
the user picked, streams.

```zig
fn serveMedia(_: ?*anyopaque, req: *myzig.SchemeRequest) void {
    if (std.mem.eql(u8, req.path, "/hello.json"))
        return req.respond(200, &.{.{ .name = "Content-Type", .value = "application/json" }}, "{\"hello\":\"scheme\"}");
    req.respond(404, &.{}, "Not Found");
}

.content = .{ .page = .{
    .url = "/",
    .assets = &assets,
    .schemes = &.{.{ .name = "media", .handler = .{ .ctx = null, .func = serveMedia } }},
} },
```

Pages load `media://localhost/hello.json`, which on Windows is
`http://media.localhost/hello.json`; a page can pick the form with
`myzig.platform`:

```js
const media = (path) =>
  myzig.platform === "windows" ? "http://media.localhost" + path : "media://localhost" + path;
const data = await (await fetch(media("/hello.json"))).json();
```

A `myzig.SchemeRequest` has the `method`, the `url` (always in the
`<scheme>://localhost/...` form), the `path` without its query, and the
`body`. It is answered once, on the main thread, now or later:

- `req.respond(status, headers, body)` answers whole;
- `req.begin(status, headers)`, then `req.write(bytes)` as often as
  needed, then `req.finish()` answers in parts. A handler may keep the
  request and finish it on a later turn of the loop (from a timer, or once
  a process answered); it is freed when finished.

`req.addHeader(name, value)` adds a header before `begin`, and
`req.header(name)` reads one set so far. When a trusted page of another
origin asks (a page on the dev server fetching `media://`), the answer
allows it with CORS headers, and preflight `OPTIONS` requests are answered
for the app.

## Trust

Bound services are the app's own code, so only pages the app trusts may
call them. A call from any other page fails with `Untrusted`. Trusted are:

- the app's schemes (`myzig://` and `PageOptions.schemes`, in either
  form on Windows), and `blob:` URLs of trusted origins;
- `file:` and `about:` pages;
- the dev server (`dev_url`, or `MYZIG_DEV_URL`), by its origin;
- the origins `trusted_origins` lists, such as `"https://example.com"`
  (compared case-insensitively, a trailing `/` ignored, the scheme and
  port included), or `"*"` for every page.

Trust is checked for the document showing when the call arrives, so a
page that navigated to another site loses it. The same rule grants
[permissions](#page-events) by default.

## Finding text

```zig
fn found(_: ?*anyopaque, r: ?myzig.page.FindResult) void {
    const res = r orelse return; // the page could not search
    std.log.info("{d} of {d}", .{ res.active, res.matches });
}

page.findInPage("needle", .{}, .{ .ctx = null, .func = found });
page.findInPage("needle", .{ .find_next = true }, .{ .ctx = null, .func = found }); // the next match
page.stopFind();
```

`myzig.page.FindOptions` has `match_case`, `backward` and `find_next`
(moving on from the current match of the same text). The bridge finds the
matches in the page's visible text on every platform alike, highlights
them (with the CSS Custom Highlight API where the engine has it, else the
selection), scrolls the current one into view, and reports how many there
are and which is current, from 1.

## Printing

`page.print()` opens the system's print dialog (`window.print()`).
`page.printToPdf(opts, cb)` makes a PDF of the page without a dialog:

```zig
fn gotPdf(_: ?*anyopaque, pdf: ?[]const u8, err: ?[]const u8) void {
    const bytes = pdf orelse return std.log.err("pdf: {s}", .{err.?});
    _ = bytes; // write it somewhere: it lives while the callback runs
}

page.printToPdf(.{ .landscape = true, .background = true }, .{ .ctx = null, .func = gotPdf });
```

`myzig.page.PdfOptions` is in inches: `width` and `height` (US Letter by
default), `landscape`, the four margins (0.4 inch) and `background`.
WebKitGTK and WebView2 follow them; on macOS (`createPDF`, macOS 11 and
later) the PDF is the page's own size.

## Cookies

The cookies of the app's pages (the webview's default store, shared by
its windows) can be read and changed from Zig, asynchronously:

```zig
page.setCookie(.{ .name = "session", .value = token, .domain = "example.com", .secure = true }, .{ .ctx = null, .func = done });
page.listCookies("https://example.com/", .{ .ctx = null, .func = listed }); // null: every cookie
page.deleteCookie("session", "example.com", "/", .{ .ctx = null, .func = done });
page.clearCookies(.{ .ctx = null, .func = done });
```

A `myzig.page.Cookie` has `name`, `value`, `domain` (`.example.com` for
its subdomains too), `path` (`/`), `expires` (seconds since 1970; null for
a session cookie), `secure`, `http_only` and `same_site` (`.lax`,
`.strict`, `.none`). `listCookies` calls a `CookiesCallback` with the
cookies a request to the URL would send (or all of them), and the others
call a `DoneCallback` with null or an error.

## Testing pages

Pages are tested hidden, through the real webview and bridge. Run an app
with `--myzig-eval=JS` and each page evaluates `JS` once its DOM is ready,
with no window on the screen; the page reports with `myzig.log(...)`,
which prints `page: ...` to the app's stderr, and ends the run with
`myzig.window.close()` (the app quits with its last window).
`--myzig-hidden` keeps windows hidden for a page that tests itself.

```sh
zig-out/bin/hello --myzig-eval='myzig.call("Greeter.greet","Ada").then(v=>{myzig.log(v);myzig.window.close()})'
zig build test-pages   # hello's calls and events, and examples/pages
```

`examples/pages` is the test of everything on this page: the page calls
services, fetches the app's scheme (whole, in parts, POST, 404), reads
`assets_dir` and a client route, streams through channels both ways, asks
for a permission, opens a window and downloads a file; then Zig evaluates
scripts, finds text, prints to PDF, sets and deletes cookies, adds a user
script, and loads an untrusted document whose call fails. It prints
`page: ok`.

On Windows, `zig build test-page-memory -Doptimize=ReleaseSmall -j1`
runs four sequential hidden WebView2 probes (Normal, restore, restore,
Normal). Each reloads once, then checks ten memory-target cycles against
the runtime memory-target and controller-visibility getters, timers,
fetch, DOM/JS state and IPC. The recovery request follows a timer asking
for two seconds without IPC or fetch (background throttling can extend
that wait). Logs, including each
timing sample, are saved in `zig-out/memory-probe/`; runs are not cached.
This measures IPC recovery in a hidden host, not visible repaint latency
or memory consumption while a window is shown. Older unsupported runtimes
report a skip; the step is Windows-only.

`zig build test-page-ipc -Doptimize=ReleaseSmall -j1` checks batched
ASCII, Unicode and 64 KiB echo payloads through the real hidden webview.
`zig build build-pages -Doptimize=ReleaseSmall -j1` installs
`zig-out/bin/pages` (`pages.exe` on Windows) for external measurements;
`MYZIG_MEMORY_PROBE=ipc` selects the IPC probe when launching it headless.
