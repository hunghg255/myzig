//! Accessibility: what assistive technology (VoiceOver, Narrator, NVDA,
//! Orca) reads of native UI, and what it does to it. Widgets describe
//! their boxes as they build them (`c.describe(id, .{ .role = .switch_ })`);
//! once a frame is laid out, `access_tree.zig` turns the boxes into a tree
//! of roles, names, values and states, which the surface shows the
//! platform (UI Automation, AT-SPI, NSAccessibility). Assistive technology
//! acts on it as the keyboard and the pointer would (`perform`): pressing
//! clicks, focusing focuses, incrementing presses an arrow key, setting a
//! text field's value replaces its text.
//!
//! None of it costs anything until assistive technology asks for the
//! window: descriptions are dropped while `State.enabled` is off, and no
//! tree is built.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

/// What an element is to assistive technology. Widgets set their own;
/// other boxes get one from what they are (`auto`): text is text, a box
/// that is clicked and takes the focus a button, a scrolling box a scroll
/// area, a box with a label or the focus a group, and the rest are left
/// out, their children going to their parent.
pub const Role = enum(u8) {
    auto,
    /// Leaves the box out, but not its children.
    none,
    group,
    text,
    button,
    link,
    checkbox,
    radio,
    switch_,
    slider,
    progress,
    text_field,
    image,
    list,
    list_item,
    scroll_area,
    dialog,
    alert_dialog,
    popup,
    tooltip,
    /// A button showing a choice, which opens a popup of the others (a select).
    popup_button,
    /// A text field with a popup of options, expanded while it shows.
    combo_box,
    tab_list,
    tab,
    tab_panel,
    splitter,
    /// News shown without the focus moving (a toast): a polite live region.
    status,
    table,
    row,
    cell,
    column_header,
    tree,
    tree_item,
    menu_button,
    toolbar,
    radio_group,
    /// A button that stays pressed while `checked`.
    toggle_button,
    /// A button showing or hiding what is below it, `expanded` while it shows.
    disclosure,
    meter,
    /// Steps a value in a range, as a spin button.
    stepper,
    color_well,
    menu,
    menu_bar,
    menu_item,
    menu_item_checkbox,
    menu_item_radio,
    /// The title of a section, ranked by `level` (1 the highest).
    heading,

    /// Whether elements of the role have a value in a range.
    pub fn ranged(r: Role) bool {
        return r == .slider or r == .progress or r == .meter or r == .stepper;
    }

    /// Whether elements of the role are named by the text inside them,
    /// rather than showing it as elements of their own.
    pub fn leaf(r: Role) bool {
        return switch (r) {
            .group, .list, .scroll_area, .dialog, .alert_dialog, .popup, .status, .tab_list, .tab_panel, .table, .row, .cell, .tree, .list_item, .toolbar, .radio_group, .menu, .menu_bar => false,
            else => true,
        };
    }

    /// Whether elements of the role take their name from their content
    /// while still showing it (a row, a list's item, a toast).
    pub fn namedByContent(r: Role) bool {
        return r.leaf() or r == .list_item or r == .row or r == .status or r == .cell;
    }
};

pub const Checked = enum(u2) { off, on, mixed };

/// The states of an element of the tree.
pub const States = packed struct(u32) {
    focusable: bool = false,
    focused: bool = false,
    disabled: bool = false,
    /// On: a checkbox, a switch, a radio button, a toggle, a menu item.
    checked: bool = false,
    /// Partly on: a checkbox over a group whose boxes differ.
    mixed: bool = false,
    /// Chosen: a tab, a list's row, a tree's item, a radio button.
    selected: bool = false,
    /// Can be chosen (by pressing or focusing it).
    selectable: bool = false,
    expanded: bool = false,
    /// Has something to show or hide (an item of a tree with children).
    expandable: bool = false,
    multiline: bool = false,
    password: bool = false,
    read_only: bool = false,
    /// Built but out of view (scrolled away, clipped).
    offscreen: bool = false,
    multiselectable: bool = false,
    invalid: bool = false,
    vertical: bool = false,
    /// A popup shows what the element opens (a menu, a list of options).
    has_popup: bool = false,
    modal: bool = false,
    _pad: u14 = 0,
};

