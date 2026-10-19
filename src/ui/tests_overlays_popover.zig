//! Popovers, tooltips, dialogs and alert dialogs through the Tester.
const std = @import("std");
const ui = @import("ui.zig");
const base = @import("overlay_base.zig");
const popover = @import("popover.zig");
const dialog = @import("dialog.zig");
const testing = std.testing;
const S = ui.Shortcut;

const Pop = struct {
    menu: base.OverlayState = .{},
    renamed: u32 = 0,
    other: u32 = 0,
    anchor_y: f32 = 20,
    field: ui.TextBuffer = .{},
    saw_dismissed: bool = false,

    fn view(s: *Pop, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .{ .left = 20, .top = s.anchor_y }, .gap = 12 });
        defer ui.end(c);
        ui.row(c, .{ .gap = 8 });
        const more = ui.button(c, "More", .{});
        if (more.clicked) s.menu.toggle();
        if (ui.button(c, "Other", .{}).clicked) s.other += 1;
        ui.end(c);
        if (popover.popover(c, &s.menu, more, .{})) |p| {
            defer p.end();
            if (ui.button(c, "Rename", .{}).clicked) {
                s.renamed += 1;
                s.menu.close();
            }
            _ = ui.textField(c, &s.field, .{ .placeholder = "Inside" });
        }
        if (s.menu.dismissed) s.saw_dismissed = true;
        ui.spacer(c);
    }
};

fn tester(t: *ui.Tester, state: anytype, opts: ui.TesterOptions) !void {
    const T = @TypeOf(state.*);
    try t.init(testing.allocator, .init(state, T.view), opts);
}

test "a popover opens below its anchor, and a choice in it closes it" {
    var s: Pop = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, .{});
    defer t.deinit();
    try testing.expect(!t.hasText("Rename"));
    try t.clickText("More");
    try testing.expect(s.menu.open);
    const more = t.findText("More").?;
    const rename = t.findText("Rename").?;
    try testing.expect(rename.y > more.y + more.h);
    try t.clickText("Rename");
    try testing.expectEqual(@as(u32, 1), s.renamed);
    try testing.expect(!s.menu.open);
    t.frame();
    try testing.expect(!t.hasText("Rename"));
}

test "a press outside a popover closes it and goes on to what is under it" {
    var s: Pop = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, .{});
    defer t.deinit();
    try t.clickText("More");
    // A press on the window, away from the panel.
    t.click(400, 300);
    try testing.expect(!s.menu.open);
    try testing.expect(s.saw_dismissed);
    // Open again, then click a button outside it: both happen.
    try t.clickText("More");
    try t.clickText("Other");
    try testing.expectEqual(@as(u32, 1), s.other);
    try testing.expect(!s.menu.open);
}

test "the anchor toggles its popover closed, and Escape closes it" {
    var s: Pop = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, .{});
    defer t.deinit();
    try t.clickText("More");
    try testing.expect(s.menu.open);
    try t.clickText("More");
    try testing.expect(!s.menu.open);
    try t.clickText("More");
    try testing.expect(t.shortcut(.{ .key = S.escape }));
    try testing.expect(!s.menu.open);
    try t.clickText("More");
    t.key(.escape);
    try testing.expect(!s.menu.open);
}

test "a popover with no room below its anchor shows above it, inside the window" {
    var s: Pop = .{ .anchor_y = 320 };
    var t: ui.Tester = undefined;
    try tester(&t, &s, .{ .width = 300, .height = 360 });
    defer t.deinit();
    try t.clickText("More");
    const more = t.findText("More").?;
    const rename = t.findText("Rename").?;
    try testing.expect(rename.y < more.y);
    try testing.expect(rename.y > 0);
}

test "Escape in a popover's field goes to the field's popover, and the focus comes back" {
    var s: Pop = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, .{});
    defer t.deinit();
    try t.clickText("More");
    try t.clickText("Inside");
    t.typeText("x");
    try testing.expectEqualStrings("x", s.field.text());
    try testing.expect(t.shortcut(.{ .key = S.escape }));
    try testing.expect(!s.menu.open);
    // Back to the button that opened it (buttons take the focus).
    try testing.expect(t.ctx.focus != 0);
    try testing.expect(std.mem.indexOfScalar(u64, t.ctx.focus_order.items, t.ctx.focus) != null);
}

