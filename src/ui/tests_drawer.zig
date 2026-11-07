//! Drawers, after vaul, through the Tester: opening and closing, drags
//! that close or settle back, snap points and the handle, the background.
const std = @import("std");
const ui = @import("ui.zig");
const drawer = @import("drawer.zig");
const testing = std.testing;

const App = struct {
    drawer: drawer.DrawerState = .{},
    opts: drawer.Options = .{},
    done: u32 = 0,
    under: u32 = 0,

    fn view(s: *App, c: *ui.Context) void {
        const back = drawer.drawerBackground(c, &s.drawer);
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(20), .gap = 8 });
        if (ui.button(c, "Open", .{}).clicked) s.drawer.show();
        if (ui.button(c, "Under", .{}).clicked) s.under += 1;
        ui.end(c);
        back.end();
        if (drawer.drawer(c, &s.drawer, s.opts)) |d| {
            defer d.end();
            ui.text(c, "Move goal", .{ .weight = .semibold });
            ui.text(c, "Set your daily activity goal.", .{});
            if (ui.button(c, "Done", .{}).clicked) {
                s.done += 1;
                s.drawer.close();
            }
        }
    }
};

const size: @import("tester.zig").Options = .{ .width = 600, .height = 500 };

fn press(t: *ui.Tester, x: f32, y: f32) void {
    t.moveTo(x, y);
    t.ctx.pointerDown();
    t.frame();
}

fn slide(t: *ui.Tester, dx: f32, dy: f32, seconds: f32) void {
    const from = t.ctx.input.mouse;
    for (1..5) |k| {
        const f: f32 = @floatFromInt(k);
        t.ctx.input.mouse = .{ .x = from.x + dx * f / 4, .y = from.y + dy * f / 4 };
        t.advance(seconds / 4);
    }
}

/// Moves the pressed pointer down by `dy` in one frame: fast.
fn flick(t: *ui.Tester, dy: f32) void {
    t.ctx.input.mouse.y += dy;
    t.frame();
}

fn letGo(t: *ui.Tester) void {
    t.ctx.pointerUp();
    t.frame();
}

test "a drawer slides up from the bottom, the content behind shrinking back, and down as it closes" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), size);
    defer t.deinit();
    try t.clickText("Open");
    t.frame();
    // On its way: still low.
    const early = t.findText("Move goal").?;
    t.settle(2);
    const title = t.findText("Move goal").?;
    try testing.expect(title.y < early.y);
    try testing.expect(title.y > 300 and title.y < 500);
    try testing.expectApproxEqAbs(@as(f32, 1), s.drawer.presence, 1e-3);
    // Its bottom at the window's, its corners beyond it.
    const done = t.findText("Done").?;
    try testing.expect(done.y + done.h < 500);
    // Behind, the content shrinks back, held by the transform.
    try testing.expect(s.drawer.presence_drawn > 0.99);
    // Escape closes it: it slides down and is gone, the focus back.
    t.key(.escape);
    t.settle(2);
    try testing.expect(!t.hasText("Move goal"));
    try testing.expect(!s.drawer.visible());
    try testing.expectEqual(@as(f32, 0), s.drawer.presence);
    // A press beside it closes it too, not reaching what is under.
    try t.clickText("Open");
    t.settle(2);
    t.click(300, 20);
    t.settle(2);
    try testing.expect(!s.drawer.visible());
    try testing.expectEqual(@as(u32, 0), s.under);
    // Its own button.
    try t.clickText("Open");
    t.settle(2);
    try t.clickText("Done");
    t.settle(2);
    try testing.expectEqual(@as(u32, 1), s.done);
    try testing.expect(!s.drawer.visible());
}

