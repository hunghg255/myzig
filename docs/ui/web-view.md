# Web views in native UI

`ui.webView` shows a web page in a box of a native UI window: a help pane,
a preview, or a page of the app's web frontend beside native controls. It
places the system's web view (WebView2, WebKitGTK, WKWebView) at a box of
the layout, every frame:

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

The app keeps a `ui.WebView`:

- The page is made the first frame that shows it. It lives until
  `destroy()` or until its window closes.
- `page` is the platform's page, with a window's methods (`load`, `eval`,
  `evalResult`, `goBack`, `setZoom`, …).
- `shown` says where the last frame showed it, null while hidden.

| `ui.WebViewOptions` | |
|---|---|
| `page` | the page's options, as a window's `PageOptions` (read when the page is made) |
| `width`, `height` | the box's size, `.fill` by default |
| `grow`, `min_width`, `min_height` | as any box's |
| `padding`, `background`, `border`, `border_width`, `radius` | around the page, in the box |
| `key` | the box's key, so the page follows it when the view reorders |

## What it does

**Placement**

- After each frame the page goes to the box's content box, snapped to
  device pixels and cut by the scroll and clip boxes around it.
- It hides when none of it shows, when its box fades to nothing, or when
  the view stops building it. It keeps its page while hidden.
- A window may show several.

**The same page as a window's**

- The bridge, bound services, events, channels, schemes, trust and
  `eval` work as in a page window.
- `Event.emit(window)` and `broadcast` reach web views too.
- `myzig.window.close()` from an embedded page leaves the window open.
- Elements styled `--app-region: drag` move the window, as in a page
  window.

**The keyboard**

- Tab stops at the web view and moves into the page; Shift+Tab enters
  from its end.
- On Windows, Tab past the page's ends comes back to native UI.
- Clicking the page takes native UI's focus away. Clicking native UI takes
  the keyboard back.

**Native UI over it.** Popovers, menus, dialogs and their backdrop,
toasts, tooltips and boxes painted after the web view show above the
page, in a *cover*:

- The CPU renderer draws it with transparency, only where something
  overlaps and only when it changes.
- It takes the pointer where it is opaque and sends it to native UI. The
  page gets the pointer everywhere else.
- It is a layered child window on Windows, a widget above the page in the
  window's GtkOverlay on Linux, and an NSView on macOS.

## Testing it

| | |
|---|---|
| `v.probe()` | reads back where the native view is and where it should be |
| `v.probeCover()`, `v.coverMatchesFrame()`, `v.clickCover(x, y)` | the same for the cover |

`examples/embed-webview` runs its own check with `--check`.
`zig build test-pages` runs it hidden on Windows.

## Platforms

| | how |
|---|---|
| Windows | a windowed WebView2 controller in a child "clip" window at the visible part; covers are layered child windows (`UpdateLayeredWindow`) |
| Linux | the drawing area moves into a GtkOverlay at the first web view; each page is a GtkLayout child placed through `get-child-position`; covers are drawing areas with an input shape |
| macOS | a clip NSView (masking to its bounds) over the surface's view, with the WKWebView in it; covers are flipped NSViews whose `hitTest:` falls through where transparent |
| browsers | not available |

Not done:

- transforms of a web view's box: it is placed at its bounds;
- opacity other than none or full;
- the page in native UI's accessibility tree.
