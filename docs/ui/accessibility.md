# Accessibility

Assistive technology reads a window of native UI as it reads other apps:
VoiceOver on macOS, Orca on Linux, and Narrator, NVDA or JAWS on Windows.
It sees the widgets with their roles, names, values and states, the
texts, and the elements that take the focus, and hears what changes. It
acts on them as the keyboard and the pointer would: it presses buttons,
checks boxes, moves sliders, replaces the text of text fields and moves
the focus.

| Platform | What myzig speaks | Where |
|---|---|---|
| macOS | NSAccessibility: elements of a runtime subclass of `NSAccessibilityElement` | `src/ui/access_mac.zig` |
| Linux | AT-SPI over D-Bus, in Zig alone (no libatk, no libdbus) | `src/linux/atspi*.zig`, `dbus*.zig` |
| Windows | UI Automation: a fragment root answering `WM_GETOBJECT`, with control patterns | `src/windows/uia*.zig` |
| Browsers | not yet: the canvas is all assistive technology sees | |

None of it costs anything until assistive technology asks for the window.
Until then descriptions are dropped as widgets make them, and no tree is
built. On Linux the app connects to the accessibility bus once the session
says assistive technology is on; `MYZIG_A11Y=1` connects regardless, to try
it.

## How it works

Widgets describe their boxes as they build them, with `c.describe(id,
description)`. Once the frame is laid out, `src/ui/access_tree.zig` turns
the boxes and their descriptions into a tree of elements, each with a
role, a name, a value, states, the actions it takes and its rectangle in
the window. The surface hands that tree to the platform and, after each
frame, compares it with the previous one to tell listeners what changed:
the focus, names, values, states, children, and announcements.

When assistive technology acts on an element, `ui.access.perform` turns
the action into what the keyboard or the pointer would do in the next
frame: pressing clicks, focusing focuses as Tab would, incrementing a
slider presses Right (a stepper, Up), and setting a text field's value
selects all of its text and types the new one, and inserting text into it
(`.insert_text`: macOS's selected text, which dictation, Voice Control and
automation type with) types it over the selection, at the caret without
one. So a widget needs nothing
of its own to be operated: what works with the keyboard works for
assistive technology.

## Names

Widgets name themselves with the text inside them: a button with its
title, a checkbox with its label, a heading with its text. Those without
text take a label in their options:

```zig
_ = ui.slider(c, &s.volume, .{ .label = "Volume" });
_ = ui.textField(c, &s.name, .{ .label = "Name", .placeholder = "Your name" });
```

A button of an icon alone is named by its symbol's name; give it a better
one by describing it after it is built. Descriptions of one box merge, the
fields set last winning:

```zig
const del = ui.button(c, "", .{ .icon = "trash" });
c.describe(del.id, .{ .label = "Delete" });
if (del.clicked) s.deleteSelection();
```

## Roles

Boxes that no widget describes get a role from what they are (`.auto`):
text is text, a box that is clicked and takes the focus is a button, a
scrolling box is a scroll area, and a box with a label or the focus is a
group. Other boxes are left out, their children going to their parent.
`.none` leaves a described box out but keeps its children.

`ui.AccessRole` (`ui.access.Role`) has the roles of myzig's widgets:
`group`, `text`, `button`, `link`, `checkbox`, `radio`, `switch_`,
`slider`, `progress`, `text_field`, `image`, `list`, `list_item`,
`scroll_area`, `dialog`, `alert_dialog`, `popup`, `tooltip`,
`popup_button`, `combo_box`, `tab_list`, `tab`, `tab_panel`, `splitter`,
`status`, `table`, `row`, `cell`, `column_header`, `tree`, `tree_item`,
`menu_button`, `toolbar`, `radio_group`, `toggle_button`, `disclosure`,
`meter`, `stepper`, `color_well`, `menu`, `menu_bar`, `menu_item`,
`menu_item_checkbox`, `menu_item_radio` and `heading`.

A widget of your own, drawn from boxes, says what it is:

