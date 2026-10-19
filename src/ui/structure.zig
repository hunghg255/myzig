//! What the structural widgets share (tabs, sidebars, trees, outlines,
//! tables, grid views): a widget's small state kept across frames, keys
//! that move a choice through items, scrolling a row into view, and the
//! colors of a chosen row.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const Key = ctx_mod.Key;

/// A number kept across frames for the box `id` (a drag's grab offset),
/// beside its animated values; forgotten a while after it stops being read.
pub fn slot(c: *Context, id: u64, salt: u32, initial: f32) *f32 {
    var h = std.hash.Wyhash.init(id);
    h.update("slot");
    h.update(std.mem.asBytes(&salt));
    const gop = c.anims.getOrPut(c.gpa, h.final()) catch @panic("OOM");
    if (!gop.found_existing) gop.value_ptr.* = .{ .value = initial, .frame = c.frame };
    gop.value_ptr.frame = c.frame;
    return &gop.value_ptr.value;
}

/// This event's key, taken: no widget built later reacts to it too.
pub fn takeKey(c: *Context) ?Key {
    const k = c.input.key orelse return null;
    c.input.key = null;
    return k;
}

/// Whether this event typed a space (what presses a focused control).
pub fn typedSpace(c: *Context) bool {
    return std.mem.eql(u8, c.input.chars, " ");
}

/// Where a key moves a choice among `count` items in a line: the arrows
/// one step (`back`, `forth`), Home and End to the ends, Page Up and Down
/// by `page`. Null when the key does not move it.
pub fn step(k: Key, current: ?usize, count: usize, back: Key, forth: Key, page: usize) ?usize {
    if (count == 0) return null;
    const last = count - 1;
    // Nothing chosen yet: a key that moves starts at an end.
    const now = current orelse {
        if (k == .end) return last;
        return if (k == back or k == forth or k == .home or k == .page_up or k == .page_down) 0 else null;
    };
    const cur = @min(now, last);
    if (k == back) return cur -| 1;
    if (k == forth) return @min(last, cur + 1);
    return switch (k) {
        .home => 0,
        .end => last,
        .page_up => cur -| @max(1, page),
        .page_down => @min(last, cur + @max(1, page)),
        else => null,
    };
}

/// The offset that shows the row from `top` to `top + h` in a view `view_h`
/// tall scrolled to `offset`, or null when it already shows.
pub fn reveal(top: f32, h: f32, offset: f32, view_h: f32) ?f32 {
    if (top < offset) return top;
    if (top + h > offset + view_h) return @max(0, top + h - view_h);
    return null;
}

/// The first item after `from` (wrapping) whose label starts with the
/// typed text, ignoring case: typing a name's first letters chooses it.
pub fn matchPrefix(labels: []const []const u8, from: ?usize, typed: []const u8) ?usize {
    if (typed.len == 0 or labels.len == 0) return null;
    const start = if (from) |f| f + 1 else 0;
    for (0..labels.len) |n| {
        const i = (start + n) % labels.len;
        const l = labels[i];
        if (l.len >= typed.len and std.ascii.eqlIgnoreCase(l[0..typed.len], typed)) return i;
    }
    return null;
}

/// The background of a row: chosen (in the accent while its list has the
/// focus, gray otherwise, as AppKit's), hovered, or none.
pub fn rowBackground(c: *Context, chosen: bool, focused: bool, hover: f32) ?types.Color {
    const th = c.theme;
    if (chosen) return if (focused) th.accent else th.text.alpha(0.12);
    if (hover > 0.01) return th.text.alpha(0.06 * hover);
    return null;
}

/// The text color on such a row.
pub fn rowText(c: *Context, chosen: bool, focused: bool) types.Color {
    return if (chosen and focused) c.theme.accent_text else c.theme.text;
}

test "step" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, 1), step(.down, 0, 3, .up, .down, 1));
    try t.expectEqual(@as(?usize, 2), step(.down, 2, 3, .up, .down, 1));
    try t.expectEqual(@as(?usize, 0), step(.up, 0, 3, .up, .down, 1));
    try t.expectEqual(@as(?usize, 2), step(.end, null, 3, .up, .down, 1));
    try t.expectEqual(@as(?usize, 0), step(.down, null, 3, .up, .down, 1));
    try t.expectEqual(@as(?usize, null), step(.enter, 1, 3, .up, .down, 1));
    try t.expectEqual(@as(?usize, 9), step(.page_down, 4, 10, .up, .down, 5));
    try t.expectEqual(@as(?usize, null), step(.down, null, 0, .up, .down, 1));
}

test "reveal and prefix" {
    const t = std.testing;
    try t.expectEqual(@as(?f32, null), reveal(20, 10, 0, 100));
    try t.expectEqual(@as(?f32, 30), reveal(30, 10, 50, 100));
    try t.expectEqual(@as(?f32, 50), reveal(140, 10, 0, 100));
    const names: []const []const u8 = &.{ "Inbox", "Sent", "Spam", "Drafts" };
    try t.expectEqual(@as(?usize, 1), matchPrefix(names, null, "s"));
    try t.expectEqual(@as(?usize, 2), matchPrefix(names, 1, "S"));
    try t.expectEqual(@as(?usize, 1), matchPrefix(names, 2, "s"));
    try t.expectEqual(@as(?usize, null), matchPrefix(names, 0, "x"));
}
