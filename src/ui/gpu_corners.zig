//! Shadows with continuous corners cut into nine-patches for the GPU
//! renderers, after mygo's (its `internal/gpu/corners.go`). A blurred
//! shadow finds, for each of its four rows of samples, where its corners'
//! curve narrows the box, by regula falsi (`raster_corner.zig`'s
//! `inset`): at every pixel of the rows whose samples reach the curved
//! rows, near its top and its bottom, whichever column the pixel is in.
//! Yet far from its sides, a pixel's blurred edges are exactly 0 and 1
//! wherever the curve puts them (erf rounds to ±1 from about 7.7 standard
//! deviations, and these are 9 or more from where the curve can put the
//! sides), and between those rows the curve is not reached at all: there
//! the shadow of the box with square corners (its twin) has the very same
//! value, without the search.
//!
//! So a large shadow is drawn as up to seven pieces, each the same
//! instance clipped to its part of the pixels it covers: the bands of rows
//! across its corners as it is at their ends and as its twin between, and
//! the band between them as its twin. A piece costs an instance (its
//! vertices and the rasterizer's setup, `piece_cost`); a band is cut only
//! where the pixels its twin draws save more, and a shadow whose pieces
//! save less than they cost stays whole. Fills and pictures are not cut:
//! one shader draws every instance, and away from their corners' boxes
//! theirs computes what it computes for square corners, at the cost of a
//! few comparisons.
//!
//! The pixels are the same: the CPU renderer draws the shadow whole.
const std = @import("std");
const gpu = @import("gpu.zig");
const corner = @import("raster_corner.zig");
const Instance = gpu.Instance;

/// What a piece costs, in pixels of the twin drawn instead of the curved
/// rows; a pixel there saves `curved_weight` (the search's five values of
/// the curve, for each of four samples).
const piece_cost = 512;
const curved_weight = 6;

/// Pixels x0, y0, x1, y1.
const Box = [4]i64;

fn area(b: Box) i64 {
    if (b[2] <= b[0] or b[3] <= b[1]) return 0;
    return (b[2] - b[0]) * (b[3] - b[1]);
}

/// Whether the instance is a shadow with continuous corners, drawn as it
/// is (not transformed), that no clip rounds.
fn splits(i: *const Instance) bool {
    return i.kind == gpu.Kind.shadow and i.radius < 0 and i.clip_round <= 0;
}

/// Up to seven pieces of `i` (`scale` pixels a point), shapes and twins,
/// or none when it is better drawn whole.
fn pieces(i: *const Instance, scale: f32, out: *[7]Instance) usize {
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const sigma = @max(i.border_width, 0.25);
    const e = @min(-i.radius, @min(hw, hh)) * corner.extent;
    const grow = i.border_width * 3;
    // The pixels the quad covers, as the renderers round them.
    const q: Box = .{
        @intFromFloat(@round(@max(i.rect[0] - grow, i.clip[0]) * scale)),
        @intFromFloat(@round(@max(i.rect[1] - grow, i.clip[1]) * scale)),
        @intFromFloat(@round(@min(i.rect[0] + i.rect[2] + grow, i.clip[2]) * scale)),
        @intFromFloat(@round(@min(i.rect[1] + i.rect[3] + grow, i.clip[3]) * scale)),
    };
    if (area(q) == 0) return 0;
    // The columns 9 sigma from where the curve can put the sides, and the
    // rows whose samples (3 sigma each way) miss the curved rows, a pixel
    // in from both for rounding.
    const px = struct {
        fn ceil(v: f32) i64 {
            return @intFromFloat(@ceil(v));
        }
        fn floor(v: f32) i64 {
            return @intFromFloat(@floor(v));
        }
    };
    const left = px.ceil((i.rect[0] + e + 9 * sigma) * scale + 1);
    const right = px.floor((i.rect[0] + i.rect[2] - e - 9 * sigma) * scale - 1);
    var top = px.ceil((i.rect[1] + e + 3 * sigma) * scale + 1);
    const bottom = px.floor((i.rect[1] + i.rect[3] - e - 3 * sigma) * scale - 1);
    top = std.math.clamp(top, q[1], q[3]);
    const bot = std.math.clamp(bottom, top, q[3]);
    var boxes: [7]Box = undefined;
    var twin: [7]bool = undefined;
    var n: usize = 0;
    const add = struct {
        fn f(bs: *[7]Box, ts: *[7]bool, k: *usize, b: Box, t: bool) void {
            if (area(b) == 0) return;
            bs[k.*] = b;
            ts[k.*] = t;
            k.* += 1;
        }
    }.f;
    var saved: i64 = 0;
    const mid: Box = .{ q[0], top, q[2], bot };
    for ([2]Box{ .{ q[0], q[1], q[2], top }, .{ q[0], bot, q[2], q[3] } }) |band| {
        if (area(band) == 0) continue;
        const between: Box = .{ @max(left, band[0]), band[1], @min(right, band[2]), band[3] };
        const ends: i64 = @as(i64, @intFromBool(between[0] > band[0])) + @intFromBool(between[2] < band[2]);
        if (area(between) * curved_weight <= piece_cost * ends) {
            add(&boxes, &twin, &n, band, false);
            continue;
        }
        add(&boxes, &twin, &n, .{ band[0], band[1], between[0], band[3] }, false);
        add(&boxes, &twin, &n, between, true);
        add(&boxes, &twin, &n, .{ between[2], band[1], band[2], band[3] }, false);
        saved += area(between) * curved_weight;
    }
    add(&boxes, &twin, &n, mid, true);
    if (n <= 1 or saved <= piece_cost * @as(i64, @intCast(n - 1))) return 0;
    const inv = 1 / scale;
    for (boxes[0..n], twin[0..n], out[0..n]) |b, t, *o| {
        o.* = i.*;
        if (t) o.radius = 0;
        // A piece's edge on the quad's keeps the clip's, which rounds to it.
        o.clip = .{
            if (b[0] == q[0]) i.clip[0] else @as(f32, @floatFromInt(b[0])) * inv,
            if (b[1] == q[1]) i.clip[1] else @as(f32, @floatFromInt(b[1])) * inv,
            if (b[2] == q[2]) i.clip[2] else @as(f32, @floatFromInt(b[2])) * inv,
            if (b[3] == q[3]) i.clip[3] else @as(f32, @floatFromInt(b[3])) * inv,
        };
    }
    return n;
}

