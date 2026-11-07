# Navigation, actions and focus

How the user moves through an app of native UI:

- pages with a history (the router), with back and forward buttons;
- the app's commands, offered at once as key combinations, menu items and
  buttons (actions);
- the keyboard's focus: Tab, focus groups, and handles that move the focus
  from code.

## The router

`ui.Router` keeps the history of a window's pages, or of a part of one,
as a browser keeps a tab's. It follows mygo's `ui.Router`. A page is a
path, such as `/notes/42`, which the view matches to build the page:

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

- `Router.pages(c, opts)` opens the router's box, where its pages show.
- `next()` returns a `*ui.Route` for each page to build: the page shown,
  and the page going away while a transition runs.
- The page going away is drawn but takes neither the pointer nor Tab
  (`r.leaving`).
- End each page with `r.end()`, and the last with `pages.end()`.

### Matching paths

`Route.match(pattern)` is true when the page's path matches `pattern`,
part by part between slashes:

| Part | Takes |
|---|---|
| `notes` | that part of the path |
| `{name}` | one part |
| `{name...}` | at the end: the rest, which may be empty |

- A slash at the end makes no difference.
- `param(name)` is what a wildcard of the last match took, `""` if none.
- `query(name)` is the value of a query parameter, as in
  `/notes/42?tab=info`.
- `title(t)` names the page, for history lists and `Router.title()`.

`nested()` returns the route of the rest that the last match's
`{name...}` took, for a layout around pages of its own. After
`match("/settings/{section...}")`, `/settings/fonts` nests `/fonts`:

```zig
} else if (r.match("/settings/{section...}")) {
    s.settingsSidebar(c);
    var inner = r.nested();
    if (inner.match("/fonts")) s.fonts(c) else s.general(c);
}
```

### Going places

| Call | |
|---|---|
| `push(target)` | goes to a page after the one shown, forgetting the pages after it; to the page shown, does nothing |
| `replace(target)` | replaces the page shown; back does not return to it |
| `back()`, `forward()`, `go(n)` | move through the history, as far as it goes |
| `canGoBack()`, `canGoForward()` | whether they can |

Relative targets resolve as links in a web page do:

- `push("edit")` from `/notes/42` goes to `/notes/edit`;
- `push("..")` goes up a level;
- `push("?tab=info")` changes the query alone.

A path with another query is the same page, which keeps its state.

| Read | |
|---|---|
| `path()` | the page shown's path |
| `location()` | its path and query, for `push` or `replace` when the app starts again |
| `query(name)` | a parameter of its query |
| `entry(n)` | the entry `n` pages back (negative) or forward, for a list of pages by title |

- The history keeps the last 50 entries, of locations up to 256 bytes.
- A page in the history keeps its boxes' state: scroll offsets, text
  being edited, animations. It gets its keyboard focus back when it shows
  again.

### Transitions and keys

- A deeper page (`/notes/42` after `/notes`) slides in from the end over
  the page it leaves, and back out. Others fade in.
- With less motion asked for, all fade (see [Motion](motion.md)).
- Cmd+[ and Cmd+] on macOS, Alt+Left and Alt+Right elsewhere, go back and
  forward.

| `ui.Router` field | Default | |
|---|---|---|
| `transition` | `.auto` | `.auto`, `.fade` or `.none` |
| `slide_seconds` | 0.25 | |
| `fade_seconds` | 0.15 | |
| `ease` | `.ease_out` | the curve |

| `ui.RouterOptions` | Default | |
|---|---|---|
| `style` | fills the room | the router's box |
| `keys` | `true` | takes the back and forward keys; `false` in a router inside another's page |

## Back and forward buttons

`Router.historyButtons(c)` draws a back and a forward button, disabled at
the ends of the history. It returns true when they moved the router.

For a history of your own, `ui.historyButtons(c, opts)` draws them and
returns a `ui.HistoryAction`: `.none`, `.back` or `.forward`.

```zig
switch (ui.historyButtons(c, .{ .can_back = s.at > 0, .can_forward = s.at + 1 < s.visited.len })) {
    .back => s.at -= 1,
    .forward => s.at += 1,
    .none => {},
}
```

| `ui.HistoryOptions` | Default | |
|---|---|---|
| `can_back`, `can_forward` | | whether each button is enabled |
| `shortcuts` | `true` | also takes the keys that go back and forward |

## Actions

`ui.Actions(E)` names the app's commands once, one per tag of the enum
`E`, with a title, key combination, icon and state. They show as key
combinations, menu items and buttons. Whatever chose an action, the app
answers one `switch`:

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

