//! The OpenGL renderer against the CPU renderer, offscreen (an EGL context
//! without a surface, framebuffers read back): frames of widgets and of
//! quads, borders, rounded clips, glyphs, pictures and shadows must come
//! out the same, to rounding, in OpenGL 3.3 and in OpenGL ES 3.0. Skipped
//! where there is no EGL (off Linux, or without Mesa's or a GPU's drivers).
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const types = @import("types.zig");
const linux = builtin.os.tag == .linux;
const gl = if (linux) @import("gl.zig") else struct {};
const Offscreen = if (linux) @import("gl_offscreen.zig").Offscreen else void;

const Scene = struct {
    on: bool = true,
    value: f32 = 0.4,
    picture: []const u8 = "",
    fn view(s: *Scene, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 14, .width = .fill, .height = .fill });
        defer ui.end(c);
        ui.text(c, "Settings", .{ .size = 22, .weight = .bold });
        ui.card(c, .{ .gap = 10, .shadow = .{ .blur = 18, .y = 6 } });
        {
            defer ui.end(c);
            ui.text(c, "Wrapped text in a card with a shadow, long enough to break onto a second line.", .{ .size = 13, .wrap = true });
            _ = ui.toggle(c, "Notifications", &s.on);
            _ = ui.slider(c, &s.value, .{});
        }
        {
            const box = ui.div(c).row().w(150).h(36).rounded(12).clip();
            defer box.end();
            const left = ui.div(c).w(90).hFull().bg(.hex(0xd04a2f));
            left.end();
            const right = ui.div(c).grow().hFull().clip().bg(.hex(0x2f6fd0));
            defer right.end();
            ui.text(c, "clipped", .{ .size = 12, .color = .{ .r = 1, .g = 1, .b = 1 } });
        }
        ui.row(c, .{ .gap = 8 });
        defer ui.end(c);
        _ = ui.button(c, "Save", .{ .variant = .primary, .icon = "checkmark" });
        _ = ui.button(c, "Cancel", .{});
        ui.icon(c, "star.fill", .{ .size = 18, .color = c.theme.accent });
        ui.badge(c, "new", c.theme.accent);
        _ = ui.image(c, .{ .key = "gradient", .bytes = s.picture, .max_width = 60, .radius = 8 });
        // A part of it, pixelated: nearest texels, as the CPU picks them.
        _ = ui.image(c, .{ .key = "gradient", .bytes = s.picture, .source = .{ .x = 5, .y = 3, .w = 7, .h = 5 }, .pixelated = true, .size = .{ .w = 31, .h = 23 }, .radius = 0 });
    }
};

/// Two frames are within `worst` levels of each other in every channel,
/// and within `mean` on average: blending rounds a little differently on
/// the GPU (a level or two per instance drawn over a pixel).
fn expectClose(gpu_px: []const u8, cpu_px: []const u8, mean: f64, worst: u8) !void {
    var total: u64 = 0;
    var most: u8 = 0;
    for (gpu_px, cpu_px) |x, y| {
        const d = if (x > y) x - y else y - x;
        total += d;
        most = @max(most, d);
    }
    const m = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(gpu_px.len));
    if (m >= mean or most > worst) {
        std.debug.print("gl vs cpu: mean {d:.4}, worst {d}\n", .{ m, most });
        return error.TestExpectedClose;
    }
}

/// A context and a renderer in it, or the test skipped.
const Setup = struct {
    o: Offscreen,
    r: gl.Renderer,

    fn init(s: *Setup, es: bool) !void {
        s.o = Offscreen.init(es) catch return error.SkipZigTest;
        s.r = gl.Renderer.init(testing.allocator) catch |e| {
            s.o.deinit();
            // A context without the shaders compiling is a failure.
            return e;
        };
    }

    fn deinit(s: *Setup) void {
        s.r.deinit();
        s.o.deinit();
    }
};

fn widgets(es: bool) !void {
    if (!linux) return error.SkipZigTest;
    var s: Setup = undefined;
    try s.init(es);
    defer s.deinit();
    const r = &s.r;
    const gpa = testing.allocator;
    var px: [48 * 32 * 4]u8 = undefined;
    for (0..32) |y| for (0..48) |x| {
        const a: u8 = @intCast(255 - x * 2);
        px[(y * 48 + x) * 4 ..][0..4].* = .{ @intCast(y * 8 * a / 255), @intCast(x * 5 * a / 255), @intCast(200 * @as(u32, a) / 255), a };
    };
    const picture = try @import("png.zig").encode(gpa, .{ .bytes = &px, .width = 48, .height = 32 });
    defer gpa.free(picture);
    var scene: Scene = .{ .picture = picture };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&scene, Scene.view), .{ .width = 360, .height = 300 });
    defer t.deinit();
    t.settle(1);
    r.syncAtlas(t.text.atlas.mask(), t.text.atlas.generation, null);
    r.syncImages(&t.text.images);
    const frame = try r.drawOffscreen(gpa, t.instances.items, t.size, t.scale, t.theme.background);
    defer frame.deinit(gpa);
    const cpu = try gpa.alloc(u8, frame.bytes.len);
    defer gpa.free(cpu);
    raster.draw(.{ .bytes = cpu, .width = frame.width, .height = frame.height }, t.instances.items, t.text.atlas.mask(), t.text.images.pictures(), t.scale, t.theme.background);
    // Measured with Mesa (llvmpipe): a mean of 0.03, at worst 2 levels apart.
    try expectClose(frame.bytes, cpu, 0.05, 4);
}

