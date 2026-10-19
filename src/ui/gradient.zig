//! Gradients as box backgrounds (`Style.gradient`), after mygo's: linear,
//! radial and conic, of up to `Gradient.max_stops` stops, mixed with
//! premultiplied alpha in sRGB or in Oklab, as CSS mixes them. Paint
//! writes a gradient's rows (`rows`); every renderer finds a pixel's color
//! from them as `colorAt` does here, the CPU renderer's twin.
//!
//! Rows, from the instance's `uv[0]`: the mode (0 linear, 1 radial, 2
//! conic, plus 4 mixed in Oklab) and the number of stops; the geometry
//! (linear: from x, y to x, y; radial: center x, y and radius; conic:
//! center x, y and the angle it starts at, in radians); then for each stop
//! its straight color, and its place with its color in Oklab.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");

pub const Gradient = types.Gradient;

/// The rows of gradient `g` filling box `r` at `opacity`.
pub fn rows(out: *std.ArrayList([4]f32), gpa: std.mem.Allocator, g: Gradient, r: types.Rect, opacity: f32) !void {
    const stops = g.stops[0..@min(g.stops.len, Gradient.max_stops)];
    var mode: f32 = switch (g.kind) {
        .linear => 0,
        .radial => 1,
        .conic => 2,
    };
    if (g.oklab) mode += 4;
    try out.append(gpa, .{ mode, @floatFromInt(stops.len), 0, 0 });
    const cx = r.x + g.center.x * r.w;
    const cy = r.y + g.center.y * r.h;
    switch (g.kind) {
        .linear => {
            const a = g.angle * std.math.pi / 180;
            const dx = @sin(a);
            const dy = -@cos(a);
            // CSS's gradient line: through the middle, as long as the box
            // is across along it.
            const half = (@abs(r.w * dx) + @abs(r.h * dy)) / 2;
            const mx = r.x + r.w / 2;
            const my = r.y + r.h / 2;
            try out.append(gpa, .{ mx - dx * half, my - dy * half, mx + dx * half, my + dy * half });
        },
        .radial => {
            const far = blk: {
                var m: f32 = 0;
                for ([_][2]f32{ .{ r.x, r.y }, .{ r.x + r.w, r.y }, .{ r.x, r.y + r.h }, .{ r.x + r.w, r.y + r.h } }) |p| {
                    m = @max(m, std.math.hypot(p[0] - cx, p[1] - cy));
                }
                break :blk m;
            };
            try out.append(gpa, .{ cx, cy, @max(g.radius orelse far, 1e-4), 0 });
        },
        .conic => try out.append(gpa, .{ cx, cy, g.start * std.math.pi / 180, 0 }),
    }
    for (stops) |s| {
        const lab = oklab(.{ s.color.r, s.color.g, s.color.b });
        try out.append(gpa, .{ s.color.r, s.color.g, s.color.b, s.color.a * opacity });
        try out.append(gpa, .{ s.at, lab[0], lab[1], lab[2] });
    }
}

/// Paints a box's gradient: its rows, and an instance that fills the box
/// with it, bordered as the box's quad would be.
pub fn paint(p: anytype, g: Gradient, st: *const types.Style, rect4: [4]f32, clip4: [4]f32, opacity: f32) void {
    const c = p.c;
    if (g.stops.len == 0) return;
    const row: u32 = @intCast(p.rows.items.len);
    rows(&p.rows, c.alloc(), g, .{ .x = rect4[0], .y = rect4[1], .w = rect4[2], .h = rect4[3] }, opacity) catch return;
    // Folded into the instance, a transform moves the geometry too.
    if (p.sp.mode == .similar) {
        const m = p.sp.m;
        const geo = &p.rows.items[row + 1];
        const a = m.apply(.{ .x = geo[0], .y = geo[1] });
        if (g.kind == .linear) {
            const b = m.apply(.{ .x = geo[2], .y = geo[3] });
            geo.* = .{ a.x, a.y, b.x, b.y };
        } else geo.* = .{ a.x, a.y, if (g.kind == .radial) geo[2] * m.a else geo[2], 0 };
    }
    p.out.append(c.gpa, .{
        .rect = rect4,
        .color = .{ 0, 0, 0, 0 },
        .border_color = gpu.color4((st.border orelse types.Color.transparent).alpha(opacity)),
        .border_width = if (st.border != null) st.border_width else 0,
        .radius = st.corners.signed(st.radius),
        .uv = .{ @floatFromInt(row), 0, 0, 0 },
        .kind = gpu.Kind.gradient,
        .clip = clip4,
    }) catch {};
}

fn toLinear(c: f32) f32 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

fn toSrgb(c: f32) f32 {
    return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, @max(c, 0), 1.0 / 2.4) - 0.055;
}

fn cbrt(v: f32) f32 {
    return std.math.sign(v) * std.math.pow(f32, @abs(v), 1.0 / 3.0);
}

/// An sRGB color in Oklab.
pub fn oklab(srgb: [3]f32) [3]f32 {
    const r = toLinear(srgb[0]);
    const g = toLinear(srgb[1]);
    const b = toLinear(srgb[2]);
    const l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return .{
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    };
}

