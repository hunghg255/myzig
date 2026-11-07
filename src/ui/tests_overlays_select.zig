//! Selects, comboboxes and autocompletes through the Tester (toasts:
//! `tests_toasts.zig`).
const std = @import("std");
const ui = @import("ui.zig");
const base = @import("overlay_base.zig");
const select = @import("select.zig");
const combobox = @import("combobox.zig");
const testing = std.testing;
const S = ui.Shortcut;

const plans = [_][]const u8{ "Free", "Pro", "Team" };
const fonts = [_][]const u8{ "Helvetica", "Menlo", "Arial", "Comic Sans", "Courier" };
const cities = [_][]const u8{ "Helsinki", "Lisbon", "Berlin", "Paris", "Geneva" };

const Form = struct {
    plan: usize = 0,
    plan_box: select.SelectState = .{},
    changes: u32 = 0,
    font: ?usize = 1,
    font_box: combobox.ComboboxState = .{},
    city: ui.TextBuffer = .{},
    city_box: combobox.AutocompleteState = .{},
    submitted: u32 = 0,
    under: u32 = 0,
    top: f32 = 20,

    fn view(s: *Form, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .{ .left = 20, .top = s.top }, .gap = 12 });
        defer ui.end(c);
        if (select.select(c, &s.plan, &plans, &s.plan_box, .{}).changed) s.changes += 1;
        _ = combobox.combobox(c, &s.font, &fonts, &s.font_box, .{ .placeholder = "Font" });
        if (combobox.autocomplete(c, &s.city, &cities, &s.city_box, .{ .placeholder = "City" }).submitted) s.submitted += 1;
        if (ui.button(c, "Under", .{}).clicked) s.under += 1;
    }
};

test "a select opens below on a click; a click on an option chooses it" {
    var s: Form = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Form.view), .{});
    defer t.deinit();
    try testing.expect(!t.hasText("Team"));
    try t.clickText("Free");
    try testing.expect(s.plan_box.isOpen());
    const team = t.findText("Team").?;
    try testing.expect(team.y > 40);
    try t.clickText("Team");
    try testing.expectEqual(@as(usize, 2), s.plan);
    try testing.expectEqual(@as(u32, 1), s.changes);
    try testing.expect(!s.plan_box.isOpen());
    t.frame();
    try testing.expect(t.hasText("Team") and !t.hasText("Pro"));
    // The focus is back on the select.
    try testing.expect(t.ctx.focus != 0);
}

test "a select's keyboard: Down opens, arrows move, Enter chooses, Escape closes" {
    var s: Form = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Form.view), .{});
    defer t.deinit();
    // A click gives it the focus (and opens it); Escape closes it.
    try t.clickText("Free");
    const sel = t.ctx.focus;
    try testing.expect(t.shortcut(.{ .key = S.escape }));
    try testing.expect(!s.plan_box.isOpen());
    t.frame();
    try testing.expectEqual(sel, t.ctx.focus);
    try testing.expect(t.shortcut(.{ .key = S.down }));
    try testing.expect(s.plan_box.isOpen());
    try testing.expectEqual(@as(i32, 0), s.plan_box.list.highlight);
    try testing.expect(t.shortcut(.{ .key = S.down }));
    try testing.expect(t.shortcut(.{ .key = S.down }));
    try testing.expect(t.shortcut(.{ .key = S.down }));
    // Wrapped round to the first.
    try testing.expectEqual(@as(i32, 0), s.plan_box.list.highlight);
    t.key(.end);
    try testing.expectEqual(@as(i32, 2), s.plan_box.list.highlight);
    t.key(.home);
    try testing.expect(t.shortcut(.{ .key = S.down }));
    t.key(.enter);
    try testing.expectEqual(@as(usize, 1), s.plan);
    try testing.expect(!s.plan_box.isOpen());
    // Space opens and chooses too.
    t.typeText(" ");
    try testing.expect(s.plan_box.isOpen());
    try testing.expectEqual(@as(i32, 1), s.plan_box.list.highlight);
    try testing.expect(t.shortcut(.{ .key = S.up }));
    t.typeText(" ");
    try testing.expectEqual(@as(usize, 0), s.plan);
}

test "a select's popup takes the press outside it, which only closes it" {
    var s: Form = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Form.view), .{});
    defer t.deinit();
    try t.clickText("Free");
    t.click(400, 340);
    try testing.expect(!s.plan_box.isOpen());
    try t.clickText("Free");
    try t.clickText("Under");
    try testing.expectEqual(@as(u32, 0), s.under);
    try testing.expect(!s.plan_box.isOpen());
    // A second click on the select closes it.
    try t.clickText("Free");
    try t.clickText("Free");
    try testing.expect(!s.plan_box.isOpen());
}

