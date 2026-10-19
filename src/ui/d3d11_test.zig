//! The Direct3D 11 renderer against the CPU renderer, offscreen (a texture
//! drawn into and read back, no window): frames of widgets and of quads,
//! borders, rounded clips, glyphs, pictures and shadows must come out the
//! same, to rounding. Skipped where there is no Direct3D on a GPU.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const d3d11 = if (builtin.os.tag == .windows) @import("d3d11.zig") else struct {};

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
        std.debug.print("d3d11 vs cpu: mean {d:.4}, worst {d}\n", .{ m, most });
        return error.TestExpectedClose;
    }
}

fn renderer() !d3d11.Renderer {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    return d3d11.Renderer.init(testing.allocator) catch return error.SkipZigTest;
}

test "Direct3D draws the widgets the CPU renderer draws: text, icons, shadows, clips, a picture" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = try renderer();
    defer r.deinit();
    const gpa = testing.allocator;
    var px: [48 * 32 * 4]u8 = undefined;
    for (0..32) |y| for (0..48) |x| {
        const a: u8 = @intCast(255 - x * 2);
        px[(y * 48 + x) * 4 ..][0..4].* = .{ @intCast(y * 8 * a / 255), @intCast(x * 5 * a / 255), @intCast(200 * @as(u32, a) / 255), a };
    };
    const picture = try @import("png.zig").encode(gpa, .{ .bytes = &px, .width = 48, .height = 32 });
    defer gpa.free(picture);
    var s: Scene = .{ .picture = picture };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 360, .height = 300 });
    defer t.deinit();
    t.settle(1);
    r.syncAtlas(t.text.atlas.mask(), t.text.atlas.generation);
    r.syncImages(&t.text.images);
    const frame = try r.drawOffscreen(gpa, t.instances.items, t.size, t.scale, t.theme.background);
    defer frame.deinit(gpa);
    const cpu = try gpa.alloc(u8, frame.bytes.len);
    defer gpa.free(cpu);
    raster.draw(.{ .bytes = cpu, .width = frame.width, .height = frame.height }, t.instances.items, t.text.atlas.mask(), t.text.images.pictures(), t.scale, t.theme.background);
    // Measured: a mean of 0.03, at worst 2 levels apart.
    try expectClose(frame.bytes, cpu, 0.05, 4);
}

test "Direct3D draws quads, borders, rounded clips, glyphs and shadows as the CPU renderer does" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = try renderer();
    defer r.deinit();
    const gpa = testing.allocator;
    // A glyph mask: a soft disc in a 64 × 64 atlas.
    var mask: [64 * 64]u8 = undefined;
    for (0..64) |y| for (0..64) |x| {
        const dx = @as(f32, @floatFromInt(x)) - 31.5;
        const dy = @as(f32, @floatFromInt(y)) - 31.5;
        mask[y * 64 + x] = @intFromFloat(std.math.clamp(28 - @sqrt(dx * dx + dy * dy), 0, 1) * 255);
    };
    const m: raster.Mask = .{ .pixels = &mask, .size = 64 };
    r.syncAtlas(m, 1);
    var prng: std.Random.DefaultPrng = .init(0xd3d11);
    const rnd = prng.random();
    const f = struct {
        fn f(x: std.Random, lo: f32, hi: f32) f32 {
            return lo + x.float(f32) * (hi - lo);
        }
    }.f;
    const size: @import("types.zig").Size = .{ .w = 200, .h = 150 };
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
        const clear: @import("types.zig").Color = .{ .r = 0.95, .g = 0.93, .b = 0.9 };
        const frame = try r.drawOffscreen(gpa, &list, size, scale, clear);
        defer frame.deinit(gpa);
        const cpu = try gpa.alloc(u8, frame.bytes.len);
        defer gpa.free(cpu);
        raster.draw(.{ .bytes = cpu, .width = frame.width, .height = frame.height }, &list, m, .{}, scale, clear);
        // Forty instances over each other: measured a mean of 0.3, at worst 4.
        try expectClose(frame.bytes, cpu, 0.5, 8);
    }
}

test "an empty frame is the clear color, and frames reuse the ring of instance buffers" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = try renderer();
    defer r.deinit();
    const gpa = testing.allocator;
    const size: @import("types.zig").Size = .{ .w = 8, .h = 4 };
    const empty = try r.drawOffscreen(gpa, &.{}, size, 1, .{ .r = 1, .g = 0, .b = 0 });
    defer empty.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, empty.bytes[0..4]);
    const box: [1]gpu.Instance = .{.{ .rect = .{ 0, 0, 8, 4 }, .color = .{ 0, 0, 1, 1 } }};
    for (0..3) |_| {
        const p = try r.drawOffscreen(gpa, &box, size, 1, .{ .r = 1, .g = 1, .b = 1 });
        defer p.deinit(gpa);
        try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, p.bytes[(1 * 8 + 3) * 4 ..][0..4]);
    }
    try testing.expect(r.buffers[0] != null and r.buffers[1] != null);
}

