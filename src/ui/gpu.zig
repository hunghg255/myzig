//! What the renderers draw, whichever draws it: instanced quads that are
//! rounded rectangles with borders, glyphs and icons from the atlas,
//! shadows, or pictures from the image atlas, each clipped. Metal draws them on macOS (`metal.zig`, with
//! `shader.metal`); `raster.zig` draws the same pixels on the CPU.
const types = @import("types.zig");
const std = @import("std");

/// One quad, as the shader reads it.
pub const Instance = extern struct {
    rect: [4]f32,
    color: [4]f32,
    border_color: [4]f32 = .{ 0, 0, 0, 0 },
    uv: [4]f32 = .{ 0, 0, 0, 0 },
    clip: [4]f32 = .{ -1e6, -1e6, 1e6, 1e6 },
    /// The corners' radius; negative for continuous corners
    /// (`raster_corner.zig`).
    radius: f32 = 0,
    border_width: f32 = 0,
    kind: f32 = 0,
    /// The clip's rounded corners (`clipRound`): 0 for a plain rectangle.
    clip_round: f32 = 0,
};

/// The clip rectangle's corners rounded by `radius`: those in `corners`
/// (1 top left, 2 top right, 4 bottom right, 8 bottom left), packed in one
/// float as the shader reads it.
pub fn clipRound(radius: f32, corners: u4) f32 {
    if (corners == 0 or radius <= 0) return 0;
    return @as(f32, @floatFromInt(corners)) * 4096 + @min(radius, 4095);
}

/// `clipRound` for continuous corners (`raster_corner.zig`): the corners'
/// bits plus 16.
pub fn clipContinuous(radius: f32, corners: u4) f32 {
    if (corners == 0 or radius <= 0) return 0;
    return (@as(f32, @floatFromInt(corners)) + 16) * 4096 + @min(radius, 4095);
}

/// `clipRound` (or `clipContinuous`) unpacked: the radius, the corners,
/// and whether they are continuous.
pub fn clipCorners(v: f32) struct { radius: f32, corners: u4, continuous: bool = false } {
    if (v <= 0) return .{ .radius = 0, .corners = 0 };
    const m = @floor(v / 4096);
    const k: u32 = @intFromFloat(m);
    return .{ .radius = v - m * 4096, .corners = @intCast(k & 15), .continuous = k >= 16 };
}

pub const Kind = struct {
    pub const quad: f32 = 0;
    pub const text: f32 = 1;
    pub const shadow: f32 = 2;
    /// A picture from the image atlas (`images.zig`), its corners rounded.
    pub const image: f32 = 3;
    /// Where a backdrop effect draws, in paint order (`effect.zig`): its
    /// shape is the rect and radius, `uv[0]` the effect's first row.
    pub const effect: f32 = 4;
    /// A rounded box filled by a gradient whose stops start at row `uv[0]`
    /// (`gradient.zig`), with a border as a quad's.
    pub const gradient: f32 = 5;
    /// Where a blurred layer starts (what follows, to its end, draws into
    /// it) and ends (the layer, blurred, is drawn over what was under it):
    /// `rect` the area it covers, `border_width` the blur, in points.
    pub const layer: f32 = 6;
    pub const layer_end: f32 = 7;
    /// The last instance of a frame with rows (`trailer`).
    pub const trailer: f32 = 15;
};

/// An instance's `kind` holds its kind and, for one drawn transformed, its
/// transform's first row (`transformRows`) plus one, times 16.
pub fn kindOf(kind: f32) f32 {
    return kind - @floor(kind / 16) * 16;
}

/// The first row of an instance's transform, if it has one.
pub fn transformOf(kind: f32) ?u32 {
    const t = @floor(kind / 16);
    if (t <= 0) return null;
    return @as(u32, @intFromFloat(t)) - 1;
}

/// Whether an instance marks where an effect or a layer draws: renderers
/// draw a frame in parts, between them.
pub fn isMarker(kind: f32) bool {
    const k = if (kind >= 16) kindOf(kind) else kind;
    return k == Kind.effect or k == Kind.layer or k == Kind.layer_end;
}

