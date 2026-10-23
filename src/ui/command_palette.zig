//! Searchable commands in a dialog. The field keeps the keyboard while
//! arrows move the active result; the app dispatches the returned index.
const std = @import("std");
const types = @import("types.zig");
const widgets = @import("widgets.zig");
const textfield = @import("textfield.zig");
const dialog_mod = @import("dialog.zig");
const base = @import("overlay_base.zig");
const listbox = @import("listbox.zig");
const Context = @import("context.zig").Context;

pub const Item = struct {
    title: []const u8,
    group: []const u8 = "",
    keywords: []const u8 = "",
    icon: []const u8 = "",
    shortcut: []const u8 = "",
    disabled: bool = false,
};

pub const Options = struct {
    width: types.Length = .{ .px = 480 },
    max_height: f32 = 320,
    label: []const u8 = "Commands",
    placeholder: []const u8 = "Search commands…",
    search_label: []const u8 = "Search commands",
    empty_label: []const u8 = "No commands found.",
};

pub const State = struct {
    overlay: base.OverlayState = .{},
    query: textfield.TextBuffer = .{},
    selected: ?usize = null,
    mouse: types.Point = .{ .x = -1e6, .y = -1e6 },

    pub fn show(s: *State) void {
        s.overlay.show();
    }

    pub fn close(s: *State) void {
        s.overlay.close();
    }

    pub fn toggle(s: *State) void {
        s.overlay.toggle();
    }
};

/// Returns the original item index on activation. Disabled results are
/// shown but skipped by the keyboard. Reopening clears the search.
pub fn commandPalette(c: *Context, s: *State, items: []const Item, opts: Options) ?usize {
    const d = dialog_mod.dialog(c, &s.overlay, .{ .width = opts.width, .padding = .all(10), .gap = 8, .animated = false }) orelse return null;
    defer d.end();
    d.panelStyle().max_width = @max(0, c.size.w - 16);
    d.panelStyle().max_height = @max(0, c.size.h - 16);
    c.describe(c.node(d.panel).id, .{ .label = opts.label });
    const opened = s.overlay.justOpened(c);
    if (opened) {
        s.query.clear();
        s.selected = null;
    }
    // Take list navigation before the editor uses Home/End or Return.
    const step: i32 = if (base.takeKey(c, .down)) 1 else if (base.takeKey(c, .up)) -1 else 0;
    const home = base.takeKey(c, .home);
    const end = base.takeKey(c, .end);
    const enter = base.takeKey(c, .enter);
    c.next_key = "search";
    const field_id = c.peekId(null);
    if (opened) c.focus = field_id;
    const edited = textfield.textField(c, &s.query, .{ .width = .fill, .bare = true, .label = opts.search_label, .placeholder = opts.placeholder });
    widgets.divider(c);
    const labels = c.alloc().alloc([]const u8, items.len) catch return null;
    for (items, 0..) |item, i| labels[i] = c.print("{s} {s}", .{ item.title, item.keywords });
    const matches = listbox.filter(c, labels, std.mem.trim(u8, s.query.text(), " \t\r\n"));
    if (edited.changed) s.selected = null;
    if (s.selected) |selected| {
        if (selected >= items.len or std.mem.indexOfScalar(usize, matches, selected) == null or items[selected].disabled) s.selected = null;
    }
    if (s.selected == null) for (matches) |index| {
        if (!items[index].disabled) {
            s.selected = index;
            break;
        }
    };
    if (matches.len > 0 and (step != 0 or home or end)) {
        var at = if (s.selected) |index| std.mem.indexOfScalar(usize, matches, index).? else 0;
        if (home) at = matches.len - 1;
        if (end) at = 0;
        const backwards = step < 0 or end;
        for (0..matches.len) |_| {
            at = if (backwards) (if (at == 0) matches.len - 1 else at - 1) else (at + 1) % matches.len;
            if (!items[matches[at]].disabled) {
                s.selected = matches[at];
                break;
            }
        }
    }
    var chosen: ?usize = if (enter) s.selected else null;
    c.next_key = "results";
    const results = c.open(.{ .width = .fill, .max_height = @max(0, @min(opts.max_height, c.size.h - 100)), .scroll = true, .clip = true, .gap = 3 }, null);
    const results_id = c.node(results).id;
    c.describe(results_id, .{ .role = .list, .label = opts.label });
    if (edited.changed or opened) c.scroll.put(c.gpa, results_id, 0) catch {};
    const moved = c.input.mouse.x != s.mouse.x or c.input.mouse.y != s.mouse.y;
    var group: []const u8 = "";
    var active_id: u64 = 0;
    var active_rect: ?types.Rect = null;
    for (matches, 0..) |index, position| {
        const item = items[index];
        if (!std.mem.eql(u8, group, item.group)) {
            group = item.group;
            if (group.len > 0) widgets.text(c, group, .{ .size = 11, .weight = .semibold, .color = c.theme.muted });
        }
        c.keyed(index);
        const row = c.open(.{ .direction = .row, .width = .fill, .align_items = .center, .padding = .xy(10, 8), .gap = 8, .radius = 6, .opacity = if (item.disabled) 0.45 else 1 }, null);
        const it = c.interact(row, .{});
        // Pointer selection must not take typing away from the search.
        if (it.hovered and c.input.pressed) c.focus = field_id;
        if (!item.disabled) {
            if (moved and it.hovered and s.selected != index) {
                s.selected = index;
                c.changed = true;
            }
            if (it.clicked) chosen = index;
        }
        const selected = s.selected == index;
        if (selected) {
            active_id = it.id;
            active_rect = it.rect;
            c.node(row).style.background = c.theme.surface_hover;
        }
        c.describe(it.id, .{ .role = .list_item, .label = item.title, .disabled = item.disabled, .selected = selected, .pos_in_set = @intCast(position + 1), .set_size = @intCast(matches.len) });
        if (item.icon.len > 0) widgets.icon(c, item.icon, .{ .size = 15, .frame = 18 });
        widgets.text(c, item.title, .{ .wrap = true });
        widgets.spacer(c);
        if (item.shortcut.len > 0) widgets.text(c, item.shortcut, .{ .size = 12, .color = c.theme.muted });
        c.end();
    }
    if (matches.len == 0) widgets.text(c, opts.empty_label, .{ .color = c.theme.muted, .wrap = true });
    c.end();
    c.describe(field_id, .{ .role = .combo_box, .expanded = true, .active_descendant = active_id });
    if (step != 0 or home or end or edited.changed) if (active_rect) |r| reveal(c, results_id, r);
    s.mouse = c.input.mouse;
    if (chosen != null) {
        s.close();
        // A chosen action may open another modal later in this view.
        // Restore the trigger before that modal records its return focus.
        _ = s.overlay.sync(c);
        c.changed = true;
    }
    return chosen;
}

fn reveal(c: *Context, id: u64, rect: types.Rect) void {
    const viewport = c.rects.get(id) orelse return;
    const before = c.scroll.get(id) orelse 0;
    var after = before;
    if (rect.y < viewport.y) after -= viewport.y - rect.y;
    if (rect.y + rect.h > viewport.y + viewport.h) after += rect.y + rect.h - viewport.y - viewport.h;
    if (before != after) {
        c.scroll.put(c.gpa, id, @max(0, after)) catch {};
        c.changed = true;
    }
}
