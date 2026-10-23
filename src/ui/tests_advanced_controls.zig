const std = @import("std");
const ui = @import("ui.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const allocator = std.testing.allocator;

const Groups = struct {
    actions: usize = 0,
    flags: [3]bool = .{ true, false, false },
    multiple: bool = false,
    disabled: bool = false,
    vertical: bool = false,

    fn view(s: *Groups, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(12), .gap = 10 });
        defer ui.end(c);
        var g = ui.buttonGroup(c, .{ .label = "Actions", .disabled = s.disabled, .vertical = s.vertical });
        if (g.button("Save", .{})) s.actions += 1;
        if (g.button("Locked", .{ .disabled = true })) s.actions += 100;
        if (g.button("Share", .{})) s.actions += 10;
        g.end();
        _ = ui.toggleGroup(c, &.{ .{ .label = "Bold" }, .{ .label = "Locked style", .disabled = true }, .{ .label = "Italic" } }, &s.flags, .{ .multiple = s.multiple, .disabled = s.disabled, .vertical = s.vertical, .allow_empty = false });
        _ = ui.button(c, "After", .{});
    }
};

test "groups: roving arrows skip disabled actions and activate independently" {
    var s: Groups = .{};
    var t: ui.Tester = undefined;
    try t.init(allocator, .init(&s, Groups.view), .{});
    defer t.deinit();
    try equal(3, t.ctx.focus_order.items.len);
    try t.clickText("Save");
    t.key(.right);
    t.key(.enter);
    try equal(11, s.actions);
    t.key(.home);
    t.key(.enter);
    try equal(12, s.actions);
    s.disabled = true;
    t.frame();
    try t.clickText("Share");
    t.key(.enter);
    try equal(12, s.actions);
    try equal(1, t.ctx.focus_order.items.len);
}

test "groups: single and multiple toggle policies and vertical focus" {
    var s: Groups = .{ .vertical = true };
    var t: ui.Tester = undefined;
    try t.init(allocator, .init(&s, Groups.view), .{});
    defer t.deinit();
    try t.clickText("Italic");
    try expect(!s.flags[0] and s.flags[2]);
    try t.clickText("Italic");
    try expect(s.flags[2]);
    s.multiple = true;
    try t.clickText("Bold");
    try expect(s.flags[0] and s.flags[2]);
    t.key(.down);
    t.key(.enter);
    try expect(s.flags[0] and !s.flags[2]);
    try t.clickText("Locked style");
    try expect(!s.flags[1]);
}

const Multi = struct {
    state: ui.MultiSelectState = .{},
    chosen: [4]bool = .{ false, false, true, false },
    disabled: bool = false,

    fn view(s: *Multi, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .padding = .all(12), .gap = 8 });
        defer ui.end(c);
        // Keep the outside action beside the anchor, clear of its popup.
        ui.row(c, .{ .gap = 12 });
        defer ui.end(c);
        _ = ui.multiSelect(c, &s.state, &.{ "Apple", "Apricot", "Pear", "Banana" }, &s.chosen, .{ .label = "Fruit", .disabled = s.disabled, .disabled_items = &.{ false, true, false, false } });
        _ = ui.button(c, "Outside", .{});
    }
};

test "multi select: search preserves original indices and stays open after toggling" {
    var s: Multi = .{};
    var t: ui.Tester = undefined;
    try t.init(allocator, .init(&s, Multi.view), .{});
    defer t.deinit();
    try t.clickText("Fruit (1)");
    t.typeText("ban");
    try expect(t.hasText("Banana") and !t.hasText("Apple"));
    t.key(.enter);
    try expect(s.chosen[3] and s.chosen[2] and s.state.overlay.open);
    t.key(.enter);
    try expect(!s.chosen[3] and s.chosen[2]);
    t.key(.escape);
    try expect(!s.state.overlay.open);
    try equal(t.ctx.focus_order.items[0], t.ctx.focus);
    try t.clickText("Fruit (1)");
    try t.clickText("Apricot");
    try expect(!s.chosen[1]);
    try t.clickText("Apple");
    t.typeText("zzz");
    try expect(s.chosen[0] and t.hasText("No matching options"));
    try t.clickText("Outside");
    try expect(!s.state.overlay.open);
    s.disabled = true;
    t.frame();
    try t.clickText("Fruit (2)");
    try expect(!s.state.overlay.open);
}

test "multi select: navigation skips disabled options and empty results do not select" {
    var s: Multi = .{};
    var t: ui.Tester = undefined;
    try t.init(allocator, .init(&s, Multi.view), .{});
    defer t.deinit();
    try t.clickText("Fruit (1)");
    t.key(.down);
    t.key(.enter);
    try expect(!s.chosen[2]);
    t.typeText("unmatched");
    t.key(.down);
    t.key(.enter);
    try expect(!s.chosen[0] and !s.chosen[1] and !s.chosen[2] and !s.chosen[3]);
}

