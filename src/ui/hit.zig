//! What the pointer can be over: an interactive box's visible rectangle,
//! recorded as it is painted (`paint.zig`), in paint order. A box drawn
//! turned or slanted (`Style.transform`) keeps its own rectangle and the
//! map from the window to it, so the pointer follows what is drawn.
const types = @import("types.zig");

pub const Hit = struct {
    id: u64,
    index: u32,
    /// In the window, or, with `inverse`, in the box's own coordinates.
    rect: types.Rect,
    scroll: bool,
    /// From the window to `rect`'s coordinates, for a box drawn transformed.
    inverse: ?types.Affine = null,
    /// What clips it in the window, around its transform.
    outer: types.Rect = types.Rect.infinite,

    pub fn contains(h: Hit, p: types.Point) bool {
        const m = h.inverse orelse return h.rect.contains(p);
        return h.outer.contains(p) and h.rect.contains(m.apply(p));
    }
};

test "a turned box takes the pointer where it is drawn" {
    const std = @import("std");
    const m = types.Affine.rotation(45).about(.{ .x = 50, .y = 50 });
    const h: Hit = .{ .id = 1, .index = 0, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .scroll = false, .inverse = m.inverse() };
    // The box's corner turned away: (2, 2) is outside it now, (50, -15) inside.
    try std.testing.expect(!h.contains(.{ .x = 2, .y = 2 }));
    try std.testing.expect(h.contains(.{ .x = 50, .y = -15 }));
    try std.testing.expect(h.contains(.{ .x = 50, .y = 50 }));
}
