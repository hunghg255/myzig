//! Frames drawn in part are frames drawn whole (`damage.zig`): random
//! frames of every kind of instance (transformed, gradients, shadows,
//! glyphs, backdrop effects, blurred layers) change a few of their parts
//! frame after frame; each is drawn only where it changed, into a target
//! that keeps the last frame, and compared byte for byte with it drawn
//! whole. The CPU renderer here; each GPU renderer gives its `Target`
//! (`partialMatchesWhole`), skipped where it has none.
const std = @import("std");
const testing = std.testing;
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const types = @import("types.zig");
const damage = @import("damage.zig");
const effect = @import("effect.zig");

/// A renderer drawing into a target that keeps what was drawn.
pub const Target = struct {
    ctx: *anyopaque,
    name: []const u8,
    /// The glyph atlas, once.
    sync: *const fn (ctx: *anyopaque, mask: raster.Mask) void,
    /// Draws a frame into the target, `w` × `h`, whole or only `part`.
    draw: *const fn (ctx: *anyopaque, instances: []const gpu.Instance, w: u32, h: u32, scale: f32, clear: types.Color, part: ?damage.Box) anyerror!void,
    /// The target's pixels (BGRA, premultiplied), and the frame drawn whole
    /// elsewhere.
    read: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator) anyerror!gpu.Pixels,
    whole: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, instances: []const gpu.Instance, w: u32, h: u32, scale: f32, clear: types.Color) anyerror!gpu.Pixels,
    /// The target forgets what it held now and then (as a GtkGLArea).
    invalidates: bool = false,
};

const red: types.Color = .hex(0xe0401a);
const blue: types.Color = .hex(0x1a4ce0);
const stops = [_]types.Stop{ .{ .color = red, .at = 0 }, .{ .color = .{ .r = 1, .g = 0.9, .b = 0.2, .a = 0.6 }, .at = 0.4 }, .{ .color = blue, .at = 1 } };

const What = enum { quad, shadow, text, gradient, effect, layer };

/// A part of a scene: an instance, or an effect, or a blurred layer
/// around the next `holds` parts.
const Part = struct {
    what: What,
    inst: gpu.Instance,
    turn: ?f32 = null,
    blur: f32 = 0,
    holds: u8 = 0,
    shown: bool = true,
};

fn rf(x: std.Random, lo: f32, hi: f32) f32 {
    return lo + x.float(f32) * (hi - lo);
}

fn randomPart(rnd: std.Random) Part {
    const what: What = switch (rnd.uintLessThan(u8, 12)) {
        0, 1, 2, 3 => .quad,
        4, 5 => .shadow,
        6, 7 => .text,
        8 => .gradient,
        9, 10 => .effect,
        else => .layer,
    };
    var i: gpu.Instance = .{
        .rect = .{ rf(rnd, -10, 170), rf(rnd, -10, 120), rf(rnd, 4, 60), rf(rnd, 4, 45) },
        .color = .{ rnd.float(f32), rnd.float(f32), rnd.float(f32), if (rnd.boolean()) 1 else rnd.float(f32) },
        .border_color = .{ rnd.float(f32), rnd.float(f32), rnd.float(f32), rnd.float(f32) },
        .radius = rf(rnd, 0, 16),
        .border_width = if (rnd.boolean()) 0 else rf(rnd, 0.5, 4),
        .uv = .{ 0, 0, 1, 1 },
    };
    switch (what) {
        .shadow => {
            i.kind = gpu.Kind.shadow;
            i.border_width = rf(rnd, 1, 8);
        },
        .text => i.kind = gpu.Kind.text,
        else => {},
    }
    if (rnd.uintLessThan(u8, 3) == 0) {
        const cx = rf(rnd, 0, 150);
        const cy = rf(rnd, 0, 100);
        i.clip = .{ cx, cy, cx + rf(rnd, 20, 120), cy + rf(rnd, 20, 90) };
        if (rnd.boolean()) i.clip_round = gpu.clipRound(rf(rnd, 2, 14), rnd.int(u4));
    }
    return .{
        .what = what,
        .inst = i,
        .turn = if (what != .effect and what != .layer and rnd.uintLessThan(u8, 4) == 0) rf(rnd, -60, 60) else null,
        .blur = rf(rnd, 1, 6),
        .holds = if (what == .layer) 1 + rnd.uintLessThan(u8, 3) else 0,
    };
}