const Tips = struct {
    fn view(_: *Tips, c: *ui.Context) void {
        ui.row(c, .{ .width = .fill, .padding = .{ .left = 4, .top = 100 }, .gap = 8 });
        defer ui.end(c);
        const a = ui.button(c, "Share", .{});
        popover.tooltip(c, a, "Share with others");
        const b = ui.button(c, "Print", .{});
        popover.tooltip(c, b, "Print it");
    }
};

test "a tooltip shows once the pointer rests, above the element, and goes as it leaves" {
    var s: Tips = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, .{});
    defer t.deinit();
    const share = t.findText("Share").?;
    t.moveTo(share.x + 2, share.y + 2);
    try testing.expect(!t.hasText("Share with others"));
    // It asked to be woken when its time comes.
    try testing.expect(t.ctx.frame_in != null);
    t.advance(0.3);
    try testing.expect(!t.hasText("Share with others"));
    t.advance(0.4);
    const tip = t.findText("Share with others") orelse return error.NoTip;
    try testing.expect(tip.y + tip.h < share.y);
    // Kept inside the window although the button is at its left edge.
    try testing.expect(tip.x >= base.window_margin);
    // Onto the next button: its tip shows at once.
    const print = t.findText("Print").?;
    t.moveTo(print.x + 2, print.y + 2);
    try testing.expect(!t.hasText("Share with others"));
    try testing.expect(t.hasText("Print it"));
    // Away, then long after, back: the delay again.
    t.moveTo(400, 300);
    try testing.expect(!t.hasText("Print it"));
    t.advance(1);
    t.moveTo(print.x + 2, print.y + 2);
    try testing.expect(!t.hasText("Print it"));
}

test "a press on the element hides its tip until the pointer comes back" {
    var s: Tips = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, .{});
    defer t.deinit();
    const share = t.findText("Share").?;
    t.moveTo(share.x + 2, share.y + 2);
    t.advance(0.7);
    try testing.expect(t.hasText("Share with others"));
    t.click(share.x + 2, share.y + 2);
    try testing.expect(!t.hasText("Share with others"));
    t.advance(1);
    try testing.expect(!t.hasText("Share with others"));
    t.moveTo(400, 300);
    t.advance(1);
    t.moveTo(share.x + 2, share.y + 2);
    t.advance(0.7);
    try testing.expect(t.hasText("Share with others"));
    // Escape hides it too.
    try testing.expect(t.shortcut(.{ .key = S.escape }));
    try testing.expect(!t.hasText("Share with others"));
}

test "a tooltip below an element at the top of the window" {
    const Top = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            ui.row(c, .{ .width = .fill, .justify = .end });
            defer ui.end(c);
            const a = ui.button(c, "Edge", .{});
            popover.tooltip(c, a, "A tip at the window's top right corner");
        }
    };
    var s: Top = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, .{});
    defer t.deinit();
    const edge = t.findText("Edge").?;
    t.moveTo(edge.x + 2, edge.y + 2);
    t.advance(0.7);
    const tip = t.findText("A tip at the window's top right corner").?;
    try testing.expect(tip.y > edge.y + edge.h);
    try testing.expect(tip.x + tip.w <= 480 - base.window_margin);
}

const Dlg = struct {
    rename: base.OverlayState = .{},
    alert: base.OverlayState = .{},
    behind: u32 = 0,
    saved: u32 = 0,
    answer: ?dialog.AlertResult = null,
    name: ui.TextBuffer = .{},
    keep_open: bool = false,
    saw_dismissed: bool = false,

    fn view(s: *Dlg, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        if (ui.button(c, "Behind", .{}).clicked) s.behind += 1;
        _ = ui.textField(c, &s.name, .{ .placeholder = "Name" });
        if (dialog.dialog(c, &s.rename, .{})) |d| {
            defer d.end();
            ui.text(c, "Rename", .{ .weight = .bold });
            if (ui.button(c, "Save", .{ .variant = .primary }).clicked) {
                s.saved += 1;
                s.rename.close();
            }
        }
        if (s.rename.dismissed) s.saw_dismissed = true;
        if (s.rename.dismissed and s.keep_open) s.rename.open = true;
        switch (dialog.alertDialog(c, &s.alert, "Delete “Notes”?", "You can't undo this.", &.{ "Cancel", "Delete" })) {
            .none => {},
            else => |r| s.answer = r,
        }
    }
};

