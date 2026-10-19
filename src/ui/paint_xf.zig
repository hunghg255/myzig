//! Transforms as painted (`Style.transform`): the space a box's subtree is
//! drawn in. Most transforms only move boxes and scale them alike both
//! ways (`Affine.isSimilar`): those are folded into the instances, which
//! stay plain boxes, and every renderer draws them as it draws any. Others
//! (turns, slants, uneven scales) keep their instances in the subtree's
//! own coordinates and give them the transform's rows (`gpu.transform_rows`),
//! which the renderers read to draw each pixel from where it is in them.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const Affine = types.Affine;
const Rect = types.Rect;

pub const Mode = enum { plain, similar, general };

/// Where a subtree draws: its coordinates (the layout's, transformed by
/// `m` into the window's), and, drawn generally, its rows and the clip
/// around it in the window.
pub const Space = struct {
    m: Affine = .identity,
    mode: Mode = .plain,
    row: u32 = 0,
    outer: Rect = Rect.infinite,
};

/// The space of a box with transform `local` (about its origin already),
/// in `sp` whose clip is `clip`: and the clip in the new coordinates. Null
/// for a transform that flattens the box, which shows nothing.
pub fn enter(rows: *std.ArrayList([4]f32), gpa: std.mem.Allocator, sp: Space, local: Affine, clip: Rect) ?struct { Space, Rect } {
    if (!local.finite()) return null;
    const m = sp.m.mul(local);
    const inv = m.inverse() orelse return null;
    // The clip in the window: exact unless the space around turns.
    var world = if (sp.mode == .general) sp.outer.intersect(sp.m.bounds(clip)) else sp.m.bounds(clip);
    if (isInfinite(clip)) world = if (sp.mode == .general) sp.outer else Rect.infinite;
    if (m.isIdentity()) return .{ .{}, world };
    if (m.isSimilar()) return .{ .{ .m = m, .mode = .similar }, if (isInfinite(world)) Rect.infinite else inv.bounds(world) };
    const row: u32 = @intCast(rows.items.len);
    rows.appendSlice(gpa, &.{
        .{ inv.a, inv.b, inv.c, inv.d },
        .{ inv.x, inv.y, m.x, m.y },
        .{ m.a, m.b, m.c, m.d },
        gpu.clip4(world),
    }) catch return null;
    return .{ .{ .m = m, .mode = .general, .row = row, .outer = world }, Rect.infinite };
}

fn isInfinite(r: Rect) bool {
    return r.x <= -1e5 and r.y <= -1e5 and r.w >= 1e5 and r.h >= 1e5;
}

/// `i`, made in `sp`'s coordinates, as the renderers draw it.
pub fn place(sp: *const Space, i: gpu.Instance) gpu.Instance {
    switch (sp.mode) {
        .plain => return i,
        .general => {
            var o = i;
            o.kind = gpu.withTransform(i.kind, sp.row);
            return o;
        },
        .similar => {
            const s = sp.m.a;
            var o = i;
            o.rect = .{ i.rect[0] * s + sp.m.x, i.rect[1] * s + sp.m.y, i.rect[2] * s, i.rect[3] * s };
            if (i.clip[0] > -1e5 or i.clip[2] < 1e5 or i.clip[1] > -1e5 or i.clip[3] < 1e5)
                o.clip = .{ i.clip[0] * s + sp.m.x, i.clip[1] * s + sp.m.y, i.clip[2] * s + sp.m.x, i.clip[3] * s + sp.m.y };
            o.radius = i.radius * s;
            // A glyph's border width is unused; a shadow's is its blur.
            if (i.kind != gpu.Kind.text) o.border_width = i.border_width * s;
            const round = gpu.clipCorners(i.clip_round);
            o.clip_round = if (round.continuous) gpu.clipContinuous(round.radius * s, round.corners) else gpu.clipRound(round.radius * s, round.corners);
            return o;
        },
    }
}

/// A rectangle of `sp`'s coordinates in the instances' (the window's,
/// but for a general transform, whose instances keep their own).
pub fn toInstance(sp: *const Space, r: Rect) Rect {
    return if (sp.mode == .similar) sp.m.bounds(r) else r;
}

/// A hit for box `id` whose visible part is `visible` in `sp`.
pub fn hit(sp: *const Space, id: u64, index: u32, visible: Rect, scroll: bool) @import("hit.zig").Hit {
    return switch (sp.mode) {
        .plain => .{ .id = id, .index = index, .rect = visible, .scroll = scroll },
        .similar => .{ .id = id, .index = index, .rect = sp.m.bounds(visible), .scroll = scroll },
        .general => .{ .id = id, .index = index, .rect = visible, .scroll = scroll, .inverse = sp.m.inverse(), .outer = sp.outer },
    };
}

test "a similar transform folds into the instance; a turn keeps it and adds rows" {
    const gpa = std.testing.allocator;
    var rows: std.ArrayList([4]f32) = .empty;
    defer rows.deinit(gpa);
    const clip: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const s = enter(&rows, gpa, .{}, Affine.scaling(2, 2).translate(10, 0), clip).?;
    try std.testing.expectEqual(Mode.similar, s[0].mode);
    try std.testing.expectEqual(@as(f32, -5), s[1].x);
    try std.testing.expectEqual(@as(f32, 50), s[1].w);
    const box = place(&s[0], .{ .rect = .{ 1, 1, 4, 4 }, .color = .{ 1, 0, 0, 1 }, .radius = 2 });
    try std.testing.expectEqual([4]f32{ 12, 2, 8, 8 }, box.rect);
    try std.testing.expectEqual(@as(f32, 4), box.radius);
    try std.testing.expectEqual(@as(usize, 0), rows.items.len);
    const t = enter(&rows, gpa, .{}, Affine.rotation(30), clip).?;
    try std.testing.expectEqual(Mode.general, t[0].mode);
    try std.testing.expectEqual(@as(usize, gpu.transform_rows), rows.items.len);
    try std.testing.expectEqual(@as(?u32, 0), gpu.transformOf(place(&t[0], .{ .rect = .{ 0, 0, 1, 1 }, .color = .{ 0, 0, 0, 1 } }).kind));
    try std.testing.expect(enter(&rows, gpa, .{}, Affine.scaling(0, 1), clip) == null);
}
