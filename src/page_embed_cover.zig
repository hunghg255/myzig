//! What native UI paints over a web view in native UI (`ui.webView`):
//! the system's web view is a native view above the window's frames, so
//! what the frame paints after the web view's box (its children, boxes
//! over it, overlays: popovers, menus, dialogs, toasts, tooltips) would
//! hide under the page. After each frame, `overlap` finds where those
//! instances fall in the web view's clip, and `render` draws them alone,
//! over transparency, for that region: the platform shows the pixels in a
//! view above the page (its cover), which takes the pointer where they are
//! opaque and lets it through to the page where they are not.
//!
//! Nothing is drawn when nothing overlaps, and only the overlapping region
//! when something does. Reached only by `ui/webview.zig`.
const std = @import("std");
const types = @import("ui/types.zig");
const gpu = @import("ui/gpu.zig");
const raster = @import("ui/raster.zig");

/// A cover's pixels: premultiplied BGRA (`0xAARRGGBB`), `w` × `h`, at
/// `x`, `y` in the window's device pixels.
pub const Image = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    px: []const u32,
    /// Device pixels per point.
    scale: f32,

    /// The pixel at `x`, `y` of the window (transparent outside).
    pub fn at(img: Image, x: i32, y: i32) u32 {
        if (x < img.x or y < img.y or x >= img.x + @as(i32, @intCast(img.w)) or y >= img.y + @as(i32, @intCast(img.h))) return 0;
        return img.px[@as(usize, @intCast(y - img.y)) * img.w + @as(usize, @intCast(x - img.x))];
    }
};

const Box = [4]f32; // x0, y0, x1, y1, in points of the window