```zig
fn wifiSwitch(c: *ui.Context, on: *bool) void {
    const i = c.open(.{ .width = .{ .px = 36 }, .height = .{ .px = 20 }, .radius = 10, .background = if (on.*) c.theme.accent else c.theme.border }, "wifi");
    const it = c.interact(i, .{ .focusable = true, .keys = true });
    c.describe(it.id, .{ .role = .switch_, .label = "Wi-Fi", .checked = if (on.*) .on else .off });
    if (it.clicked) {
        on.* = !on.*;
        c.changed = true;
    }
    c.end();
}
```

`c.describeOpen(description)` describes the innermost box open, for
widgets that hold no id.

## States and values

`ui.AccessDescription` (`ui.access.Description`) carries what a role needs,
as ARIA's states do on the web. Fields left null are found from the box:

| Field | What it tells |
|---|---|
| `label`, `value` | the name, and the value (a text field's text, the choice a popup button shows) |
| `description` | more than the name, read after it: help text, an error |
| `placeholder` | what an empty text field shows |
| `checked` | `.off`, `.on` or `.mixed`: a checkbox, switch, radio, toggle or menu item |
| `expanded`, `expandable`, `has_popup` | whether what the element opens shows, whether it opens with expand and collapse, whether it opens a popup |
| `selected`, `selectable`, `multiselectable` | choice in tabs, lists, trees, radio groups |
| `range` | `.{ .min, .max, .now, .step }` of a slider, progress bar, meter or stepper |
| `level` | a heading's rank, or a tree item's depth, from 1 |
| `pos_in_set`, `set_size` | which of all the items this is, built or not: "5 of 10 000" |
| `active_descendant` | the id of the option that has the focus while this element keeps it (a combobox's highlighted option) |
| `selection` | a text field's selection, in bytes of its value |
| `disabled`, `read_only`, `password`, `multiline`, `invalid`, `vertical`, `modal` | as named; `modal` makes what is behind a dialog inert |

The tree's elements also carry the actions they take (`ui.access.Actions`:
press, focus, increment, decrement, set value, scroll into view, expand),
from their role and states: a disabled button takes none.

## Lists and tables

A virtual [list](lists.md)'s rows say which of all the rows they are,
although the list builds only those in view; a table's rows and cells are
named by the text inside them. Assistive technology moving to an element
out of view asks for `scroll_into_view`, which scrolls the boxes around it.

## Announcements

News that does not move the focus, as a search done or a file saved,
reaches assistive technology with `c.announce(text)`: it reads it once,
after what it is reading (VoiceOver's announcements, AT-SPI's, and a
polite live region on Windows). A frame built again does not announce
twice. [Toasts](overlays.md) are `status` elements, read as they show.

```zig
if (ui.button(c, "Save", .{}).clicked) {
    s.save();
    c.announce("Saved");
}
```

## Testing it

A [Tester](testing.md) builds the same tree, so a test can check what
assistive technology sees and act as it does. Turn descriptions on, run a
frame, and build the tree:

```zig
var t: ui.Tester = undefined;
try t.init(gpa, .init(&app, App.view), .{ .height = 480 });
defer t.deinit();
t.ctx.access.enabled = true;
t.frame();

var tree: ui.AccessTree = .init(gpa);
defer tree.deinit();
tree.build(&t.ctx);

const save = tree.byName(.button, "Save") orelse return error.NoSave;
try std.testing.expect(save.actions.press and save.states.focusable);
const volume = tree.byName(.slider, "Volume").?;
try std.testing.expectEqual(@as(f64, 0.5), volume.range.now);

ui.access.perform(&t.ctx, save.id, save.role, .press);
t.frame();
tree.build(&t.ctx);
try std.testing.expectEqualStrings("Saved", tree.announcements[0]);
```

`tree.find(id)`, `tree.byName(role, name)`, `tree.count(role)` and
`tree.at(point)` find elements; `tree.focus` is the id of the focused one.
`src/ui/tests_access.zig` and `tests_access_widgets.zig` test every widget
this way; `src/linux/atspi_test.zig` and `atspi_bus_test.zig` test the
AT-SPI server, and `src/windows/uia_test.zig` the UI Automation provider.
