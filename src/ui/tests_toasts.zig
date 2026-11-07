//! Toasts, after sonner, through the Tester: their corner, the stack and
//! its spreading out, changes in place, swipes, buttons and keys.
const std = @import("std");
const ui = @import("ui.zig");
const toast = @import("toast.zig");
const node = @import("node.zig");
const testing = std.testing;

const Toaster = struct {
    toasts: toast.Toasts = .{},
    undo: u64 = 0,
    undone: u32 = 0,
    canceled: u32 = 0,
    closed: u32 = 0,
    under: u32 = 0,
    last_timed_out: ?u64 = null,

    fn view(s: *Toaster, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(20) });
        defer ui.end(c);
        ui.spacer(c);
        if (ui.button(c, "Under", .{}).clicked) s.under += 1;
        const r = toast.toasts(c, &s.toasts);
        if (r.action) |id| if (id == s.undo) {
            s.undone += 1;
        };
        if (r.cancel != null) s.canceled += 1;
        if (r.closed != null) s.closed += 1;
        s.last_timed_out = r.timed_out;
    }
};

const wide: @import("tester.zig").Options = .{ .width = 800, .height = 400 };

fn indexOfText(t: *ui.Tester, s: []const u8) ?u32 {
    for (t.ctx.nodes.items, 0..) |n, i| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, s)) return @intCast(i),
        else => {},
    };
    return null;
}

/// The opacity a text is drawn with: its own and its boxes'.
fn opacityOf(t: *ui.Tester, s: []const u8) f32 {
    var i = indexOfText(t, s) orelse return 0;
    var o: f32 = 1;
    while (true) {
        const n = t.ctx.nodes.items[i];
        o *= n.style.opacity;
        if (n.parent == node.none or i == 0) return o;
        i = n.parent;
    }
}

/// The toast box a text is in: its title's row's box.
fn boxOf(t: *ui.Tester, s: []const u8) node.Node {
    var i = indexOfText(t, s).?;
    for (0..3) |_| i = t.ctx.nodes.items[i].parent;
    return t.ctx.nodes.items[i];
}

test "toasts show in the bottom right corner and go after their time" {
    var s: Toaster = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Toaster.view), wide);
    defer t.deinit();
    _ = s.toasts.show("Saved");
    t.settle(1);
    const box = boxOf(&t, "Saved").rect;
    try testing.expectApproxEqAbs(@as(f32, 800 - 24), box.x + box.w, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 400 - 24), box.y + box.h, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 356), box.w, 0.5);
    try testing.expect(t.ctx.frame_in != null);
    t.advance(3.5);
    try testing.expect(t.hasText("Saved"));
    t.advance(1);
    t.settle(1);
    try testing.expect(!t.hasText("Saved"));
    try testing.expectEqual(@as(usize, 0), s.toasts.len);
    // At the top in the middle, or across a narrow window.
    s.toasts.position = .top_center;
    _ = s.toasts.show("Up here");
    t.settle(1);
    const up = boxOf(&t, "Up here").rect;
    try testing.expectApproxEqAbs(@as(f32, 24), up.y, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 400), up.x + up.w / 2, 0.5);
    t.resize(400, 400);
    t.settle(1);
    try testing.expectApproxEqAbs(@as(f32, 400 - 32), boxOf(&t, "Up here").rect.w, 0.5);
}

test "the newest in front, three behind peeking out blank, spread out under the pointer" {
    var s: Toaster = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Toaster.view), wide);
    defer t.deinit();
    for ([_][]const u8{ "One", "Two", "Three", "Four" }) |m| _ = s.toasts.show(m);
    t.settle(1);
    const four = boxOf(&t, "Four").rect;
    const three = boxOf(&t, "Three").rect;
    // Behind, the gap higher, the front's height, its content hidden.
    try testing.expectApproxEqAbs(@as(f32, 14), four.y - three.y, 0.5);
    try testing.expectApproxEqAbs(four.h, three.h, 0.5);
    try testing.expect(opacityOf(&t, "Four") > 0.99);
    try testing.expect(opacityOf(&t, "Three") < 0.01);
    // The fourth is past those that show.
    try testing.expect(opacityOf(&t, "One") < 0.01);
    // Under the pointer they spread out, their time stopped.
    t.moveTo(four.x + 20, four.y + 10);
    t.settle(1);
    const spread_four = boxOf(&t, "Four").rect;
    const spread_three = boxOf(&t, "Three").rect;
    try testing.expectApproxEqAbs(spread_four.y - 14 - spread_three.h, spread_three.y, 0.5);
    try testing.expect(opacityOf(&t, "Three") > 0.99);
    t.advance(10);
    try testing.expectEqual(@as(usize, 4), s.toasts.count());
    // The pointer gone: together again, and their time runs out.
    t.moveTo(10, 10);
    t.settle(1);
    try testing.expectApproxEqAbs(@as(f32, 14), boxOf(&t, "Four").rect.y - boxOf(&t, "Three").rect.y, 0.5);
    t.advance(4.5);
    t.settle(1);
    try testing.expectEqual(@as(usize, 0), s.toasts.len);
}

