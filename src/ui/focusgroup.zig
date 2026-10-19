//! Focus groups, after mygo's: the controls inside a group's box are one
//! stop of Tab, as a toolbar's, a radio group's or a tab list's are. Tab
//! goes into the group to the control that had the focus there last (else
//! the one `entry` names, as the chosen tab, else the first) and on out of
//! it; the arrows of its orientation move the focus among its controls,
//! around from the last to the first, and Home and End to the first and the
//! last (a roving focus). Right to left, Left goes to the next one.
//!
//!     var g = ui.focusGroup(c, .{ .direction = .row, .gap = 4 }, .{});
//!     if (ui.button(c, "Bold", .{}).clicked) s.bold = !s.bold;
//!     if (ui.button(c, "Italic", .{}).clicked) s.italic = !s.italic;
//!     _ = g.end();
//!
//! A control inside that takes the arrows itself takes them first, when it
//! consumes the key (`Context.input.key`).
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const direction = @import("direction.zig");
const Context = ctx_mod.Context;
const Key = ctx_mod.Key;
const S = ctx_mod.Shortcut;

pub const Orientation = enum { horizontal, vertical, both };

pub const Options = struct {
    orientation: Orientation = .horizontal,
    /// The control Tab enters at when none had the focus yet (the chosen
    /// tab, the checked radio button), by its place in the group.
    entry: ?usize = null,
    /// The arrows go around from the last to the first.
    wrap: bool = true,
};

pub const Result = struct {
    /// The control the arrows moved the focus to in this frame: a radio
    /// group chooses it.
    moved: ?usize = null,
    /// The control of the group with the focus.
    focused: ?usize = null,
    /// How many controls take the focus in it.
    count: usize = 0,
};

pub const FocusGroup = struct {
    c: *Context,
    index: u32,
    start: usize,
    opts: Options,

    /// Closes the group's box; answers its keys and keeps one of its
    /// controls in Tab's order.
    pub fn end(g: FocusGroup) Result {
        const c = g.c;
        const id = c.node(g.index).id;
        const rtl = direction.of(c, g.index) == .rtl;
        c.end();
        const order = &c.focus_order;
        if (g.start > order.items.len) return .{};
        const members = c.alloc().dupe(u64, order.items[g.start..]) catch return .{};
        var r: Result = .{ .count = members.len };
        if (members.len == 0) return r;
        const last = lastSlot(c, id);
        var at = std.mem.indexOfScalar(u64, members, c.focus);
        if (at) |i| last.* = @floatFromInt(i);

        if (at) |i| if (keyOf(c)) |k| if (target(k, i, members.len, g.opts, rtl)) |to| {
            consume(c);
            if (to != i) {
                c.focus = members[to];
                c.focus_visible = true;
                c.changed = true;
                r.moved = to;
            }
            at = to;
            last.* = @floatFromInt(to);
        };
        r.focused = at;

        // One stop of Tab: the control that had the focus last.
        const remembered: usize = @intFromFloat(@max(0, last.*));
        const entry = if (last.* >= 0 and remembered < members.len) remembered else @min(g.opts.entry orelse 0, members.len - 1);
        order.shrinkRetainingCapacity(g.start);
        order.appendAssumeCapacity(members[entry]);
        return r;
    }
};

/// Where the focus was last in group `id`, by place, -1 for nowhere.
fn lastSlot(c: *Context, id: u64) *f32 {
    var h = std.hash.Wyhash.init(id);
    h.update("focus group");
    const gop = c.anims.getOrPut(c.gpa, h.final()) catch @panic("OOM");
    if (!gop.found_existing) gop.value_ptr.* = .{ .value = -1, .frame = c.frame };
    gop.value_ptr.frame = c.frame;
    return &gop.value_ptr.value;
}

/// This event's arrow, Home or End, without modifiers.
fn keyOf(c: *Context) ?Key {
    if (c.input.key) |k| return if (c.input.cmd or c.input.ctrl or c.input.shift) null else k;
    const s = c.input.shortcut orelse return null;
    if (s.cmd or s.ctrl or s.alt or s.shift) return null;
    return switch (s.key) {
        S.left => .left,
        S.right => .right,
        S.up => .up,
        S.down => .down,
        else => null,
    };
}

fn consume(c: *Context) void {
    c.input.key = null;
    if (c.input.shortcut != null) {
        c.input.shortcut = null;
        c.shortcut_taken = true;
    }
}

/// Where key `k` moves the focus from control `i` of `n`.
pub fn target(k: Key, i: usize, n: usize, opts: Options, rtl: bool) ?usize {
    const h = opts.orientation != .vertical;
    const v = opts.orientation != .horizontal;
    const back: Key = if (rtl) .right else .left;
    const forth: Key = if (rtl) .left else .right;
    const next = (h and k == forth) or (v and k == .down);
    const prev = (h and k == back) or (v and k == .up);
    if (next) return if (i + 1 < n) i + 1 else if (opts.wrap) 0 else i;
    if (prev) return if (i > 0) i - 1 else if (opts.wrap) n - 1 else i;
    return switch (k) {
        .home => 0,
        .end => n - 1,
        else => null,
    };
}

/// Opens a focus group's box (a row or a column, as `style` says): its
/// controls follow, then `FocusGroup.end`.
pub fn focusGroup(c: *Context, style: types.Style, opts: Options) FocusGroup {
    const index = c.open(style, null);
    return .{ .c = c, .index = index, .start = c.focus_order.items.len, .opts = opts };
}

test "target" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, 1), target(.right, 0, 3, .{}, false));
    try t.expectEqual(@as(?usize, 0), target(.right, 2, 3, .{}, false));
    try t.expectEqual(@as(?usize, 2), target(.right, 2, 3, .{ .wrap = false }, false));
    try t.expectEqual(@as(?usize, 2), target(.left, 0, 3, .{}, false));
    try t.expectEqual(@as(?usize, 1), target(.left, 0, 3, .{}, true));
    try t.expectEqual(@as(?usize, null), target(.down, 0, 3, .{}, false));
    try t.expectEqual(@as(?usize, 1), target(.down, 0, 3, .{ .orientation = .vertical }, false));
    try t.expectEqual(@as(?usize, null), target(.right, 0, 3, .{ .orientation = .vertical }, false));
    try t.expectEqual(@as(?usize, 2), target(.end, 0, 3, .{}, false));
    try t.expectEqual(@as(?usize, 0), target(.home, 2, 3, .{ .orientation = .both }, false));
}
