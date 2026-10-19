//! The GPU renderers against the CPU renderer for what draws on the
//! general path and between a frame's parts: transformed instances of
//! every kind (random turns, slants and scales), gradients, backdrop
//! effects (plain and with a shader) and blurred layers, in frames of
//! widgets through `ui.Tester` and in random frames. Each GPU renderer
//! gives its drawing function (`Draw`); the test is skipped where it has
//! none.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const types = @import("types.zig");
const effect = @import("effect.zig");

/// Draws a frame offscreen on a GPU: its pixels (BGRA, premultiplied).
pub const Draw = struct {
    ctx: *anyopaque,
    sync: *const fn (ctx: *anyopaque, mask: raster.Mask, generation: u64, t: ?*ui.Tester) void,
    draw: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, instances: []const gpu.Instance, size: types.Size, scale: f32, clear: types.Color) anyerror!gpu.Pixels,
    name: []const u8,
};

/// Within `worst` levels everywhere and `mean` on average.
pub fn expectClose(name: []const u8, what: []const u8, a: []const u8, b: []const u8, mean: f64, worst: u8) !void {
    var total: u64 = 0;
    var most: u8 = 0;
    for (a, b) |x, y| {
        const d = if (x > y) x - y else y - x;
        total += d;
        most = @max(most, d);
    }
    const m = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(a.len));
    if (m >= mean or most > worst) {
        std.debug.print("{s} vs cpu, {s}: mean {d:.4}, worst {d}\n", .{ name, what, m, most });
        return error.TestExpectedClose;
    }
}

const red: types.Color = .hex(0xe0401a);
const blue: types.Color = .hex(0x1a4ce0);
const stops = [_]types.Stop{ .{ .color = red, .at = 0 }, .{ .color = .{ .r = 1, .g = 0.9, .b = 0.2, .a = 0.6 }, .at = 0.4 }, .{ .color = blue, .at = 1 } };

fn tint(in: *const effect.Input) [3]f32 {
    const b = in.sample(in.p[0] + 3, in.p[1]);
    const k = in.params[0];
    return .{ b[0] * k[0] + k[3], b[1] * k[1] + k[3], b[2] * k[2] + k[3] };
}

const tint_shader: effect.Shader = .{
    .name = "test-tint",
    .cpu = tint,
    .hlsl =
    \\float3 effect_color(EffectIn i) {
    \\    float3 b = backdrop_at(i, i.p + float2(3, 0));
    \\    return b * i.params[0].xyz + i.params[0].w;
    \\}
    ,
    .glsl =
    \\vec3 effect_color(EffectIn i) {
    \\    vec3 b = backdrop_at(i, i.p + vec2(3.0, 0.0));
    \\    return b * i.params[0].xyz + i.params[0].w;
    \\}
    ,
    .msl =
    \\float3 effect_color(EffectIn i, texture2d<float> backdrop) {
    \\    float3 b = backdrop_at(i, backdrop, i.p + float2(3, 0));
    \\    return b * i.params[0].xyz + i.params[0].w;
    \\}
    ,
};

