//! Toasts: short messages near the bottom of the window, as the outcome of
//! what the user just did, which go after a few seconds.
//!
//!     if (ui.button(c, "Save", .{}).clicked) _ = s.toasts.show("Saved");
//!     ...
//!     // Once in the view, last:
//!     if (ui.toasts(c, &s.toasts).action) |id| if (id == s.undo_id) s.restore();
//!
//! Their time is the context's clock (`Context.time`), not the wall's: it
//! stops while the pointer rests on them. The newest three show, stacked
//! above one another; older ones wait hidden, their time running.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const widgets = @import("widgets.zig");
const base = @import("overlay_base.zig");
const Context = ctx_mod.Context;

pub const Kind = enum { info, success, @"error" };

/// A toast to add (`Toasts.add`); its strings are copied.
pub const Toast = struct {
    title: []const u8,
    description: []const u8 = "",
    kind: Kind = .info,
    /// Seconds it shows: `default_timeout` when 0, until closed when negative.
    timeout: f32 = 0,
    /// A button that closes it, reported by `toasts` (as Undo).
    action: []const u8 = "",
    /// Names it: adding one with the key of a toast showing changes that
    /// toast, which shows anew. Its title when empty.
    key: []const u8 = "",
};

pub const default_timeout: f32 = 4;
/// A toast with an action shows longer, for the user to reach it.
pub const action_timeout: f32 = 8;
pub const visible_max = 3;
pub const capacity = 16;

fn Str(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,

        fn set(s: *@This(), v: []const u8) void {
            var l = @min(v.len, n);
            // Never cut a UTF-8 sequence.
            while (l > 0 and l < v.len and (v[l] & 0xc0) == 0x80) l -= 1;
            @memcpy(s.buf[0..l], v[0..l]);
            s.len = l;
        }

        fn get(s: *const @This()) []const u8 {
            return s.buf[0..s.len];
        }
    };
}

pub const Item = struct {
    id: u64,
    title: Str(128) = .{},
    description: Str(256) = .{},
    action: Str(32) = .{},
    kind: Kind = .info,
    /// Seconds left, or negative to show until closed.
    left: f32,
    closing: bool = false,
    /// Shown anew from this frame: fades in.
    fresh: bool = true,

    pub fn titleText(it: *const Item) []const u8 {
        return it.title.get();
    }
};

/// The window's toasts, kept by the app.
pub const Toasts = struct {
    items: [capacity]Item = undefined,
    len: usize = 0,
    /// The context's clock as last seen, and the frame.
    last_time: f64 = -1,
    last_frame: u64 = std.math.maxInt(u64),
    /// The pointer rested on one in the last frame: the time stops.
    paused: bool = false,

    pub fn idOf(t: Toast) u64 {
        return std.hash.Wyhash.hash(0x746f617374, if (t.key.len > 0) t.key else t.title);
    }

    /// Shows a toast, or shows anew the one with its key; returns its id.
    pub fn add(s: *Toasts, t: Toast) u64 {
        const id = idOf(t);
        var item: Item = .{ .id = id, .left = 0 };
        if (s.find(id)) |i| s.removeAt(i);
        if (s.len == capacity) s.removeAt(0);
        item.title.set(t.title);
        item.description.set(t.description);
        item.action.set(t.action);
        item.kind = t.kind;
        item.left = if (t.timeout == 0) (if (t.action.len > 0) action_timeout else default_timeout) else t.timeout;
        s.items[s.len] = item;
        s.len += 1;
        return id;
    }

    pub fn show(s: *Toasts, title: []const u8) u64 {
        return s.add(.{ .title = title });
    }

    /// A toast with a button, as Undo after deleting.
    pub fn showAction(s: *Toasts, title: []const u8, action: []const u8) u64 {
        return s.add(.{ .title = title, .action = action });
    }

    /// Closes the toast `id` (it fades out).
    pub fn close(s: *Toasts, id: u64) void {
        if (s.find(id)) |i| s.items[i].closing = true;
    }

    pub fn closeAll(s: *Toasts) void {
        for (s.items[0..s.len]) |*it| it.closing = true;
    }

    /// Whether the toast `id` shows (or waits to).
    pub fn has(s: *const Toasts, id: u64) bool {
        const i = s.find(id) orelse return false;
        return !s.items[i].closing;
    }

    /// Toasts not closing, shown or waiting.
    pub fn count(s: *const Toasts) usize {
        var n: usize = 0;
        for (s.items[0..s.len]) |it| {
            if (!it.closing) n += 1;
        }
        return n;
    }

    fn find(s: *const Toasts, id: u64) ?usize {
        for (s.items[0..s.len], 0..) |it, i| if (it.id == id) return i;
        return null;
    }

    fn removeAt(s: *Toasts, i: usize) void {
        std.mem.copyForwards(Item, s.items[i .. s.len - 1], s.items[i + 1 .. s.len]);
        s.len -= 1;
    }

    /// Runs the toasts' time to the context's clock, once a frame.
    fn tick(s: *Toasts, c: *Context) void {
        if (s.last_frame == c.frame) return;
        s.last_frame = c.frame;
        const elapsed: f32 = if (s.last_time < 0) 0 else @floatCast(@max(0, c.time - s.last_time));
        s.last_time = c.time;
        if (s.paused) return;
        for (s.items[0..s.len]) |*it| {
            if (it.closing or it.left < 0) continue;
            it.left -= elapsed;
            if (it.left <= 0) it.closing = true;
        }
    }
};