/// What an element does when assistive technology asks.
pub const Actions = packed struct(u8) {
    press: bool = false,
    focus: bool = false,
    increment: bool = false,
    decrement: bool = false,
    set_value: bool = false,
    scroll_into_view: bool = false,
    expand: bool = false,
    /// Moves the caret and the selection of its text (`Action.select_text`).
    select_text: bool = false,
};

/// An action of assistive technology on an element (`perform`).
pub const Action = union(enum) {
    press,
    focus,
    increment,
    decrement,
    /// Replaces a text field's text.
    set_value: []const u8,
    scroll_into_view,
    expand,
    collapse,
    /// Selects bytes of a text's value from an anchor to the caret
    /// (equal: moves the caret), as the pointer would.
    select_text: [2]u32,
    /// Types text over a text field's selection, at the caret when nothing
    /// is selected: how dictation, Voice Control and automation insert
    /// text (macOS's kAXSelectedText).
    insert_text: []const u8,
};

/// A row of text as drawn, for assistive technology's ranges: bytes
/// [start, end) of the element's value, the row's box, and the x of each
/// byte from the box's left (`xs.len == end - start + 1`; the bytes inside
/// a character repeat the next one's). Widgets give the box from their
/// own box's top left; the tree, from the window's.
pub const TextRow = struct {
    start: u32,
    end: u32,
    rect: types.Rect,
    xs: []const f32 = &.{},

    /// The x of byte `at` of the row, from the window's left.
    pub fn xOf(r: TextRow, at: usize) f32 {
        const i = @min(at, r.end) -| r.start;
        if (r.xs.len == 0) {
            const n: f32 = @floatFromInt(@max(1, r.end - r.start));
            return r.rect.x + r.rect.w * @as(f32, @floatFromInt(i)) / n;
        }
        return r.rect.x + r.xs[@min(i, r.xs.len - 1)];
    }
};

pub const Range = struct {
    min: f64 = 0,
    max: f64 = 1,
    now: f64 = 0,
    /// How far an increment moves the value; 0 for a hundredth of the range.
    step: f64 = 0,
};

/// What a widget tells assistive technology about one of its boxes
/// (`describe`). Fields left null are found from the box.
pub const Description = struct {
    role: Role = .auto,
    /// Names it; null takes the text inside (for roles that take it).
    label: ?[]const u8 = null,
    /// Its value: a text field's text, the choice a popup button shows.
    value: ?[]const u8 = null,
    /// Tells more than the name, read after it (help text, an error).
    description: []const u8 = "",
    /// What an empty text field shows.
    placeholder: []const u8 = "",
    checked: ?Checked = null,
    expanded: ?bool = null,
    selected: ?bool = null,
    disabled: bool = false,
    range: ?Range = null,
    /// A heading's rank or a tree item's depth, from 1; 0 for none.
    level: u32 = 0,
    /// The place of an item in its set from 1, and the set's size: a
    /// list's rows say which of all they are, built or not.
    pos_in_set: u32 = 0,
    set_size: u32 = 0,
    /// The id of the option that has the focus while this element keeps
    /// it (the one the arrows are on in a combobox's popup).
    active_descendant: u64 = 0,
    /// A text field's selection, in bytes of its value: the anchor, then
    /// the caret.
    selection: ?[2]u32 = null,
    /// Where its text is drawn, for a text's ranges (`TextRow`): the rows
    /// in view, in the frame's memory. None: the whole box holds it.
    rows: []const TextRow = &.{},
    /// Behind it is inert while it shows: a dialog.
    modal: bool = false,
    multiline: bool = false,
    password: bool = false,
    read_only: bool = false,
    selectable: bool = false,
    multiselectable: bool = false,
    invalid: bool = false,
    vertical: bool = false,
    has_popup: bool = false,
    /// Opens and closes with `expand` and `collapse` (rather than press).
    expandable: bool = false,

    /// `d`'s fields over `base`'s, where set.
    fn over(base: Description, d: Description) Description {
        var r = base;
        if (d.role != .auto) r.role = d.role;
        if (d.label) |v| r.label = v;
        if (d.value) |v| r.value = v;
        if (d.description.len > 0) r.description = d.description;
        if (d.placeholder.len > 0) r.placeholder = d.placeholder;
        if (d.checked) |v| r.checked = v;
        if (d.expanded) |v| r.expanded = v;
        if (d.selected) |v| r.selected = v;
        if (d.range) |v| r.range = v;
        if (d.level != 0) r.level = d.level;
        if (d.set_size != 0) {
            r.pos_in_set = d.pos_in_set;
            r.set_size = d.set_size;
        }
        if (d.active_descendant != 0) r.active_descendant = d.active_descendant;
        if (d.selection) |v| r.selection = v;
        if (d.rows.len > 0) r.rows = d.rows;
        inline for (.{ "disabled", "modal", "multiline", "password", "read_only", "selectable", "multiselectable", "invalid", "vertical", "has_popup", "expandable" }) |f|
            @field(r, f) = @field(r, f) or @field(d, f);
        return r;
    }
};

