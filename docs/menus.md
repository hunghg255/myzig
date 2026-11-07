# Menus, trays and global shortcuts

The menu bar, tray icons and global shortcuts belong to the app, not to a
window. Menus are built from templates: arrays of `myzig.MenuItem`, the
same on every platform. Menus drawn inside native UI (context menus, menu
buttons, selects) are widgets: see [Native UI menus](ui/menus.md).

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

| `myzig.MenuItem` | |
|---|---|
| `label` | its text; the role's own label when empty |
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

- Clicks run on the main thread.
- A checkbox item's `checked` is toggled before its click runs.
- A radio item is checked and the rest of its group unchecked. A group is
  the radio items next to each other, up to a separator or another kind
  of item.
- On Windows, Linux and browsers, myzig builds the menus itself and keeps
  the template's strings. A template made at run time, and the `click`
  contexts, must outlive the menu.

### Roles

A role gives an item the system's label, accelerator and action. The app
writes nothing for it:

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

- Editing roles act on what has the keyboard: a native UI text field, or
  a page's focused element.
- Window roles act on the window in front.
- An item with a role and a `click` runs its click.

Four roles stand for whole menus with their usual items:

| role | macOS | Windows and Linux |
|---|---|---|
| `.app_menu` | the app's name: About, Hide, Hide Others, Show All, Quit | File: Exit |
| `.edit_menu` | Edit: Undo, Redo, Cut, Copy, Paste, Select All | Edit: the same, with Delete |
| `.view_menu` | View: Enter Full Screen | View: Toggle Full Screen |
| `.window_menu` | Window: Minimize, Zoom, Bring All to Front, Close | Window: Minimize, Maximize, Close |

- With a `submenu` of its own, a whole-menu role keeps its title and role
  but shows those items instead. A `label` becomes its title.
- On macOS, `.window_menu` is also where AppKit lists the windows.
- On macOS every app starts with `myzig.App.default_menu`: the app menu,
  Edit, View and Window.
- Keep `.edit_menu` in your own menus on macOS. A web page's text fields
  need it to copy and paste with the keyboard.
- On Windows and Linux an app has no menu until it calls `setMenu`.

### Changing items

```zig
if (app.menuItem("wrap")) |item| {
    item.setChecked(false);
    item.setEnabled(editor.open);
}
```

`app.menuItem(id)` finds the menu bar's item whose template had `id`.

| | |
|---|---|
| `setChecked` | checks a checkbox or radio item; a radio item unchecks its group |
| `setEnabled` | grays it out or not |
| `setLabel` | changes its text (macOS) |
| `item.checked`, `item.id` | read it |

To change more, call `setMenu` again with another template. It replaces
the menu bar.

## The menu bar

`app.setMenu(template)` replaces the menu bar:

- **macOS**: the menu bar at the top of the screen, built of NSMenus.
- **Windows**: a menu bar at the top of every window with a title bar,
  built of HMENUs. Windows with a hidden title bar, or frameless, have
  none. Checks and grayed items are refreshed as each menu opens.
- **Linux**: no bar shows; the accelerators work in every window.
- **Browsers**: no bar shows; the accelerators work in the page.

Keys and labels:

- Everywhere, a menu item's accelerator runs the item, in native UI and
  in pages.
- On Windows and Linux, `&` in a label marks its mnemonic (`"&File"`),
  as the standard menus' titles do. `"&&"` is an ampersand. macOS shows
  labels as written.
- On Windows and Linux, a view that sets `c.keys_first` gets key
  combinations before the menu bar's accelerators. It is kept across
  frames. An accelerator runs only when the view doesn't take the keys:
  a terminal with the keyboard keeps Ctrl+L or Ctrl+W for its shell.

## Context menus

A native UI context menu is a widget, `ui.contextMenu`. myzig draws it in
the window's own layer, with keyboard navigation, submenus and checks:
see [Native UI menus](ui/menus.md). Pages show their own, or the
webview's (with Inspect Element while `inspectable` is set).

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
notification area (Windows) or the panel (Linux).

