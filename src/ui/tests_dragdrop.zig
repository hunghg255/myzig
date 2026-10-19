//! Drag and drop within a window, through the Tester's pointer.
const std = @import("std");
const ui = @import("ui.zig");
const transfer = @import("../transfer.zig");
const DragDrop = @import("dragdrop.zig").DragDrop;
const Finished = @import("dragdrop.zig").Finished;

const gpa = std.testing.allocator;

const Fruit = struct { name: []const u8, basket: bool = false };

const State = struct {
    dnd: DragDrop = .{},
    fruits: [2]Fruit = .{ .{ .name = "Apple" }, .{ .name = "Pear" } },
    clicks: usize = 0,
    dropped_text: std.ArrayList(u8) = .empty,
    effect: transfer.Effect = .none,
    finished: ?Finished = null,
    over_basket: bool = false,
    bin_drops: usize = 0,
    starts: usize = 0,

    fn deinit(s: *State) void {
        s.dnd.deinit();
        s.dropped_text.deinit(gpa);
    }

    fn view(s: *State, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(10), .gap = 10 });
        ui.row(c, .{ .gap = 10 });
        for (&s.fruits) |*f| {
            ui.key(c, f.name);
            var d = s.dnd.draggable(c, .{ .width = .{ .px = 100 }, .height = .{ .px = 40 }, .background = c.theme.surface }, .{ .effects = .copy_move });
            if (d.starting) {
                s.starts += 1;
                d.offer(transfer.Data.init(gpa, &.{.{ .reps = &.{
                    transfer.bytes(transfer.text, f.name),
                    transfer.bytes(transfer.value_format(Fruit), std.mem.asBytes(&@intFromPtr(f))),
                } }}) catch unreachable);
            }
            // A button inside: a press that doesn't move clicks it.
            if (ui.button(c, f.name, .{}).clicked) s.clicks += 1;
            const r = d.end();
            if (r.finished) |fin| s.finished = fin;
        }
        ui.end(c);
        const basket = c.open(.{ .width = .{ .px = 200 }, .height = .{ .px = 100 }, .border = c.theme.border }, "basket");
        const t = s.dnd.target(c, basket, .{ .formats = &.{transfer.text}, .effects = .copy_move });
        s.over_basket = t.over;
        if (t.over) c.node(basket).style.border = c.theme.accent;
        if (t.dropped) |drop| {
            s.dropped_text.clearRetainingCapacity();
            s.dropped_text.appendSlice(gpa, drop.data.read(c.alloc(), transfer.text) catch "") catch {};
            s.effect = drop.effect;
            if (drop.data.value(Fruit)) |fruit| fruit.basket = true;
        }
        ui.text(c, "Basket", .{});
        c.end();
        const bin = c.open(.{ .width = .{ .px = 200 }, .height = .{ .px = 60 } }, "bin");
        // Takes images only: text never drops here.
        if (s.dnd.target(c, bin, .{ .formats = &.{transfer.png} }).dropped != null) s.bin_drops += 1;
        ui.text(c, "Bin", .{});
        c.end();
        ui.end(c);
        s.dnd.preview(c);
    }
};

fn center(r: ui.Rect) [2]f32 {
    return .{ r.x + r.w / 2, r.y + r.h / 2 };
}

