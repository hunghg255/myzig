# Menus, trays and global shortcuts

The menu bar, tray icons and global shortcuts are the app's, not a
window's. Menus are built from templates: arrays of `myzig.MenuItem`, the
same on every platform. Menus drawn inside native UI (context menus,
menu buttons, selects) are widgets: see [Native UI menus](ui/menus.md).

## Templates

```zig
const Menus = struct {
    fn newNote(m: *Menus, item: *myzig.menu.Item) void {
        _ = item;
        m.notes.add();
    }
    fn wrap(m: *Menus, item: *myzig.menu.Item) void {
        m.editor.wrap = item.checked; // already toggled
    }
    fn small(m: *Menus, _: *myzig.menu.Item) void {
        m.editor.size = 13;
    }
    fn large(m: *Menus, _: *myzig.menu.Item) void {
        m.editor.size = 17;
    }
};

var menus: Menus = .{ .notes = &notes, .editor = &editor };
try app.setMenu(&.{
    .{ .role = .app_menu },
    .{ .label = "File", .submenu = &.{
        .{ .label = "New Note", .accelerator = "CmdOrCtrl+N", .click = .of(&menus, Menus.newNote) },
        .separator,
        .{ .role = .close },
    } },
    .{ .role = .edit_menu },
    .{ .label = "Format", .submenu = &.{
        .{ .label = "Wrap Lines", .id = "wrap", .kind = .checkbox, .checked = true, .click = .of(&menus, Menus.wrap) },
        .separator,
        .{ .label = "Small", .kind = .radio, .checked = true, .click = .of(&menus, Menus.small) },
        .{ .label = "Large", .kind = .radio, .click = .of(&menus, Menus.large) },
    } },
    .{ .role = .view_menu },
    .{ .role = .window_menu },
});
```

A `myzig.MenuItem` has:

| field | what it is |
|---|---|
| `label` | its text; a role's own label when empty |
| `accelerator` | its key combination ([Accelerators](#accelerators)) |
| `role` | a standard item or a whole standard menu ([Roles](#roles)) |
| `kind` | `.normal`, `.checkbox` or `.radio` |
| `checked` | a checkbox's or radio item's initial state |
| `disabled` | grayed out |
| `hidden` | left out |
| `tooltip` | shown on hover (macOS) |
| `id` | to find the item later with `app.menuItem(id)` |
| `submenu` | a template of its own: the item opens it |
| `click` | a `myzig.MenuClick`: `.of(&state, State.method)` with `fn method(s: *State, item: *myzig.menu.Item) void` |

`.separator` is a line between groups of items.

Clicks run on the main thread. A checkbox item's `checked` is toggled
before its click runs, and a radio item is checked and the other items of
its group unchecked: the radio items next to each other, up to a
separator or another kind of item, are a group.

Templates are usually literals, as above. Where myzig builds menus
itself (Windows, Linux, browsers) the items keep the template's strings,
so a template made at run time, and the `click` contexts, must outlive
the menu.

### Roles

A role gives an item the system's label, accelerator and action, so the
app writes nothing for it:

| role | macOS | Windows and Linux |
|---|---|---|
| `.about` | About *App* | left out |
| `.hide`, `.hide_others`, `.unhide` | Hide *App* (⌘H), Hide Others (⌥⌘H), Show All | left out |
| `.quit` | Quit *App* (⌘Q) | E&xit |
| `.undo`, `.redo` | Undo (⌘Z), Redo (⇧⌘Z) | Ctrl+Z, Ctrl+Y |
| `.cut`, `.copy`, `.paste`, `.delete`, `.select_all` | ⌘X, ⌘C, ⌘V, Delete, ⌘A | Ctrl+X, Ctrl+C, Ctrl+V, Delete, Ctrl+A |
| `.minimize`, `.zoom` | Minimize (⌘M), Zoom | Minimize, Maximize |
| `.close` | Close Window (⌘W) | Close (Ctrl+W) |
| `.toggle_full_screen` | Enter Full Screen (⌃⌘F) | Toggle Full Screen (F11) |
| `.front` | Bring All to Front | left out |

The editing roles act on what has the keyboard: a text field of native
UI, a page's focused element. Window roles act on the window in front.
An item with a role and a `click` runs its click.

Four roles stand for whole menus, filled with their usual items:

| role | macOS | Windows and Linux |
|---|---|---|
| `.app_menu` | the app's name: About, Hide, Hide Others, Show All, Quit | File: Exit |
| `.edit_menu` | Edit: Undo, Redo, Cut, Copy, Paste, Select All | Edit: the same, with Delete |
| `.view_menu` | View: Enter Full Screen | View: Toggle Full Screen |
| `.window_menu` | Window: Minimize, Zoom, Bring All to Front, Close | Window: Minimize, Maximize, Close |

A whole-menu role with a `submenu` of its own keeps its title and role
and shows those items instead; with a `label`, the label is its title.
On macOS, `.window_menu` is also the menu AppKit lists the windows in.

On macOS every app starts with `myzig.App.default_menu`: the app menu,
Edit, View and Window. A web page's text fields need the Edit menu for
copying and pasting with the keyboard there, so keep `.edit_menu` in
menus of your own. On Windows and Linux an app has no menu until it calls
`setMenu`.

### Changing items

```zig
if (app.menuItem("wrap")) |item| {
    item.setChecked(false);
    item.setEnabled(editor.open);
}
```

`app.menuItem(id)` finds the menu bar's item whose template had `id`.
`setChecked` changes a checkbox or radio item (checking a radio item
unchecks its group), `setEnabled` grays it or not; `item.checked` and
`item.id` read it. On macOS `setLabel` changes its text. To change more,
call `setMenu` again with another template: it replaces the menu bar.

## The menu bar

`app.setMenu(template)` replaces the menu bar:

- **macOS**: the menu bar at the top of the screen, built of NSMenus.
- **Windows**: a menu bar at the top of every window with a title bar
  (windows whose title bar is hidden or frameless have none), built of
  HMENUs; checks and grayed items are refreshed as each menu opens.
- **Linux**: no bar shows; the items' accelerators work in every window.
- **Browsers**: no bar shows; the accelerators work in the page.

Everywhere, a key combination that is a menu item's accelerator runs the
item, in native UI and in pages. On Windows and Linux, `&` in a label
marks its mnemonic (`"&File"`; `"&&"` is an ampersand), as the standard
menus' titles do; macOS shows labels as written.

## Context menus

A context menu of native UI is a widget, `ui.contextMenu`, drawn by
myzig in the window's own layer, with keyboard navigation, submenus and
checks: see [Native UI menus](ui/menus.md). Pages show their own, or
the webview's (with Inspect Element while `inspectable` is set).

## Tray icons

```zig
const Tray = struct {
    fn show(t: *Tray, _: *myzig.menu.Item) void {
        t.window.show();
        t.window.focus();
    }
    fn clicked(t: *Tray, _: *myzig.Tray) void {
        t.window.show();
    }
};

var tray_state: Tray = .{ .window = win };
const tray = try app.newTray(.{
    .icon = @embedFile("tray.png"),
    .symbol = "bolt.fill",
    .tooltip = "Sync",
    .menu = &.{
        .{ .label = "Show Window", .click = .of(&tray_state, Tray.show) },
        .separator,
        .{ .role = .quit },
    },
    .on_click = .of(&tray_state, Tray.clicked),
});
```

`app.newTray` adds an icon to the menu bar's status area (macOS), the
notification area (Windows) or the panel (Linux). `myzig.TrayOptions`:

| field | what it is |
|---|---|
| `id` | names the icon across launches, unique among the app's icons (below) |
| `title` | text next to the icon (macOS's menu bar, Linux panels that show labels); the tooltip elsewhere when there is none |
| `symbol` | an SF Symbol's name (`"star.fill"`), drawn as a template image that follows the menu bar's appearance (macOS) |
| `icon` | a PNG file's bytes (16 or 32 pixels square suit Windows); the app's icon when empty |
| `template` | the icon is black and transparent: macOS tints it to match the menu bar, Windows shows it white on a dark taskbar |
| `tooltip` | shown on hover |
| `menu` | a template, shown on a right click (Windows) or on any click (elsewhere) |
| `on_click` | a `myzig.TrayClick`: a left click on Windows, a click on macOS when there is no menu, a click of a GtkStatusIcon on Linux |
| `on_appearance` | a `myzig.TrayClick` called as the bar the icon shows on turns dark or light (`tray.dark()`) |

The icon lives until `app.removeTray(tray)` or the app's end. Change it
with `setTitle`, `setTooltip`, `setSymbol` (macOS), `setIcon(png)` and
`setMenu(app.options.name, template)`; `popUpMenu()` opens its menu from
code (Windows, Linux).

An app may show several icons, as a menu bar app showing its measures
each in an item of its own. On macOS a new icon goes left of those
already there, and the user moves icons by dragging them with ⌘ held:
give each an `id`, unique among the app's icons, and it goes back where
the user put it whenever it is made again, at the next launch or after
`removeTray` (the status item's autosave name). On Windows, where the
user chooses which icons show on the taskbar rather than in its
overflow, an icon with an `id` keeps that choice whatever order the app
makes its icons in: it is numbered by its `id` (FNV-1a, with the high
bit set), not counted as icons come. Linux panels place icons
themselves.

A template icon follows the bar by itself. An icon in color, as one
drawing each of its measures in its own color, draws its ink for the
bar: `tray.dark()` tells whether the bar is dark — the macOS menu bar as
AppKit tints its items (by the system's appearance, or the wallpaper
under a translucent bar), the Windows taskbar in the system's mode,
which may differ from the apps' — and `on_appearance` is called on the
main thread as it turns, to `setIcon` again. Linux panels draw their
icon themes their own way: `dark()` is false there.

How each platform shows it:

- **macOS**: an NSStatusItem in the menu bar. With a menu, a click opens
  it; without one, a click calls `on_click`.
- **Windows**: a notification area icon. A left click calls `on_click`, a
  right click opens the menu. The first tray icon also shows the app's
  notifications ([Notifications](app.md#notifications)).
- **Linux**: a StatusNotifierItem through libayatana-appindicator (loaded
  with `dlopen`), which panels show with its menu on a click. Where the
  library is missing, a GtkStatusIcon (X11 panels with a system tray):
  a click calls `on_click`, a right click opens the menu. A run without
  a display fails with `error.Headless`.
- **Browsers**: `error.Unsupported`.

Apps that live in the tray set `quit_on_last_window_closed = false`, so
that closing the window leaves them running, and keep a `.quit` item in
the tray's menu. A panel under the icon, as menu bar apps have, is a
flyout anchored to the tray icon ([Flyouts](windows.md#flyouts)).

Headless runs (`--myzig-hidden`, `--myzig-eval`) should add no icon:
check `app.flags.hidden` first.

## Global shortcuts

A global shortcut reaches the app while another app is in front, as
launchers open (Spotlight, Raycast, PowerToys Run):

```zig
const Launcher = struct {
    panel: *myzig.Window,

    fn toggle(l: *Launcher, _: void) void {
        if (l.panel.isVisible()) l.panel.hide() else {
            l.panel.show();
            l.panel.focus();
        }
    }
};

var launcher: Launcher = .{ .panel = panel };
const id = try app.registerHotkey("Alt+Shift+Space", .of(&launcher, Launcher.toggle));
defer app.unregisterHotkey(id);
```

`registerHotkey` takes an [accelerator](#accelerators) and a
`myzig.Handler(void)`, which runs on the main thread when it is pressed,
and returns the shortcut's id for `unregisterHotkey`. It fails with:

- `error.UnsupportedKey`: a key a global shortcut cannot use, or none;
- `error.Unavailable`: another app has it, or the system refused it;
- `error.Unsupported`: the system has no global shortcuts.

| platform | how |
|---|---|
| macOS | Carbon's RegisterEventHotKey |
| Windows | RegisterHotKey on the app's hidden window |
| Linux | an X11 key grab on the root window, with Caps Lock and Num Lock on or off; on Wayland the desktop portal's GlobalShortcuts (the desktop asks the user to allow them once) |
| browsers | not available |

`App.destroy` unregisters the shortcuts that are left.

## Accelerators

Accelerators are written as modifiers and a key joined by `+`:

```
CmdOrCtrl+N   CmdOrCtrl+Shift+K   Alt+Up   F5   Cmd+,   Cmd++   Ctrl+Space
```

| part | names |
|---|---|
| ⌘ on macOS, Ctrl elsewhere | `CmdOrCtrl`, `CommandOrControl`, `Cmd`, `Command`, `Super`, `Meta` |
| Control | `Ctrl`, `Control` |
| Alt, ⌥ | `Alt`, `Option` |
| Shift | `Shift` |
| named keys | `Up`, `Down`, `Left`, `Right`, `Enter`, `Return`, `Tab`, `Space`, `Escape`, `Esc`, `Backspace`, `Delete`, `Home`, `End`, `PageUp`, `PageDown`, `Plus`, `F1` to `F20` |
| other keys | the character itself (`N`, `,`, `/`); `Cmd++` names the plus key |

Names are not case-sensitive. On Windows and Linux, ⌘ and Ctrl are both
Ctrl, and menus show accelerators as those systems write them
(`Ctrl+Shift+K`). macOS shows them with its symbols. In native UI,
`ui.keys.label("⌘P")` and `ui.shortcutLabel` write key combinations for
the platform ([Navigation](ui/navigation.md)).