test "a toast with the key of one showing changes it where it is; loading lasts" {
    var s: Toaster = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Toaster.view), wide);
    defer t.deinit();
    const id = s.toasts.loading("Uploading report.pdf", "upload");
    _ = s.toasts.add(.{ .title = "Other", .timeout = -1 });
    t.settle(1);
    t.advance(30);
    try testing.expect(s.toasts.has(id));
    // Done: the same toast, still behind the newer one, its time starting.
    try testing.expectEqual(id, s.toasts.add(.{ .title = "Uploaded", .kind = .success, .key = "upload" }));
    t.settle(1);
    try testing.expect(t.hasText("Uploaded"));
    try testing.expect(!t.hasText("Uploading report.pdf"));
    try testing.expectEqual(@as(usize, 2), s.toasts.count());
    try testing.expectEqual(id, s.toasts.items[0].id);
    t.advance(4.5);
    t.settle(1);
    try testing.expect(!s.toasts.has(id));
}

fn press(t: *ui.Tester, x: f32, y: f32) void {
    t.moveTo(x, y);
    t.ctx.pointerDown();
    t.frame();
}

/// Moves the pressed pointer by (dx, dy) over `seconds`, in four steps.
fn slide(t: *ui.Tester, dx: f32, dy: f32, seconds: f32) void {
    const from = t.ctx.input.mouse;
    for (1..5) |k| {
        const f: f32 = @floatFromInt(k);
        t.ctx.input.mouse = .{ .x = from.x + dx * f / 4, .y = from.y + dy * f / 4 };
        t.advance(seconds / 4);
    }
}

fn letGo(t: *ui.Tester) void {
    t.ctx.pointerUp();
    t.frame();
}

test "a swipe toward the edge closes a toast; a short one comes back; the other way holds back" {
    var s: Toaster = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Toaster.view), wide);
    defer t.deinit();
    const id = s.toasts.add(.{ .title = "Swipe me", .timeout = -1 });
    t.settle(1);
    const box = boxOf(&t, "Swipe me").rect;
    // Short and slow: back where it was.
    press(&t, box.x + 100, box.y + 20);
    slide(&t, 0, 20, 0.8);
    try testing.expectApproxEqAbs(@as(f32, 20), s.toasts.items[0].swipe.y, 0.5);
    letGo(&t);
    t.settle(1);
    try testing.expect(s.toasts.has(id));
    try testing.expectEqual(@as(f32, 0), s.toasts.items[0].swipe.y);
    // Up, away from the edge: held back.
    press(&t, box.x + 100, box.y + 20);
    slide(&t, 0, -40, 0.8);
    // 40 points held back to 40 / (1.5 + 40 / 20).
    try testing.expectApproxEqAbs(@as(f32, -40.0 / 3.5), s.toasts.items[0].swipe.y, 0.5);
    try testing.expect(s.toasts.items[0].swipe.y < 0);
    letGo(&t);
    t.settle(1);
    try testing.expect(s.toasts.has(id));
    // Right, toward the edge of a toast at the right: gone.
    press(&t, box.x + 100, box.y + 20);
    slide(&t, 60, 0, 0.8);
    letGo(&t);
    try testing.expect(!s.toasts.has(id));
    try testing.expectEqual(@as(u32, 1), s.closed);
    t.settle(1);
    try testing.expect(!t.hasText("Swipe me"));
    // Fast, though short: gone too.
    const fast = s.toasts.add(.{ .title = "Flick me", .timeout = -1 });
    t.settle(1);
    const fb = boxOf(&t, "Flick me").rect;
    press(&t, fb.x + 100, fb.y + 20);
    slide(&t, 0, 30, 0.1);
    letGo(&t);
    try testing.expect(!s.toasts.has(fast));
}

test "action, Cancel and the close button; the pointer goes through the room around them" {
    var s: Toaster = .{ .toasts = .{ .close_button = true } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Toaster.view), wide);
    defer t.deinit();
    s.undo = s.toasts.add(.{ .title = "Note deleted", .action = "Undo", .cancel = "Keep" });
    t.settle(1);
    try t.clickText("Under");
    try testing.expectEqual(@as(u32, 1), s.under);
    try t.clickText("Undo");
    try testing.expectEqual(@as(u32, 1), s.undone);
    t.settle(1);
    try testing.expect(!s.toasts.has(s.undo));
    const kept = s.toasts.add(.{ .title = "Draft saved", .cancel = "Keep" });
    t.settle(1);
    try t.clickText("Keep");
    try testing.expectEqual(@as(u32, 1), s.canceled);
    try testing.expect(!s.toasts.has(kept));
    t.settle(1);
    // The close button at its top left corner.
    const id = s.toasts.add(.{ .title = "Uploading", .description = "report.pdf", .timeout = -1 });
    t.settle(1);
    const box = boxOf(&t, "Uploading").rect;
    t.click(box.x + 3, box.y + 3);
    try testing.expect(!s.toasts.has(id));
    try testing.expectEqual(@as(u32, 1), s.closed);
}