pub const Result = struct {
    /// The toast whose action button was clicked in this frame (closed).
    action: ?u64 = null,
    /// A toast closed by its close button in this frame.
    closed: ?u64 = null,
};

/// Builds the window's toasts over everything else, at its bottom center:
/// call it once in the view, last, to be over the other overlays. The
/// pointer goes through the room around them.
pub fn toasts(c: *Context, s: *Toasts) Result {
    s.tick(c);
    var result: Result = .{};
    if (s.len == 0) return result;
    const th = c.theme;
    _ = base.overlay(c, .{ .absolute = true, .width = .fill, .height = .fill, .padding = .all(16), .gap = 8, .justify = .end, .align_items = .center }, base.seedOf(s));
    defer c.end();

    // The newest three of those not closing, and those fading out among them.
    var shown: usize = 0;
    var first: usize = s.len;
    while (first > 0 and shown < visible_max) {
        first -= 1;
        if (!s.items[first].closing) shown += 1;
    }
    var hovered = false;
    var soonest: ?f32 = null;
    var i: usize = 0;
    while (i < s.len) : (i +%= 1) {
        const it = &s.items[i];
        if (!it.closing and it.left >= 0) soonest = if (soonest) |v| @min(v, it.left) else it.left;
        if (i < first and !it.closing) continue;
        c.next_key_int = it.id;
        const box = c.open(.{
            .direction = .row,
            .gap = 12,
            .padding = .xy(14, 10),
            .radius = 10,
            .align_items = .center,
            .min_width = 200,
            .max_width = 420,
            .background = th.text,
            .shadow = .{ .color = th.shadow.alpha(1.5), .blur = 16, .y = 6 },
        }, null);
        const bid = c.node(box).id;
        const fresh = it.fresh;
        it.fresh = false;
        if (fresh) base.restart(c, bid, 0x7461, 0);
        // Screen readers read it as it comes, without the focus moving.
        c.describe(bid, .{ .role = .status });
        if (fresh) c.announce(it.title.get());
        const t = c.animate(bid, 0x7461, if (it.closing) 0 else 1, 14);
        c.node(box).style.opacity = t;
        c.node(box).style.offset.y = (1 - t) * 8;
        if (!it.closing) {
            const hit = c.interact(box, .{});
            if (hit.hovered) hovered = true;
        }
        const fg = th.background;
        if (it.kind != .info) widgets.icon(c, if (it.kind == .success) "checkmark.circle.fill" else "exclamationmark.triangle", .{
            .size = 15,
            .color = if (it.kind == .success) th.success else th.danger,
        });
        widgets.column(c, .{ .gap = 2, .grow = 1 });
        widgets.text(c, it.title.get(), .{ .size = 13, .weight = .semibold, .color = fg });
        if (it.description.len > 0) widgets.text(c, it.description.get(), .{ .size = 12, .color = fg.alpha(0.7) });
        widgets.end(c);
        if (it.action.len > 0) {
            const a = widgets.pressable(c, .{ .padding = .xy(8, 3), .radius = 6, .control = true }, fg.alpha(0.15));
            widgets.text(c, it.action.get(), .{ .size = 13, .weight = .semibold, .color = th.accent });
            widgets.end(c);
            if (a.clicked and !it.closing) {
                result.action = it.id;
                it.closing = true;
                c.changed = true;
            }
        }
        const x = widgets.pressable(c, .{ .padding = .all(3), .radius = 5, .control = true }, fg.alpha(0.15));
        c.describe(x.id, .{ .label = "Close" });
        widgets.icon(c, "xmark", .{ .size = 11, .color = fg.alpha(0.6) });
        widgets.end(c);
        if (x.clicked and !it.closing) {
            result.closed = it.id;
            it.closing = true;
            c.changed = true;
        }
        c.end();
        // Gone once faded out.
        if (it.closing and t <= 0.02) {
            s.removeAt(i);
            if (i < first) first -= 1;
            i -%= 1;
        }
    }
    s.paused = hovered;
    if (soonest) |v| if (!hovered) c.frameIn(v);
    return result;
}