/// The instances of `parts`, then their rows.
fn build(gpa: std.mem.Allocator, parts: []const Part, out: *std.ArrayList(gpu.Instance)) !void {
    out.clearRetainingCapacity();
    var rows: std.ArrayList([4]f32) = .empty;
    defer rows.deinit(gpa);
    var ends: [16]struct { left: u8, inst: gpu.Instance } = undefined;
    var open: usize = 0;
    for (parts) |p| {
        if (p.shown and p.what == .layer and open < ends.len) {
            var l = p.inst;
            l.kind = gpu.Kind.layer;
            l.border_width = p.blur;
            l.color = .{ 0, 0, 0, 0 };
            try out.append(gpa, l);
            l.kind = gpu.Kind.layer_end;
            ends[open] = .{ .left = p.holds, .inst = l };
            open += 1;
            continue;
        }
        if (p.shown) switch (p.what) {
            .layer => {},
            .effect => {
                const e: effect.Effect = .{ .blur = p.blur };
                var i = p.inst;
                i.kind = gpu.Kind.effect;
                i.uv = .{ @floatFromInt(rows.items.len), 0, 0, 0 };
                try rows.appendSlice(gpa, &effect.encode(&e));
                try out.append(gpa, i);
            },
            else => {
                var i = p.inst;
                if (p.what == .gradient) {
                    i.kind = gpu.Kind.gradient;
                    i.uv = .{ @floatFromInt(rows.items.len), 0, 0, 0 };
                    try @import("gradient.zig").rows(&rows, gpa, .{ .stops = &stops, .angle = i.radius * 20 }, .{ .x = i.rect[0], .y = i.rect[1], .w = i.rect[2], .h = i.rect[3] }, 1);
                }
                if (p.turn) |t| {
                    const o: types.Point = .{ .x = i.rect[0] + i.rect[2] / 2, .y = i.rect[1] + i.rect[3] / 2 };
                    const m = types.Affine.rotation(t).about(o);
                    const inv = m.inverse().?;
                    const row: u32 = @intCast(rows.items.len);
                    try rows.appendSlice(gpa, &.{ .{ inv.a, inv.b, inv.c, inv.d }, .{ inv.x, inv.y, m.x, m.y }, .{ m.a, m.b, m.c, m.d }, .{ -1e6, -1e6, 1e6, 1e6 } });
                    i.kind = gpu.withTransform(i.kind, row);
                }
                try out.append(gpa, i);
            },
        };
        // A part done: the innermost layer holds one less; one holding
        // none more ends, a part of the one around it.
        while (open > 0) {
            ends[open - 1].left -= 1;
            if (ends[open - 1].left > 0) break;
            open -= 1;
            try out.append(gpa, ends[open].inst);
        }
    }
    while (open > 0) {
        open -= 1;
        try out.append(gpa, ends[open].inst);
    }
    try gpu.appendRows(gpa, out, rows.items);
}

/// Changes a few parts of the scene, as frames do.
fn change(rnd: std.Random, parts: []Part) void {
    for (0..1 + rnd.uintLessThan(usize, 3)) |_| {
        const p = &parts[rnd.uintLessThan(usize, parts.len)];
        switch (rnd.uintLessThan(u8, 6)) {
            0 => p.inst.color[0] = rnd.float(f32),
            1 => {
                p.inst.rect[0] += rf(rnd, -6, 6);
                p.inst.rect[1] += rf(rnd, -6, 6);
            },
            2 => p.inst.rect[2] = @max(2, p.inst.rect[2] + rf(rnd, -5, 5)),
            3 => p.shown = !p.shown,
            4 => if (p.turn) |*t| {
                t.* += rf(rnd, -10, 10);
            } else {
                p.blur = rf(rnd, 1, 6);
            },
            else => p.* = randomPart(rnd),
        }
    }
}

pub fn glyphMask() [64 * 64]u8 {
    var mask: [64 * 64]u8 = undefined;
    for (0..64) |y| for (0..64) |x| {
        const dx = @as(f32, @floatFromInt(x)) - 31.5;
        const dy = @as(f32, @floatFromInt(y)) - 31.5;
        mask[y * 64 + x] = @intFromFloat(std.math.clamp(28 - @sqrt(dx * dx + dy * dy), 0, 1) * 255);
    };
    return mask;
}

