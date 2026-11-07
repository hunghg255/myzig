//! Toasts, after sonner (github.com/emilkowalski/sonner): short messages in
//! a corner of the window, as the outcome of what the user just did, which
//! go after a few seconds.
//!
//!     if (ui.button(c, "Save", .{}).clicked) _ = s.toasts.success("Saved");
//!     ...
//!     // Once in the view, last:
//!     if (ui.toasts(c, &s.toasts).action) |id| if (id == s.undo_id) s.restore();
//!
//! The newest is in front; up to `visible` more peek out behind it, a
//! little smaller, and spread out while the pointer is over them (or always,
//! with `expand`). A swipe toward the window's edge closes one. Their time
//! is the context's clock (`Context.time`), not the wall's: it stops while
//! the pointer is over them. The view is `toast_view.zig`.
const std = @import("std");
const types = @import("types.zig");
const Context = @import("context.zig").Context;

pub const Kind = enum {
    /// No icon.
    normal,
    info,
    success,
    warning,
    @"error",
    /// A spinner, until the app changes it (`add` with its key) or closes it.
    loading,
};

/// Where the toasts are in the window.
pub const Position = enum {
    top_left,
    top_center,
    top_right,
    bottom_left,
    bottom_center,
    bottom_right,

    pub fn bottom(p: Position) bool {
        return switch (p) {
            .bottom_left, .bottom_center, .bottom_right => true,
            else => false,
        };
    }

    /// -1 at the left, 0 in the middle, 1 at the right.
    pub fn side(p: Position) i2 {
        return switch (p) {
            .top_left, .bottom_left => -1,
            .top_center, .bottom_center => 0,
            .top_right, .bottom_right => 1,
        };
    }
};

/// A toast to add (`Toasts.add`); its strings are copied.
pub const Toast = struct {
    title: []const u8,
    description: []const u8 = "",
    kind: Kind = .normal,
    /// Seconds it shows: `default_timeout` when 0, until closed when
    /// negative. A loading toast shows until changed or closed.
    timeout: f32 = 0,
    /// A button that closes it, reported by `toasts` (as Undo).
    action: []const u8 = "",
    /// A button beside the action that closes it, reported as `cancel`.
    cancel: []const u8 = "",
    /// Names it: adding one with the key of a toast showing changes that
    /// toast where it is, its time starting anew. Its title when empty.
    key: []const u8 = "",
    /// A swipe, the close button and Cancel close it.
    dismissible: bool = true,
    /// Overrides `Toasts.close_button` and `Toasts.rich_colors`.
    close_button: ?bool = null,
    rich_colors: ?bool = null,
    /// A symbol in place of its kind's icon (`"star.fill"`).
    icon: []const u8 = "",
    /// Its content built by the app, in place of its icon, title and
    /// description, as sonner's `toast.custom`; the title still names it
    /// for screen readers. What `View.ptr` points to must outlive it.
    content: ?View = null,
};

const View = @import("ui.zig").View;

pub const default_timeout: f32 = 4;
/// A toast with an action shows longer, for the user to reach it.
pub const action_timeout: f32 = 8;
pub const visible_max = 3;
pub const capacity = 16;

pub fn Str(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,

        pub fn set(s: *@This(), v: []const u8) void {
            var l: usize = @min(v.len, n);
            // Never cut a UTF-8 sequence.
            while (l > 0 and l < v.len and (v[l] & 0xc0) == 0x80) l -= 1;
            @memcpy(s.buf[0..l], v[0..l]);
            s.len = l;
        }

        pub fn get(s: *const @This()) []const u8 {
            return s.buf[0..s.len];
        }
    };
}

pub const Item = struct {
    id: u64,
    title: Str(128) = .{},
    description: Str(256) = .{},
    action: Str(32) = .{},
    cancel: Str(32) = .{},
    kind: Kind = .normal,
    dismissible: bool = true,
    close_button: ?bool = null,
    rich_colors: ?bool = null,
    icon: Str(48) = .{},
    content: ?View = null,
    /// Done loading in this frame: its icon comes in.
    settled: bool = false,
    /// Seconds left, or negative to show until closed.
    left: f32,
    closing: bool = false,
    /// Shown anew from this frame: comes in.
    fresh: bool = true,
    /// Changed in place: read out again.
    changed: bool = false,

    // Kept by the view (`toast_view.zig`).
    /// Its height as its content asks, from the last layout; 0 unknown.
    height: f32 = 0,
    /// The context's clock as it began to close.
    closed_at: f64 = -1,
    /// Where it was as it began to close, to leave from.
    last_y: f32 = 0,
    last_h: f32 = 0,
    last_index: usize = 0,
    last_expanded: bool = false,
    swipe: Swipe = .{},

    pub fn titleText(it: *const Item) []const u8 {
        return it.title.get();
    }
};

/// Ways a swipe may go, as sonner's `swipeDirections`.
pub const Directions = struct {
    top: bool = false,
    right: bool = false,
    bottom: bool = false,
    left: bool = false,
};

/// A swipe of a toast, by the pointer.
pub const Swipe = struct {
    on: bool = false,
    start: types.Point = .{},
    start_time: f64 = 0,
    /// The axis it goes along once it moved: 0 none yet, 1 x, 2 y.
    axis: u2 = 0,
    /// Where it is moved to now.
    x: f32 = 0,
    y: f32 = 0,
    /// It was swiped away: it leaves the way it went.
    out: bool = false,
};