| `myzig.TrayOptions` | |
|---|---|
| `id` | names the icon across launches, unique among the app's icons ([Several icons](#several-icons)) |
| `title` | text next to the icon (macOS's menu bar, Linux panels that show labels); elsewhere the tooltip when there is none |
| `symbol` | an SF Symbol's name (`"star.fill"`), drawn as a template image that follows the menu bar's appearance (macOS) |
| `icon` | a PNG file's bytes (16 or 32 pixels square suit Windows); the app's icon when empty |
| `template` | the icon is black and transparent: macOS tints it to match the menu bar, Windows shows it white on a dark taskbar |
| `tooltip` | shown on hover |
| `menu` | a template, shown on a right click (Windows) or on any click (elsewhere) |
| `on_click` | a `myzig.TrayClick`: a left click on Windows, a click on macOS when there is no menu, a click of a GtkStatusIcon on Linux |
| `on_appearance` | a `myzig.TrayClick` called as the bar under the icon turns dark or light (`tray.dark()`) |

- The icon lives until `app.removeTray(tray)` or the app's end.
- Change it with `setTitle`, `setTooltip`, `setSymbol` (macOS),
  `setIcon(png)` and `setMenu(app.options.name, template)`.
- `popUpMenu()` opens its menu from code (Windows, Linux).

How each platform shows it:

- **macOS**: an NSStatusItem in the menu bar. With a menu, a click opens
  it; without one, a click calls `on_click`.
- **Windows**: a notification area icon. A left click calls `on_click`, a
  right click opens the menu. The first tray icon also shows the app's
  notifications ([Notifications](app.md#notifications)).
- **Linux**: a StatusNotifierItem through libayatana-appindicator, loaded
  with `dlopen`. Panels show its menu on a click. Without the library, a
  GtkStatusIcon (X11 panels with a system tray): a click calls
  `on_click`, a right click opens the menu. A run without a display fails
  with `error.Headless`.
- **Browsers**: `error.Unsupported`.

Apps that live in the tray:

- set `quit_on_last_window_closed = false`, so closing the window leaves
  them running;
- keep a `.quit` item in the tray's menu;
- show a panel under the icon as a flyout anchored to the tray icon
  ([Flyouts](windows.md#flyouts)).

Headless runs (`--myzig-hidden`, `--myzig-eval`) should add no icon:
check `app.flags.hidden` first.

### Several icons

An app may show several icons, as a menu bar app that shows each of its
measures in its own item.

- **macOS**: a new icon goes left of those already there. The user moves
  icons by dragging them with ⌘ held. An icon with an `id` goes back
  where the user put it whenever it is made again, at the next launch or
  after `removeTray`. The `id` is the status item's autosave name.
- **Windows**: the user chooses which icons show on the taskbar rather
  than in its overflow. An icon with an `id` keeps that choice whatever
  order the app makes its icons in. It is numbered by its `id` (FNV-1a,
  with the high bit set), not counted as icons come.
- **Linux**: panels place icons themselves.

### Dark and light bars

A template icon follows the bar by itself. A colored icon, say one that
draws each measure in its own color, picks its ink for the bar:

- `tray.dark()` tells whether the bar is dark.
- `on_appearance` is called on the main thread as the bar turns. Call
  `setIcon` again there.
- **macOS**: the menu bar as AppKit tints its items, by the system's
  appearance or the wallpaper under a translucent bar.
- **Windows**: the taskbar in the system's mode, which may differ from
  the apps' mode.
- **Linux**: panels draw their icon themes their own way, and `dark()`
  is false.

## Global shortcuts

A global shortcut reaches the app while another app is in front, as
launchers do (Spotlight, Raycast, PowerToys Run):

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
`myzig.Handler(void)`, run on the main thread on each press. It returns
the shortcut's id for `unregisterHotkey`. It fails with:

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

Modifiers and a key, joined by `+`:

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

- Names are not case-sensitive.
- On Windows and Linux, ⌘ and Ctrl are both Ctrl. Menus show
  accelerators as those systems write them (`Ctrl+Shift+K`).
- macOS shows them with its symbols.
- In native UI, `ui.keys.label("⌘P")` and `ui.shortcutLabel` write key
  combinations for the platform ([Navigation](ui/navigation.md)).