/// Random frames changing frame after frame, drawn by `t` only where they
/// changed, against them drawn whole: the same bytes. Returns how many
/// were drawn in part.
pub fn partialMatchesWhole(t: Target, frames: usize) !usize {
    const gpa = testing.allocator;
    var mask = glyphMask();
    t.sync(t.ctx, .{ .pixels = &mask, .size = 64 });
    var prng: std.Random.DefaultPrng = .init(0xda3a6e);
    const rnd = prng.random();
    var parts: [36]Part = undefined;
    for (&parts) |*p| p.* = randomPart(rnd);
    var list: std.ArrayList(gpu.Instance) = .empty;
    defer list.deinit(gpa);
    var d: damage.Differ = .init(gpa);
    defer d.deinit();
    const w: u32 = 400;
    const h: u32 = 300;
    const scale: f32 = 2;
    const clear: types.Color = .{ .r = 0.95, .g = 0.93, .b = 0.9 };
    var drawn_in_part: usize = 0;
    for (0..frames) |n| {
        if (n > 0) change(rnd, &parts);
        if (t.invalidates and n % 7 == 6) d.invalidate();
        try build(gpa, &parts, &list);
        const f: damage.Frame = .{ .instances = list.items, .width = w, .height = h, .scale = scale, .clear = clear };
        const plan = d.planOne(f, d.diff(f));
        if (plan) |part| {
            if (!damage.empty(part)) {
                try t.draw(t.ctx, list.items, w, h, scale, clear, part);
                drawn_in_part += 1;
            }
        } else try t.draw(t.ctx, list.items, w, h, scale, clear, null);
        d.remember(f);
        const got = try t.read(t.ctx, gpa);
        defer got.deinit(gpa);
        const want = try t.whole(t.ctx, gpa, list.items, w, h, scale, clear);
        defer want.deinit(gpa);
        if (!std.mem.eql(u8, got.bytes, want.bytes)) {
            var first: usize = 0;
            while (got.bytes[first] == want.bytes[first]) first += 1;
            std.debug.print("{s}: frame {d} drawn in part differs at pixel {d},{d} (part {any})\n", .{ t.name, n, first / 4 % w, first / 4 / w, plan });
            return error.TestExpectedEqual;
        }
    }
    return drawn_in_part;
}

// The CPU renderer, in many rectangles as windows drawn on the CPU draw.
const Cpu = struct {
    mask: raster.Mask = .{ .pixels = &.{}, .size = 0 },
    pixels: []u8 = &.{},

    fn sync(ctx: *anyopaque, mask: raster.Mask) void {
        const c: *Cpu = @ptrCast(@alignCast(ctx));
        c.mask = mask;
    }

    fn draw(ctx: *anyopaque, instances: []const gpu.Instance, w: u32, h: u32, scale: f32, clear: types.Color, part: ?damage.Box) anyerror!void {
        const c: *Cpu = @ptrCast(@alignCast(ctx));
        if (c.pixels.len == 0) c.pixels = try testing.allocator.alloc(u8, @as(usize, w) * h * 4);
        const out: gpu.Pixels = .{ .bytes = c.pixels, .width = w, .height = h };
        if (part) |p| {
            raster.drawPart(out, instances, c.mask, .{}, scale, clear, .{ @intCast(p[0]), @intCast(p[1]), @intCast(p[2]), @intCast(p[3]) });
        } else raster.draw(out, instances, c.mask, .{}, scale, clear);
    }

    fn read(ctx: *anyopaque, gpa: std.mem.Allocator) anyerror!gpu.Pixels {
        const c: *Cpu = @ptrCast(@alignCast(ctx));
        return .{ .bytes = try gpa.dupe(u8, c.pixels), .width = 400, .height = 300 };
    }

    fn whole(ctx: *anyopaque, gpa: std.mem.Allocator, instances: []const gpu.Instance, w: u32, h: u32, scale: f32, clear: types.Color) anyerror!gpu.Pixels {
        const c: *Cpu = @ptrCast(@alignCast(ctx));
        const bytes = try gpa.alloc(u8, @as(usize, w) * h * 4);
        raster.draw(.{ .bytes = bytes, .width = w, .height = h }, instances, c.mask, .{}, scale, clear);
        return .{ .bytes = bytes, .width = w, .height = h };
    }
};