test "a dialog blocks the view under it; its backdrop and Escape close it" {
    var s: Dlg = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, .{});
    defer t.deinit();
    s.rename.show();
    t.frame();
    t.settle(1);
    try testing.expect(t.hasText("Rename"));
    // Centered in the window.
    const title = t.findText("Rename").?;
    try testing.expect(title.y > 100 and title.y < 200);
    // A click on "Behind" lands on the backdrop: it closes the dialog only.
    try t.clickText("Behind");
    try testing.expectEqual(@as(u32, 0), s.behind);
    try testing.expect(!s.rename.open);
    try testing.expect(s.saw_dismissed);
    t.frame();
    try testing.expect(!t.hasText("Rename"));
    try t.clickText("Behind");
    try testing.expectEqual(@as(u32, 1), s.behind);
    // Escape.
    s.rename.show();
    t.frame();
    t.key(.escape);
    try testing.expect(!s.rename.open);
    // A click in the panel is the panel's.
    s.rename.show();
    t.frame();
    try t.clickText("Rename");
    try testing.expect(s.rename.open);
    try t.clickText("Save");
    try testing.expectEqual(@as(u32, 1), s.saved);
    try testing.expect(!s.rename.open);
}

test "a dialog takes the focus from behind it and gives it back" {
    var s: Dlg = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, .{});
    defer t.deinit();
    try t.clickText("Name");
    const field = t.ctx.focus;
    try testing.expect(field != 0);
    s.rename.show();
    t.frame();
    try testing.expectEqual(@as(u64, 0), t.ctx.focus);
    // Typing goes nowhere behind it.
    t.typeText("x");
    try testing.expectEqual(@as(usize, 0), s.name.len);
    try testing.expect(t.shortcut(.{ .key = S.escape }));
    t.frame();
    try testing.expectEqual(field, t.ctx.focus);
}

test "a dialog that must stay open sets itself open as it is dismissed" {
    var s: Dlg = .{ .keep_open = true };
    var t: ui.Tester = undefined;
    try tester(&t, &s, .{});
    defer t.deinit();
    s.rename.show();
    t.frame();
    t.key(.escape);
    t.frame();
    try testing.expect(s.rename.open);
    try testing.expect(t.hasText("Rename"));
}

test "an alert returns the button clicked; Enter clicks the last; Escape dismisses" {
    var s: Dlg = .{};
    var t: ui.Tester = undefined;
    try tester(&t, &s, .{});
    defer t.deinit();
    s.alert.show();
    t.frame();
    try testing.expect(t.hasText("You can't undo this."));
    // A press outside does nothing.
    t.click(5, 5);
    try testing.expect(s.alert.open);
    try testing.expect(s.answer == null);
    try t.clickText("Cancel");
    try testing.expectEqual(dialog.AlertResult{ .chosen = 0 }, s.answer.?);
    try testing.expect(!s.alert.open);
    t.frame();
    try testing.expect(!t.hasText("You can't undo this."));

    s.answer = null;
    s.alert.show();
    t.frame();
    t.key(.enter);
    try testing.expectEqual(dialog.AlertResult{ .chosen = 1 }, s.answer.?);
    try testing.expect(!s.alert.open);

    s.answer = null;
    s.alert.show();
    t.frame();
    try testing.expect(t.shortcut(.{ .key = S.escape }));
    try testing.expectEqual(dialog.AlertResult.dismissed, s.answer.?);
    try testing.expect(!s.alert.open);
    try testing.expect(s.answer.? != .chosen);
}