test "drag and drop: a box dragged onto a target drops its data there" {
    var s: State = .{};
    defer s.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, State.view), .{ .width = 480, .height = 360 });
    defer t.deinit();
    const apple = center(t.findText("Apple").?);
    const basket = center(t.findText("Basket").?);

    // Pressed and moved a little: still a press.
    t.moveTo(apple[0], apple[1]);
    t.ctx.pointerDown();
    t.frame();
    t.moveTo(apple[0] + 2, apple[1]);
    try std.testing.expect(!s.dnd.dragging());
    // Past the threshold: it drags, and a copy follows the pointer.
    t.moveTo(apple[0] + 20, apple[1] + 20);
    try std.testing.expect(s.dnd.dragging());
    try std.testing.expectEqual(@as(usize, 1), s.starts);
    var copies: usize = 0;
    for (t.ctx.nodes.items) |n| if (n.content == .text and std.mem.eql(u8, n.content.text.str, "Apple")) {
        copies += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), copies);
    // Over the basket: it would take it.
    t.moveTo(basket[0], basket[1]);
    t.frame();
    try std.testing.expect(s.over_basket);
    // Let go: dropped, copied (no key held), and the source hears it.
    t.ctx.pointerUp();
    t.frame();
    try std.testing.expect(!s.dnd.dragging());
    try std.testing.expectEqualStrings("Apple", s.dropped_text.items);
    try std.testing.expectEqual(transfer.Effect.copy, s.effect);
    try std.testing.expect(s.fruits[0].basket);
    try std.testing.expect(!s.fruits[1].basket);
    try std.testing.expectEqual(transfer.Effect.copy, s.finished.?.effect);
    try std.testing.expect(!s.finished.?.canceled);
    // The press that dragged was no click of the button inside.
    try std.testing.expectEqual(@as(usize, 0), s.clicks);
    // A press that doesn't move clicks it.
    try t.clickText("Pear");
    try std.testing.expectEqual(@as(usize, 1), s.clicks);
    try std.testing.expect(!s.dnd.dragging());
}

test "drag and drop: Shift moves, a target of other formats takes nothing, Escape gives up" {
    var s: State = .{};
    defer s.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, State.view), .{ .width = 480, .height = 360 });
    defer t.deinit();
    const pear = center(t.findText("Pear").?);
    const basket = center(t.findText("Basket").?);
    const bin = center(t.findText("Bin").?);

    // Shift asks for a move, which both ends allow.
    t.ctx.input.shift = true;
    t.drag(pear[0], pear[1], basket[0], basket[1]);
    t.ctx.input.shift = false;
    try std.testing.expectEqualStrings("Pear", s.dropped_text.items);
    try std.testing.expectEqual(transfer.Effect.move, s.effect);
    try std.testing.expectEqual(transfer.Effect.move, s.finished.?.effect);

    // The bin takes images: text dropped there is given up.
    s.finished = null;
    t.drag(pear[0], pear[1], bin[0], bin[1]);
    try std.testing.expectEqual(@as(usize, 0), s.bin_drops);
    try std.testing.expect(s.finished.?.canceled);
    // Let go over no target: canceled, not given up; in the window.
    try std.testing.expect(!s.finished.?.escaped);
    try std.testing.expect(s.finished.?.screen == null);

    // Escape gives up while it drags.
    s.finished = null;
    t.moveTo(pear[0], pear[1]);
    t.ctx.pointerDown();
    t.frame();
    t.moveTo(basket[0], basket[1]);
    t.moveTo(basket[0] + 1, basket[1]);
    try std.testing.expect(s.dnd.dragging());
    t.key(.escape);
    try std.testing.expect(!s.dnd.dragging());
    try std.testing.expect(s.finished.?.canceled and s.finished.?.escaped);
    t.ctx.pointerUp();
    t.frame();
    try std.testing.expectEqual(transfer.Effect.move, s.effect); // nothing new dropped
}