fn day(n: u8) ui.Date {
    return .{ .year = 2026, .month = 5, .day = n };
}

fn unavailable(d: ui.Date) bool {
    return d.eql(day(15));
}

const Dates = struct {
    range: ?ui.DateRange = null,
    state: ui.DateRangeState = .{},
    changes: usize = 0,

    fn view(s: *Dates, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(12), .gap = 8 });
        defer ui.end(c);
        if (ui.dateRangeInput(c, &s.range, &s.state, .{ .calendar = .{ .min = day(10), .max = day(25), .disabled = unavailable } })) s.changes += 1;
        _ = ui.button(c, "Outside", .{});
    }
};

test "date range: two endpoints commit once, reverse selection orders dates" {
    var s: Dates = .{};
    var t: ui.Tester = undefined;
    try t.init(allocator, .init(&s, Dates.view), .{});
    defer t.deinit();
    try t.clickText("Choose date range");
    try t.clickText("12");
    try expect(s.range == null and s.state.pending.?.eql(day(12)));
    try t.clickText("10");
    try expect(s.range.?.start.eql(day(10)) and s.range.?.end.eql(day(12)));
    try equal(1, s.changes);
    try expect(!s.state.overlay.open);
}

test "date range: bounds, disabled endpoints and crossing disabled dates do not commit" {
    var s: Dates = .{};
    var t: ui.Tester = undefined;
    try t.init(allocator, .init(&s, Dates.view), .{});
    defer t.deinit();
    try t.clickText("Choose date range");
    try t.clickText("9");
    try expect(s.state.pending == null);
    try t.clickText("15");
    try expect(s.state.pending == null);
    try t.clickText("12");
    try t.clickText("18");
    try expect(s.range == null and s.state.overlay.open);
    try expect(t.hasText("Range includes an unavailable date"));
    t.key(.escape);
    try expect(s.range == null and !s.state.overlay.open);
}

test "date range: keyboard chooses both endpoints without toggling trigger" {
    var s: Dates = .{};
    var t: ui.Tester = undefined;
    try t.init(allocator, .init(&s, Dates.view), .{});
    defer t.deinit();
    try t.clickText("Choose date range");
    t.key(.enter);
    t.key(.right);
    t.key(.enter);
    try expect(s.range.?.start.eql(day(10)) and s.range.?.end.eql(day(11)));
    try equal(1, s.changes);
}

const Files = struct {
    files: ui.FileList = .init(allocator),
    drag: ui.DragDrop = .{},
    disabled: bool = false,
    browse: usize = 0,
    rejected: usize = 0,

    fn view(s: *Files, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .padding = .all(12) });
        defer ui.end(c);
        const r = ui.fileDropZone(c, &s.drag, &s.files, .{ .disabled = s.disabled, .max_files = 2 });
        if (r.browse) s.browse += 1;
        s.rejected += r.rejected;
        if (r.err != null) @panic("drop failed");
    }
};

test "file drop: owns paths, deduplicates and removes without touching files" {
    var s: Files = .{};
    defer s.files.deinit();
    defer s.drag.deinit();
    var buffer = [_]u8{ '/', 'a', '.', 't', 'x', 't' };
    try expect(try s.files.add(&buffer));
    buffer[1] = 'b';
    try std.testing.expectEqualStrings("/a.txt", s.files.paths.items[0]);
    try expect(!try s.files.add("/a.txt"));
    var t: ui.Tester = undefined;
    try t.init(allocator, .init(&s, Files.view), .{});
    defer t.deinit();
    try t.clickText("Browse files");
    try equal(1, s.browse);
    s.disabled = true;
    t.frame();
    try t.clickText("Remove");
    try equal(1, s.files.paths.items.len);
    s.disabled = false;
    t.frame();
    try t.clickText("Remove");
    try equal(0, s.files.paths.items.len);
}

test "file drop: external file list enforces capacity and keeps paths after drag ends" {
    const transfer = @import("../transfer.zig");
    var s: Files = .{};
    defer s.files.deinit();
    defer s.drag.deinit();
    var t: ui.Tester = undefined;
    try t.init(allocator, .init(&s, Files.view), .{});
    defer t.deinit();
    const rect = t.findText("Drop files here").?;
    const point: ui.Point = .{ .x = rect.x + 2, .y = rect.y + 2 };
    var data = try transfer.Data.init(allocator, &.{.{ .reps = &.{transfer.bytes(transfer.file_list, "file:///a.txt\nfile:///b.txt\nfile:///c.txt")} }});
    defer data.deinit();
    _ = s.drag.externalEnter(try data.clone(allocator), .{}, point);
    t.frame();
    _ = s.drag.externalOver(point, null);
    _ = s.drag.externalDrop(point, null, null);
    t.frame();
    try equal(2, s.files.paths.items.len);
    try equal(1, s.rejected);
    t.frame();
    try equal(2, s.files.paths.items.len);
}