test "dragged down far or fast it closes; a short drag settles back; up, it holds back" {
    var s: App = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), size);
    defer t.deinit();
    s.drawer.show();
    t.settle(2);
    const title = t.findText("Move goal").?;
    const x = title.x + title.w + 40;
    const y = title.y + 4;
    // A short slow drag: back to open.
    press(&t, x, y);
    slide(&t, 0, 20, 0.8);
    try testing.expectApproxEqAbs(@as(f32, 20), s.drawer.drag.at, 0.5);
    letGo(&t);
    t.settle(2);
    try testing.expect(s.drawer.open);
    try testing.expectApproxEqAbs(@as(f32, 0), s.drawer.drag.at, 0.5);
    // Up past open: held back, a little.
    press(&t, x, y);
    slide(&t, 0, -100, 0.8);
    // vaul's hold: 8 (ln(100 + 1) - 2).
    try testing.expectApproxEqAbs(-8 * (@log(@as(f32, 101)) - 2), s.drawer.drag.at, 0.5);
    letGo(&t);
    t.settle(2);
    try testing.expectApproxEqAbs(@as(f32, 0), s.drawer.drag.at, 0.5);
    // The dimming follows a drag down.
    press(&t, x, y);
    slide(&t, 0, 40, 0.8);
    try testing.expect(s.drawer.presence < 1);
    try testing.expect(s.drawer.presence > 0.3);
    // Let go past a quarter of its height: it closes.
    slide(&t, 0, s.drawer.extent * 0.3, 0.8);
    letGo(&t);
    try testing.expect(!s.drawer.open);
    t.settle(2);
    try testing.expect(!s.drawer.visible());
    // A flick closes it from not far.
    s.drawer.show();
    t.settle(2);
    press(&t, x, y);
    flick(&t, 25);
    letGo(&t);
    try testing.expect(!s.drawer.open);
}

test "snap points: it opens at the first, the handle and drags move it among them" {
    var s: App = .{ .opts = .{ .snap_points = &.{ .{ .fraction = 0.4 }, .{ .fraction = 1 } } } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), size);
    defer t.deinit();
    s.drawer.show();
    t.settle(2);
    const extent = drawer.extentOf(&t.ctx, &s.drawer, s.opts);
    try testing.expectApproxEqAbs(@as(f32, 400), extent, 0.5);
    try testing.expectEqual(@as(usize, 0), s.drawer.snap);
    try testing.expectApproxEqAbs(extent * 0.6, s.drawer.drag.at, 0.5);
    // Below the last snap point the window is not dimmed.
    try testing.expectApproxEqAbs(@as(f32, 0), s.drawer.presence, 1e-3);
    // A click on the handle: the next.
    try t.clickText("Move goal");
    const title = t.findText("Move goal").?;
    t.click(300, title.y - 16 - 6);
    t.settle(2);
    try testing.expectEqual(@as(usize, 1), s.drawer.snap);
    try testing.expectApproxEqAbs(@as(f32, 0), s.drawer.drag.at, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 1), s.drawer.presence, 1e-3);
    // Dragged slowly most of the way down: the nearest, the first.
    const at = t.findText("Move goal").?;
    press(&t, at.x + at.w + 40, at.y + 4);
    slide(&t, 0, 200, 1.6);
    letGo(&t);
    t.settle(2);
    try testing.expect(s.drawer.open);
    try testing.expectEqual(@as(usize, 0), s.drawer.snap);
    // Thrown down from the first: closed.
    const low = t.findText("Move goal").?;
    press(&t, low.x + low.w + 40, low.y + 4);
    flick(&t, 25);
    letGo(&t);
    try testing.expect(!s.drawer.open);
}

test "a drawer that is not dismissible stays: Escape, a press beside, a drag" {
    var s: App = .{ .opts = .{ .dismissible = false } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), size);
    defer t.deinit();
    s.drawer.show();
    t.settle(2);
    t.key(.escape);
    t.click(300, 20);
    const title = t.findText("Move goal").?;
    press(&t, title.x + title.w + 40, title.y + 4);
    slide(&t, 0, 200, 0.2);
    letGo(&t);
    t.settle(2);
    try testing.expect(s.drawer.open);
    try testing.expectApproxEqAbs(@as(f32, 0), s.drawer.drag.at, 0.5);
}

test "drawers at the other sides; the presence follows how far it is from open" {
    const opts: drawer.Options = .{ .snap_points = &.{ .{ .fraction = 0.25 }, .{ .px = 200 }, .{ .fraction = 1 } }, .fade_from = 1 };
    try testing.expectApproxEqAbs(@as(f32, 0), drawer.presenceAt(opts, 400, 300), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), drawer.presenceAt(opts, 400, 200), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), drawer.presenceAt(opts, 400, 250), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), drawer.presenceAt(.{}, 400, 200), 1e-4);

    var s: App = .{ .opts = .{ .side = .right } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), size);
    defer t.deinit();
    s.drawer.show();
    t.settle(2);
    const title = t.findText("Move goal").?;
    try testing.expect(title.x > 600 - 384 and title.x < 600 - 384 + 40);
    // Dragged right, toward its edge: it closes.
    press(&t, title.x + 4, title.y + 60);
    slide(&t, 200, 0, 0.8);
    letGo(&t);
    try testing.expect(!s.drawer.open);
    s.opts.side = .top;
    t.settle(2);
    s.drawer.show();
    t.settle(2);
    try testing.expect(t.findText("Move goal").?.y < 100);
}

