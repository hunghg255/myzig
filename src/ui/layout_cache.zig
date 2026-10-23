//! What layout keeps of texts from frame to frame, after mygo's layout
//! cache: each text box's text, its width and its last two wraps, found
//! again by its id and compared, rather than hashed into the text
//! system's caches (as Taffy keeps a node's measurements, and Blink the
//! layout result of a box). The view builds the tree anew every frame, so
//! a box whose text is as it was, as most are, as the rows of a list
//! scrolling, asks the text system nothing; one whose text changed asks
//! it once. Texts styled by their spans (weights, italics, code) are
//! measured as before. A change of zoom or fonts forgets everything, and
//! boxes gone for a while are forgotten.
//!
//! Within a frame, `layout.zig` measures a box once per width it is
//! measured at (`Node.measured_at`), so deep trees are not measured again
//! for every level around them.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const text = @import("text.zig");
const rich = text.rich;

/// A wrap of a held text at a width.
const Wrap = struct {
    avail: f32 = -1,
    lines: std.ArrayListUnmanaged(text.Line) = .empty,
};

/// What a text box keeps. Its buffers stay as its text changes, so a
/// text changing every frame (a counter) allocates nothing.
const Held = struct {
    str: std.ArrayListUnmanaged(u8) = .empty,
    style: types.TextStyle = .{},
    frame: u64 = 0,
    pass: u32 = 0,
    width: ?f32 = null,
    wraps: [2]Wrap = .{ .{}, .{} },
    next: u1 = 0,

    fn deinit(h: *Held, gpa: std.mem.Allocator) void {
        h.str.deinit(gpa);
        for (&h.wraps) |*w| w.lines.deinit(gpa);
    }

    fn same(h: *const Held, s: []const u8, style: types.TextStyle) bool {
        return std.mem.eql(u8, h.str.items, s) and std.meta.eql(h.style, style);
    }

    /// Takes `s` in `style`, forgetting what it held of another.
    fn hold(h: *Held, gpa: std.mem.Allocator, s: []const u8, style: types.TextStyle) bool {
        if (h.same(s, style)) return true;
        h.str.clearRetainingCapacity();
        h.str.appendSlice(gpa, s) catch return false;
        h.style = style;
        h.width = null;
        for (&h.wraps) |*w| {
            w.avail = -1;
            w.lines.clearRetainingCapacity();
        }
        return true;
    }
};

pub const Cache = struct {
    held: std.AutoHashMapUnmanaged(u64, Held) = .empty,
    /// What laid the texts out: the text system's zoom and fonts.
    gen: u64 = 0,
    /// Turned off, every text is measured anew (to compare, in tests).
    off: bool = false,

    pub fn deinit(k: *Cache, gpa: std.mem.Allocator) void {
        var it = k.held.valueIterator();
        while (it.next()) |h| h.deinit(gpa);
        k.held.deinit(gpa);
    }

    fn clear(k: *Cache, gpa: std.mem.Allocator) void {
        var it = k.held.valueIterator();
        while (it.next()) |h| h.deinit(gpa);
        k.held.clearRetainingCapacity();
    }
};

/// Before a frame's layout: forgets everything if the fonts or the zoom
/// changed, and, now and then, the boxes gone a while.
pub fn beginFrame(c: *Context) void {
    const k = &c.layout_cache;
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&c.text.zoom));
    h.update(std.mem.asBytes(&c.scale));
    h.update(c.theme.font orelse "");
    h.update("\x00");
    h.update(c.theme.mono_font orelse "");
    const gen = h.final();
    if (gen != k.gen) {
        k.clear(c.gpa);
        k.gen = gen;
    }
    if (c.frame % 60 == 0 and k.held.count() > 0) {
        // Collect before removing: mutating the map invalidates its iterator.
        // A scrolling list can expire more than a fixed batch per sweep.
        // Keep the small batch as a fallback if frame scratch cannot grow.
        var buf: [256]u64 = undefined;
        const gone: []u64 = if (k.held.count() <= buf.len) &buf else c.alloc().alloc(u64, k.held.count()) catch &buf;
        var n: usize = 0;
        var it = k.held.iterator();
        while (it.next()) |e| {
            if (n == gone.len) break;
            if (e.value_ptr.frame + 2 < c.frame) {
                gone[n] = e.key_ptr.*;
                n += 1;
            }
        }
        for (gone[0..n]) |id| if (k.held.fetchRemove(id)) |kv| {
            var v = kv.value;
            v.deinit(c.gpa);
        };
    }
}

/// The text box `index` holds, kept, or null where nothing is kept.
fn heldOf(c: *Context, index: u32, t: *const ctx_mod.Content.Text) ?*Held {
    if (c.layout_pass == 0 or c.layout_cache.off or rich.styled(t.spans)) return null;
    const gop = c.layout_cache.held.getOrPut(c.gpa, c.node(index).id) catch return null;
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const h = gop.value_ptr;
    // Another box of this frame with its id (two with one key) holds it:
    // its lines are in use, and this one keeps nothing.
    if (h.pass == c.layout_pass and !h.same(t.str, t.style)) return null;
    h.frame = c.frame;
    h.pass = c.layout_pass;
    if (!h.hold(c.gpa, t.str, t.style)) return null;
    return h;
}

/// The width of text box `index`'s text on one line, rounded up, as
/// kept; null where nothing is kept (it is measured as before).
pub fn width(c: *Context, index: u32, t: *const ctx_mod.Content.Text) ?f32 {
    const h = heldOf(c, index, t) orelse return null;
    if (h.width) |w| return w;
    const w = @ceil(c.text.width(t.str, t.style));
    h.width = w;
    return w;
}

/// The lines of text box `index`'s wrapping text within `inner_w`, as
/// kept for its last two widths.
pub fn wrap(c: *Context, index: u32, t: *const ctx_mod.Content.Text, inner_w: f32) []const text.Line {
    const h = heldOf(c, index, t) orelse return c.text.wrapAttributed(t.str, t.style, t.spans, inner_w);
    for (h.wraps) |w| if (w.avail == inner_w) return w.lines.items;
    const lines = c.text.wrapAttributed(t.str, t.style, t.spans, inner_w);
    const w = &h.wraps[h.next];
    w.avail = -1;
    w.lines.clearRetainingCapacity();
    w.lines.appendSlice(c.gpa, lines) catch return lines;
    w.avail = inner_w;
    h.next +%= 1;
    return w.lines.items;
}
