//! Sidebars, toolbars and breadcrumbs through `Tester`: clicks, sections
//! that hide their items, and the keys that move among items and controls.
const std = @import("std");
const ui = @import("ui.zig");
const sidebar = @import("sidebar.zig");
const toolbar = @import("toolbar.zig");
const breadcrumbs = @import("breadcrumbs.zig");
const testing = std.testing;

const Mail = struct {
    mailbox: []const u8 = "inbox",
    mailboxes: bool = true,
    changes: u32 = 0,
    fn view(s: *Mail, c: *ui.Context) void {
        ui.row(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        var sb = sidebar.sidebar(c, &s.mailbox, .{});
        if (sb.section("Mailboxes", &s.mailboxes)) {
            sb.item("inbox", "Inbox", .{ .icon = "doc.text", .badge = "3" });
            sb.item("sent", "Sent", .{});
            sb.item("spam", "Spam", .{});
        }
        if (sb.section("Tags", null)) {
            sb.item("work", "Work", .{});
            sb.item("home", "Home", .{});
        }
        if (sb.end().changed) s.changes += 1;
        ui.column(c, .{ .grow = 1, .padding = .all(10) });
        defer ui.end(c);
        ui.text(c, c.print("Showing {s}", .{s.mailbox}), .{});
    }
};

test "sidebar: a click chooses an item, a section's title hides and shows its items" {
    var s: Mail = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Mail.view), .{});
    defer t.deinit();
    try testing.expect(t.hasText("3"));
    try t.clickText("Sent");
    try testing.expectEqualStrings("sent", s.mailbox);
    try testing.expect(t.hasText("Showing sent"));
    try testing.expectEqual(@as(u32, 1), s.changes);
    try t.clickText("Mailboxes");
    try testing.expect(!s.mailboxes);
    try testing.expect(!t.hasText("Inbox"));
    try testing.expect(t.hasText("Work"));
    try t.clickText("Mailboxes");
    try testing.expect(t.hasText("Inbox"));
    // A section without a state stays open.
    try t.clickText("Tags");
    try testing.expect(t.hasText("Work"));
}

test "sidebar: Up, Down, Home, End and typed letters choose while it has the focus" {
    var s: Mail = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Mail.view), .{});
    defer t.deinit();
    t.key(.down);
    try testing.expectEqualStrings("inbox", s.mailbox);
    try t.clickText("Inbox");
    t.key(.down);
    try testing.expectEqualStrings("sent", s.mailbox);
    t.key(.down);
    t.key(.down);
    try testing.expectEqualStrings("work", s.mailbox);
    t.key(.end);
    try testing.expectEqualStrings("home", s.mailbox);
    t.key(.down);
    try testing.expectEqualStrings("home", s.mailbox);
    t.key(.home);
    try testing.expectEqualStrings("inbox", s.mailbox);
    t.key(.up);
    try testing.expectEqualStrings("inbox", s.mailbox);
    t.typeText("s");
    try testing.expectEqualStrings("sent", s.mailbox);
    t.typeText("s");
    try testing.expectEqualStrings("spam", s.mailbox);
    t.typeText("w");
    try testing.expectEqualStrings("work", s.mailbox);
    try testing.expect(t.hasText("Showing work"));
    // Hidden items are skipped.
    s.mailboxes = false;
    t.key(.up);
    try testing.expectEqualStrings("work", s.mailbox);
    t.key(.down);
    try testing.expectEqualStrings("home", s.mailbox);
}

const Editor = struct {
    bold: bool = false,
    backs: u32 = 0,
    shares: u32 = 0,
    fn view(s: *Editor, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        var tb = toolbar.toolbar(c, .{});
        if (tb.button("Back", .{ .icon = "arrow.right" })) s.backs += 1;
        _ = tb.toggle("Bold", &s.bold);
        tb.separator();
        _ = tb.button("Disabled", .{ .disabled = true });
        tb.spacer();
        if (tb.button("Share", .{})) s.shares += 1;
        tb.end();
        ui.text(c, "Document", .{});
    }
};

test "toolbar: buttons click, toggles stay down, the spacer pushes to the end" {
    var s: Editor = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Editor.view), .{});
    defer t.deinit();
    try t.clickText("Back");
    try testing.expectEqual(@as(u32, 1), s.backs);
    try t.clickText("Bold");
    try testing.expect(s.bold);
    try t.clickText("Bold");
    try testing.expect(!s.bold);
    try t.clickText("Disabled");
    try t.clickText("Share");
    try testing.expectEqual(@as(u32, 1), s.shares);
    const share = t.findText("Share").?;
    try testing.expect(share.x + share.w > 480 - 30);
}

test "toolbar: one stop of the keyboard, Left and Right move among its controls" {
    var s: Editor = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Editor.view), .{});
    defer t.deinit();
    try t.clickText("Back");
    t.key(.right);
    t.key(.enter);
    try testing.expect(s.bold);
    t.typeText(" ");
    try testing.expect(!s.bold);
    t.key(.end);
    t.key(.enter);
    try testing.expectEqual(@as(u32, 1), s.shares);
    t.key(.home);
    t.key(.enter);
    try testing.expectEqual(@as(u32, 2), s.backs);
    // The disabled button takes the keys' place, but no press.
    t.key(.right);
    t.key(.right);
    t.key(.enter);
    try testing.expect(!s.bold);
    try testing.expectEqual(@as(u32, 1), s.shares);
    // Without the focus the keys go elsewhere.
    try t.clickText("Document");
    t.key(.enter);
    try testing.expectEqual(@as(u32, 2), s.backs);
}

const Path = struct {
    chosen: usize = 99,
    picks: u32 = 0,
    fn view(s: *Path, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(10) });
        defer ui.end(c);
        if (breadcrumbs.breadcrumbs(c, &.{ "Macintosh HD", "Users", "ada", "Documents" }, &s.chosen, .{})) s.picks += 1;
    }
};

test "breadcrumbs: the items but the last are links; Enter chooses the focused one" {
    var s: Path = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Path.view), .{});
    defer t.deinit();
    try t.clickText("Users");
    try testing.expectEqual(@as(usize, 1), s.chosen);
    try t.clickText("Documents");
    try testing.expectEqual(@as(usize, 1), s.chosen);
    try testing.expectEqual(@as(u32, 1), s.picks);
    try t.clickText("Macintosh HD");
    try testing.expectEqual(@as(usize, 0), s.chosen);
    s.chosen = 99;
    t.key(.enter);
    try testing.expectEqual(@as(usize, 0), s.chosen);
    try testing.expectEqual(@as(u32, 3), s.picks);
    // The items follow each other, chevrons between them.
    try testing.expect(t.findText("Users").?.x > t.findText("Macintosh HD").?.x + 20);
}