/// The context's part: descriptions of this frame, announcements, and
/// the action assistive technology asked for, done by the next frame.
pub const State = struct {
    /// Assistive technology asked for the window: frames are described.
    enabled: bool = false,
    described: std.AutoHashMapUnmanaged(u64, Description) = .empty,
    /// Texts to read once, after what is being read (`announce`), until
    /// the surface takes them.
    announcements: std.ArrayList([]u8) = .empty,
    /// The box to click in the next frame (`perform(.press)`).
    press: u64 = 0,
    /// The box to open (or close) in the next frame, by a widget that
    /// asks `expandRequest`.
    expand: u64 = 0,
    expand_open: bool = false,
    /// The text whose selection to set in the next frame (`selectRequest`).
    select: u64 = 0,
    select_range: [2]u32 = .{ 0, 0 },
    /// A text field's new text, given as operations of the next frame.
    set_text: std.ArrayList(u8) = .empty,
    ops: [2]ctx_mod.TextOp = undefined,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.described.deinit(gpa);
        for (s.announcements.items) |a| gpa.free(a);
        s.announcements.deinit(gpa);
        s.set_text.deinit(gpa);
    }

    /// A frame starts: last frame's descriptions go.
    pub fn begin(s: *State) void {
        s.described.clearRetainingCapacity();
    }

    /// Takes the announcements (the caller frees each with `gpa`).
    pub fn takeAnnouncements(s: *State, gpa: std.mem.Allocator) ![][]u8 {
        return s.announcements.toOwnedSlice(gpa);
    }

    pub fn clearAnnouncements(s: *State, gpa: std.mem.Allocator) void {
        for (s.announcements.items) |a| gpa.free(a);
        s.announcements.clearRetainingCapacity();
    }
};

/// Tells assistive technology what the box `id` is: its role, name and
/// states. Nothing is kept while no assistive technology listens.
/// Its strings are copied into the frame's memory.
pub fn describe(c: *Context, id: u64, d: Description) void {
    if (!c.access.enabled) return;
    // Read after the view returns: copied, as a text's bytes are.
    var kept = d;
    const a = c.alloc();
    if (kept.label) |l| kept.label = a.dupe(u8, l) catch return;
    if (kept.value) |v| kept.value = a.dupe(u8, v) catch return;
    kept.description = a.dupe(u8, kept.description) catch return;
    kept.placeholder = a.dupe(u8, kept.placeholder) catch return;
    const gop = c.access.described.getOrPut(c.gpa, id) catch return;
    gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.over(kept) else kept;
}

/// Describes the innermost open box (a `pressable`'s, a `column`'s).
pub fn describeOpen(c: *Context, d: Description) void {
    if (!c.access.enabled) return;
    describe(c, c.nodes.items[c.stack.items[c.stack.items.len - 1]].id, d);
}

/// Has assistive technology read `text` once, after what it is reading:
/// news that does not move the focus (a search done, a file saved).
pub fn announce(c: *Context, text: []const u8) void {
    if (!c.access.enabled or text.len == 0) return;
    const list = &c.access.announcements;
    // A frame built again announces again: once is enough.
    if (list.items.len > 0 and std.mem.eql(u8, list.items[list.items.len - 1], text)) return;
    const copy = c.gpa.dupe(u8, text) catch return;
    list.append(c.gpa, copy) catch c.gpa.free(copy);
}

/// Whether assistive technology asked this frame to open (true) or close
/// (false) the box `id`, for widgets that open otherwise than when pressed.
pub fn expandRequest(c: *Context, id: u64) ?bool {
    if (c.access.expand != id or id == 0) return null;
    c.access.expand = 0;
    c.changed = true;
    return c.access.expand_open;
}

