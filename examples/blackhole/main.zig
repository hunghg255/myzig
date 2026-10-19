//! A black hole in a shader, after mygo's examples/blackhole: every pixel's
//! ray traced backward through the hole's gravity (`blackhole.zsl`), the
//! accretion disk and the stars behind, drawn by whichever renderer draws
//! the window (Direct3D 11, OpenGL, Metal, or the CPU twin). Drag to orbit,
//! scroll to come nearer.
//!
//!     zig build run-blackhole
//!     zig-out/bin/blackhole --myzig-snapshot=/tmp/hole.png
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

pub const hole = ui.shader.compile("blackhole", @embedFile("blackhole.zsl"));

const white: ui.Color = .{ .r = 1, .g = 1, .b = 1, .a = 0.92 };
const muted: ui.Color = .{ .r = 1, .g = 1, .b = 1, .a = 0.5 };

/// The camera orbits the hole: its angles about the disk's axis (yaw) and
/// above the disk (pitch), in radians, and its distance, in radii.
pub const Camera = struct {
    yaw: f32 = 0.6,
    pitch: f32 = 0.1,
    dist: f32 = 22,

    pub const Axes = struct { eye: [3]f32, right: [3]f32, forward: [3]f32 };

    /// Where the camera is, and its right and forward axes (its up is
    /// their cross product, which the shader takes).
    pub fn axes(c: Camera) Axes {
        const cp = @cos(c.pitch);
        const eye: @Vector(3, f32) = .{ cp * @sin(c.yaw) * c.dist, @sin(c.pitch) * c.dist, cp * @cos(c.yaw) * c.dist };
        const forward = normalize(-eye);
        const right = normalize(cross(forward, .{ 0, 1, 0 }));
        return .{ .eye = eye, .right = right, .forward = forward };
    }
};

fn cross(a: @Vector(3, f32), b: @Vector(3, f32)) @Vector(3, f32) {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn normalize(a: @Vector(3, f32)) @Vector(3, f32) {
    return a / @as(@Vector(3, f32), @splat(@sqrt(@reduce(.Add, a * a))));
}

pub const Hole = struct {
    cam: Camera = .{},
    /// The disk's clock, in seconds; it stops when `still`.
    time: f64 = 0,
    still: bool = false,
    last: ?f64 = null,
    /// How far the orbit turns on its own, radians a second.
    spin: f32 = 0.025,
    /// The steps a ray takes at most.
    steps: i32 = 240,
    drag: ?ui.Point = null,

    pub fn view(s: *Hole, c: *ui.Context) void {
        const dt: f64 = if (s.last) |l| @min(c.time - l, 0.1) else 0;
        s.last = c.time;
        if (!s.still) {
            s.time += dt;
            s.cam.yaw += s.spin * @as(f32, @floatCast(dt));
            c.animationFrame();
        }
        const a = s.cam.axes();
        const root = ui.shaderBox(c, &hole, .{
            .time = @as(f32, @floatCast(s.time)),
            .eye = a.eye,
            .right = a.right,
            .forward = a.forward,
            .focal = 1.5,
            .steps = s.steps,
        }, .{ .width = .fill, .height = .fill, .direction = .row, .align_items = .end, .padding = .{ .left = 30, .right = 28, .bottom = 26 }, .gap = 12 });
        defer c.end();
        s.input(c, root);
        {
            ui.column(c, .{ .gap = 4 });
            defer ui.end(c);
            ui.text(c, "Gargantua", .{ .size = 22, .weight = .semibold, .color = white });
            ui.text(c, "A black hole, its light traced through gravity by a shader written once", .{ .size = 12, .color = muted });
        }
        ui.spacer(c);
        ui.text(c, "Drag to orbit · Scroll to zoom", .{ .size = 12, .color = muted });
    }

    /// Drags turn the camera about the hole, the wheel moves it nearer.
    fn input(s: *Hole, c: *ui.Context, root: u32) void {
        c.wants_moves = true;
        const it = c.interact(root, .{});
        if (it.pressed and c.input.down) {
            if (s.drag) |d| {
                s.cam.yaw -= (c.input.mouse.x - d.x) * 0.006;
                s.cam.pitch = std.math.clamp(s.cam.pitch + (c.input.mouse.y - d.y) * 0.006, -1.4, 1.4);
                c.changed = true;
            }
            s.drag = c.input.mouse;
        } else s.drag = null;
        if (it.hovered and c.input.scroll.y != 0) {
            s.cam.dist = std.math.clamp(s.cam.dist * @exp(-c.input.scroll.y * 0.002), 8, 36);
            c.changed = true;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Black Hole" });
    defer app.destroy();
    var state: Hole = .{};
    _ = try app.newWindow(.{
        .title = "Black Hole",
        .width = 720,
        .height = 460,
        .content = .{ .view = .init(&state, Hole.view) },
    });
    try app.run();
}

test "the black hole draws: a dark middle, the disk's light around, the title" {
    var s: Hole = .{ .still = true, .time = 3, .steps = 120 };
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, Hole.view), .{ .width = 160, .height = 100, .scale = 1 });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.hasText("Gargantua"));
    const px = try t.render(std.testing.allocator);
    defer px.deinit(std.testing.allocator);
    const at = struct {
        fn luma(p: anytype, x: usize, y: usize) u32 {
            const b = p.bytes[(y * p.width + x) * 4 ..][0..4];
            return @as(u32, b[0]) + b[1] + b[2];
        }
    }.luma;
    // The hole's shadow is black in the middle; the disk around it is lit.
    var dark: u32 = 765;
    for (30..46) |y| for (70..90) |x| {
        dark = @min(dark, at(px, x, y));
    };
    try std.testing.expect(dark < 30);
    var lit: u32 = 0;
    for (20..80) |y| for (0..160) |x| {
        lit = @max(lit, at(px, x, y));
    };
    try std.testing.expect(lit > 400);
}

test "a drag orbits the camera" {
    var s: Hole = .{ .still = true, .steps = 8 };
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, Hole.view), .{ .width = 120, .height = 80, .scale = 1 });
    defer t.deinit();
    t.settle(1);
    const yaw = s.cam.yaw;
    t.drag(60, 40, 90, 50);
    try std.testing.expect(s.cam.yaw < yaw);
    try std.testing.expect(s.cam.pitch > 0.1);
}