test "drag and drop: a drag leaving the window goes on in the system's" {
    var s: State = .{};
    defer s.deinit();
    const Sys = struct {
        var started: usize = 0;
        var formats: usize = 0;
        fn start(_: ?*anyopaque, dd: *DragDrop) void {
            started += 1;
            formats = dd.active.?.data.items[0].len;
        }
    };
    s.dnd.external = .{ .start = Sys.start };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, State.view), .{ .width = 480, .height = 360 });
    defer t.deinit();
    const apple = center(t.findText("Apple").?);
    t.moveTo(apple[0], apple[1]);
    t.ctx.pointerDown();
    t.frame();
    t.moveTo(apple[0] + 30, apple[1]);
    try std.testing.expect(s.dnd.dragging());
    // Out of the window: handed to the system's drag, once.
    t.moveTo(-20, apple[1]);
    t.moveTo(-30, apple[1]);
    try std.testing.expectEqual(@as(usize, 1), Sys.started);
    try std.testing.expectEqual(@as(usize, 2), Sys.formats);
    // Another app took it, moved: the source hears it in the next frame.
    s.dnd.externalDone(.move);
    t.frame();
    try std.testing.expect(!s.dnd.dragging());
    try std.testing.expectEqual(transfer.Effect.move, s.finished.?.effect);
    try std.testing.expect(!t.ctx.input.down);
    try std.testing.expectEqual(@as(usize, 0), s.clicks);
    try std.testing.expect(!s.finished.?.canceled and !s.finished.?.escaped);

    // Again, let go over no target outside every window: canceled, not
    // given up, and where it ended; then given up with Escape.
    for ([_]bool{ false, true }) |escaped| {
        t.moveTo(apple[0], apple[1]);
        t.ctx.pointerDown();
        t.frame();
        t.moveTo(apple[0] + 30, apple[1]);
        t.moveTo(-20, apple[1]);
        t.moveTo(-30, apple[1]);
        s.dnd.externalEnd(.{ .effect = .none, .escaped = escaped, .screen = .{ .x = -40, .y = 900 } });
        t.frame();
        const f = s.finished.?;
        try std.testing.expect(f.canceled and f.escaped == escaped);
        try std.testing.expectEqual(@as(f32, -40), f.screen.?.x);
        try std.testing.expectEqual(@as(f32, 900), f.screen.?.y);
    }
}

test "drag and drop: drags from other apps drop on targets taking their formats" {
    var s: State = .{};
    defer s.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, State.view), .{ .width = 480, .height = 360 });
    defer t.deinit();
    const basket = center(t.findText("Basket").?);
    const bin = center(t.findText("Bin").?);
    // Text from another app: the basket takes it, the bin doesn't.
    s.dnd.externalEnter(try transfer.textData(gpa, "Plum"), .copy_move, .{ .x = bin[0], .y = bin[1] });
    t.frame();
    try std.testing.expectEqual(transfer.Effect.none, s.dnd.externalOver(.{ .x = bin[0], .y = bin[1] }, null));
    try std.testing.expectEqual(transfer.Effect.copy, s.dnd.externalOver(.{ .x = basket[0], .y = basket[1] }, null));
    try std.testing.expectEqual(transfer.Effect.move, s.dnd.externalOver(.{ .x = basket[0], .y = basket[1] }, .move));
    t.frame();
    try std.testing.expect(s.over_basket);
    // The bytes read at the drop replace what entered.
    try std.testing.expectEqual(transfer.Effect.copy, s.dnd.externalDrop(.{ .x = basket[0], .y = basket[1] }, try transfer.textData(gpa, "Plums"), null));
    t.frame();
    try std.testing.expectEqualStrings("Plums", s.dropped_text.items);
    try std.testing.expectEqual(transfer.Effect.copy, s.effect);
    try std.testing.expect(!s.dnd.dragging());
    try std.testing.expect(s.finished == null); // no source here to tell
    // One that leaves drops nothing; one let go over nothing neither.
    s.dnd.externalEnter(try transfer.textData(gpa, "Fig"), .{}, .{ .x = basket[0], .y = basket[1] });
    t.frame();
    s.dnd.externalLeave();
    t.frame();
    try std.testing.expect(!s.dnd.dragging());
    s.dnd.externalEnter(try transfer.textData(gpa, "Fig"), .{}, .{ .x = bin[0], .y = bin[1] });
    t.frame();
    try std.testing.expectEqual(transfer.Effect.none, s.dnd.externalDrop(.{ .x = bin[0], .y = bin[1] }, null, null));
    t.frame();
    try std.testing.expectEqualStrings("Plums", s.dropped_text.items);
    try std.testing.expect(!s.dnd.dragging());
}
