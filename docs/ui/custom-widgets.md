# Custom widgets

Every widget of myzig is a Zig function made of the same few pieces a
widget of your own uses: boxes opened on the `ui.Context`, an
interaction read from the last frame's layout, values animated across
frames, and a description for assistive technology. There is no widget
class to extend and no retained object to keep: a widget is a function
of the app's state, called on every frame.

## Boxes

`c.open(style, key)` opens a box styled with a `ui.Style` and returns its
index in this frame's node list; its children follow until `c.end()`.
`c.leaf(style, content, key)` adds a box without children, whose content
is `.none`, a text, an icon or an image (the `ui.text`, `ui.icon` and
`ui.image` widgets make these). `c.node(index)` returns the `*Node`, to
change its style once its state is known (a hover color, a highlight).

```zig
const box = c.open(.{ .direction = .row, .gap = 8, .padding = .xy(10, 6), .radius = 999, .control = true }, null);
defer c.end();
// ... children ...
c.node(box).style.background = c.theme.accent;
```

`ui.row`, `ui.column`, `ui.card` and `ui.div(c)` open boxes too, with a
direction or a look set (see [Views](views.md) and [Layout](layout.md)).
`style.control = true` marks a control: it takes the focus with Tab and
draws a focus ring when the focus came from the keyboard.

## Ids

Every box has an id, which is how state survives from one frame to the
next: its layout, its hover, its animations, its scroll offset, its text
being edited. A box's id comes from its parent's and its place among the
parent's children, or from a key:

- `key` (the last argument of `open` and `leaf`), or `ui.key(c, k)`
  before a widget, names the next box: rows of a list keyed by the item's
  id keep their state when items above them come and go.
- `c.next_key_int = i` does the same with a number.
- `c.peekId(key)` is the id the next child of the open box will get, for
  a widget that must know its id before it opens its box.

### A box that comes or goes moves the ids after it

An id made from a place changes when the place does. A box shown only
sometimes before a button (a mark while the row is hovered, a badge
while something is new) gives the button another id in the frames it
shows, and the box that came takes the button's old one. The press, made
on the id the pointer was over in the last frame, then finds no button
to take it: the click is lost, without an error.

```zig
// The mark comes with the hover, and the button's id goes with it.
if (s.hovered) _ = c.leaf(.{ .width = .{ .px = 3 } }, .none, null);
const it = ui.button(c, project.name, .{});
s.hovered = it.hovered;
```

Either keep the ids still:

- key the button (`c.keyed(project)` or `ui.key(c, project.path)` before
  it): a keyed id does not depend on its place, or
- always build the box before it, and hide it with its look instead (a
  transparent background, a width of 0), so the places stay.

Debug builds tell of it: when no box answers to the id pressed while the
pointer is still where that box was, and the box now under the pointer
was not there the frame before, the log says once
`myzig: the box pressed changed its id between frames (a box before it
came or went?)`. Release builds don't check.

Strings given to boxes are kept until the frame is drawn, after the view
returns: pass the app's own memory or the frame's (`c.print`,
`c.alloc()`), never a buffer on the stack.

## Interactions

`c.interact(index, opts)` tells how the pointer and the keyboard relate
to the box `index`, from the last frame's layout, and makes it take the
pointer. It returns a `ui.Interaction`:

| Field | |
|---|---|
| `id` | the box's id |
| `rect` | where it was in the last frame, null in its first |
| `hovered` | the pointer is over it, or over a box inside it, as CSS's `:hover` |
| `pressed` | held down: pressed on it and not yet released |
| `clicked` | pressed and released on it, or pressed with a key or by assistive technology |
| `double_clicked` | the second click of a double click (it is a click too) |
| `focused` | it has the keyboard focus |

With `.focusable = true` the box takes the focus when pressed and joins
Tab's order; with `.keys = true`, Enter and Space click it while it has
the focus, as they do a button or a checkbox. Presses go to the topmost
interactive box under the pointer alone; hover goes to the boxes it is in
too.

`ui.pressable(c, style, hover_color)` opens a box and interacts with it,
with the focus ring of a control and, given a color, a background that
eases toward it while hovered. Most widgets start there.

## State changes

A widget whose interaction changes the app's state sets `c.changed`.
The frame is then built again before it is drawn, so the screen never
lags the state: a checkbox clicked shows checked in the same frame.
Widgets take the app's values by pointer (`*bool`, `*usize`, `*f32`) and
return what happened, `clicked`, `changed`, `submitted`, as the
built-in ones do.

## Animated values

`c.animate(id, salt, target, speed)` moves a number kept for the box `id`
toward `target` at `speed` (larger is faster) and returns its value now:
a hover's fade, a switch's knob, a disclosure opening. `salt` tells
several values of one box apart. While a value has not reached its
target, the window draws another frame; once all have, it stops: nothing
polls.

```zig
const t = c.animate(it.id, 0, if (on.*) 1 else 0, 16);
c.node(track).style.background = c.theme.track.mix(c.theme.success, t);
```