/// The window's toasts, kept by the app, and how they show.
pub const Toasts = struct {
    position: Position = .bottom_right,
    /// Spread out always, not only under the pointer.
    expand: bool = false,
    /// How many show at once.
    visible: usize = visible_max,
    /// Room between toasts spread out, and how far each peeks out behind.
    gap: f32 = 14,
    /// Room between the toasts and the window's edges.
    offset: f32 = 24,
    /// Tinted backgrounds after each kind (green for success, ...).
    rich_colors: bool = false,
    /// A close button at each toast's corner.
    close_button: bool = false,
    /// The theme's colors swapped: dark toasts in the light.
    invert: bool = false,
    /// Alt+T spreads them out and takes the keyboard to the newest.
    hotkey: bool = true,
    /// The ways a swipe closes a toast: toward the edges they are at when null.
    swipe_directions: ?Directions = null,

    items: [capacity]Item = undefined,
    len: usize = 0,
    /// The context's clock as last seen, and the frame.
    last_time: f64 = -1,
    last_frame: u64 = std.math.maxInt(u64),
    /// Their time stops: the pointer is over them, or the keyboard.
    paused: bool = false,
    /// Spread out by the pointer over them, or by the hotkey.
    hovered: bool = false,
    by_keys: bool = false,
    /// The focus as the hotkey took it, given back with Escape.
    return_focus: u64 = 0,

    pub fn idOf(t: Toast) u64 {
        return std.hash.Wyhash.hash(0x746f617374, if (t.key.len > 0) t.key else t.title);
    }

    /// Shows a toast, or changes the one showing with its key; returns its id.
    pub fn add(s: *Toasts, t: Toast) u64 {
        const id = idOf(t);
        var item: Item = .{ .id = id, .left = 0 };
        var at: ?usize = null;
        if (s.find(id)) |i| {
            if (s.items[i].closing) s.removeAt(i) else {
                at = i;
                item = s.items[i];
                item.fresh = false;
                item.changed = true;
            }
        }
        if (at == null and s.len == capacity) s.removeAt(0);
        const was_loading = at != null and item.kind == .loading;
        item.title.set(t.title);
        item.description.set(t.description);
        item.action.set(t.action);
        item.cancel.set(t.cancel);
        item.kind = t.kind;
        item.dismissible = t.dismissible;
        item.close_button = t.close_button;
        item.rich_colors = t.rich_colors;
        item.icon.set(t.icon);
        item.content = t.content;
        item.settled = was_loading and t.kind != .loading;
        item.left = if (t.timeout != 0)
            t.timeout
        else if (t.kind == .loading)
            -1
        else if (t.action.len > 0)
            action_timeout
        else
            default_timeout;
        if (at) |i| s.items[i] = item else {
            s.items[s.len] = item;
            s.len += 1;
        }
        return id;
    }

    pub fn show(s: *Toasts, title: []const u8) u64 {
        return s.add(.{ .title = title });
    }

    pub fn success(s: *Toasts, title: []const u8) u64 {
        return s.add(.{ .title = title, .kind = .success });
    }

    pub fn info(s: *Toasts, title: []const u8) u64 {
        return s.add(.{ .title = title, .kind = .info });
    }

    pub fn warning(s: *Toasts, title: []const u8) u64 {
        return s.add(.{ .title = title, .kind = .warning });
    }

    pub fn failure(s: *Toasts, title: []const u8) u64 {
        return s.add(.{ .title = title, .kind = .@"error" });
    }

    /// A toast with a spinner, until `add` with the same `key` says how the
    /// work went (as sonner's `toast.promise`), or `close`.
    pub fn loading(s: *Toasts, title: []const u8, key: []const u8) u64 {
        return s.add(.{ .title = title, .kind = .loading, .key = key });
    }

    /// A toast with a button, as Undo after deleting.
    pub fn showAction(s: *Toasts, title: []const u8, action: []const u8) u64 {
        return s.add(.{ .title = title, .action = action });
    }

    /// Closes the toast `id` (it leaves).
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

    pub fn find(s: *const Toasts, id: u64) ?usize {
        for (s.items[0..s.len], 0..) |it, i| if (it.id == id) return i;
        return null;
    }

    pub fn removeAt(s: *Toasts, i: usize) void {
        std.mem.copyForwards(Item, s.items[i .. s.len - 1], s.items[i + 1 .. s.len]);
        s.len -= 1;
    }

    /// Runs the toasts' time to the context's clock, once a frame;
    /// returns one whose time ran out.
    pub fn tick(s: *Toasts, c: *Context) ?u64 {
        if (s.last_frame == c.frame) return null;
        s.last_frame = c.frame;
        const elapsed: f32 = if (s.last_time < 0) 0 else @floatCast(@max(0, c.time - s.last_time));
        s.last_time = c.time;
        if (s.paused) return null;
        var out: ?u64 = null;
        for (s.items[0..s.len]) |*it| {
            if (it.closing or it.left < 0) continue;
            it.left -= elapsed;
            if (it.left <= 0) {
                it.closing = true;
                out = it.id;
            }
        }
        return out;
    }
};

pub const Result = struct {
    /// The toast whose action button was clicked in this frame (closed).
    action: ?u64 = null,
    /// The toast whose Cancel was clicked in this frame (closed).
    cancel: ?u64 = null,
    /// A toast closed by its close button or a swipe in this frame, as
    /// sonner's `onDismiss`.
    closed: ?u64 = null,
    /// A toast whose time ran out in this frame, as sonner's `onAutoClose`.
    timed_out: ?u64 = null,
};

pub const toasts = @import("toast_view.zig").toasts;