| `ui.Action` | Default | |
|---|---|---|
| `title` | | |
| `shortcut` | `null` | a `ui.Shortcut` |
| `icon` | `""` | for its menu item and button |
| `enabled` | `true` | |
| `checked` | `null` | no check mark; true or false: a check mark, or room for one, in menus |

| Call | |
|---|---|
| `shortcuts(c)` | returns the enabled action whose key combination this event is, and takes it |
| `menuItem(panel, e)` | adds its item to an open menu, with its shortcut, grayed out while disabled; true in the frame it is chosen |
| `button(c, e, opts)` | a button for it, disabled with it, with its icon unless `opts` gives one |
| `get(e)` | the `*Action` |
| `setEnabled(e, on)`, `setChecked(e, on)` | change its state everywhere it shows |
| `last` | the action chosen last |

Call `shortcuts(c)` after the widgets that take keys: a focused field's
own ⌘A comes first.

Actions are for the menus, buttons and keys drawn in the window. The
app's menu bar is the system's, built from templates (see
[Menus](../menus.md)).

## Key combinations

`c.shortcut(.{ .key = 'k', .cmd = true })` is true when this event is that
combination. It takes the event, so nothing built later sees it.

| `ui.Shortcut` | |
|---|---|
| `key` | a code point: `'k'`, or `ui.Shortcut.up`, `.down`, `.left`, `.right`, `.escape`, `.tab`, `.enter` |
| `cmd`, `ctrl`, `alt`, `shift` | the modifiers |

Write Command shortcuts with `cmd`. On Linux, Windows and in browsers
there is no Command key, so they are Control ones there
(`Shortcut.native()`).

To show a combination as the platform writes it:

- `ui.shortcutLabel(c, shortcut)` writes a `ui.Shortcut` in the frame's
  memory: `⇧⌘S` on the Mac, `Ctrl+Shift+S` elsewhere.
- `ui.keys.label("⇧⌘S")` does the same at compile time, for a string
  written with the Mac's symbols.
- `ui.keys.mac` is true where the command key is Command.

## The keyboard's focus

- Controls that take the focus do so when pressed, and with Tab, in the
  order they are built. Shift+Tab goes back.
- A focused control draws a ring in the accent color when the focus came
  from the keyboard, not from a press (`c.focus_visible`).
- `c.focus` is the id of the focused box, 0 for none. An `Interaction`'s
  `focused` tells a widget whether it has it.
- Escape in a dialog or a popover goes to what is inside first. The focus
  comes back to what opened them as they close.

### Focus groups

```zig
var g = ui.focusGroup(c, .{ .direction = .row, .gap = 4 }, .{});
if (ui.button(c, "Bold", .{}).clicked) s.bold = !s.bold;
if (ui.button(c, "Italic", .{}).clicked) s.italic = !s.italic;
if (ui.button(c, "Underline", .{}).clicked) s.underline = !s.underline;
_ = g.end();
```

`ui.focusGroup(c, style, opts)` makes the controls inside its box one Tab
stop, as in a toolbar, a radio group or a tab list (a roving focus):

- Tab enters at the control focused there last, else at `entry`, else
  at the first. The next Tab leaves the group.
- The arrows of its orientation move the focus among its controls, around
  from the last to the first.
- Home and End go to the first and the last.
- Right to left, Left goes to the next one.
- A control inside that takes the arrows itself, such as a text field,
  takes them first.

| `ui.FocusGroupOptions` | Default | |
|---|---|---|
| `orientation` | `.horizontal` | `.horizontal`, `.vertical` or `.both` |
| `entry` | `null` | where Tab enters when none had the focus yet, by its place in the group |
| `wrap` | `true` | the arrows go around |

`end()` returns a `ui.FocusGroupResult`:

| Field | |
|---|---|
| `moved` | the control the arrows moved the focus to in this frame; a radio group chooses it |
| `focused` | the control with the focus |
| `count` | how many controls take the focus in it |

### Handles

A `ui.Handle` names a control across frames, to focus it from code: a
search field on ⌘F, the first field of a form that opens.

```zig
// In the app's state: search: ui.Handle = .{},

const it = ui.button(c, "Find", .{});
s.search.bind(c, it);
if (c.shortcut(.{ .key = 'f', .cmd = true })) s.search.focus();
```

Bind it to the control's interaction every frame. A request made before
the control shows waits for it.

| Call | |
|---|---|
| `bindId(c, id)` | binds a box by its id |
| `cancelFocus()` | drops a request not yet answered |
| `focused(c)` | whether the control has the focus |
| `shown(c)` | whether it was built in the last frame |
| `visible` | field, `true`: draws the focus ring, as Tab would |