/// The selection assistive technology asked the text `id` to take this
/// frame, anchor then caret in bytes of its value: taken once.
pub fn selectRequest(c: *Context, id: u64) ?[2]u32 {
    if (c.access.select != id or id == 0) return null;
    c.access.select = 0;
    c.changed = true;
    return c.access.select_range;
}

/// Whether assistive technology pressed `id` (in `interact`): taken once.
pub fn takePress(c: *Context, id: u64) bool {
    if (c.access.press != id or id == 0) return false;
    c.access.press = 0;
    return true;
}

/// Does an action of assistive technology on the element `id` of the last
/// tree (`node` is its tree node, for its role): the caller then runs a
/// frame, which does it as the keyboard or the pointer would.
pub fn perform(c: *Context, id: u64, role: Role, action: Action) void {
    switch (action) {
        .press => c.access.press = id,
        .focus => focusOn(c, id),
        .increment, .decrement => {
            focusOn(c, id);
            // Sliders step right and left, steppers up and down.
            const up = action == .increment;
            c.input.key = if (role == .stepper) (if (up) .up else .down) else if (up) .right else .left;
        },
        .expand, .collapse => {
            c.access.expand = id;
            c.access.expand_open = action == .expand;
            // Widgets that open when pressed open so; a tree's item, which
            // pressing chooses, opens by itself.
            if (role != .tree_item) c.access.press = id;
        },
        .set_value => |text| {
            focusOn(c, id);
            c.access.set_text.clearRetainingCapacity();
            c.access.set_text.appendSlice(c.gpa, text) catch return;
            c.access.ops = .{ .{ .command = .select_all }, .{ .insert = c.access.set_text.items } };
            c.input.ops = &c.access.ops;
        },
        .insert_text => |text| {
            focusOn(c, id);
            c.access.set_text.clearRetainingCapacity();
            c.access.set_text.appendSlice(c.gpa, text) catch return;
            c.access.ops[1] = .{ .insert = c.access.set_text.items };
            c.input.ops = c.access.ops[1..2];
        },
        .scroll_into_view => scrollIntoView(c, id),
        .select_text => |r| {
            c.access.select = id;
            c.access.select_range = r;
        },
    }
}

/// Gives `id` the keyboard focus, as Tab would, if it takes it.
fn focusOn(c: *Context, id: u64) void {
    if (std.mem.indexOfScalar(u64, c.focus_order.items, id) == null) return;
    c.focus = id;
    c.focus_visible = true;
}

/// Scrolls the scrolling boxes around `id` (of the last frame) to show it.
fn scrollIntoView(c: *Context, id: u64) void {
    var at: u32 = ctx_mod.none;
    for (c.nodes.items, 0..) |n, i| if (n.id == id) {
        at = @intCast(i);
        break;
    };
    if (at == ctx_mod.none) return;
    const target = c.nodes.items[at].rect;
    var p = c.nodes.items[at].parent;
    var shift: f32 = 0;
    while (p != ctx_mod.none) : (p = c.nodes.items[p].parent) {
        const box = c.nodes.items[p];
        if (!box.style.scroll) continue;
        const top = target.y - shift;
        const r = box.rect.inset(box.style.padding);
        const gop = c.scroll.getOrPut(c.gpa, box.id) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        const off = gop.value_ptr;
        var d: f32 = 0;
        if (top < r.y) d = top - r.y else if (top + target.h > r.y + r.h) d = @min(top - r.y, top + target.h - (r.y + r.h));
        const before = off.*;
        off.* = @max(0, off.* + d);
        shift += off.* - before;
    }
}

test "descriptions merge, and none are kept while nobody listens" {
    const d = (Description{ .role = .button, .label = "OK" }).over(.{ .disabled = true, .checked = .on });
    try std.testing.expectEqual(Role.button, d.role);
    try std.testing.expectEqualStrings("OK", d.label.?);
    try std.testing.expect(d.disabled);
    try std.testing.expectEqual(Checked.on, d.checked.?);
    try std.testing.expect(Role.button.leaf() and !Role.list.leaf() and Role.row.namedByContent());
    try std.testing.expect(Role.slider.ranged() and !Role.button.ranged());
}