test "the embedded shaders are d3d11.hlsl compiled" {
    try testing.expect(@import("d3d11_gen.zig").embedded(@embedFile("d3d11.cso")) != null);
}

extern "user32" fn CreateWindowExW(ex: u32, class: [*:0]const u16, title: ?[*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?*anyopaque, menu: ?*anyopaque, inst: ?*anyopaque, param: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn DestroyWindow(hwnd: *anyopaque) callconv(.winapi) i32;

test "a window's swap chain draws, resizes and presents (the window never shows)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = try renderer();
    defer r.deinit();
    const gpa = testing.allocator;
    const popup = 0x80000000; // and not visible
    const hwnd = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), null, popup, 0, 0, 64, 48, null, null, null, null) orelse return error.SkipZigTest;
    defer _ = DestroyWindow(hwnd);
    try r.attach(hwnd, 64, 48);
    const box: [1]gpu.Instance = .{.{ .rect = .{ 4, 4, 20, 10 }, .color = .{ 0, 1, 0, 1 }, .radius = 3 }};
    for ([_][2]u32{ .{ 64, 48 }, .{ 100, 30 }, .{ 100, 30 } }) |size| {
        try r.resize(size[0], size[1]);
        try r.drawUnpresented(&box, 2, .{ .r = 1, .g = 1, .b = 1 });
        const back = try r.readBackBuffer(gpa);
        defer back.deinit(gpa);
        try testing.expectEqual(@as(usize, size[0]), back.width);
        try testing.expectEqual(@as(usize, size[1]), back.height);
        const cpu = try gpa.alloc(u8, back.bytes.len);
        defer gpa.free(cpu);
        raster.draw(.{ .bytes = cpu, .width = back.width, .height = back.height }, &box, .{ .pixels = &.{}, .size = 0 }, .{}, 2, .{ .r = 1, .g = 1, .b = 1 });
        try expectClose(back.bytes, cpu, 0.05, 2);
        try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, back.bytes[(16 * back.width + 20) * 4 ..][0..4]);
        try r.present(1);
    }
}

test "effects and layers keep their textures as their boxes move, and free them once frames stop drawing them" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = try renderer();
    defer r.deinit();
    const gpa = testing.allocator;
    const effect = @import("effect.zig");
    var list: std.ArrayList(gpu.Instance) = .empty;
    defer list.deinit(gpa);
    const clear: @import("types.zig").Color = .{ .r = 1, .g = 1, .b = 1 };
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
    // Five textures an effect's and a layer's passes take, in the sizes a
    // box moving by half pixels takes: made once each, then kept.
    const pool = &r.fx.pool;
    // (Measured: 13, of the 240 forty frames took before.)
    try testing.expect(pool.made <= 16);
    try testing.expect(pool.count() > 0);
    // Frames without them: the textures go.
    for (0..130) |_| {
        const p = try r.drawOffscreen(gpa, list.items[0..1], .{ .w = 200, .h = 100 }, 2, clear);
        p.deinit(gpa);
    }
    try testing.expectEqual(@as(usize, 0), pool.count());
}

test "frames timed for benchmarks draw only what changed, and the GPU tells how long it took" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var r = try renderer();
    defer r.deinit();
    const damage = @import("damage.zig");
    var timer = try @import("d3d11_timing.zig").Timer.init(&r, testing.allocator, 400, 200);
    defer timer.deinit(&r);
    var box = [_]gpu.Instance{ .{ .rect = .{ 0, 0, 200, 100 }, .color = .{ 1, 1, 1, 1 } }, .{ .rect = .{ 10, 10, 2, 16 }, .color = .{ 0, 0, 1, 1 } } };
    const f: damage.Frame = .{ .instances = &box, .width = 400, .height = 200, .scale = 2, .clear = .{} };
    try testing.expectEqual(d3d11.Renderer.Drawn.whole, (try timer.draw(&r, f, false)).drawn);
    try testing.expectEqual(d3d11.Renderer.Drawn.nothing, (try timer.draw(&r, f, false)).drawn);
    box[1].color[0] = 1;
    const t = try timer.draw(&r, f, false);
    try testing.expectEqual(d3d11.Renderer.Drawn.part, t.drawn);
    try testing.expect(t.gpu_ms > 0 and t.encode_ms > 0);
    try testing.expectEqual(d3d11.Renderer.Drawn.whole, (try timer.draw(&r, f, true)).drawn);
}
