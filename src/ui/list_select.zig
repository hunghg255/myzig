//! A list whose rows are chosen (`ListOptions.choice`): a click chooses a
//! row, the arrows, Home, End and Page Up and Down move the cursor while
//! the list has the focus, Enter or a double click submits it; with a
//! `Selection`, Shift and Cmd choose several, Cmd+A every row, and a
//! right-click on a row not chosen chooses it before its menu opens
//! (`selection_set.zig`). With a key, the choice follows its items as
//! rows come and go.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const structure = @import("structure.zig");
const set = @import("selection_set.zig");
const Context = ctx_mod.Context;
const Choice = set.Choice;

pub const Result = struct {
    /// A click or a key chose another row (or others).
    changed: bool = false,
    /// Enter or a double click on the cursor's row.
    submitted: bool = false,
    /// The row right-clicked in this frame, which its menu acts on.
    menu_row: ?usize = null,
    focused: bool = false,
};

/// Before the rows: follows the items, and reads the keys of a focused
/// list `id` of `count` rows `row_h` tall in view `view_h`; where to
/// scroll to show the cursor.
pub fn begin(c: *Context, ch: *Choice, id: u64, count: usize, row_h: f32, view_h: f32, result: *Result) ?f32 {
    Choice.sync(ch, count);
    if (c.focus != id) return null;
    result.focused = true;
    if (Choice.all(ch, if (ch.selection != null and c.shortcut(.{ .key = 'a', .cmd = true })) count else 0)) {
        result.changed = true;
        c.changed = true;
    }
    const k = c.input.key orelse return null;
    const page: usize = @intFromFloat(@max(1, @floor(view_h / row_h) - 1));
    if (k == .enter and ch.selected != null) {
        _ = structure.takeKey(c);
        result.submitted = true;
        c.changed = true;
        return null;
    }
    const to = structure.step(k, ch.selected, count, .up, .down, page) orelse return null;
    _ = structure.takeKey(c);
    c.changed = true;
    const moved = if (c.input.shift and ch.selection != null) Choice.extend(ch, to, false) else Choice.only(ch, to);
    if (moved) result.changed = true;
    const top = row_h * @as(f32, @floatFromInt(to));
    return structure.reveal(top, row_h, c.scroll.get(id) orelse 0, view_h);
}

/// Opens row `i`'s box (`row_h` tall) and answers its presses, clicks and
/// right-clicks; its content follows, then `c.end()`.
pub fn row(c: *Context, ch: *Choice, i: usize, row_h: f32, list_id: u64, result: *Result) void {
    const box = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = row_h }, .align_items = .center, .control = true }, null);
    const it = c.interact(box, .{});
    const several = ch.selection != null;
    if (it.pressed and c.input.pressed) {
        if (c.focus != list_id) {
            c.focus = list_id;
            c.changed = true;
        }
        if (several) {
            // A press on a row not chosen chooses it as the pointer goes
            // down; on one chosen, at the release.
            const changed = if (c.input.shift)
                Choice.extend(ch, i, c.input.adding())
            else if (c.input.adding())
                Choice.toggle(ch, i)
            else if (!Choice.chosen(ch, i)) Choice.only(ch, i) else false;
            if (changed) result.changed = true;
            c.changed = true;
        }
    }
    if (it.clicked) {
        const plain = !c.input.shift and !c.input.adding();
        if ((!several or plain) and Choice.only(ch, i)) result.changed = true;
        if (it.double_clicked) result.submitted = true;
        c.changed = true;
    }
    if (it.hovered and @import("overlay_base.zig").rightPressed(c)) {
        if (Choice.rightClick(ch, i)) {
            result.changed = true;
            c.changed = true;
        }
        result.menu_row = i;
    }
    const hover = c.animate(it.id, 0, if (it.hovered) 1 else 0, 20);
    const now = Choice.chosen(ch, i);
    c.describe(it.id, .{ .role = .row, .selected = now });
    if (ch.selected == i) c.describe(list_id, .{ .active_descendant = it.id });
    c.node(box).style.background = structure.rowBackground(c, now, c.focus == list_id, hover);
}

/// Whether the row the element `index` is in was double-clicked with the
/// pointer over it, without taking the click from the row (which goes on
/// choosing): a part of a row that renames its item, say.
pub fn rowDoubleClicked(c: *Context, index: u32) bool {
    if (!c.input.released or c.input.click_count < 2) return false;
    const r = c.rects.get(c.node(index).id) orelse return false;
    return r.contains(c.input.mouse);
}