test "OpenGL draws the widgets the CPU renderer draws: text, icons, shadows, clips, a picture" {
    try widgets(false);
}

test "OpenGL ES draws the widgets the CPU renderer draws" {
    try widgets(true);
}

fn random(es: bool) !void {
    if (!linux) return error.SkipZigTest;
    var s: Setup = undefined;
    try s.init(es);
    defer s.deinit();
    const r = &s.r;
    const gpa = testing.allocator;
    // A glyph mask: a soft disc in a 64 × 64 atlas.
    var mask: [64 * 64]u8 = undefined;
    for (0..64) |y| for (0..64) |x| {
        const dx = @as(f32, @floatFromInt(x)) - 31.5;
        const dy = @as(f32, @floatFromInt(y)) - 31.5;
        mask[y * 64 + x] = @intFromFloat(std.math.clamp(28 - @sqrt(dx * dx + dy * dy), 0, 1) * 255);
    };
    const m: raster.Mask = .{ .pixels = &mask, .size = 64 };
    r.syncAtlas(m, 1, null);
    var prng: std.Random.DefaultPrng = .init(0x91);
    const rnd = prng.random();
    const f = struct {
        fn f(x: std.Random, lo: f32, hi: f32) f32 {
            return lo + x.float(f32) * (hi - lo);
        }
    }.f;
    const size: types.Size = .{ .w = 200, .h = 150 };
    for (0..12) |round| {
        var list: [40]gpu.Instance = undefined;
        for (&list) |*i| {
            const kind: f32 = switch (rnd.uintLessThan(u8, 4)) {
                0, 1 => gpu.Kind.quad,
                2 => gpu.Kind.shadow,
                else => gpu.Kind.text,
            };
            const x = f(rnd, -10, 180);
            const y = f(rnd, -10, 130);
            i.* = .{
                .rect = .{ x, y, f(rnd, 1, 80), f(rnd, 1, 60) },
                .color = .{ rnd.float(f32), rnd.float(f32), rnd.float(f32), if (rnd.boolean()) 1 else rnd.float(f32) },
                .border_color = .{ rnd.float(f32), rnd.float(f32), rnd.float(f32), rnd.float(f32) },
                .radius = f(rnd, 0, 25),
                .border_width = if (kind == gpu.Kind.shadow) f(rnd, 1, 12) else if (rnd.boolean()) 0 else f(rnd, 0.5, 6),
                .kind = kind,
                .uv = .{ 0, 0, 1, 1 },
            };
            if (rnd.boolean()) {
                const cx = f(rnd, -10, 150);
                const cy = f(rnd, -10, 100);
                i.clip = .{ cx, cy, cx + f(rnd, 20, 120), cy + f(rnd, 20, 90) };
                if (rnd.boolean()) i.clip_round = gpu.clipRound(f(rnd, 2, 20), rnd.int(u4));
            }
        }
        const scale: f32 = if (round % 2 == 0) 2 else 1.5;
        const clear: types.Color = .{ .r = 0.95, .g = 0.93, .b = 0.9 };
        const frame = try r.drawOffscreen(gpa, &list, size, scale, clear);
        defer frame.deinit(gpa);
        const cpu = try gpa.alloc(u8, frame.bytes.len);
        defer gpa.free(cpu);
        raster.draw(.{ .bytes = cpu, .width = frame.width, .height = frame.height }, &list, m, .{}, scale, clear);
        // Forty instances over each other: measured a mean of 0.24, at worst 4.
        try expectClose(frame.bytes, cpu, 0.5, 8);
    }
}

test "OpenGL draws quads, borders, rounded clips, glyphs and shadows as the CPU renderer does" {
    try random(false);
}

test "OpenGL ES draws quads, borders, rounded clips, glyphs and shadows as the CPU renderer does" {
    try random(true);
}

