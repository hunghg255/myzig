# Navigation, actions and focus

How the user moves through an app of native UI: pages with a history
(the router), back and forward buttons, the commands of the app offered
as key combinations, menu items and buttons at once (actions), and the
keyboard's focus: Tab, focus groups and handles that move the focus from
code.

## The router

`ui.Router` keeps the history of the pages of a window, or of a part of
one, as a browser keeps a tab's, after mygo's `ui.Router`. A page is a
path, as `/notes/42`, which the view matches to build the page shown:

```zig
const Notes = struct {
    router: ui.Router = .init("/notes"),

    fn view(s: *Notes, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        ui.row(c, .{ .gap = 8, .padding = .all(4), .align_items = .center });
        _ = s.router.historyButtons(c);
        ui.text(c, s.router.title(), .{ .weight = .semibold });
        ui.end(c);

        var pages = s.router.pages(c, .{});
        while (pages.next()) |r| {
            defer r.end();
            if (r.match("/notes")) {
                r.title("Notes");
                if (ui.button(c, "Open 42", .{}).clicked) s.router.push("/notes/42");
            } else if (r.match("/notes/{id}")) {
                r.title("Note");
                ui.text(c, c.print("Note {s}", .{r.param("id")}), .{});
            } else ui.text(c, "Not found", .{});
        }
        pages.end();
    }
};
```

`Router.pages(c, opts)` opens the router's box, where its pages show (all
the room it is given, by default). `next()` returns a `*ui.Route` for each
page to build: the page shown, and while a transition runs, the page
going away, which is drawn but takes neither the pointer nor Tab
(`r.leaving` is true for it). Build each page's content, then `r.end()`;
after the last, `pages.end()`.

### Matching paths

`Route.match(pattern)` is true when the page's path matches `pattern`,
whose parts between slashes are the path's own or wildcards: `{name}`
takes one part, `{name...}` (at the end) the rest, which may be empty. A
slash at the end makes no difference. `param(name)` is what a wildcard of
the last match took (`""` if none), and `query(name)` the value of a
query parameter (`/notes/42?tab=info`).

`title(t)` names the page, for history lists and `Router.title()`.

`nested()` returns the route of the rest of the path that the last
match's `{name...}` took, for a layout around pages of its own: `/fonts`
of `/settings/fonts` after `match("/settings/{section...}")`:

```zig
} else if (r.match("/settings/{section...}")) {
    s.settingsSidebar(c);
    var inner = r.nested();
    if (inner.match("/fonts")) s.fonts(c) else s.general(c);
}
```

### Going places

- `push(target)` goes to a page after the page shown, forgetting the
  pages after it. Going to the page shown does nothing.
- `replace(target)` shows a page in place of the page shown: back does not
  return to the page replaced.
- `back()`, `forward()` and `go(n)` move through the history, as far as it
  goes; `canGoBack()` and `canGoForward()` tell whether they can.

Targets relative to the page shown resolve as links in a web page do:
`push("edit")` from `/notes/42` goes to `/notes/edit`, `push("..")` up a
level, and `push("?tab=info")` changes the query alone. A path with
another query is the same page, which keeps its state.

`path()` is the path of the page shown, `location()` its path and query
(what `push` and `replace` take, to show it again when the app starts),
`query(name)` a parameter of its query, and `entry(n)` the entry `n`
pages back (negative) or forward, for a list of pages to go to by their
titles. The history keeps the last 50 entries, of locations up to 256
bytes.

A page keeps the state of its boxes (scroll offsets, text being edited,
animations) while it is in the history, and the keyboard focus it had is
given back as it shows again.

### Transitions and keys

A page deeper in the paths (`/notes/42` after `/notes`) slides in from the
end over the page it leaves, and back; others fade in. With less motion
asked for (see [Motion](motion.md)), all fade. The router's fields
`transition` (`.auto`, `.fade` or `.none`), `slide_seconds` (0.25),
`fade_seconds` (0.15) and `ease` change that.

Cmd+[ and Cmd+] on macOS, Alt+Left and Alt+Right elsewhere go back and
forward. `ui.RouterOptions` has `style`, the router's box, and `keys`
(true): a router inside a page of another leaves the keys to the outer
one with `.keys = false`.

## Back and forward buttons

`Router.historyButtons(c)` draws a back and a forward button for a
router, disabled at the ends of its history, and returns true when they
moved it. For a history of your own, `ui.historyButtons(c, opts)` draws
them and returns a `ui.HistoryAction` (`.none`, `.back` or `.forward`):

```zig
switch (ui.historyButtons(c, .{ .can_back = s.at > 0, .can_forward = s.at + 1 < s.visited.len })) {
    .back => s.at -= 1,
    .forward => s.at += 1,
    .none => {},
}
```

`ui.HistoryOptions` has `can_back`, `can_forward`, and `shortcuts` (true:
it also takes the keys that go back and forward).

## Actions

`ui.Actions(E)` names the commands of an app once, one per tag of the
enum `E`, with their title, key combination, icon and state, and offers
them wherever they show: as key combinations, menu items (with their
shortcut shown, and grayed out while disabled) and buttons. What chose
an action does not matter to the app, which answers one `switch`:

```zig
const Cmd = enum { new, save, wrap };

const Editor = struct {
    acts: ui.Actions(Cmd) = .init(.{
        .new = .{ .title = "New", .shortcut = .{ .key = 'n', .cmd = true } },
        .save = .{ .title = "Save", .shortcut = .{ .key = 's', .cmd = true } },
        .wrap = .{ .title = "Wrap Lines", .checked = false },
    }),
    file_menu: ui.Menu = .{},
    dirty: bool = false,
    wrap: bool = false,

    fn run(s: *Editor, cmd: Cmd) void {
        switch (cmd) {
            .new => s.newDocument(),
            .save => s.save(),
            .wrap => s.wrap = !s.wrap,
        }
    }

    fn view(s: *Editor, c: *ui.Context) void {
        s.acts.setEnabled(.save, s.dirty);
        s.acts.setChecked(.wrap, s.wrap);
        if (s.acts.button(c, .save, .{})) s.run(.save);
        if (ui.menuButton(c, "File", &s.file_menu, .{})) |m| {
            defer m.end();
            inline for (.{ Cmd.new, Cmd.save, Cmd.wrap }) |cmd| if (s.acts.menuItem(m, cmd)) s.run(cmd);
        }
        if (s.acts.shortcuts(c)) |cmd| s.run(cmd);
    }
};
```

A `ui.Action` has `title`, `shortcut` (a `ui.Shortcut`, or null), `icon`,
`enabled` (true) and `checked` (null: no check mark; true or false: a
check mark or room for one in menus).

- `shortcuts(c)` returns the enabled action whose key combination this
  event is, and takes it. Call it after the widgets that take keys (a
  focused field's own ⌘A comes first).
- `menuItem(panel, e)` adds the action's item to an open menu, with its
  key combination shown, true in the frame it is chosen.
- `button(c, e, opts)` is a button for it, disabled with it, with its
  icon unless `opts` gives one.
- `get(e)` returns the `*Action`; `setEnabled(e, on)` and
  `setChecked(e, on)` change its state for every place it shows. `last`
  is the action chosen last.

The app's menu bar is the system's, built from templates (see
[Menus](../menus.md)); actions are for the menus, buttons and keys drawn
in the window.

## Key combinations

`c.shortcut(.{ .key = 'k', .cmd = true })` is true when this event is
that combination, and takes it, so nothing built later sees it. A
`ui.Shortcut` has `key` (a code point: `'k'`, or `ui.Shortcut.up`,
`.down`, `.left`, `.right`, `.escape`, `.tab`, `.enter`) and the
modifiers `cmd`, `ctrl`, `alt` and `shift`. Write Command shortcuts with
`cmd`: they are Control ones on Linux, Windows and in browsers, where
there is no Command key (`Shortcut.native()`).

To show a combination as the platform writes it, `ui.shortcutLabel(c,
shortcut)` writes a `ui.Shortcut` (`⇧⌘S` on the Mac, `Ctrl+Shift+S`
elsewhere) in the frame's memory, and `ui.keys.label("⇧⌘S")` does the
same at compile time for a string written with the Mac's symbols.
`ui.keys.mac` is true where the command key is Command.

## The keyboard's focus

Controls that take the focus do so when pressed, and with Tab, in the
order they are built; Shift+Tab goes back. A focused control draws a
ring in the accent color when the focus came from the keyboard, not
from a press (`c.focus_visible`). `c.focus` is the id of the focused box
(0 for none), and an `Interaction`'s `focused` tells a widget whether it
has it. Escape in a dialog or a popover goes to what is inside first,
and the focus comes back to what opened them as they close.

### Focus groups

`ui.focusGroup(c, style, opts)` makes the controls inside its box one
stop of Tab, as a toolbar's, a radio group's or a tab list's are. Tab
goes into the group to the control that had the focus there last (else
the one `entry` names, else the first) and on out of it; the arrows of
its orientation move the focus among its controls, around from the last
to the first, and Home and End to the first and the last (a roving
focus). Right to left, Left goes to the next one.

```zig
var g = ui.focusGroup(c, .{ .direction = .row, .gap = 4 }, .{});
if (ui.button(c, "Bold", .{}).clicked) s.bold = !s.bold;
if (ui.button(c, "Italic", .{}).clicked) s.italic = !s.italic;
if (ui.button(c, "Underline", .{}).clicked) s.underline = !s.underline;
_ = g.end();
```

`ui.FocusGroupOptions` has `orientation` (`.horizontal`, `.vertical` or
`.both`), `entry` (the control Tab enters at when none had the focus
yet, by its place in the group) and `wrap` (true). `end()` returns a
`ui.FocusGroupResult`: `moved`, the control the arrows moved the focus to
in this frame (a radio group chooses it), `focused`, the control with
the focus, and `count`. A control inside that takes the arrows itself
(a text field) takes them first.

### Handles

A `ui.Handle` is a control known to the app across frames, to move the
focus to it from code: a search field focused by ⌘F, the first field of
a form that opens. Bind it to the control's interaction every frame; a
request made before the control shows waits for it:

```zig
// In the app's state: search: ui.Handle = .{},

const it = ui.button(c, "Find", .{});
s.search.bind(c, it);
if (c.shortcut(.{ .key = 'f', .cmd = true })) s.search.focus();
```

`bindId(c, id)` binds a box by its id, `cancelFocus()` drops a request
not yet answered, `focused(c)` tells whether the control has the focus,
and `shown(c)` whether it was built in the last frame. The handle's
`visible` field (true) draws the focus ring, as Tab would.
