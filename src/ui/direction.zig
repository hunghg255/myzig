//! Right to left, after mygo's: the direction an interface reads in, as
//! Arabic and Hebrew read, as Flutter's TextDirection, SwiftUI's
//! LayoutDirection and CSS's direction say.
//!
//! A window takes a direction (`set`, or `fromLocale` with the app's
//! language), and a box that of the box it is built in, unless it is given
//! one (`scope`): a code sample, a phone number or a media player's
//! controls stay left to right in a right-to-left window.
//!
//! Right to left, layout mirrors every box inside its parent once it is
//! arranged (`mirror`, which `layout.arrange` runs): a row lays its
//! children out from the right, `align_items` and `justify` start at the
//! right, padding on the left goes to the right, an absolute box offset
//! from the left is offset from the right. As in Godot, the coordinates
//! are not mirrored: x still grows to the right in rectangles, canvases and
//! the pointer. Text, icons and pictures are not mirrored; widgets that
//! draw what points along a line (arrows, a slider's fill) read `current`.
//! Overlays keep the place their widget gave them, in window coordinates,
//! and lay their insides out in the window's direction.
const std = @import("std");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const Key = ctx_mod.Key;
const none = ctx_mod.none;

pub const Direction = enum {
    ltr,
    rtl,

    pub fn flip(d: Direction) Direction {
        return if (d == .rtl) .ltr else .rtl;
    }
};

// The direction lives in the context's kept values (`Context.anims`),
// under keys of its own, until the context has a field for it.
const window_key: u64 = 0x6d79_7a69_6764_6972; // "myzigdir"
const scopes_key: u64 = 0x6d79_7a69_6773_6370; // "myzigscp"

fn boxKey(id: u64) u64 {
    var h = std.hash.Wyhash.init(id);
    h.update("direction");
    return h.final();
}

/// Lays the window out in `d` from now on (a `Tester`'s too:
/// `ui.direction.set(&t.ctx, .rtl)`).
pub fn set(c: *Context, d: Direction) void {
    // Widgets built before it read the old one: build again.
    if (window(c) != d) c.changed = true;
    c.anims.put(c.gpa, window_key, .{ .value = if (d == .rtl) 1 else 0, .frame = c.frame }) catch {};
}

/// Lays the window out in the direction `locale` is written in: right to
/// left for Arabic, Hebrew, Persian, Urdu.
pub fn fromLocale(c: *Context, locale: []const u8) void {
    const tag = @import("../i18n/tag.zig");
    set(c, if (tag.direction(locale) == .rtl) .rtl else .ltr);
}

/// The window's direction.
pub fn window(c: *Context) Direction {
    const e = c.anims.getPtr(window_key) orelse return .ltr;
    // Read every frame by layout: kept as long as the window lives.
    e.frame = c.frame;
    return if (e.value == 1) .rtl else .ltr;
}

/// How many boxes were given a direction of their own this frame.
fn scopeCount(c: *Context) u32 {
    const e = c.anims.get(scopes_key) orelse return 0;
    return if (e.frame == c.frame) @intFromFloat(e.value) else 0;
}

/// Gives box `index` (just opened, before its children) and what is built
/// inside it the direction `d`, whatever the direction around it.
pub fn scope(c: *Context, index: u32, d: Direction) void {
    const id = c.node(index).id;
    c.anims.put(c.gpa, boxKey(id), .{ .value = if (d == .rtl) 1 else 2, .frame = c.frame }) catch return;
    const n = scopeCount(c);
    c.anims.put(c.gpa, scopes_key, .{ .value = @floatFromInt(n + 1), .frame = c.frame }) catch {};
}

/// The direction given to the box `id` itself this frame, if any.
fn own(c: *Context, id: u64) ?Direction {
    const e = c.anims.get(boxKey(id)) orelse return null;
    if (e.frame != c.frame) return null;
    return if (e.value == 1) .rtl else .ltr;
}

/// The direction of the box `index`: its own, else its parent's.
pub fn of(c: *Context, index: u32) Direction {
    if (scopeCount(c) > 0) {
        var at = index;
        while (at != none) : (at = c.node(at).parent) if (own(c, c.node(at).id)) |d| return d;
    }
    return window(c);
}

/// The direction of what is built now: that of the box open, for widgets
/// that draw what points along the line.
///
///     const forward = if (ui.direction.current(c) == .rtl) "chevron.left" else "chevron.right";
pub fn current(c: *Context) Direction {
    return of(c, c.stack.items[c.stack.items.len - 1]);
}

pub fn isRtl(c: *Context) bool {
    return current(c) == .rtl;
}

/// The arrows that go back and forth along a line built now: Left and
/// Right, or Right and Left right to left.
pub fn arrows(c: *Context) struct { back: Key, forth: Key } {
    return if (isRtl(c)) .{ .back = .right, .forth = .left } else .{ .back = .left, .forth = .right };
}

/// `t` along a line from its start (0) to its end (1), as a fraction from
/// its left: a slider's value under the pointer, a fill's side.
pub fn alongLine(c: *Context, t: f32) f32 {
    return if (isRtl(c)) 1 - t else t;
}

/// Mirrors what lays out right to left, after `layout.arrange` placed the
/// tree left to right: each box of a right-to-left box goes to the other
/// side of it, with what is inside it.
pub fn mirror(c: *Context) void {
    const win = window(c);
    if (win == .ltr and scopeCount(c) == 0) return;
    place(c, 0, 0, win);
}

fn isOverlay(c: *Context, index: u32) bool {
    return std.mem.indexOfScalar(u32, c.overlays.items, index) != null;
}

fn place(c: *Context, index: u32, dx: f32, inherited: Direction) void {
    const n = c.node(index);
    n.rect.x += dx;
    const d = if (scopeCount(c) > 0) own(c, n.id) orelse inherited else inherited;
    const r = n.rect;
    var ch = n.first_child;
    while (ch != none) {
        const child = c.node(ch);
        const next = child.next;
        var cdx = dx;
        // Overlays are placed in the window's coordinates by their widget.
        if (d == .rtl and !(index == 0 and isOverlay(c, ch))) {
            const x = child.rect.x + dx;
            const mirrored = 2 * r.x + r.w - x - child.rect.w;
            cdx = dx + mirrored - x;
        }
        place(c, ch, cdx, d);
        ch = next;
    }
}