test "an OpenGL frame is the clear color when empty; resized frames and the instance buffer grow" {
    if (!linux) return error.SkipZigTest;
    var s: Setup = undefined;
    try s.init(false);
    defer s.deinit();
    const r = &s.r;
    const gpa = testing.allocator;
    const empty = try r.drawOffscreen(gpa, &.{}, .{ .w = 8, .h = 4 }, 1, .{ .r = 1, .g = 0, .b = 0 });
    defer empty.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, empty.bytes[0..4]);
    // Top left blue, the rest white: rows come from the top.
    const box: [1]gpu.Instance = .{.{ .rect = .{ 0, 0, 4, 2 }, .color = .{ 0, 0, 1, 1 } }};
    for ([_][2]f32{ .{ 8, 4 }, .{ 30, 20 }, .{ 5, 3 } }) |wh| {
        const p = try r.drawOffscreen(gpa, &box, .{ .w = wh[0], .h = wh[1] }, 1, .{ .r = 1, .g = 1, .b = 1 });
        defer p.deinit(gpa);
        try testing.expectEqual(@as(usize, @intFromFloat(wh[0])), p.width);
        try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, p.bytes[(1 * p.width + 3) * 4 ..][0..4]);
        try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, p.bytes[(2 * p.width + 3) * 4 ..][0..4]);
    }
    // Thousands of instances: the buffer grows.
    const many = try gpa.alloc(gpu.Instance, 5000);
    defer gpa.free(many);
    for (many, 0..) |*i, k| i.* = .{ .rect = .{ @floatFromInt(k % 50), @floatFromInt(k / 50), 1, 1 }, .color = .{ 0, 1, 0, 1 } };
    const p = try r.drawOffscreen(gpa, many, .{ .w = 50, .h = 100 }, 1, .{ .r = 0, .g = 0, .b = 0 });
    defer p.deinit(gpa);
    try testing.expect(r.capacity >= 5000 * @sizeOf(gpu.Instance));
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, p.bytes[(99 * 50 + 49) * 4 ..][0..4]);
}

test "frames drawn on the CPU are shown through OpenGL, rows from the top" {
    if (!linux) return error.SkipZigTest;
    var s: Setup = undefined;
    try s.init(false);
    defer s.deinit();
    const gpa = testing.allocator;
    const g = &@import("gl_api.zig").api;
    const c = @import("gl_api.zig");
    var tex: u32 = 0;
    g.glGenTextures(1, &tex);
    defer g.glDeleteTextures(1, &tex);
    g.glBindTexture(c.texture_2d, tex);
    g.glTexImage2D(c.texture_2d, 0, c.rgba8, 3, 2, 0, c.rgba, c.unsigned_byte, null);
    var fb: u32 = 0;
    g.glGenFramebuffers(1, &fb);
    defer g.glDeleteFramebuffers(1, &fb);
    g.glBindFramebuffer(c.framebuffer, fb);
    defer g.glBindFramebuffer(c.framebuffer, 0);
    g.glFramebufferTexture2D(c.framebuffer, c.color_attachment0, c.texture_2d, tex, 0);
    var pixels: [3 * 2 * 4]u8 = undefined;
    for (&pixels, 0..) |*b, i| b.* = @intCast(i * 10);
    var p: gl.Presenter = .{};
    defer p.deinit(gpa);
    try p.present(gpa, &pixels, 3, 2);
    const back = try gl.readFramebuffer(gpa, 3, 2);
    defer back.deinit(gpa);
    try testing.expectEqualSlices(u8, &pixels, back.bytes);
}

test "OpenGL's effects and layers keep their textures as their boxes move, and free them once frames stop drawing them" {
    if (!linux) return error.SkipZigTest;
    var s: Setup = undefined;
    try s.init(false);
    defer s.deinit();
    const r = &s.r;
    const gpa = testing.allocator;
    const effect = @import("effect.zig");
    var list: std.ArrayList(gpu.Instance) = .empty;
    defer list.deinit(gpa);
    const clear: types.Color = .{ .r = 1, .g = 1, .b = 1 };
    for (0..40) |n| {
        const x: f32 = 10 + @as(f32, @floatFromInt(n)) * 1.5;
        list.clearRetainingCapacity();
        try list.append(gpa, .{ .rect = .{ 0, 0, 200, 20 }, .color = .{ 1, 0, 0, 1 } });
        try list.append(gpa, .{ .rect = .{ x, 4, 40, 30 }, .color = .{ 0, 0, 0, 0 }, .radius = 6, .kind = gpu.Kind.effect });
        try list.append(gpa, .{ .rect = .{ x, 50, 40, 30 }, .color = .{ 0, 0, 0, 0 }, .border_width = 2, .kind = gpu.Kind.layer });
        try list.append(gpa, .{ .rect = .{ x + 6, 56, 20, 10 }, .color = .{ 0, 0, 1, 1 } });
        try list.append(gpa, .{ .rect = .{ x, 50, 40, 30 }, .color = .{ 0, 0, 0, 0 }, .border_width = 2, .kind = gpu.Kind.layer_end });
        try gpu.appendRows(gpa, &list, &effect.encode(&.{ .blur = 4 }));
        const p = try r.drawOffscreen(gpa, list.items, .{ .w = 200, .h = 100 }, 2, clear);
        p.deinit(gpa);
    }
    // Made once each size, then kept, rather than the 240 of forty frames.
    try testing.expect(r.fx.pool.made <= 16);
    try testing.expect(r.fx.pool.count() > 0);
    for (0..130) |_| {
        const p = try r.drawOffscreen(gpa, list.items[0..1], .{ .w = 200, .h = 100 }, 2, clear);
        p.deinit(gpa);
    }
    try testing.expectEqual(@as(usize, 0), r.fx.pool.count());
}
