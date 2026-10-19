# Windows

A window shows one of two contents: native UI that myzig draws (a
`ui.View`), or a web page in the system's webview. Everything else, the
options, the events, the title bars, flyouts, is the same for both.

```zig
const win = try app.newWindow(.{
    .title = "Notes",
    .width = 900,
    .height = 600,
    .min_width = 480,
    .min_height = 320,
    .title_bar = .hidden,
    .state = myzig.windowState("main"),
    .content = .{ .view = .init(&state, State.view) },
});
```

`App.newWindow` makes the window, shows it unless `visible` is false, and
returns it. The app keeps it in `app.windows` until it closes; then it is
freed, and the pointer must not be used again (`on_close` is the place to
forget it).

A page instead of a view:

```zig
const assets = [_]myzig.Asset{
    .{ .path = "/index.html", .data = @embedFile("frontend/index.html") },
};

_ = try app.newWindow(.{
    .title = "Hello",
    .content = .{ .page = .{ .url = "/", .assets = &assets } },
});
```

What a page's options are (`myzig.PageOptions`: assets, a directory, a
dev server, schemes, trusted origins, scripts, its listener) is in
[Pages](pages.md).

## Options

`myzig.WindowOptions`:

| field | default | what it does |
|---|---|---|
| `title` | `""` | the title bar's text |
| `width`, `height` | 800, 600 | the content's size in points |
| `min_width`, `min_height` | 200, 150 | the smallest the user can make it |
| `resizable` | true | the user can resize it |
| `x`, `y` | null | its top left in screen points from the primary screen's top left; centered when null |
| `visible` | true | shown at once; otherwise call `show` |
| `always_on_top` | false | above other apps' windows |
| `skip_taskbar` | false | out of the taskbar and the app switcher (Linux, Windows) |
| `title_bar` | `.default` | `.default`, `.hidden` or `.frameless` ([below](#title-bars)) |
| `title_bar_height` | 0 | the height of a hidden title bar, or of a frameless window's drag strip; 0 is the system's (32 on Windows, 28 elsewhere) |
| `theme` | null | native UI's colors, fixed (`ui.Theme.light`, `ui.Theme.dark_theme`, one of the app's); the system's light or dark when null |
| `material` | `.none` | what shows through the background ([Materials](#materials)) |
| `state` | null | remember the frame under a key ([below](#remember-where-windows-were)) |
| `on_close` | null | called as the window closes, before it is freed |
| `on_close_request` | null | asked whether the window closes as the user closes it |
| `on_event` | null | focus, moves, resizes, minimizing, maximizing |
| `on_drop` | null | files dropped on the window from a file manager |
| `content` | (required) | `.{ .view = ... }` or `.{ .page = ... }` |

A flyout is a window too, made by `App.newFlyout` ([Flyouts](#flyouts)).

## Show windows without flashing

A window shown before its content is ready flashes empty. Make it with
`.visible = false` and show it when it is ready:

```zig
const win = try app.newWindow(.{ .title = "Report", .visible = false, .content = content });
// ... load what it shows ...
win.show();
```

`--myzig-hidden` (and the other headless flags) keep every window hidden
whatever the app asks: tests and snapshots never put anything on the
screen.

## Size, position and state

| method | what it does |
|---|---|
| `show()`, `hide()`, `isVisible()` | shows or hides the window |
| `focus()`, `isFocused()` | brings the window and the app to the front; whether it has the keyboard |
| `close()` | closes it at once, without asking `on_close_request` |
| `requestClose()` | closes it as the user would, asking `on_close_request` |
| `setTitle(title)` | the title bar's text |
| `frame()` | `Window.Frame`: `x`, `y`, `width`, `height` in screen points, from the primary screen's top left |
| `contentSize()` | the content's `[2]f64` width and height, without the title bar |
| `setSize(w, h)` | resizes the content, keeping the top left |
| `setPosition(x, y)` | moves the top left |
| `center()` | centers it on its screen |
| `setMinSize(w, h)` | the smallest content size |
| `setResizable(on)`, `setAlwaysOnTop(on)` | as the options |
| `minimize()`, `isMinimized()` | to the Dock or the taskbar |
| `zoom()`, `isMaximized()` | maximizes it, or restores it |
| `setFullScreen(on)`, `isFullScreen()` | full screen (its own Space on macOS) |
| `setMaterial(m)` | the material behind the content; false where there is none |
| `redraw()` | draws native UI again at the next refresh, for state changed outside its events |

From a page, `myzig.window.close()`, `minimize()`, `toggleMaximize()` and
`setTitle(title)` do the same for the page's own window.

## Remember where windows were

```zig
_ = try app.newWindow(.{
    .title = "Notes",
    .state = myzig.windowState("main"),
    .content = content,
});
```

With a `state` key, a window opens where the last window with that key
was: its position, its size and whether it was maximized override `x`,
`y`, `width` and `height`. The states are kept in `window-state.txt` in
the app's data directory, a line per key, read when the first window with
a key opens and written as such a window closes. A state that no longer
fits (a screen unplugged, a size under 50 points) is ignored. Give each
kind of window its own key (`"main"`, `"preferences"`, `"note"`). Apps
that remember no window don't link the store.

## Closing

```zig
const State = struct {
    dirty: bool = false,
    window: ?*myzig.Window = null,

    fn mayClose(s: *State, win: *myzig.Window) bool {
        _ = win;
        if (!s.dirty) return true;
        const r = myzig.dialog.message(.{
            .title = "Close without saving?",
            .buttons = &.{ "Close", "Cancel" },
        });
        return r.button == 0;
    }

    fn closed(ctx: *anyopaque, win: *myzig.Window) void {
        _ = win;
        const s: *State = @ptrCast(@alignCast(ctx));
        s.window = null;
    }
};

_ = try app.newWindow(.{
    .on_close_request = .of(&state, State.mayClose),
    .on_close = .{ .ctx = &state, .func = State.closed },
    .content = content,
});
```

`on_close_request` (a `myzig.CloseRequest`) is asked when the user closes
the window: its close button, Alt+F4, the Dock's or taskbar's Close,
macOS's Close Window item, `requestClose`. False keeps it open. `close` does not
ask. `on_close` runs as the window goes, before it is freed, whichever
way it closed. [Documents](documents.md) ask for you, saving or
discarding each document's changes.

## Events

```zig
fn onWindow(s: *State, win: *myzig.Window, e: myzig.WindowEvent) void {
    _ = win;
    switch (e) {
        .focus => s.active = true,
        .blur => s.active = false,
        .resized => |size| s.width = size.width,
        .moved => |p| std.log.info("at {d}, {d}", .{ p.x, p.y }),
        .minimized, .maximized, .restored => {},
    }
}

_ = try app.newWindow(.{ .on_event = .of(&state, State.onWindow), .content = content });
```

`myzig.WindowEvent` is a union of `focus`, `blur`, `moved` (the top left,
in screen points), `resized` (the content's size), `minimized`,
`maximized` and `restored` (back from either). Events come on the main
thread, once per change: the systems repeat sizes and activations that
change nothing, and myzig drops them.

## Title bars

`title_bar` is one of:

- **`.default`**: the system's title bar above the content.
- **`.hidden`**: the content fills the window, under the system's window
  controls: macOS's traffic lights, Windows 11's caption buttons over the
  top right corner (with snap layouts on maximize), GTK's header bar with
  its title buttons. The empty space of the top `title_bar_height` moves
  the window, as a title bar does, and a double click there maximizes it.
- **`.frameless`**: no title bar and no controls. The content draws all
  of it and moves the window from its drag regions. The window still
  resizes from its edges and keeps its shadow.

In native UI, a press in the drag strip moves the window unless it lands
on an interactive box (a button, a tab, a field): those take it. A view
whose toolbar is taller than the title bar sets `c.title_bar_height` to
the toolbar's height, and the strip follows it. To keep clear of the
system's controls, ask the window how much room they take:

```zig
fn view(s: *State, c: *ui.Context) void {
    const area = s.window.titleBar(); // myzig.TitleBarArea
    const bar = ui.div(c).row().itemsCenter().wFull().h(@floatCast(@max(area.height, 40)))
        .pl(@floatCast(area.left + 8)).pr(@floatCast(area.right + 8));
    defer bar.end();
    ui.text(c, "Notes", .{ .weight = .semibold });
}
```

`myzig.TitleBarArea` has the `height` the controls take, and the widths
they cover on the `left` (macOS's traffic lights) and on the `right`
(Windows' caption buttons). It is empty for windows that are not hidden,
in full screen, and on Linux, where GTK's header bar sits above the
content.

A frameless window moves from its own title bar: call `startDrag()` from
a press on it. On Windows 11, a frameless window that draws its own
maximize button calls `setSnapButton(rect)` with the button's rectangle
in the content, so that hovering it shows the snap layouts; null removes
it.

Pages mark their drag regions in CSS: elements styled
`--app-region: drag` move the window (a double click maximizes it), and
`--app-region: no-drag` exempts what is inside one, such as buttons:

```css
header { --app-region: drag; height: 38px; }
header button { --app-region: no-drag; }
```

## Materials

```zig
_ = try app.newWindow(.{ .material = .sidebar, .title_bar = .hidden, .content = content });
```

`myzig.Material` is what shows through the window's background where the
system has materials, and the content leaves it clear:

| material | macOS (vibrancy) | Windows 11 |
|---|---|---|
| `.none` | none | none |
| `.sidebar` | the sidebar's | Mica |
| `.under_window` | under the window's content | Mica Alt (tabbed) |
| `.popover` | a popover's or HUD's | Acrylic |

`setMaterial` changes it later, and returns false where the system has
none (Linux, Windows 10, browsers).

## Flyouts

A flyout is a borderless panel without a taskbar button, placed next to
a rectangle: a box of its parent window, a point of the screen, or a tray
icon. Menu bar apps, pickers and suggestion lists are flyouts.

```zig
const panel = try app.newFlyout(.{
    .tray = tray,                // or .parent = win with .anchor in its content
    .width = 320,
    .height = 420,
    .dismiss = .hide,
    .hidden = true,
    .content = .{ .view = .init(&state, State.panel) },
});
// The tray icon's click toggles it:
fn trayClicked(s: *State, t: *myzig.Tray) void {
    _ = t;
    if (s.panel.isVisible()) s.panel.hide() else s.panel.show();
}
```

`myzig.FlyoutOptions`:

| field | default | what it does |
|---|---|---|
| `parent` | null | the window whose content `anchor` is in; the flyout stays above it |
| `tray` | null | anchors the flyout to a tray icon: below a macOS menu bar's, above a taskbar's at the bottom; centered in the work area where the system does not tell where icons are (Linux) |
| `anchor` | empty | a `myzig.flyout.Rect` in points: in the parent's content, or on the screen without a parent |
| `placement` | `.bottom_start` | the side and alignment: `bottom`, `top`, `right`, `left`, each `_start`, centered, or `_end` |
| `gap` | 0 | points between the anchor and the flyout |
| `width`, `height` | 200, 200 | its size |
| `focusable` | true | takes the keyboard as it shows, and is dismissed when another window takes it; otherwise it never takes the keyboard (tooltips, suggestions) and stays until closed |
| `dismiss` | `.close` | what a dismissed flyout does: `.close` (as the user closing it) or `.hide` (to show again) |
| `hidden` | false | created hidden: `show` shows it, placed again |
| `popover` | false | on macOS, the system's popover (`NSPopover`): its material, rounded corners and an arrow pointing at the anchor's middle; on `placement`'s side or the opposite one (the rest of the placement and `gap` do not apply); needs a `parent` or a `tray`. A regular flyout elsewhere |
| `material` | `.none` | a translucent, blurred material behind the content, as a window's ([Materials](#materials)); a popover has its own |
| `corner_radius` | 0 | rounds the corners on macOS, in points: the material and the content are cut to them, and the shadow follows them. Windows 11 rounds flyouts as it rounds its menus; Linux does not |
| `theme` | null | as a window's |
| `content` | (required) | a view or a page |

A focusable flyout is dismissed when another window takes the keyboard
(a click elsewhere, the app deactivated) and on Escape; a press on its
own tray icon is left to the icon's click, which toggles it, rather than
closing it for the click to open it again (macOS, Windows). It is placed as
menus are: on each axis it flips to the other side of the anchor, or its
other end, where it would not fit and the flipped one would, then slides
back into the work area, then shrinks to it.

A popover flyout's content draws no background over the material.
With `focusable` it closes as the user clicks elsewhere (asking
`on_close_request`), and from a tray icon it activates the app and
highlights the icon while it shows. Its window is the popover's while it
shows.

When the anchor moves (the parent moved, the tray icon did),
`placeFlyout()` places it again; `setAnchor(rect)` gives it another
anchor; `setSize` resizes it in place; `isFlyout()` tells flyouts from
other windows.

## Attention and progress

- `flash(true)` asks for attention until the window is focused: it
  bounces the Dock icon (macOS), flashes the taskbar button (Windows), or
  marks the window urgent (Linux); `flash(false)` stops.
- `setProgress(.{ .state = .normal, .value = 0.4 })` shows a task's
  progress (`myzig.Progress`: `state` is `.none`, `.normal`,
  `.indeterminate`, `.paused` or `.failed`, `value` from 0 to 1) on the
  taskbar button (Windows) or the launcher entry (Linux docks with the
  Unity API). It returns false where nothing shows it (macOS, where
  `app.setBadge` is the Dock's).

## Documents

- `setDocumentEdited(true)` marks the window's document as having unsaved
  changes: a dot in macOS's close button, `*` before the title on Windows
  and Linux. `isDocumentEdited()` reads it.
- `setRepresentedFile(path)` names the file the window shows: on macOS its
  icon in the title bar, which the user can drag, and ⌘-click for its
  folders; nothing elsewhere.

[Documents](documents.md) does both for document windows.

## Files dropped on a window

```zig
fn dropped(s: *State, win: *myzig.Window, paths: []const []const u8) void {
    _ = win;
    for (paths) |p| s.open(p);
}

_ = try app.newWindow(.{ .on_drop = .of(&state, State.dropped), .content = content });
```

`on_drop` gets the paths of files dropped from Finder, Explorer or a file
manager. Drags within native UI, and out of it to other apps, are in
[Data transfer](data-transfer.md) and [Drag and drop](ui/drag-and-drop.md).

## Pages in windows

A window that shows a page also runs scripts in it and loads other URLs:

- `loadUrl(url)` loads another URL.
- `eval(js)` runs a script, not waiting for it.
- `evalResult(js, cb)` evaluates an expression and passes its value as
  JSON, or its error, to a `myzig.EvalCallback`.
- `sendOwned(msg)` queues an encoded message for the page, from any
  thread; typed events do it for you.

The page itself is `win.page` (null for native UI), with finding,
printing, cookies and the rest: see [Pages](pages.md).

## Platforms

| | macOS | Linux | Windows | browsers |
|---|---|---|---|---|
| windows | NSWindow | GtkWindow | Win32 | the page's canvas, one window |
| native UI drawn with | Metal | OpenGL, or the CPU | Direct3D 11, or the CPU | WebGL 2 |
| pages | WKWebView | WebKitGTK | WebView2 | no |
| hidden title bar | traffic lights over the content | a GTK header bar | caption buttons over the content, snap layouts | no |
| materials | vibrancy | no | Mica, Mica Alt, Acrylic (Windows 11) | no |
| flyouts | yes | yes (tray flyouts centered) | yes | no |
| progress | no (the Dock's badge) | Unity launcher | taskbar | no |
| represented file | yes | no | no | no |

In a browser, the first window of native UI fills the page; sizes,
positions and the window's state do nothing there ([Browsers](browsers.md)).
