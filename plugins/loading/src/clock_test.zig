//! Public widget clocks are tested against elapsed time and rendered phases.
const std = @import("std");
const ui = @import("myzig").ui;
const loading = @import("loading.zig");

fn hash(t: *ui.Tester) !u64 {
    const p = try t.render(std.testing.allocator);
    defer p.deinit(std.testing.allocator);
    return std.hash.Wyhash.hash(0, p.bytes);
}

test "doubling duration takes twice the elapsed time to reach the same painted phase" {
    const S = struct {
        indicator: loading.Indicator = .{},
        duration: f64,
        fn view(s: *@This(), c: *ui.Context) void {
            _ = s.indicator.show(c, .arc, .{ .size = 32, .duration = s.duration });
        }
    };
    var fast: S = .{ .duration = 1 };
    var slow: S = .{ .duration = 2 };
    var a: ui.Tester = undefined;
    try a.init(std.testing.allocator, .init(&fast, S.view), .{ .width = 48, .height = 48, .scale = 1 });
    defer a.deinit();
    var b: ui.Tester = undefined;
    try b.init(std.testing.allocator, .init(&slow, S.view), .{ .width = 48, .height = 48, .scale = 1 });
    defer b.deinit();
    a.dt = 0;
    b.dt = 0;
    a.time = 0.25;
    b.time = 0.25;
    a.frame();
    b.frame();
    const quarter = try hash(&a);
    try std.testing.expect(quarter != try hash(&b));
    b.time = 0.5;
    b.frame();
    try std.testing.expectEqual(quarter, try hash(&b));
}

test "instances pause independently and rebuilding a frame does not advance clocks twice" {
    const S = struct {
        a: loading.Indicator = .{},
        b: loading.Indicator = .{},
        pause_b: bool = true,
        rebuilds: u8 = 0,
        fn view(s: *@This(), c: *ui.Context) void {
            _ = s.a.show(c, .ring, .{});
            _ = s.b.show(c, .ring, .{ .paused = s.pause_b });
            if (s.rebuilds > 0) {
                s.rebuilds -= 1;
                c.changed = true;
            }
        }
    };
    var s: S = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, S.view), .{ .width = 100, .height = 100, .scale = 1 });
    defer t.deinit();
    t.dt = 0;
    s.rebuilds = 2;
    t.time = 0.25;
    t.frame();
    try std.testing.expectEqual(@as(u32, 3), t.ctx.stats.passes);
    try std.testing.expectEqual(@as(f64, 0.25), s.a.seconds);
    try std.testing.expectEqual(@as(f64, 0), s.b.seconds);
    s.pause_b = false;
    t.frame();
    t.time = 0.5;
    t.frame();
    try std.testing.expectEqual(@as(f64, 0.5), s.a.seconds);
    try std.testing.expectEqual(@as(f64, 0.25), s.b.seconds);
}
