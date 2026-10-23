//! Page navigation, independent of how an app loads or displays its data.
const std = @import("std");
const widgets = @import("widgets.zig");
const focusgroup = @import("focusgroup.zig");
const state = @import("controls_state.zig");
const Context = @import("context.zig").Context;

const focus_salt = 0x70616765;

pub const Options = struct {
    /// Null: unknown total, showing only Previous, the page and Next.
    /// Zero: empty data, with page normalized to zero and no active controls.
    page_count: ?usize = null,
    /// Whether another page can be loaded, only used for an unknown total.
    has_next: bool = false,
    /// Numbered neighbors on each side of the current page.
    siblings: u2 = 1,
    disabled: bool = false,
    label: []const u8 = "Pagination",
    previous_label: []const u8 = "Previous",
    next_label: []const u8 = "Next",
    page_label: []const u8 = "Page",
};

const Pages = struct {
    // Three neighbors each side, endpoints and two gaps: bounded even for
    // a server reporting billions of pages. Zero represents an ellipsis.
    items: [11]usize = undefined,
    len: usize = 0,

    fn add(p: *Pages, n: usize) void {
        std.debug.assert(p.len < p.items.len);
        p.items[p.len] = n;
        p.len += 1;
    }
};

fn pages(current: usize, count: usize, siblings: u2) Pages {
    var p: Pages = .{};
    if (count == 0) return p;
    const radius: usize = siblings;
    if (count <= 2 * radius + 5) {
        for (0..count) |i| p.add(i + 1);
        return p;
    }
    p.add(1);
    const first = @max(2, current -| radius);
    const last = @min(count - 1, current +| radius);
    if (first > 2) p.add(if (first == 3) 2 else 0);
    if (last >= first) for (first..last + 1) |n| p.add(n);
    if (last < count - 1) p.add(if (last == count - 2) count - 1 else 0);
    p.add(count);
    return p;
}

/// `page` is one-based (zero only for empty data). True when navigation
/// or normalization changes it. Arrows/Home/End move focus; Enter/Space
/// activate a button. Tab enters/leaves the whole group in one stop.
pub fn pagination(c: *Context, page: *usize, opts: Options) bool {
    const before = page.*;
    page.* = if (opts.page_count) |count| if (count == 0) 0 else std.math.clamp(page.*, 1, count) else @max(1, page.*);
    const current = page.*;
    const back = !opts.disabled and current > 1;
    const next = !opts.disabled and current < (opts.page_count orelse std.math.maxInt(usize)) and (opts.page_count != null or opts.has_next);
    var group = focusgroup.focusGroup(c, .{ .direction = .row, .align_items = .center, .gap = 4 }, .{ .wrap = false });
    const id = c.node(group.index).id;
    const had_focus = c.focus != 0 and state.getBool(c, id ^ c.focus, focus_salt);
    c.describe(id, .{ .role = .group, .label = opts.label, .disabled = opts.disabled });
    c.next_key = "previous";
    if (widgets.button(c, opts.previous_label, .{ .disabled = !back, .variant = .ghost }).clicked) page.* = current - 1;
    if (opts.page_count) |count| {
        const numbered = pages(current, count, opts.siblings);
        var entry: usize = @intFromBool(back);
        for (numbered.items[0..numbered.len], 0..) |n, slot| {
            if (n == 0) {
                c.keyed(.{ "gap", slot });
                widgets.text(c, "…", .{ .color = c.theme.muted });
                continue;
            }
            c.keyed(n);
            const selected = n == current;
            const it = widgets.button(c, c.print("{d}", .{n}), .{
                .variant = if (selected) .primary else .ghost,
                .width = .{ .px = @max(36, c.text.width(c.print("{d}", .{n}), .{}) + 28) },
                .disabled = opts.disabled,
            });
            c.describe(it.id, .{ .label = c.print("{s} {d}", .{ opts.page_label, n }), .selected = selected, .selectable = true });
            if (it.clicked) page.* = n;
            if (selected) group.opts.entry = entry;
            entry += 1;
        }
    } else {
        c.next_key = "current";
        widgets.text(c, c.print("{s} {d}", .{ opts.page_label, current }), .{ .color = c.theme.muted });
    }
    c.next_key = "next";
    if (widgets.button(c, opts.next_label, .{ .disabled = !next, .variant = .ghost }).clicked) page.* = current + 1;
    // A boundary can disable the focused button; new totals or a narrower
    // page window can remove it entirely. Remember ownership by id so
    // replacing it never takes focus from another pager or control.
    const members = c.focus_order.items[group.start..];
    if (c.focus != 0 and std.mem.indexOfScalar(u64, members, c.focus) == null) {
        var owned = had_focus;
        for (c.nodes.items[group.index + 1 ..]) |n| if (n.id == c.focus) {
            owned = true;
            break;
        };
        if (owned) {
            c.focus = if (members.len == 0) 0 else members[@min(group.opts.entry orelse 0, members.len - 1)];
            c.changed = true;
        }
    }
    if (group.end().focused != null) state.putBool(c, id ^ c.focus, focus_salt, true);
    const changed = page.* != before;
    if (changed) c.changed = true;
    return changed;
}

test "pagination: bounded page windows including usize limits" {
    const t = std.testing;
    for (0..4) |radius| {
        for (0..80) |count| {
            for (1..@max(2, count + 1)) |current| {
                const p = pages(current, count, @intCast(radius));
                if (count == 0) {
                    try t.expectEqual(0, p.len);
                    continue;
                }
                try t.expectEqual(1, p.items[0]);
                try t.expectEqual(count, p.items[p.len - 1]);
                try t.expect(std.mem.indexOfScalar(usize, p.items[0..p.len], current) != null);
                var previous: usize = 0;
                for (p.items[0..p.len]) |n| if (n != 0) {
                    try t.expect(n > previous and n <= count);
                    previous = n;
                };
            }
        }
        const max = std.math.maxInt(usize);
        const p = pages(max, max, @intCast(radius));
        try t.expectEqual(max, p.items[p.len - 1]);
    }
}