test "Alt+T takes the keyboard to the newest toast, spread out; Escape gives it back" {
    var s: Toaster = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Toaster.view), wide);
    defer t.deinit();
    _ = s.toasts.show("First");
    _ = s.toasts.show("Second");
    t.settle(1);
    try testing.expect(t.shortcut(.{ .key = 't', .alt = true }));
    t.settle(1);
    try testing.expect(s.toasts.by_keys);
    try testing.expectEqual(boxOf(&t, "Second").id, t.ctx.focus);
    try testing.expect(opacityOf(&t, "First") > 0.99);
    t.advance(10);
    try testing.expectEqual(@as(usize, 2), s.toasts.count());
    t.key(.escape);
    t.frame();
    try testing.expect(!s.toasts.by_keys);
    try testing.expectEqual(@as(u64, 0), t.ctx.focus);
}

test "rich colors tint a toast after its kind; invert swaps the theme's" {
    var s: Toaster = .{ .toasts = .{ .rich_colors = true } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Toaster.view), wide);
    defer t.deinit();
    _ = s.toasts.success("Paid");
    _ = s.toasts.show("Plain");
    t.settle(1);
    try testing.expectEqual(ui.Color.hex(0xecfdf3), boxOf(&t, "Paid").style.background.?);
    // A toast without a kind keeps the theme's.
    try testing.expectEqual(t.ctx.theme.surface, boxOf(&t, "Plain").style.background.?);
    s.toasts.rich_colors = false;
    s.toasts.invert = true;
    t.frame();
    try testing.expectEqual(t.ctx.theme.text, boxOf(&t, "Plain").style.background.?);
}

const Custom = struct {
    fn view(_: *Custom, c: *ui.Context) void {
        ui.text(c, "Built by the app", .{});
    }
};

test "a toast's own content and icon; the one whose time ran out; ways to swipe" {
    var s: Toaster = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Toaster.view), wide);
    defer t.deinit();
    var custom: Custom = .{};
    _ = s.toasts.add(.{ .title = "Custom", .content = .init(&custom, Custom.view), .timeout = -1 });
    _ = s.toasts.add(.{ .title = "Starred", .icon = "star.fill", .timeout = 1 });
    t.settle(1);
    try testing.expect(t.hasText("Built by the app"));
    try testing.expect(!t.hasText("Custom"));
    var starred = false;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .icon => |ic| starred = starred or std.mem.eql(u8, ic.name, "star.fill"),
        else => {},
    };
    try testing.expect(starred);
    // Its time runs out: reported once, in that frame.
    var seen: u32 = 0;
    var waited: f32 = 0;
    while (waited < 1.5) : (waited += 1.0 / 60.0) {
        t.frame();
        if (s.last_timed_out != null) seen += 1;
    }
    try testing.expectEqual(@as(u32, 1), seen);
    // Only left: a swipe down does nothing, one left closes it.
    s.toasts.swipe_directions = .{ .left = true };
    const id = s.toasts.add(.{ .title = "Left only", .timeout = -1 });
    t.settle(1);
    const box = boxOf(&t, "Left only").rect;
    press(&t, box.x + 100, box.y + 20);
    slide(&t, 0, 60, 0.8);
    letGo(&t);
    t.settle(1);
    try testing.expect(s.toasts.has(id));
    press(&t, box.x + 100, box.y + 20);
    slide(&t, -60, 0, 0.8);
    letGo(&t);
    try testing.expect(!s.toasts.has(id));
}

test "done loading, the toast's new icon grows in" {
    var s: Toaster = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Toaster.view), wide);
    defer t.deinit();
    _ = s.toasts.loading("Saving", "save");
    t.settle(1);
    _ = s.toasts.add(.{ .title = "Saved", .kind = .success, .key = "save" });
    t.frame();
    const early = iconBox(&t, "checkmark.circle.fill").style.opacity;
    t.settle(1);
    try testing.expect(early < 0.5);
    try testing.expectApproxEqAbs(@as(f32, 1), iconBox(&t, "checkmark.circle.fill").style.opacity, 1e-3);
}

/// The box an icon is drawn in.
fn iconBox(t: *ui.Tester, name: []const u8) node.Node {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .icon => |ic| if (std.mem.eql(u8, ic.name, name)) return t.ctx.nodes.items[n.parent],
        else => {},
    };
    unreachable;
}