const Scene = struct {
    turn: f32 = 17,
    frost: effect.Effect = .{ .blur = 6 },
    tinted: effect.Effect = .{ .blur = 3, .shader = &tint_shader, .params = .{ .{ 0.8, 0.9, 1.1, 0.05 }, @splat(0), @splat(0), @splat(0) } },
    fn view(s: *Scene, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(16), .gap = 10, .width = .fill, .height = .fill });
        defer ui.end(c);
        ui.text(c, "Motion and effects", .{ .size = 20, .weight = .bold });
        {
            _ = c.open(.{ .direction = .row, .gap = 12, .padding = .all(8), .radius = 10, .background = .hex(0xf3efe6), .transform = .rotation(s.turn) }, null);
            defer c.end();
            ui.text(c, "Turned", .{ .size = 14 });
            _ = ui.button(c, "Button", .{ .variant = .primary, .icon = "checkmark" });
            _ = c.open(.{ .width = .{ .px = 30 }, .height = .{ .px = 30 }, .radius = 6, .background = red, .shadow = .{ .blur = 10, .y = 3 }, .transform = types.Affine.skewing(12, 0).then(.scaling(1.2, 0.8)) }, null);
            c.end();
        }
        {
            _ = c.open(.{ .direction = .row, .gap = 8 }, null);
            defer c.end();
            _ = c.open(.{ .width = .{ .px = 70 }, .height = .{ .px = 40 }, .radius = 12, .gradient = &.{ .stops = &stops, .angle = 120 }, .border = .hex(0x223344), .border_width = 2 }, null);
            c.end();
            _ = c.open(.{ .width = .{ .px = 40 }, .height = .{ .px = 40 }, .radius = 20, .gradient = &.{ .kind = .radial, .stops = &stops } }, null);
            c.end();
            _ = c.open(.{ .width = .{ .px = 40 }, .height = .{ .px = 40 }, .gradient = &.{ .kind = .conic, .stops = &stops, .start = 30, .oklab = true }, .transform = .rotation(-20) }, null);
            c.end();
            _ = c.open(.{ .width = .{ .px = 50 }, .height = .{ .px = 30 }, .background = blue, .radius = 6, .blur = 2.5 }, null);
            ui.text(c, "blur", .{ .size = 11, .color = .white });
            c.end();
        }
        // Stripes under two panes: frosted, and tinted by a shader.
        {
            _ = c.open(.{ .direction = .row, .height = .{ .px = 70 }, .width = .fill }, null);
            defer c.end();
            for (0..40) |k| {
                _ = c.open(.{ .width = .{ .px = 5 }, .height = .fill, .background = if (k % 3 == 0) red else if (k % 3 == 1) types.Color.white else blue }, null);
                c.end();
            }
            _ = c.open(.{ .absolute = true, .offset = .{ .x = 10, .y = 10 }, .width = .{ .px = 80 }, .height = .{ .px = 50 }, .radius = 14, .effect = &s.frost, .padding = .all(8) }, null);
            ui.text(c, "frost", .{ .size = 12 });
            c.end();
            _ = c.open(.{ .absolute = true, .offset = .{ .x = 110, .y = 10 }, .width = .{ .px = 80 }, .height = .{ .px = 50 }, .radius = 8, .effect = &s.tinted }, null);
            c.end();
        }
    }
};

/// The widgets scene on `d` and on the CPU.
pub fn widgets(d: Draw) !void {
    var s: Scene = .{};
    try compareView(d, .init(&s, Scene.view), 320, 260);
}

/// A view's frame on `d` and on the CPU: within a level or two.
pub fn compareView(d: Draw, view: ui.View, w: f32, h: f32) !void {
    const gpa = testing.allocator;
    var t: ui.Tester = undefined;
    try t.init(gpa, view, .{ .width = w, .height = h });
    defer t.deinit();
    t.settle(1);
    d.sync(d.ctx, t.text.atlas.mask(), t.text.atlas.generation, &t);
    const frame = try d.draw(d.ctx, gpa, t.instances.items, t.size, t.scale, t.theme.background);
    defer frame.deinit(gpa);
    const cpu = try gpa.alloc(u8, frame.bytes.len);
    defer gpa.free(cpu);
    raster.draw(.{ .bytes = cpu, .width = frame.width, .height = frame.height }, t.instances.items, t.text.atlas.mask(), t.text.images.pictures(), t.scale, t.theme.background);
    expectClose(d.name, "widgets", frame.bytes, cpu, 0.05, 4) catch |e| {
        // Where they differ, by bands of rows.
        var bands: [32]u64 = @splat(0);
        for (0..frame.height) |y| for (0..frame.width * 4) |x| {
            const a = frame.bytes[y * frame.width * 4 + x];
            const b = cpu[y * frame.width * 4 + x];
            bands[y * 32 / frame.height] += if (a > b) a - b else b - a;
        };
        std.debug.print("by rows: {any}\n", .{bands});
        return e;
    };
}