For springs, keyframes, timelines and transitions of their own, see
[Motion](motion.md). `c.frameIn(seconds)` asks for a frame within that
many seconds (a spinner's next step, a clock's second), and
`c.animationFrame()` for one as soon as the display can show it, for
views that animate from `c.time` every frame. `c.dt` is the time since
the last frame and `c.time` the seconds since the first: the context's
clock, which the Tester advances in tests.

`ui.overlays.memo(c, id, salt, default)` keeps any number for a box
across frames (a drag's grab offset, the time a tip started), forgotten a
while after the box is gone.

## Input

`c.input` is this event's input: the pointer (`mouse`, `down`,
`pressed`, `released`, `click_count`, and `right_pressed` and
`middle_pressed` for the other buttons), the modifiers, the key (`key`,
`shortcut`) and the text typed (`chars`). A widget that answers a key
takes it, so that what is built later does not see it too:
`c.shortcut(...)` takes a key combination, and `ui.overlays.takeKey(c, k)`
a plain key. Text input of your own (an editor of a kind myzig lacks)
reads `ui.TextOp`s; see [Text input](text-input.md).

Set `c.wants_moves` while the view follows the pointer inside one box (a
graph's crosshair), `c.wants_wheel` to take the wheel where nothing
scrolls, and `c.wants_keys` to receive keys going down and up
(`input.key_down`, `input.key_up`), for games. `c.cursor` asks for a
cursor over what the widgets set (`.arrow`, `.hand`, `.text`,
`.resize_left_right`, `.resize_up_down`).

## Accessibility

`c.describe(id, description)` tells assistive technology what the box
is: its role, its label, its value, whether it is checked, expanded,
selected or disabled. Built-in widgets describe themselves; a widget of
your own should too:

```zig
c.describe(it.id, .{ .role = .switch_, .label = title, .checked = if (on.*) .on else .off });
```

See [Accessibility](accessibility.md) for the roles and the rest of
`ui.AccessDescription`.

## A widget of your own

A pill that toggles a `*bool`, in the accent color while on, focusable,
pressed by Enter and Space, eased, and described as a toggle button:

```zig
const ui = @import("myzig").ui;

pub fn pill(c: *ui.Context, title: []const u8, on: *bool) bool {
    const th = c.theme;
    const box = c.open(.{ .direction = .row, .gap = 6, .padding = .xy(12, 5), .radius = 999, .border = th.border, .control = true }, null);
    defer c.end();
    const it = c.interact(box, .{ .focusable = true, .keys = true });
    if (it.clicked) {
        on.* = !on.*;
        c.changed = true;
    }
    c.describe(it.id, .{ .role = .toggle_button, .label = title, .checked = if (on.*) .on else .off });
    const t = c.animate(it.id, 0, if (on.*) 1 else 0, 18);
    const hover = c.animate(it.id, 1, if (it.hovered) 1 else 0, 20);
    const n = c.node(box);
    n.style.background = th.surface.mix(th.surface_hover, hover).mix(th.accent, t);
    if (it.focused and c.focus_visible) n.style.border = th.accent;
    ui.text(c, title, .{ .size = 13, .weight = .medium, .color = th.text.mix(th.accent_text, t) });
    return it.clicked;
}
```

Use it as any other: `if (pill(c, "Wrap", &s.wrap)) s.relayout();`, and
test it with the Tester: `try t.clickText("Wrap")` (see
[Testing](testing.md)).

## Widgets without a look

Some widgets have a variant without a look of their own, which handles
the pointer, the keyboard and the focus and leaves the colors and shapes
to you:

| Without a look | |
|---|---|
| `ui.popover(..., .{ .bare = true })` | style the panel with `Panel.style()` ([Overlays](overlays.md)) |
| `ui.dialog(..., .{ .bare = true })` | `Dialog.backdropStyle()` and `Dialog.panelStyle()` |
| `ui.tooltipBase`, `ui.tooltipEnd` | a tip of your own beside an element |
| `ui.textField(..., .{ .bare = true })` | a field without border, fill or focus ring, inside a frame of yours (a chat composer) |
| `ui.textArea(..., .{ .bare = true })` | the same for multi-line text ([Text area](text-area.md)) |
| `ui.richTextEditorBase` | the rich text editor without its box ([Rich text](rich-text.md)) |
| `ui.shaderBox` | a box drawn by a shader of yours ([Shaders](shaders.md)) |

For menus, selects and other overlays of your own, the pieces in
`ui.overlays` place a panel beside its anchor, close it for a press
outside and give the focus back (see
[Overlays](overlays.md#building-overlays-of-your-own)). The rows, lists
and choices helpers in `src/ui/structure.zig` (moving a choice with the
arrows, Home, End and Page keys; choosing by typed prefix; row colors)
are what the built-in lists use.

## Theme

`c.theme` is the window's `ui.Theme`: `background`, `surface`,
`surface_hover`, `text`, `muted`, `border`, `accent`, `accent_hover`,
`accent_text`, `track`, `knob`, `danger`, `success`, `shadow`, and
`dark`. Draw with its colors, not fixed ones, so that a widget follows
light and dark and the app's own theme (see [Styling](styling.md)).
