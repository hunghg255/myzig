//! Continuous corners (`Style.corners = .continuous`, `raster_corner.zig`)
//! on every GPU renderer against the CPU renderer: fills, borders,
//! shadows, pictures, gradients and what boxes clip, as widgets draw them
//! through `ui.Tester`, and random frames, some instances transformed.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const types = @import("types.zig");
const fx_test = @import("gpu_fx_test.zig");
const Draw = fx_test.Draw;

const stops = [_]types.Stop{ .{ .color = .hex(0xe0401a), .at = 0 }, .{ .color = .hex(0x2f6fd0), .at = 1 } };
const gradient: types.Gradient = .{ .stops = &stops, .angle = 30 };
const frost: types.Effect = .{ .blur = 3 };

const Scene = struct {
    picture: []const u8 = "",
    fn view(s: *Scene, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(16), .gap = 12, .width = .fill, .height = .fill });
        defer ui.end(c);
        ui.card(c, .{ .gap = 8, .radius = 18, .corners = .continuous, .shadow = .{ .blur = 18, .y = 6 } });
        {
            defer ui.end(c);
            ui.text(c, "Continuous corners", .{ .size = 15, .weight = .bold });
        }
        {
            const row = ui.div(c).row().gap(10);
            defer row.end();
            const clip = ui.div(c).row().w(150).h(44).rounded(16).continuous().clip();
            {
                defer clip.end();
                ui.div(c).w(90).hFull().bg(.hex(0xd04a2f)).end();
                ui.div(c).grow().hFull().bg(.hex(0x2f6fd0)).end();
                // A backdrop effect, cut by the clip's corners.
                _ = c.leaf(.{ .absolute = true, .width = .{ .px = 150 }, .height = .{ .px = 44 }, .effect = &frost }, .none, null);
            }
            ui.div(c).w(60).h(44).rounded(14).continuous().bg(.hex(0x3a9d5d)).border(.hex(0x1f4d2e)).borderW(3).end();
            _ = c.leaf(.{ .width = .{ .px = 60 }, .height = .{ .px = 44 }, .radius = 22, .corners = .continuous, .gradient = &gradient }, .none, null);
        }
        _ = ui.image(c, .{ .key = "corners", .bytes = s.picture, .max_width = 80, .radius = 16, .corners = .continuous });
    }
};

fn picture(gpa: std.mem.Allocator) ![]u8 {
    var px: [48 * 32 * 4]u8 = undefined;
    for (0..32) |y| for (0..48) |x| {
        px[(y * 48 + x) * 4 ..][0..4].* = .{ @intCast(y * 8), @intCast(x * 5), 200, 255 };
    };
    return @import("png.zig").encode(gpa, .{ .bytes = &px, .width = 48, .height = 32 });
}

/// The widgets scene, drawn by `d` and by the CPU.
pub fn widgets(d: Draw) !void {
    const gpa = testing.allocator;
    const png = try picture(gpa);
    defer gpa.free(png);
    var s: Scene = .{ .picture = png };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 320, .height = 260 });
    defer t.deinit();
    t.settle(1);
    d.sync(d.ctx, t.text.atlas.mask(), t.text.atlas.generation, &t);
    const frame = try d.draw(d.ctx, gpa, t.instances.items, t.size, t.scale, t.theme.background);
    defer frame.deinit(gpa);
    const cpu = try gpa.alloc(u8, frame.bytes.len);
    defer gpa.free(cpu);
    raster.draw(.{ .bytes = cpu, .width = frame.width, .height = frame.height }, t.instances.items, t.text.atlas.mask(), t.text.images.pictures(), t.scale, t.theme.background);
    try fx_test.expectClose(d.name, "continuous corners", frame.bytes, cpu, 0.05, 6);
}