/// Random frames of transformed instances of every kind and gradients.
pub fn random(d: Draw) !void {
    const gpa = testing.allocator;
    var mask: [64 * 64]u8 = undefined;
    for (0..64) |y| for (0..64) |x| {
        const dx = @as(f32, @floatFromInt(x)) - 31.5;
        const dy = @as(f32, @floatFromInt(y)) - 31.5;
        mask[y * 64 + x] = @intFromFloat(std.math.clamp(28 - @sqrt(dx * dx + dy * dy), 0, 1) * 255);
    };
    const m: raster.Mask = .{ .pixels = &mask, .size = 64 };
    d.sync(d.ctx, m, 1, null);
    var prng: std.Random.DefaultPrng = .init(0x7f0a);
    const rnd = prng.random();
    const f = struct {
        fn f(x: std.Random, lo: f32, hi: f32) f32 {
            return lo + x.float(f32) * (hi - lo);
        }
    }.f;
    const size: types.Size = .{ .w = 200, .h = 150 };
    for (0..10) |round| {
        var list: std.ArrayList(gpu.Instance) = .empty;
        defer list.deinit(gpa);
        var rows: std.ArrayList([4]f32) = .empty;
        defer rows.deinit(gpa);
        for (0..30) |_| {
            const kind: f32 = switch (rnd.uintLessThan(u8, 5)) {
                0, 1 => gpu.Kind.quad,
                2 => gpu.Kind.shadow,
                3 => gpu.Kind.text,
                else => gpu.Kind.gradient,
            };
            var i: gpu.Instance = .{
                .rect = .{ f(rnd, 0, 160), f(rnd, 0, 110), f(rnd, 4, 70), f(rnd, 4, 50) },
                .color = .{ rnd.float(f32), rnd.float(f32), rnd.float(f32), if (rnd.boolean()) 1 else rnd.float(f32) },
                .border_color = .{ rnd.float(f32), rnd.float(f32), rnd.float(f32), rnd.float(f32) },
                .radius = f(rnd, 0, 20),
                .border_width = if (kind == gpu.Kind.shadow) f(rnd, 1, 10) else if (rnd.boolean()) 0 else f(rnd, 0.5, 5),
                .kind = kind,
                .uv = .{ 0, 0, 1, 1 },
            };
            if (kind == gpu.Kind.gradient) {
                const g: types.Gradient = .{ .kind = @enumFromInt(rnd.uintLessThan(u8, 3)), .stops = &stops, .angle = f(rnd, 0, 360), .start = f(rnd, 0, 360), .oklab = rnd.boolean() };
                i.uv = .{ @floatFromInt(rows.items.len), 0, 0, 0 };
                try @import("gradient.zig").rows(&rows, gpa, g, .{ .x = i.rect[0], .y = i.rect[1], .w = i.rect[2], .h = i.rect[3] }, 1);
            }
            if (rnd.boolean()) {
                const cx = f(rnd, 0, 150);
                const cy = f(rnd, 0, 100);
                i.clip = .{ cx, cy, cx + f(rnd, 20, 120), cy + f(rnd, 20, 90) };
                if (rnd.boolean()) i.clip_round = gpu.clipRound(f(rnd, 2, 20), rnd.int(u4));
            }
            if (rnd.uintLessThan(u8, 3) != 0) {
                const o: types.Point = .{ .x = i.rect[0] + i.rect[2] / 2, .y = i.rect[1] + i.rect[3] / 2 };
                const mt = types.Affine.scaling(f(rnd, 0.6, 1.5), f(rnd, 0.6, 1.5)).then(.skewing(f(rnd, -20, 20), 0)).then(.rotation(f(rnd, -180, 180))).then(.translation(f(rnd, -10, 10), f(rnd, -10, 10))).about(o);
                const inv = mt.inverse().?;
                const row: u32 = @intCast(rows.items.len);
                try rows.appendSlice(gpa, &.{ .{ inv.a, inv.b, inv.c, inv.d }, .{ inv.x, inv.y, mt.x, mt.y }, .{ mt.a, mt.b, mt.c, mt.d }, .{ f(rnd, -10, 40), f(rnd, -10, 40), f(rnd, 120, 210), f(rnd, 90, 160) } });
                i.kind = gpu.withTransform(i.kind, row);
            }
            try list.append(gpa, i);
        }
        try gpu.appendRows(gpa, &list, rows.items);
        const scale: f32 = if (round % 2 == 0) 2 else 1.5;
        const clear: types.Color = .{ .r = 0.95, .g = 0.93, .b = 0.9 };
        const frame = try d.draw(d.ctx, gpa, list.items, size, scale, clear);
        defer frame.deinit(gpa);
        const cpu = try gpa.alloc(u8, frame.bytes.len);
        defer gpa.free(cpu);
        raster.draw(.{ .bytes = cpu, .width = frame.width, .height = frame.height }, list.items, m, .{}, scale, clear);
        // Thirty instances over each other, smoothed edges through turns.
        try expectClose(d.name, "random transformed", frame.bytes, cpu, 0.5, 6);
    }
}