test "a select at the bottom of the window opens above it" {
    var s: Form = .{ .top = 300 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Form.view), .{ .height = 400 });
    defer t.deinit();
    try t.clickText("Free");
    const pro = t.findText("Pro").?;
    try testing.expect(pro.y < 300);
    try testing.expect(pro.y > 0);
}

test "a combobox filters as one types, Down shows them all, Enter chooses" {
    var s: Form = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Form.view), .{});
    defer t.deinit();
    try testing.expectEqualStrings("Menlo", s.font_box.buffer.text());
    // A click shows every option, the text selected for typing to replace.
    try t.clickText("Menlo");
    try testing.expect(s.font_box.isOpen());
    try testing.expect(t.hasText("Helvetica") and t.hasText("Courier"));
    t.typeText("co");
    try testing.expectEqualStrings("co", s.font_box.buffer.text());
    // Starting with it first, then containing it.
    try testing.expect(t.hasText("Courier") and t.hasText("Comic Sans"));
    try testing.expect(!t.hasText("Arial") and !t.hasText("Helvetica"));
    const courier = t.findText("Courier").?;
    const comic = t.findText("Comic Sans").?;
    try testing.expect(comic.y < courier.y);
    try testing.expectEqual(@as(i32, 0), s.font_box.list.highlight);
    try testing.expect(t.shortcut(.{ .key = S.down }));
    t.key(.enter);
    try testing.expectEqual(@as(?usize, 4), s.font);
    try testing.expectEqualStrings("Courier", s.font_box.buffer.text());
    try testing.expect(!s.font_box.isOpen());
    // The field kept the focus.
    try testing.expect(t.ctx.focus != 0);
    try testing.expect(t.ctx.focused_text != null);
    // Down shows them all again.
    try testing.expect(t.shortcut(.{ .key = S.down }));
    try testing.expect(t.hasText("Helvetica"));
    try testing.expectEqual(@as(i32, 4), s.font_box.list.highlight);
    // Escape closes the list, keeping the focus.
    try testing.expect(t.shortcut(.{ .key = S.escape }));
    try testing.expect(!s.font_box.isOpen());
    try testing.expect(t.ctx.focused_text != null);
}

test "a click on a combobox's option chooses it; leaving puts the choice back" {
    var s: Form = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Form.view), .{});
    defer t.deinit();
    try t.clickText("Menlo");
    try t.clickText("Arial");
    try testing.expectEqual(@as(?usize, 2), s.font);
    try testing.expectEqualStrings("Arial", s.font_box.buffer.text());
    try testing.expect(t.ctx.focused_text != null);
    t.typeText("zz");
    try testing.expect(t.hasText("No results"));
    // Away: the text goes back to the choice.
    t.click(400, 340);
    try testing.expect(!s.font_box.isOpen());
    t.frame();
    try testing.expectEqualStrings("Arial", s.font_box.buffer.text());
    try testing.expectEqual(@as(?usize, 2), s.font);
}

test "an autocomplete suggests what contains the text, and keeps what was typed" {
    var s: Form = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Form.view), .{});
    defer t.deinit();
    try t.clickText("City");
    try testing.expect(!s.city_box.isOpen());
    t.typeText("e");
    try testing.expect(s.city_box.isOpen());
    try testing.expect(t.hasText("Helsinki") and t.hasText("Berlin") and t.hasText("Geneva"));
    try testing.expect(!t.hasText("Lisbon") and !t.hasText("Paris"));
    // Enter on no suggestion submits what was typed.
    t.key(.enter);
    try testing.expectEqual(@as(u32, 1), s.submitted);
    try testing.expectEqualStrings("e", s.city.text());
    try testing.expect(t.shortcut(.{ .key = S.down }));
    try testing.expect(t.shortcut(.{ .key = S.down }));
    t.key(.enter);
    try testing.expectEqualStrings("Berlin", s.city.text());
    try testing.expectEqual(@as(u32, 1), s.submitted);
    try testing.expect(!s.city_box.isOpen());
    // Typing on: no suggestion is the text itself.
    t.key(.backspace);
    try testing.expect(s.city_box.isOpen());
    try t.clickText("Berlin");
    try testing.expectEqualStrings("Berlin", s.city.text());
    try testing.expect(t.ctx.focused_text != null);
    // Escape closes the list; the field keeps the focus.
    t.key(.backspace);
    try testing.expect(s.city_box.isOpen());
    t.key(.escape);
    try testing.expect(!s.city_box.isOpen());
    try testing.expect(t.ctx.focused_text != null);
}