pub fn withTransform(kind: f32, row: u32) f32 {
    return kind + @as(f32, @floatFromInt(row + 1)) * 16;
}

/// A transform's rows: the map from the window to the instance's own
/// coordinates (a, b, c, d; then x, y), the map back (x, y; then a, b, c,
/// d), and the clip around it in the window (x0, y0, x1, y1). All in points.
pub const transform_rows = 4;

/// A frame's instances, and the rows of data its transforms, gradients and
/// effects read: those come after the instances drawn, packed six to an
/// instance, and a last instance of kind `trailer` says where they start.
/// A frame without rows is its instances alone.
pub const Frame = struct {
    instances: []const Instance,
    rows: []const [4]f32 = &.{},
    /// Where the rows start among the instances (`instances.len` without).
    first_row_instance: usize = 0,

    pub fn of(all: []const Instance) Frame {
        if (all.len == 0 or all[all.len - 1].kind != Kind.trailer) return .{ .instances = all, .first_row_instance = all.len };
        const s: usize = @intFromFloat(all[all.len - 1].rect[0]);
        const data = all[s .. all.len - 1];
        return .{ .instances = all[0..s], .rows = std.mem.bytesAsSlice([4]f32, std.mem.sliceAsBytes(data)), .first_row_instance = s };
    }
};

/// Appends `rows` to `out` as `Frame.of` reads them.
pub fn appendRows(gpa: std.mem.Allocator, out: *std.ArrayList(Instance), rows: []const [4]f32) !void {
    if (rows.len == 0) return;
    const first = out.items.len;
    const n = (rows.len + 5) / 6;
    try out.ensureUnusedCapacity(gpa, n + 1);
    for (0..n) |k| {
        var packed_rows: [6][4]f32 = @splat(.{ 0, 0, 0, 0 });
        const part = rows[k * 6 .. @min(rows.len, k * 6 + 6)];
        @memcpy(packed_rows[0..part.len], part);
        out.appendAssumeCapacity(std.mem.bytesToValue(Instance, std.mem.asBytes(&packed_rows)));
    }
    out.appendAssumeCapacity(.{ .rect = .{ @floatFromInt(first), 0, 0, 0 }, .color = .{ 0, 0, 0, 0 }, .kind = Kind.trailer });
}

test "a frame's rows ride after its instances" {
    var list: std.ArrayList(Instance) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, .{ .rect = .{ 1, 2, 3, 4 }, .color = .{ 1, 1, 1, 1 } });
    try std.testing.expectEqual(@as(usize, 0), Frame.of(list.items).rows.len);
    const rows = [_][4]f32{ .{ 1, 2, 3, 4 }, .{ 5, 6, 7, 8 }, .{ 9, 10, 11, 12 }, .{ 0, 0, 0, 1 }, .{ 0, 0, 0, 2 }, .{ 0, 0, 0, 3 }, .{ 7, 7, 7, 7 } };
    try appendRows(std.testing.allocator, &list, &rows);
    const f = Frame.of(list.items);
    try std.testing.expectEqual(@as(usize, 1), f.instances.len);
    try std.testing.expectEqual([4]f32{ 7, 7, 7, 7 }, f.rows[6]);
    try std.testing.expectEqual([4]f32{ 5, 6, 7, 8 }, f.rows[1]);
    try std.testing.expectEqual(@as(?u32, 41), transformOf(withTransform(Kind.shadow, 41)));
    try std.testing.expectEqual(Kind.shadow, kindOf(withTransform(Kind.shadow, 41)));
    try std.testing.expectEqual(@as(?u32, null), transformOf(Kind.image));
}

pub fn color4(c: types.Color) [4]f32 {
    return .{ c.r, c.g, c.b, c.a };
}

pub fn clip4(r: types.Rect) [4]f32 {
    return .{ r.x, r.y, r.x + r.w, r.y + r.h };
}

/// A rendered frame: BGRA, premultiplied, `width * 4` bytes per row.
pub const Pixels = struct {
    bytes: []u8,
    width: usize,
    height: usize,

    pub fn deinit(p: Pixels, gpa: std.mem.Allocator) void {
        gpa.free(p.bytes);
    }
};
