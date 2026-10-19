//! Flyouts: borderless windows without a taskbar button, placed next to a
//! rectangle (a box of a window, a point, a tray icon) and kept in the
//! work area of a display, as menus and popovers are. `App.newFlyout`
//! makes them; this is where they go, the same on every platform.
const std = @import("std");

/// A rectangle in screen points, or pixels: its origin is its top left.
pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,

    pub fn contains(r: Rect, x: f64, y: f64) bool {
        return x >= r.x and y >= r.y and x < r.x + r.width and y < r.y + r.height;
    }

    pub fn scaled(r: Rect, s: f64) Rect {
        return .{ .x = r.x * s, .y = r.y * s, .width = r.width * s, .height = r.height * s };
    }
};

/// Where a flyout goes from its anchor: the side, and how it lines up
/// with the anchor along that side (`bottom_start`: below it, their left
/// edges lined up).
pub const Placement = enum {
    bottom_start,
    bottom,
    bottom_end,
    top_start,
    top,
    top_end,
    right_start,
    right,
    right_end,
    left_start,
    left,
    left_end,

    pub const Side = enum { bottom, top, right, left };

    pub fn side(p: Placement) Side {
        return @enumFromInt(@intFromEnum(p) / 3);
    }

    /// -1 for the start, 0 for the center, 1 for the end.
    pub fn cross(p: Placement) i8 {
        return @as(i8, @intCast(@intFromEnum(p) % 3)) - 1;
    }
};

/// What a dismissed flyout does: a focusable one is dismissed when
/// another window takes the keyboard (a click elsewhere, the app
/// deactivated) or on Escape.
pub const Dismiss = enum {
    /// Closes, as the user closing it (`on_close_request` may keep it).
    close,
    /// Hides, to show again (a menu bar app's panel toggled by its icon).
    hide,
};

/// A point of a rectangle on one axis: -1 its start, 0 its middle, 1 its end.
const Gravity = struct { x: i8, y: i8 };

fn gravities(p: Placement, gap: f64) struct { anchor: Gravity, window: Gravity, dx: f64, dy: f64 } {
    const c = p.cross();
    return switch (p.side()) {
        .top => .{ .anchor = .{ .x = c, .y = -1 }, .window = .{ .x = c, .y = 1 }, .dx = 0, .dy = -gap },
        .right => .{ .anchor = .{ .x = 1, .y = c }, .window = .{ .x = -1, .y = c }, .dx = gap, .dy = 0 },
        .left => .{ .anchor = .{ .x = -1, .y = c }, .window = .{ .x = 1, .y = c }, .dx = -gap, .dy = 0 },
        .bottom => .{ .anchor = .{ .x = c, .y = 1 }, .window = .{ .x = c, .y = -1 }, .dx = 0, .dy = gap },
    };
}

/// Where a flyout of `width` × `height` goes against `anchor`, in the work
/// area `work`, resolved as GTK places popups (flip, slide, resize) and
/// as mygo does: on each axis it flips to the other side of the anchor,
/// or its other end, where it would not fit and the flipped one would;
/// then slides back into the work area; then shrinks to it.
pub fn place(anchor: Rect, width: f64, height: f64, placement: Placement, gap: f64, work: Rect) Rect {
    const g = gravities(placement, gap);
    var r: Rect = .{ .width = width, .height = height };
    r.x = flip(work.x, work.width, anchor.x, anchor.width, width, g.anchor.x, g.window.x, g.dx);
    r.y = flip(work.y, work.height, anchor.y, anchor.height, height, g.anchor.y, g.window.y, g.dy);
    slide(work.x, work.width, &r.x, &r.width);
    slide(work.y, work.height, &r.y, &r.height);
    return r;
}

/// A flyout without an anchor (a tray icon the system does not place):
/// in the middle of the work area, as large as fits.
pub fn centered(width: f64, height: f64, work: Rect) Rect {
    const w = @min(width, work.width);
    const h = @min(height, work.height);
    return .{ .x = work.x + (work.width - w) / 2, .y = work.y + (work.height - h) / 2, .width = w, .height = h };
}

fn flip(bounds_pos: f64, bounds_size: f64, rect_pos: f64, rect_size: f64, size: f64, rect_sign: i8, window_sign: i8, offset: f64) f64 {
    const rs: f64 = @floatFromInt(rect_sign);
    const ws: f64 = @floatFromInt(window_sign);
    const primary = rect_pos + (1 + rs) * rect_size / 2 + offset - (1 + ws) * size / 2;
    const fits = struct {
        fn f(p: f64, s: f64, bp: f64, bs: f64) bool {
            return p >= bp and p + s <= bp + bs;
        }
    }.f;
    if (fits(primary, size, bounds_pos, bounds_size)) return primary;
    const secondary = rect_pos + (1 - rs) * rect_size / 2 - offset - (1 - ws) * size / 2;
    if (fits(secondary, size, bounds_pos, bounds_size)) return secondary;
    return primary;
}

fn slide(bounds_pos: f64, bounds_size: f64, pos: *f64, size: *f64) void {
    if (pos.* + size.* > bounds_pos + bounds_size) pos.* = bounds_pos + bounds_size - size.*;
    if (pos.* < bounds_pos) pos.* = bounds_pos;
    if (pos.* + size.* > bounds_pos + bounds_size) size.* = bounds_pos + bounds_size - pos.*;
    size.* = @max(size.*, 1);
}