test "frames drawn in part on the CPU are the frames drawn whole" {
    var c: Cpu = .{};
    defer testing.allocator.free(c.pixels);
    const parts = try partialMatchesWhole(.{ .ctx = &c, .name = "cpu", .sync = Cpu.sync, .draw = Cpu.draw, .read = Cpu.read, .whole = Cpu.whole, .invalidates = true }, 120);
    // The others change half of it or more, or follow a target that forgot.
    try testing.expect(parts > 20);
}

test "frames drawn in many rectangles on the CPU are the frames drawn whole" {
    const gpa = testing.allocator;
    var mask = glyphMask();
    const m: raster.Mask = .{ .pixels = &mask, .size = 64 };
    var prng: std.Random.DefaultPrng = .init(0x5ec7);
    const rnd = prng.random();
    var parts: [36]Part = undefined;
    for (&parts) |*p| p.* = randomPart(rnd);
    var list: std.ArrayList(gpu.Instance) = .empty;
    defer list.deinit(gpa);
    var d: damage.Differ = .init(gpa);
    defer d.deinit();
    const w = 400;
    const h = 300;
    const clear: types.Color = .{ .r = 1, .g = 1, .b = 1 };
    const kept = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(kept);
    const fresh = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(fresh);
    var many: usize = 0;
    for (0..100) |n| {
        if (n > 0) change(rnd, &parts);
        try build(gpa, &parts, &list);
        const f: damage.Frame = .{ .instances = list.items, .width = w, .height = h, .scale = 2, .clear = clear };
        const out: gpu.Pixels = .{ .bytes = kept, .width = w, .height = h };
        if (d.plan(f, d.diff(f))) |rects| {
            if (rects.len > 1) many += 1;
            for (rects.slice()) |p| raster.drawPart(out, list.items, m, .{}, 2, clear, .{ @intCast(p[0]), @intCast(p[1]), @intCast(p[2]), @intCast(p[3]) });
        } else raster.draw(out, list.items, m, .{}, 2, clear);
        d.remember(f);
        raster.draw(.{ .bytes = fresh, .width = w, .height = h }, list.items, m, .{}, 2, clear);
        try testing.expectEqualSlices(u8, fresh, kept);
    }
    try testing.expect(many > 5);
}

test "a frame like the last changes nothing; a blinking caret changes only itself" {
    const gpa = testing.allocator;
    var d: damage.Differ = .init(gpa);
    defer d.deinit();
    var list = [_]gpu.Instance{
        .{ .rect = .{ 0, 0, 200, 100 }, .color = .{ 1, 1, 1, 1 } },
        .{ .rect = .{ 20, 20, 1, 16 }, .color = .{ 0, 0, 0, 1 } },
        .{ .rect = .{ 40, 20, 60, 16 }, .color = .{ 0.2, 0.2, 0.2, 1 } },
    };
    const f: damage.Frame = .{ .instances = &list, .width = 400, .height = 200, .scale = 2, .clear = .{} };
    try testing.expect(d.diff(f) == null);
    d.remember(f);
    try testing.expectEqual(@as(usize, 0), d.diff(f).?.len);
    d.remember(f);
    list[1].color[3] = 0;
    const part = d.planOne(f, d.diff(f)).?;
    // The caret's pixels (40,40 to 42,72), reached by two more.
    try testing.expectEqual(damage.Box{ 38, 38, 44, 74 }, part);
    d.remember(f);
    // Another size, scale, background or emptied atlas: all of it.
    var g = f;
    g.scale = 1;
    try testing.expect(d.diff(g) == null);
    g = f;
    g.atlas = 1;
    try testing.expect(d.diff(g) == null);
    d.invalidate();
    try testing.expect(d.diff(f) == null);
}

