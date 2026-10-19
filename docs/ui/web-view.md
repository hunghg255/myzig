# Web views in native UI

A window of native UI can show web pages in boxes of its own: a help
pane, a preview, a page of an app's web frontend beside its native
controls. `ui.webView` places the system's web view (WebView2, WebKitGTK,
WKWebView) at a box of the layout, every frame:

```zig
const State = struct {
    docs: ui.WebView = .{},

    fn view(s: *State, c: *ui.Context) void {
        ui.row(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        sidebar(c);
        _ = ui.webView(c, &s.docs, .{
            .page = .{ .url = "/notes.html", .assets = &assets },
            .grow = 1,
            .radius = 12,
            .key = "notes",
        });
    }
};
```

`ui.WebView` is what the app keeps: the page is made the first frame that
shows it and lives until `destroy()` or its window closes. Its `page` is
the platform's page, with the same methods as a window's (`load`, `eval`,
`evalResult`, `goBack`, `setZoom`, …), and `shown` says where the last frame
showed it (null while hidden).

`ui.WebViewOptions`:

| field | |
|---|---|
| `page` | the page's options, as a window's `PageOptions` (read when the page is made) |
| `width`, `height` | the box's size, `.fill` by default |
| `grow`, `min_width`, `min_height` | as any box's |
| `padding`, `background`, `border`, `border_width`, `radius` | around the page, in the box |
| `key` | the box's key, so the page follows it when the view reorders |

## What it does

- **Placement.** After each frame the page is put at the box's content
  box, snapped to device pixels, and cut by the scroll and clip boxes
  around it. It hides when none of it shows, when its box fades to
  nothing, or when the view stops building it; it keeps its page while
  hidden. A window may show several.
- **The same page as a window's.** The bridge, bound services, events
  (`Event.emit(window)` and `broadcast` reach web views too), channels,
  schemes, trust and `eval` work as in a page window. `myzig.window.close()`
  from an embedded page leaves the window open.
- **The keyboard.** Tab stops at the web view and moves into the page
  (Shift+Tab from its end); on Windows, Tab past the page's ends comes back
  to native UI. Clicking the page takes native UI's focus away; clicking
  native UI takes the keyboard back.
- **Native UI over it.** What native UI paints over a web view — popovers,
  menus, dialogs and their backdrop, toasts, tooltips, and boxes painted
  after it — shows above the page, in a *cover*: a layered child window
  on Windows, a widget above it in the window's GtkOverlay on Linux, an
  NSView on macOS, drawn by the CPU renderer with transparency, only where
  something overlaps and only when it changes. The cover takes the
  pointer where it is opaque and sends it to native UI; the page gets it
  everywhere else.
- **Drag regions.** Elements styled `--app-region: drag` in the page move
  the window, as in a page window.

## Testing it

`v.probe()` reads back where the native view really is and where it should
be; `v.probeCover()`, `v.coverMatchesFrame()` and `v.clickCover(x, y)` do
the same for the cover. `examples/embed-webview` runs its own check with
`--check` (`zig build test-pages` runs it hidden on Windows).

## Platforms

| | how |
|---|---|
| Windows | a windowed WebView2 controller in a child "clip" window at the visible part; covers are layered child windows (`UpdateLayeredWindow`) |
| Linux | the drawing area moves into a GtkOverlay at the first web view; each page is a GtkLayout child placed through `get-child-position`; covers are drawing areas with an input shape |
| macOS | a clip NSView (masking to its bounds) over the surface's view, with the WKWebView in it; covers are flipped NSViews whose `hitTest:` falls through where transparent |
| browsers | not available |

Not done: transforms of a web view's box (it is placed at its bounds),
opacity other than none or full, and the page in native UI's
accessibility tree.