/// A frame's instances (packed as `gpu.Frame.of` reads them) with its
/// large shadows with continuous corners cut into pieces, in `out`; or
/// `all` itself when none is.
pub fn split(gpa: std.mem.Allocator, all: []const Instance, scale: f32, out: *std.ArrayList(Instance)) []const Instance {
    const fr = gpu.Frame.of(all);
    const first = for (fr.instances, 0..) |*i, k| {
        if (splits(i)) {
            var buf: [7]Instance = undefined;
            if (pieces(i, scale, &buf) > 0) break k;
        }
    } else return all;
    out.clearRetainingCapacity();
    out.appendSlice(gpa, fr.instances[0..first]) catch return all;
    for (fr.instances[first..]) |*i| {
        var buf: [7]Instance = undefined;
        const n = if (splits(i)) pieces(i, scale, &buf) else 0;
        if (n == 0) {
            out.append(gpa, i.*) catch return all;
        } else out.appendSlice(gpa, buf[0..n]) catch return all;
    }
    if (fr.first_row_instance < all.len) {
        // The rows, after the instances, and where they start.
        const at = out.items.len;
        out.appendSlice(gpa, all[fr.first_row_instance..]) catch return all;
        out.items[out.items.len - 1].rect[0] = @floatFromInt(at);
    }
    return out.items;
}

test "a large shadow is cut into its corners' bands and its twin, which draw the pixels it draws" {
    const raster = @import("raster.zig");
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Instance) = .empty;
    defer out.deinit(gpa);
    const shadow: Instance = .{ .rect = .{ 40, 30, 300, 160 }, .color = .{ 0, 0, 0, 0.5 }, .radius = -24, .border_width = 6, .kind = gpu.Kind.shadow };
    const small: Instance = .{ .rect = .{ 10, 10, 20, 16 }, .color = .{ 0, 0, 0, 0.5 }, .radius = -6, .border_width = 3, .kind = gpu.Kind.shadow };
    const box: Instance = .{ .rect = .{ 40, 30, 300, 160 }, .color = .{ 1, 1, 1, 1 }, .radius = -24 };
    const frame = [_]Instance{ small, shadow, box };
    const cut = split(gpa, &frame, 2, &out);
    // The small shadow stays whole; the large one is seven pieces.
    try std.testing.expectEqual(@as(usize, 1 + 7 + 1), cut.len);
    var twins: usize = 0;
    for (cut[1..8]) |i| twins += @intFromBool(i.radius == 0);
    try std.testing.expectEqual(@as(usize, 3), twins);
    // Nothing to cut: the frame itself.
    try std.testing.expectEqual(@as([*]const Instance, &frame), split(gpa, frame[0..1], 2, &out).ptr);
    for ([_]f32{ 2, 1.5, 1 }) |scale| {
        const cut2 = split(gpa, &frame, scale, &out);
        const w = 400;
        const h = 240;
        const a = try gpa.alloc(u8, w * h * 4);
        defer gpa.free(a);
        const b = try gpa.alloc(u8, w * h * 4);
        defer gpa.free(b);
        const none: raster.Mask = .{ .pixels = &.{}, .size = 0 };
        raster.draw(.{ .bytes = a, .width = w, .height = h }, &frame, none, .{}, scale, .{ .r = 0.9, .g = 0.9, .b = 0.9 });
        raster.draw(.{ .bytes = b, .width = w, .height = h }, cut2, none, .{}, scale, .{ .r = 0.9, .g = 0.9, .b = 0.9 });
        try std.testing.expectEqualSlices(u8, a, b);
    }
}

test "the rows after the instances move with them" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(Instance) = .empty;
    defer list.deinit(gpa);
    var out: std.ArrayList(Instance) = .empty;
    defer out.deinit(gpa);
    try list.append(gpa, .{ .rect = .{ 40, 30, 300, 160 }, .color = .{ 0, 0, 0, 0.5 }, .radius = -24, .border_width = 6, .kind = gpu.Kind.shadow });
    try gpu.appendRows(gpa, &list, &.{ .{ 1, 2, 3, 4 }, .{ 5, 6, 7, 8 } });
    const f = gpu.Frame.of(split(gpa, list.items, 2, &out));
    try std.testing.expectEqual(@as(usize, 7), f.instances.len);
    try std.testing.expectEqual([4]f32{ 5, 6, 7, 8 }, f.rows[1]);
}