test "pictures count as changed when the image atlas did; an effect grows the part by all it reads" {
    const gpa = testing.allocator;
    var d: damage.Differ = .init(gpa);
    defer d.deinit();
    var list: std.ArrayList(gpu.Instance) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rect = .{ 0, 0, 10, 10 }, .color = .{ 1, 0, 0, 1 } });
    try list.append(gpa, .{ .rect = .{ 100, 100, 20, 20 }, .color = .{ 1, 1, 1, 1 }, .kind = gpu.Kind.image });
    try list.append(gpa, .{ .rect = .{ 40, 0, 30, 20 }, .color = .{ 0, 0, 0, 0 }, .kind = gpu.Kind.effect });
    try gpu.appendRows(gpa, &list, &effect.encode(&.{ .blur = 4 }));
    var f: damage.Frame = .{ .instances = list.items, .width = 300, .height = 300, .scale = 1, .clear = .{} };
    _ = d.diff(f);
    d.remember(f);
    f.images = 1;
    const part = d.planOne(f, d.diff(f)).?;
    try testing.expectEqual(damage.Box{ 98, 98, 122, 122 }, part);
    d.remember(f);
    // The square under the effect's backdrop changes: the part takes in
    // all the effect reads, its blur's reach around it.
    list.items[0].rect[0] = 30;
    const grown = d.planOne(f, d.diff(f)).?;
    try testing.expect(grown[0] <= 2 and grown[2] >= 70 + 12 and grown[3] >= 20 + 12);
}

// Direct3D 11, into a texture kept across frames.
const builtin = @import("builtin");
const d3d11 = if (builtin.os.tag == .windows) @import("d3d11.zig") else struct {
    pub const Renderer = void;
};

const D3d = struct {
    r: *d3d11.Renderer,
    t: ?d3d11.Renderer.Target = null,

    fn of(ctx: *anyopaque) *D3d {
        return @ptrCast(@alignCast(ctx));
    }
    fn sync(ctx: *anyopaque, mask: raster.Mask) void {
        of(ctx).r.syncAtlas(mask, 1, null);
    }
    fn draw(ctx: *anyopaque, instances: []const gpu.Instance, w: u32, h: u32, scale: f32, clear: types.Color, part: ?damage.Box) anyerror!void {
        const d = of(ctx);
        if (d.t == null) d.t = try d.r.newTarget(w, h);
        try d.r.drawTarget(d.t.?, instances, scale, clear, part);
    }
    fn read(ctx: *anyopaque, gpa: std.mem.Allocator) anyerror!gpu.Pixels {
        const d = of(ctx);
        return d.r.readTarget(gpa, d.t.?);
    }
    fn whole(ctx: *anyopaque, gpa: std.mem.Allocator, instances: []const gpu.Instance, w: u32, h: u32, scale: f32, clear: types.Color) anyerror!gpu.Pixels {
        const d = of(ctx);
        const fresh = try d.r.newTarget(w, h);
        defer d.r.freeTarget(fresh);
        try d.r.drawTarget(fresh, instances, scale, clear, null);
        return d.r.readTarget(gpa, fresh);
    }
};

test "frames drawn in part with Direct3D are the frames drawn whole" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = d3d11.Renderer.init(testing.allocator) catch return error.SkipZigTest;
    defer r.deinit();
    var d: D3d = .{ .r = &r };
    defer if (d.t) |t| r.freeTarget(t);
    const parts = try partialMatchesWhole(.{ .ctx = &d, .name = "d3d11", .sync = D3d.sync, .draw = D3d.draw, .read = D3d.read, .whole = D3d.whole }, 80);
    try testing.expect(parts > 15);
}