/// Random frames of fills, borders and shadows with continuous corners,
/// clips with continuous corners, some instances transformed.
pub fn random(d: Draw) !void {
    const gpa = testing.allocator;
    d.sync(d.ctx, .{ .pixels = &.{0}, .size = 1 }, 1, null);
    var prng: std.Random.DefaultPrng = .init(0xc0de);
    const rnd = prng.random();
    const f = struct {
        fn f(x: std.Random, lo: f32, hi: f32) f32 {
            return lo + x.float(f32) * (hi - lo);
        }
    }.f;
    const size: types.Size = .{ .w = 200, .h = 150 };
    for (0..12) |round| {
        var list: std.ArrayList(gpu.Instance) = .empty;
        defer list.deinit(gpa);
        var rows: std.ArrayList([4]f32) = .empty;
        defer rows.deinit(gpa);
        for (0..30) |_| {
            const kind: f32 = if (rnd.uintLessThan(u8, 3) == 0) gpu.Kind.shadow else gpu.Kind.quad;
            var i: gpu.Instance = .{
                .rect = .{ f(rnd, -10, 170), f(rnd, -10, 120), f(rnd, 2, 90), f(rnd, 2, 70) },
                .color = .{ rnd.float(f32), rnd.float(f32), rnd.float(f32), if (rnd.boolean()) 1 else rnd.float(f32) },
                .border_color = .{ rnd.float(f32), rnd.float(f32), rnd.float(f32), rnd.float(f32) },
                .radius = -f(rnd, 0.5, 40),
                .border_width = if (kind == gpu.Kind.shadow) f(rnd, 1, 12) else if (rnd.boolean()) 0 else f(rnd, 0.5, 6),
                .kind = kind,
            };
            if (rnd.boolean()) {
                const cx = f(rnd, -10, 150);
                const cy = f(rnd, -10, 100);
                i.clip = .{ cx, cy, cx + f(rnd, 20, 120), cy + f(rnd, 20, 90) };
                if (rnd.boolean()) i.clip_round = gpu.clipContinuous(f(rnd, 2, 30), rnd.int(u4));
            }
            if (rnd.uintLessThan(u8, 4) == 0) {
                const o: types.Point = .{ .x = i.rect[0] + i.rect[2] / 2, .y = i.rect[1] + i.rect[3] / 2 };
                const mt = types.Affine.scaling(f(rnd, 0.6, 1.5), f(rnd, 0.6, 1.5)).then(.rotation(f(rnd, -180, 180))).about(o);
                const inv = mt.inverse().?;
                const row: u32 = @intCast(rows.items.len);
                try rows.appendSlice(gpa, &.{ .{ inv.a, inv.b, inv.c, inv.d }, .{ inv.x, inv.y, mt.x, mt.y }, .{ mt.a, mt.b, mt.c, mt.d }, .{ -1e6, -1e6, 1e6, 1e6 } });
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
        raster.draw(.{ .bytes = cpu, .width = frame.width, .height = frame.height }, list.items, .{ .pixels = &.{0}, .size = 1 }, .{}, scale, clear);
        try fx_test.expectClose(d.name, "random continuous corners", frame.bytes, cpu, 0.5, 8);
    }
}

/// Large shadows with continuous corners, which renderers cut into pieces
/// (`gpu_corners.zig`), over and under boxes.
pub fn shadows(d: Draw) !void {
    const gpa = testing.allocator;
    d.sync(d.ctx, .{ .pixels = &.{0}, .size = 1 }, 1, null);
    const size: types.Size = .{ .w = 320, .h = 220 };
    for ([_]f32{ 2, 1.5, 1 }) |scale| {
        const list = [_]gpu.Instance{
            .{ .rect = .{ 20, 20, 200, 120 }, .color = .{ 0, 0, 0, 0.45 }, .radius = -28, .border_width = 8, .kind = gpu.Kind.shadow },
            .{ .rect = .{ 20, 20, 200, 120 }, .color = .{ 1, 1, 1, 1 }, .radius = -28 },
            .{ .rect = .{ 120, 90, 180, 110 }, .color = .{ 0.1, 0.2, 0.6, 0.6 }, .radius = -40, .border_width = 4, .kind = gpu.Kind.shadow, .clip = .{ 0, 0, 290, 205 } },
            .{ .rect = .{ 60, 150, 240, 40 }, .color = .{ 0, 0, 0, 0.3 }, .radius = -12, .border_width = 2, .kind = gpu.Kind.shadow },
        };
        const clear: types.Color = .{ .r = 0.95, .g = 0.93, .b = 0.9 };
        const frame = try d.draw(d.ctx, gpa, &list, size, scale, clear);
        defer frame.deinit(gpa);
        const cpu = try gpa.alloc(u8, frame.bytes.len);
        defer gpa.free(cpu);
        raster.draw(.{ .bytes = cpu, .width = frame.width, .height = frame.height }, &list, .{ .pixels = &.{0}, .size = 1 }, .{}, scale, clear);
        // Measured: a mean of 0.2 (as with circular corners), at worst 3.
        try fx_test.expectClose(d.name, "large shadows with continuous corners", frame.bytes, cpu, 0.3, 4);
    }
}

test "Direct3D draws continuous corners as the CPU renderer does" {
    try fx_test.withD3d(shadows);
    try fx_test.withD3d(widgets);
    try fx_test.withD3d(random);
}

test "OpenGL draws continuous corners as the CPU renderer does" {
    try fx_test.withGl(false, shadows);
    try fx_test.withGl(false, widgets);
    try fx_test.withGl(false, random);
}

test "OpenGL ES draws continuous corners as the CPU renderer does" {
    try fx_test.withGl(true, shadows);
    try fx_test.withGl(true, widgets);
    try fx_test.withGl(true, random);
}

test "Metal draws continuous corners as the CPU renderer does" {
    if (@import("text.zig").portable) return error.SkipZigTest;
    try metal();
}

/// The widgets scene on Metal (macOS), against the CPU renderer over the
/// atlas's texels as Metal has them.
pub fn metal() !void {
    const gpa = testing.allocator;
    const png = try picture(gpa);
    defer gpa.free(png);
    var s: Scene = .{ .picture = png };
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
    try fx_test.expectClose("metal", "continuous corners", frame.bytes, cpu, 0.1, 16);
}