test "snap points one at a time; a long press on the handle is not a click" {
    var s: App = .{ .opts = .{ .snap_points = &.{ .{ .fraction = 0.3 }, .{ .fraction = 0.6 }, .{ .fraction = 1 } }, .snap_to_sequential = true } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, App.view), size);
    defer t.deinit();
    s.drawer.show();
    t.settle(2);
    // Thrown up hard from the first: the second, not the last.
    const at = t.findText("Move goal").?;
    press(&t, at.x + at.w + 40, at.y + 4);
    flick(&t, -100);
    letGo(&t);
    t.settle(2);
    try testing.expectEqual(@as(usize, 1), s.drawer.snap);
    // Held on the handle, then let go: it stays.
    const title = t.findText("Move goal").?;
    press(&t, 300, title.y - 16 - 6);
    t.advance(0.5);
    letGo(&t);
    t.settle(2);
    try testing.expectEqual(@as(usize, 1), s.drawer.snap);
}

const Nested = struct {
    outer: drawer.DrawerState = .{},
    inner: drawer.DrawerState = .{},
    modal: bool = true,
    under: u32 = 0,

    fn view(s: *Nested, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(20) });
        if (ui.button(c, "Under", .{}).clicked) s.under += 1;
        ui.end(c);
        if (drawer.drawer(c, &s.outer, .{ .modal = s.modal })) |d| {
            defer d.end();
            ui.text(c, "Outer drawer", .{});
            if (ui.button(c, "Open another", .{}).clicked) s.inner.show();
            if (drawer.drawer(c, &s.inner, .{ .parent = &s.outer })) |n| {
                defer n.end();
                ui.text(c, "Inner drawer", .{});
            }
        }
    }
};

test "a drawer opened from another pushes it back, and lets it come forward as it closes" {
    var s: Nested = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Nested.view), size);
    defer t.deinit();
    s.outer.show();
    t.settle(2);
    try testing.expectEqual(@as(?ui.Affine, null), panelOf(&t, "Outer drawer").style.transform);
    try t.clickText("Open another");
    t.settle(2);
    try testing.expect(t.hasText("Inner drawer"));
    try testing.expectApproxEqAbs(@as(f32, 1), s.outer.child, 1e-3);
    // Smaller by 16 points of the window's width, and 16 points up.
    const m = panelOf(&t, "Outer drawer").style.transform.?;
    try testing.expectApproxEqAbs(@as(f32, (600.0 - 16.0) / 600.0), m.a, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, -16), m.y, 1e-3);
    // Escape closes the inner one alone.
    t.key(.escape);
    t.settle(2);
    try testing.expect(!s.inner.visible());
    try testing.expect(s.outer.open);
    try testing.expectEqual(@as(?ui.Affine, null), panelOf(&t, "Outer drawer").style.transform);
}

test "a drawer that is not modal leaves the window to use beside it" {
    var s: Nested = .{ .modal = false };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Nested.view), size);
    defer t.deinit();
    s.outer.show();
    t.settle(2);
    // Not dimmed; a press behind reaches what is there, the drawer staying.
    try t.clickText("Under");
    try testing.expectEqual(@as(u32, 1), s.under);
    try testing.expect(s.outer.open);
    // Escape still closes it.
    t.key(.escape);
    t.settle(2);
    try testing.expect(!s.outer.visible());
}

/// The panel a text is in: the box under the drawer's overlay.
fn panelOf(t: *ui.Tester, text: []const u8) @import("node.zig").Node {
    const nodes = t.ctx.nodes.items;
    var i: u32 = for (nodes, 0..) |n, k| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, text)) break @intCast(k),
        else => {},
    } else unreachable;
    while (nodes[nodes[i].parent].parent != 0) i = nodes[i].parent;
    return nodes[i];
}

test {
    _ = @import("drawer_drag.zig");
}