extern "user32" fn CreateWindowExW(ex: u32, class: [*:0]const u16, title: ?[*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?*anyopaque, menu: ?*anyopaque, inst: ?*anyopaque, param: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn DestroyWindow(hwnd: *anyopaque) callconv(.winapi) i32;

test "a window's swap chain presents frames drawn in part as the frames drawn whole (the window never shows)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = d3d11.Renderer.init(gpa) catch return error.SkipZigTest;
    defer r.deinit();
    const popup = 0x80000000; // and not visible
    const hwnd = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), null, popup, 0, 0, 200, 150, null, null, null, null) orelse return error.SkipZigTest;
    defer _ = DestroyWindow(hwnd);
    try r.attach(hwnd, 200, 150);
    var mask = glyphMask();
    r.syncAtlas(.{ .pixels = &mask, .size = 64 }, 1, null);
    var prng: std.Random.DefaultPrng = .init(0x5a7c);
    const rnd = prng.random();
    var parts: [12]Part = undefined;
    for (&parts) |*p| p.* = randomPart(rnd);
    var list: std.ArrayList(gpu.Instance) = .empty;
    defer list.deinit(gpa);
    const clear: types.Color = .{ .r = 1, .g = 1, .b = 1 };
    var drawn: [3]usize = @splat(0);
    // The frames presented last, drawn whole.
    var shown: [2]?gpu.Pixels = .{ null, null };
    defer for (shown) |p| if (p) |x| x.deinit(gpa);
    for (0..40) |n| {
        if (n > 0) change(rnd, &parts);
        // A resize makes the buffers anew: they hold nothing.
        if (n == 20) {
            try r.resize(200, 140);
            for (&shown) |*p| if (p.*) |x| {
                x.deinit(gpa);
                p.* = null;
            };
        }
        try build(gpa, &parts, &list);
        const f: damage.Frame = .{ .instances = list.items, .width = r.width, .height = r.height, .scale = 1, .clear = clear };
        drawn[@intFromEnum(try r.render(f))] += 1;
        if (!r.unpresented()) continue;
        try r.present(0);
        if (shown[0]) |x| x.deinit(gpa);
        shown[0] = shown[1];
        shown[1] = try r.drawOffscreen(gpa, list.items, .{ .w = @floatFromInt(r.width), .h = @floatFromInt(r.height) }, 1, clear);
        // The buffer handed back is the one presented before: DXGI filled
        // what the frame did not draw from the frame before it.
        const want = shown[0] orelse continue;
        const back = try r.readBackBuffer(gpa);
        defer back.deinit(gpa);
        try testing.expectEqualSlices(u8, want.bytes, back.bytes);
    }
    try testing.expect(drawn[@intFromEnum(d3d11.Renderer.Drawn.part)] > 10);
}

// OpenGL 3.3 and OpenGL ES 3.0 offscreen, where EGL makes a context (Linux).
const linux = builtin.os.tag == .linux;
const gl = if (linux) @import("gl.zig") else struct {
    pub const Renderer = struct {
        pub const Target = void;
    };
};

const Gl = struct {
    r: *gl.Renderer,
    t: ?gl.Renderer.Target = null,

    fn of(ctx: *anyopaque) *Gl {
        return @ptrCast(@alignCast(ctx));
    }
    fn sync(ctx: *anyopaque, mask: raster.Mask) void {
        of(ctx).r.syncAtlas(mask, 1, null);
    }
    fn draw(ctx: *anyopaque, instances: []const gpu.Instance, w: u32, h: u32, scale: f32, clear: types.Color, part: ?damage.Box) anyerror!void {
        const d = of(ctx);
        if (d.t == null) d.t = try d.r.newTarget(w, h);
        try d.r.drawTarget(d.t.?, instances, scale, clear, part);
    }
    fn read(ctx: *anyopaque, gpa: std.mem.Allocator) anyerror!gpu.Pixels {
        const d = of(ctx);
        return d.r.readTarget(gpa, d.t.?);
    }
    fn whole(ctx: *anyopaque, gpa: std.mem.Allocator, instances: []const gpu.Instance, w: u32, h: u32, scale: f32, clear: types.Color) anyerror!gpu.Pixels {
        const d = of(ctx);
        var fresh = try d.r.newTarget(w, h);
        defer d.r.freeTarget(&fresh);
        try d.r.drawTarget(fresh, instances, scale, clear, null);
        return d.r.readTarget(gpa, fresh);
    }
};

fn glPartial(es: bool) !void {
    if (!linux) return error.SkipZigTest;
    var o = @import("gl_offscreen.zig").Offscreen.init(es) catch return error.SkipZigTest;
    defer o.deinit();
    var r = try gl.Renderer.init(testing.allocator);
    defer r.deinit();
    var d: Gl = .{ .r = &r };
    defer if (d.t) |*t| r.freeTarget(t);
    const parts = try partialMatchesWhole(.{ .ctx = &d, .name = if (es) "gles" else "gl", .sync = Gl.sync, .draw = Gl.draw, .read = Gl.read, .whole = Gl.whole, .invalidates = true }, 60);
    try testing.expect(parts > 10);
}

test "frames drawn in part with OpenGL are the frames drawn whole" {
    try glPartial(false);
}

test "frames drawn in part with OpenGL ES are the frames drawn whole" {
    try glPartial(true);
}
