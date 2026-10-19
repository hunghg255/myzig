//! Flexbox as Chrome lays it out, where myzig strayed from CSS (mygo's
//! layout_css tests): the sizes wanted are Chrome's for the same boxes.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;
const Style = ui.Style;

fn wantSize(t: *ui.Tester, index: u32, w: f32, h: f32) !void {
    const r = t.ctx.node(index).rect;
    try testing.expectApproxEqAbs(w, r.w, 0.05);
    try testing.expectApproxEqAbs(h, r.h, 0.05);
}

/// A view of its own for each test: `build` with the boxes it records.
fn Case(comptime build: fn (c: *ui.Context, at: *[4]u32) void) type {
    return struct {
        at: [4]u32 = @splat(0),
        fn view(s: *@This(), c: *ui.Context) void {
            _ = c.open(.{ .width = .{ .px = 600 }, .height = .{ .px = 500 }, .align_items = .stretch }, null);
            build(c, &s.at);
            c.end();
        }
    };
}

fn run(comptime build: fn (c: *ui.Context, at: *[4]u32) void, t: *ui.Tester, s: *Case(build)) !void {
    try t.init(testing.allocator, .init(s, Case(build).view), .{ .width = 600, .height = 500 });
}

test "css: a box is never smaller than its padding, whatever its size says" {
    const build = struct {
        fn f(c: *ui.Context, at: *[4]u32) void {
            const box: Style = .{ .width = .{ .px = 8 }, .padding = .{ .left = 11, .right = 3 } };
            _ = c.open(.{ .align_items = .start }, null);
            at[0] = c.leaf(box, .none, null);
            c.end();
            _ = c.open(.{ .direction = .row }, null);
            at[1] = c.leaf(box, .none, null);
            c.end();
        }
    }.f;
    var s: Case(build) = .{};
    var t: ui.Tester = undefined;
    try run(build, &t, &s);
    defer t.deinit();
    try wantSize(&t, s.at[0], 14, 0);
    try wantSize(&t, s.at[1], 14, 0);
}

test "css: a flex base size smaller than the padding is the padding's" {
    const build = struct {
        fn f(c: *ui.Context, at: *[4]u32) void {
            at[0] = c.leaf(.{ .grow = 1, .height = .{ .px = 9 }, .padding = .{ .top = 14 } }, .none, null);
            at[1] = c.leaf(.{ .grow = 2 }, .none, null);
        }
    }.f;
    var s: Case(build) = .{};
    var t: ui.Tester = undefined;
    try run(build, &t, &s);
    defer t.deinit();
    try wantSize(&t, s.at[0], 600, 176);
    try wantSize(&t, s.at[1], 600, 324);
}

test "css: a minimum does not change the base the free room is shared from" {
    const build = struct {
        fn f(c: *ui.Context, at: *[4]u32) void {
            at[0] = c.leaf(.{ .grow = 1 }, .none, null);
            at[1] = c.leaf(.{ .grow = 1, .min_height = 166 }, .none, null);
        }
    }.f;
    var s: Case(build) = .{};
    var t: ui.Tester = undefined;
    try run(build, &t, &s);
    defer t.deinit();
    try wantSize(&t, s.at[0], 600, 250);
    try wantSize(&t, s.at[1], 600, 250);
}

test "css: an item whose minimum wins over its maximum is frozen at it" {
    const build = struct {
        fn f(c: *ui.Context, at: *[4]u32) void {
            _ = c.open(.{ .align_items = .stretch }, null);
            at[0] = c.leaf(.{ .direction = .row, .height = .{ .px = 163 }, .min_height = 42, .max_height = 14 }, .none, null);
            at[1] = c.open(.{ .grow = 1 }, null);
            _ = c.leaf(.{ .padding = .{ .top = 8 } }, .none, null);
            c.end();
            c.end();
        }
    }.f;
    var s: Case(build) = .{};
    var t: ui.Tester = undefined;
    try run(build, &t, &s);
    defer t.deinit();
    try wantSize(&t, s.at[0], 600, 42);
    try wantSize(&t, s.at[1], 600, 8);
}

test "css: a growing item stopped by its maximum leaves the rest to the others" {
    const build = struct {
        fn f(c: *ui.Context, at: *[4]u32) void {
            _ = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = 10 } }, null);
            at[0] = c.leaf(.{ .grow = 1, .max_width = 100 }, .none, null);
            at[1] = c.leaf(.{ .grow = 1 }, .none, null);
            c.end();
        }
    }.f;
    var s: Case(build) = .{};
    var t: ui.Tester = undefined;
    try run(build, &t, &s);
    defer t.deinit();
    try wantSize(&t, s.at[0], 100, 0);
    try wantSize(&t, s.at[1], 500, 0);
}

test "css: wrapping text shrinks by its base size less its padding" {
    const build = struct {
        fn f(c: *ui.Context, at: *[4]u32) void {
            _ = c.open(.{ .direction = .row, .width = .{ .px = 300 } }, null);
            const words = "some words, wrapped";
            at[0] = c.leaf(.{}, .{ .text = .{ .str = words, .style = .{ .wrap = true }, .color = .black } }, null);
            at[1] = c.leaf(.{ .padding = .{ .left = 100 } }, .{ .text = .{ .str = words, .style = .{ .wrap = true }, .color = .black } }, null);
            c.end();
        }
    }.f;
    var s: Case(build) = .{};
    var t: ui.Tester = undefined;
    try run(build, &t, &s);
    defer t.deinit();
    const w = t.text.width("some words, wrapped", .{ .wrap = true });
    // Bases w and w + 100, shrinking by w each: half the lack each.
    const lack = 2 * w + 100 - 300;
    try testing.expect(lack > 0);
    try testing.expectApproxEqAbs(w - lack / 2, t.ctx.node(s.at[0]).rect.w, 0.6);
    try testing.expectApproxEqAbs(w + 100 - lack / 2, t.ctx.node(s.at[1]).rect.w, 0.6);
}