fn fromOklab(lab: [3]f32) [3]f32 {
    var l = lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2];
    var m = lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2];
    var s = lab[0] - 0.0894841775 * lab[1] - 1.2914855480 * lab[2];
    l = l * l * l;
    m = m * m * m;
    s = s * s * s;
    return .{
        toSrgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
        toSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
        toSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
    };
}

fn premul(c: [4]f32) [4]f32 {
    return .{ c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3] };
}

/// Where along the gradient whose rows start at `row` the point (x, y) is.
pub fn place(all: []const [4]f32, row: usize, x: f32, y: f32) f32 {
    const mode = all[row][0];
    const geo = all[row + 1];
    const kind = mode - @floor(mode / 4) * 4;
    if (kind < 0.5) {
        const dx = geo[2] - geo[0];
        const dy = geo[3] - geo[1];
        return ((x - geo[0]) * dx + (y - geo[1]) * dy) / @max(dx * dx + dy * dy, 0.0001);
    }
    const dx = x - geo[0];
    const dy = y - geo[1];
    if (kind < 1.5) return @sqrt(dx * dx + dy * dy) / geo[2];
    var t = (std.math.atan2(dx, -dy) - geo[2]) * 0.15915494309189535;
    t -= @floor(t);
    return t;
}

/// The gradient's premultiplied color at `t` along it.
pub fn stopsAt(all: []const [4]f32, row: usize, t: f32) [4]f32 {
    const lab = all[row][0] >= 3.5;
    const n: usize = @intFromFloat(all[row][1]);
    if (n == 0) return .{ 0, 0, 0, 0 };
    const first = row + 2;
    var a = all[first];
    var ap = all[first + 1];
    if (t <= ap[0]) return premul(a);
    const last = all[first + 2 * (n - 1)];
    const lastp = all[first + 2 * (n - 1) + 1];
    if (t >= lastp[0]) return premul(last);
    var b = last;
    var bp = lastp;
    var i: usize = 1;
    while (i + 1 < n) : (i += 1) {
        const cc = all[first + 2 * i];
        const cp = all[first + 2 * i + 1];
        if (t < cp[0]) {
            b = cc;
            bp = cp;
            break;
        }
        a = cc;
        ap = cp;
    }
    const f = std.math.clamp((t - ap[0]) / @max(bp[0] - ap[0], 1e-6), 0, 1);
    const alpha = a[3] + (b[3] - a[3]) * f;
    if (!lab) {
        var o: [4]f32 = undefined;
        for (0..3) |k| o[k] = a[k] * a[3] + (b[k] * b[3] - a[k] * a[3]) * f;
        o[3] = alpha;
        return o;
    }
    if (alpha <= 0) return .{ 0, 0, 0, 0 };
    var mixed: [3]f32 = undefined;
    for (0..3) |k| mixed[k] = (ap[k + 1] * a[3] + (bp[k + 1] * b[3] - ap[k + 1] * a[3]) * f) / alpha;
    const rgb = fromOklab(mixed);
    return .{ std.math.clamp(rgb[0], 0, 1) * alpha, std.math.clamp(rgb[1], 0, 1) * alpha, std.math.clamp(rgb[2], 0, 1) * alpha, alpha };
}

/// The premultiplied color of the gradient at `row` at point (x, y).
pub fn colorAt(all: []const [4]f32, row: usize, x: f32, y: f32) [4]f32 {
    return stopsAt(all, row, place(all, row, x, y));
}

const testing = std.testing;

test "linear, radial and conic gradients place points as CSS does, and mix their stops" {
    const gpa = testing.allocator;
    var list: std.ArrayList([4]f32) = .empty;
    defer list.deinit(gpa);
    const box: types.Rect = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const stops = [_]types.Stop{ .{ .color = .{ .r = 1, .g = 0, .b = 0 }, .at = 0 }, .{ .color = .{ .r = 0, .g = 0, .b = 1 }, .at = 1 } };
    try rows(&list, gpa, .{ .stops = &stops, .angle = 90 }, box, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.25), place(list.items, 0, 25, 10), 1e-5);
    const mid = colorAt(list.items, 0, 50, 0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mid[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mid[2], 1e-5);
    // Top to bottom by default.
    list.clearRetainingCapacity();
    try rows(&list, gpa, .{ .stops = &stops }, box, 1);
    try testing.expectApproxEqAbs(@as(f32, 1), place(list.items, 0, 0, 50), 1e-5);
    list.clearRetainingCapacity();
    try rows(&list, gpa, .{ .kind = .radial, .stops = &stops, .radius = 20 }, box, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.5), place(list.items, 0, 60, 25), 1e-5);
    list.clearRetainingCapacity();
    try rows(&list, gpa, .{ .kind = .conic, .stops = &stops }, box, 1);
    // A quarter turn clockwise from up is the right.
    try testing.expectApproxEqAbs(@as(f32, 0.25), place(list.items, 0, 90, 25), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), place(list.items, 0, 50, 45), 1e-5);
    // Oklab keeps midpoints lighter than sRGB's.
    list.clearRetainingCapacity();
    try rows(&list, gpa, .{ .stops = &stops, .angle = 90, .oklab = true }, box, 1);
    const lab = colorAt(list.items, 0, 50, 0);
    try testing.expect(lab[0] + lab[1] + lab[2] > mid[0] + mid[1] + mid[2]);
    try testing.expectApproxEqAbs(@as(f32, 1), lab[3], 1e-5);
}