// Direct3D 11, where there is one.
const builtin = @import("builtin");
const d3d11 = if (builtin.os.tag == .windows) @import("d3d11.zig") else struct {
    pub const Renderer = void;
};

fn d3dSync(ctx: *anyopaque, mask: raster.Mask, generation: u64, t: ?*ui.Tester) void {
    const r: *d3d11.Renderer = @ptrCast(@alignCast(ctx));
    r.syncAtlas(mask, generation);
    if (t) |x| r.syncImages(&x.text.images);
}

fn d3dDraw(ctx: *anyopaque, gpa: std.mem.Allocator, instances: []const gpu.Instance, size: types.Size, scale: f32, clear: types.Color) anyerror!gpu.Pixels {
    const r: *d3d11.Renderer = @ptrCast(@alignCast(ctx));
    return r.drawOffscreen(gpa, instances, size, scale, clear);
}

pub fn withD3d(comptime f: fn (Draw) anyerror!void) !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = d3d11.Renderer.init(testing.allocator) catch return error.SkipZigTest;
    defer r.deinit();
    try f(.{ .ctx = &r, .sync = d3dSync, .draw = d3dDraw, .name = "d3d11" });
}

test "Direct3D draws transforms, gradients, effects and blurred layers as the CPU renderer does" {
    try withD3d(widgets);
}

test "Direct3D draws random transformed instances and gradients as the CPU renderer does" {
    try withD3d(random);
}

// OpenGL 3.3 and OpenGL ES 3.0, where EGL makes a context (Linux).
const linux = builtin.os.tag == .linux;
const gl = if (linux) @import("gl.zig") else struct {
    pub const Renderer = void;
};
const Offscreen = if (linux) @import("gl_offscreen.zig").Offscreen else void;

fn glSync(ctx: *anyopaque, mask: raster.Mask, generation: u64, t: ?*ui.Tester) void {
    const r: *gl.Renderer = @ptrCast(@alignCast(ctx));
    r.syncAtlas(mask, generation);
    if (t) |x| r.syncImages(&x.text.images);
}

fn glDraw(ctx: *anyopaque, gpa: std.mem.Allocator, instances: []const gpu.Instance, size: types.Size, scale: f32, clear: types.Color) anyerror!gpu.Pixels {
    const r: *gl.Renderer = @ptrCast(@alignCast(ctx));
    return r.drawOffscreen(gpa, instances, size, scale, clear);
}

pub fn withGl(es: bool, comptime f: fn (Draw) anyerror!void) !void {
    if (!linux) return error.SkipZigTest;
    var o = Offscreen.init(es) catch return error.SkipZigTest;
    defer o.deinit();
    var r = try gl.Renderer.init(testing.allocator);
    defer r.deinit();
    try f(.{ .ctx = &r, .sync = glSync, .draw = glDraw, .name = if (es) "gles" else "gl" });
}

test "OpenGL draws transforms, gradients, effects and blurred layers as the CPU renderer does" {
    try withGl(false, widgets);
}

test "OpenGL ES draws transforms, gradients, effects and blurred layers as the CPU renderer does" {
    try withGl(true, widgets);
}

test "OpenGL draws random transformed instances and gradients as the CPU renderer does" {
    try withGl(false, random);
}

test "OpenGL ES draws random transformed instances and gradients as the CPU renderer does" {
    try withGl(true, random);
}

// Metal, where text is the system's (macOS): the widgets scene against the
// CPU renderer, over the atlas's texels as Metal has them.
test "Metal draws transforms, gradients, effects and blurred layers as the CPU renderer does" {
    if (@import("text.zig").portable) return error.SkipZigTest;
    const gpa = testing.allocator;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 320, .height = 260 });
    defer t.deinit();
    t.settle(1);
    t.renderer.syncImages(&t.text.images);
    const frame = try t.renderer.drawOffscreen(gpa, t.instances.items, t.text.texture(), t.size, t.scale, t.theme.background);
    defer frame.deinit(gpa);
    const texels = try t.text.atlas.read(gpa);
    defer gpa.free(texels);
    const cpu = try gpa.alloc(u8, frame.bytes.len);
    defer gpa.free(cpu);
    raster.draw(.{ .bytes = cpu, .width = frame.width, .height = frame.height }, t.instances.items, .{ .pixels = texels, .size = t.text.atlas.size }, t.text.images.pictures(), t.scale, t.theme.background);
    try expectClose("metal", "widgets", frame.bytes, cpu, 0.1, 16);
}