/// What `App.newFlyout` takes, with each platform's window and tray.
pub fn Options(comptime Window: type, comptime Tray: type, comptime Content: type, comptime Theme: type) type {
    return struct {
        /// The window whose content `anchor` is in: the flyout stays
        /// above it. A flyout has a parent, a tray, or neither (then
        /// `anchor` is on the screen).
        parent: ?*Window = null,
        /// Anchors the flyout to a tray icon, as a menu bar app's panel:
        /// next to the icon (below one of the macOS menu bar, flipped above
        /// one of a taskbar at the bottom), above other apps' windows.
        /// Where the system does not tell where the icon is (Linux), in
        /// the middle of the primary display's work area.
        tray: ?*Tray = null,
        /// In points: in the parent's content, or on the screen.
        anchor: Rect = .{},
        placement: Placement = .bottom_start,
        gap: f64 = 0,
        width: f64 = 200,
        height: f64 = 200,
        /// Takes the keyboard as it shows, and is dismissed when another
        /// window takes it. Without it, the flyout never takes the
        /// keyboard (tooltips, suggestions) and stays until closed.
        focusable: bool = true,
        dismiss: Dismiss = .close,
        /// Created hidden: `Window.show` shows it, placed again.
        hidden: bool = false,
        /// On macOS, the look of the system's popovers: it shows in an
        /// NSPopover (material, rounded corners, an arrow pointing at the
        /// anchor's middle, animations), on `placement`'s side or the
        /// opposite one; the rest of the placement, and `gap`, do not
        /// apply. It needs a `parent` or a `tray`. Elsewhere, a regular
        /// flyout.
        popover: bool = false,
        /// A translucent, blurred material behind the content, as a
        /// window's `material`: content drawn opaque covers it. A
        /// popover has its own.
        material: @import("window_types.zig").Material = .none,
        /// Rounds the corners on macOS, in points: the material and the
        /// content are cut to them, and the shadow follows them. Windows
        /// 11 rounds flyouts as it rounds its menus; Linux does not.
        corner_radius: f64 = 0,
        theme: ?Theme = null,
        content: Content,
    };
}

/// What a window keeps of its flyout options (`Options` without the
/// content), the platform's tray behind a pointer.
pub const State = struct {
    parent: ?*anyopaque = null,
    tray: ?*anyopaque = null,
    anchor: Rect = .{},
    placement: Placement = .bottom_start,
    gap: f64 = 0,
    focusable: bool = true,
    dismiss: Dismiss = .close,
    popover: bool = false,
    radius: f64 = 0,

    pub fn of(o: anytype) State {
        return .{ .parent = o.parent, .tray = o.tray, .anchor = o.anchor, .placement = o.placement, .gap = o.gap, .focusable = o.focusable, .dismiss = o.dismiss, .popover = o.popover, .radius = o.corner_radius };
    }
};

const testing = std.testing;

fn expectRect(want: Rect, got: Rect) !void {
    try testing.expectEqual(want.x, got.x);
    try testing.expectEqual(want.y, got.y);
    try testing.expectEqual(want.width, got.width);
    try testing.expectEqual(want.height, got.height);
}

test "a flyout goes below its anchor, and flips above it at the bottom of the screen" {
    const work: Rect = .{ .width = 1000, .height = 800 };
    const button: Rect = .{ .x = 100, .y = 100, .width = 80, .height = 30 };
    try expectRect(.{ .x = 100, .y = 134, .width = 200, .height = 300 }, place(button, 200, 300, .bottom_start, 4, work));
    try expectRect(.{ .x = 40, .y = 134, .width = 200, .height = 300 }, place(button, 200, 300, .bottom, 4, work));
    // Its right edge on the button's would cross the screen's left: the other end.
    try expectRect(.{ .x = 100, .y = 134, .width = 200, .height = 300 }, place(button, 200, 300, .bottom_end, 4, work));
    try expectRect(.{ .x = 380, .y = 134, .width = 200, .height = 300 }, place(.{ .x = 500, .y = 100, .width = 80, .height = 30 }, 200, 300, .bottom_end, 4, work));
    // A taskbar's icon at the bottom: no room below, so above.
    const icon: Rect = .{ .x = 900, .y = 770, .width = 24, .height = 30 };
    try expectRect(.{ .x = 800, .y = 470, .width = 200, .height = 300 }, place(icon, 200, 300, .bottom, 0, work));
    try testing.expectEqual(Placement.Side.left, Placement.left_end.side());
    try testing.expectEqual(@as(i8, 1), Placement.left_end.cross());
}

test "a flyout slides back into the work area, and shrinks to it" {
    const work: Rect = .{ .x = 0, .y = 0, .width = 500, .height = 400 };
    // To the right of an anchor, without room on either side: it slides.
    try testing.expectEqual(@as(f64, 0), place(.{ .x = 300, .y = 10, .width = 10, .height = 10 }, 300, 100, .right_start, 0, work).x);
    const r = place(.{ .x = 250, .y = 10, .width = 10, .height = 10 }, 300, 100, .right_start, 0, work);
    try testing.expectEqual(@as(f64, 200), r.x);
    // Taller than the screen: it shrinks.
    const tall = place(.{ .x = 10, .y = 10, .width = 10, .height = 10 }, 100, 900, .bottom_start, 0, work);
    try expectRect(.{ .x = 10, .y = 0, .width = 100, .height = 400 }, tall);
    try expectRect(.{ .x = 150, .y = 100, .width = 200, .height = 200 }, centered(200, 200, work));
}