/// Where instance `i` may draw in the window, or null if it draws
/// nothing (a quad without fill or border, a transparent glyph).
fn boundsOf(i: *const gpu.Instance, rows: []const [4]f32) ?Box {
    const k = gpu.kindOf(i.kind);
    if (k == gpu.Kind.layer_end) return null;
    const visible = switch (@as(u32, @intFromFloat(k))) {
        0 => i.color[3] > 0 or (i.border_width > 0 and i.border_color[3] > 0), // quad
        1, 2, 3 => i.color[3] > 0, // glyph, shadow, picture
        else => true, // effect, gradient, layer
    };
    if (!visible) return null;
    const grow: f32 = if (k == gpu.Kind.shadow) i.border_width * 3 + 1 else if (k == gpu.Kind.layer) 0 else 1;
    var b: Box = .{
        @max(i.rect[0] - grow, i.clip[0]),
        @max(i.rect[1] - grow, i.clip[1]),
        @min(i.rect[0] + i.rect[2] + grow, i.clip[2]),
        @min(i.rect[1] + i.rect[3] + grow, i.clip[3]),
    };
    if (b[2] <= b[0] or b[3] <= b[1]) return null;
    if (gpu.transformOf(i.kind)) |t| {
        // Drawn turned: the window's box around its corners, in the
        // clip around its transform.
        if (t + gpu.transform_rows > rows.len) return null;
        const r = rows[t..][0..gpu.transform_rows];
        var out: Box = .{ std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
        for ([_][2]f32{ .{ b[0], b[1] }, .{ b[2], b[1] }, .{ b[0], b[3] }, .{ b[2], b[3] } }) |p| {
            const wx = r[2][0] * p[0] + r[2][2] * p[1] + r[1][2];
            const wy = r[2][1] * p[0] + r[2][3] * p[1] + r[1][3];
            out = .{ @min(out[0], wx), @min(out[1], wy), @max(out[2], wx), @max(out[3], wy) };
        }
        b = .{ @max(out[0], r[3][0]), @max(out[1], r[3][1]), @min(out[2], r[3][2]), @min(out[3], r[3][3]) };
        if (b[2] <= b[0] or b[3] <= b[1]) return null;
    }
    return b;
}

fn meet(a: Box, b: Box) ?Box {
    const r: Box = .{ @max(a[0], b[0]), @max(a[1], b[1]), @min(a[2], b[2]), @min(a[3], b[3]) };
    return if (r[2] > r[0] and r[3] > r[1]) r else null;
}

fn boxOf(r: types.Rect) Box {
    return .{ r.x, r.y, r.x + r.w, r.y + r.h };
}

/// The box, within `clip` (points of the window), of what the frame
/// `all` (its instances, with their rows) draws from instance `from` on;
/// null when none of it falls there.
pub fn overlap(all: []const gpu.Instance, from: usize, clip: types.Rect) ?types.Rect {
    const fr = gpu.Frame.of(all);
    if (from >= fr.instances.len) return null;
    const c = boxOf(clip);
    var u: ?Box = null;
    for (fr.instances[from..]) |*i| {
        const b = meet(boundsOf(i, fr.rows) orelse continue, c) orelse continue;
        u = if (u) |v| .{ @min(v[0], b[0]), @min(v[1], b[1]), @max(v[2], b[2]), @max(v[3], b[3]) } else b;
    }
    const b = u orelse return null;
    return .{ .x = b[0], .y = b[1], .w = b[2] - b[0], .h = b[3] - b[1] };
}

/// The device pixels `r` touches, within those of `clip` (both in points),
/// on multiples of `unit` pixels (a platform's point, where it places
/// views in points; the nearest pixel to one at a fractional scale): x0,
/// y0, x1, y1; null when empty.
pub fn pixelArea(r: types.Rect, clip: types.Rect, scale: f32, unit: f32) ?[4]i32 {
    const u = @max(unit, 1);
    const f = struct {
        fn down(v: f32, s: f32, n: f32) i32 {
            return @intFromFloat(@round(@floor(@round(v * s * 1000) / 1000 / n) * n));
        }
        fn up(v: f32, s: f32, n: f32) i32 {
            return @intFromFloat(@round(@ceil(@round(v * s * 1000) / 1000 / n) * n));
        }
        fn near(v: f32, s: f32, n: f32) i32 {
            return @intFromFloat(@round(v * s / n) * n);
        }
    };
    const a: [4]i32 = .{
        @max(f.down(r.x, scale, u), f.near(clip.x, scale, u), 0),
        @max(f.down(r.y, scale, u), f.near(clip.y, scale, u), 0),
        @min(f.up(r.x + r.w, scale, u), f.near(clip.x + clip.w, scale, u)),
        @min(f.up(r.y + r.h, scale, u), f.near(clip.y + clip.h, scale, u)),
    };
    if (a[2] <= a[0] or a[3] <= a[1]) return null;
    return a;
}

/// A hash of what `render` would draw for `area`: the same, nothing to
/// draw again.
/// `generation` tells the atlases changed.
pub fn hashOf(all: []const gpu.Instance, from: usize, area: [4]i32, scale: f32, generation: u64) u64 {
    var h = std.hash.Wyhash.init(generation);
    h.update(std.mem.asBytes(&area));
    h.update(std.mem.asBytes(&scale));
    // Through the end: the rows the instances read ride after them.
    if (from < all.len) h.update(std.mem.sliceAsBytes(all[from..]));
    return h.final();
}

/// Draws the instances of frame `all` from `from` on, alone, over
/// transparency, into `out` for the device pixels `area` (`pixelArea`).
/// The renderer's dither follows pixels: the instances are moved by a
/// multiple of 8 pixels, so each pixel is the window's.
pub fn render(gpa: std.mem.Allocator, out: *std.ArrayList(u32), all: []const gpu.Instance, from: usize, area: [4]i32, mask: raster.Mask, pictures: raster.Pictures, scale: f32) !Image {
    const fr = gpu.Frame.of(all);
    const ox = area[0] & ~@as(i32, 7);
    const oy = area[1] & ~@as(i32, 7);
    const bw: usize = @intCast(area[2] - ox);
    const bh: usize = @intCast(area[3] - oy);
    const dx = @as(f32, @floatFromInt(ox)) / scale;
    const dy = @as(f32, @floatFromInt(oy)) / scale;
    const region: Box = .{ dx, dy, dx + @as(f32, @floatFromInt(bw)) / scale, dy + @as(f32, @floatFromInt(bh)) / scale };

    var rows = try gpa.dupe([4]f32, fr.rows);
    defer gpa.free(rows);
    var moved = try std.DynamicBitSetUnmanaged.initEmpty(gpa, rows.len);
    defer moved.deinit(gpa);
    var list: std.ArrayList(gpu.Instance) = .empty;
    defer list.deinit(gpa);
    // A layer the renderer opens over the whole and never closes: it
    // clears to transparent what follows draws over.
    try list.append(gpa, .{ .rect = .{ -16, -16, region[2] - dx + 32, region[3] - dy + 32 }, .color = .{ 0, 0, 0, 0 }, .kind = gpu.Kind.layer });
    var depth: usize = 0;
    if (from < fr.instances.len) for (fr.instances[from..]) |src| {
        const k = gpu.kindOf(src.kind);
        if (k == gpu.Kind.layer_end) {
            // One opened before the web view closes: not here.
            if (depth == 0) continue;
            depth -= 1;
        } else if (k == gpu.Kind.layer) {
            depth += 1;
        } else {
            const b = boundsOf(&src, fr.rows) orelse continue;
            _ = meet(b, region) orelse continue;
        }
        var i = src;
        if (gpu.transformOf(i.kind)) |t| {
            if (t + gpu.transform_rows <= rows.len and !moved.isSet(t)) {
                moved.set(t);
                const r = rows[t..][0..gpu.transform_rows];
                r[1] = .{ r[1][0] + r[0][0] * dx + r[0][2] * dy, r[1][1] + r[0][1] * dx + r[0][3] * dy, r[1][2] - dx, r[1][3] - dy };
                r[3] = .{ r[3][0] - dx, r[3][1] - dy, r[3][2] - dx, r[3][3] - dy };
            }
        } else {
            i.rect[0] -= dx;
            i.rect[1] -= dy;
            i.clip = .{ i.clip[0] - dx, i.clip[1] - dy, i.clip[2] - dx, i.clip[3] - dy };
            if (k == gpu.Kind.gradient) {
                // Its geometry is in the window too.
                const g: usize = @intFromFloat(i.uv[0]);
                if (g + 1 < rows.len and !moved.isSet(g)) {
                    moved.set(g);
                    const mode = rows[g][0] - @floor(rows[g][0] / 4) * 4;
                    const geo = &rows[g + 1];
                    geo[0] -= dx;
                    geo[1] -= dy;
                    if (mode < 0.5) {
                        geo[2] -= dx;
                        geo[3] -= dy;
                    }
                }
            }
        }
        try list.append(gpa, i);
    };
    try gpu.appendRows(gpa, &list, rows);

    const bytes = try gpa.alloc(u8, bw * bh * 4);
    defer gpa.free(bytes);
    raster.draw(.{ .bytes = bytes, .width = bw, .height = bh }, list.items, mask, pictures, scale, types.Color.transparent);

    const w: usize = @intCast(area[2] - area[0]);
    const h: usize = @intCast(area[3] - area[1]);
    try out.resize(gpa, w * h);
    const x0: usize = @intCast(area[0] - ox);
    const y0: usize = @intCast(area[1] - oy);
    const src: []align(1) const u32 = std.mem.bytesAsSlice(u32, bytes);
    for (0..h) |y| @memcpy(out.items[y * w ..][0..w], src[(y + y0) * bw + x0 ..][0..w]);
    return .{ .x = area[0], .y = area[1], .w = @intCast(w), .h = @intCast(h), .px = out.items, .scale = scale };
}

/// Whether the cover shows what the window's frame shows, where it is
/// opaque (what is under it shows nowhere there): `frame` is the whole
/// frame drawn, `width` pixels a row. For tests.
pub fn matches(img: Image, frame: []const u8, width: usize) bool {
    const px: []align(1) const u32 = std.mem.bytesAsSlice(u32, frame);
    for (0..img.h) |y| for (0..img.w) |x| {
        const c = img.px[y * img.w + x];
        if (c >> 24 != 255) continue;
        const f = px[(@as(usize, @intCast(img.y)) + y) * width + @as(usize, @intCast(img.x)) + x];
        inline for (.{ 0, 8, 16 }) |s| {
            const a: i32 = @intCast((c >> s) & 0xff);
            const b: i32 = @intCast((f >> s) & 0xff);
            if (@abs(a - b) > 2) return false;
        }
    };
    return true;
}

/// How many of the cover's pixels are opaque, and transparent.
pub fn census(img: Image) [2]usize {
    var n: [2]usize = .{ 0, 0 };
    for (img.px) |c| {
        if (c >> 24 == 255) n[0] += 1;
        if (c >> 24 == 0) n[1] += 1;
    }
    return n;
}
