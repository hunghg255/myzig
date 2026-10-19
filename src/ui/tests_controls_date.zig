//! Dates, calendars, date inputs and time inputs through `Tester`.
const std = @import("std");
const ui = @import("ui.zig");
const date = @import("controls_date.zig");
const time = @import("controls_time.zig");
const testing = std.testing;
const Date = date.Date;

test "civil dates: days, weekdays, months and leap years" {
    try testing.expectEqual(@as(i32, 0), (Date{ .year = 1970, .month = 1, .day = 1 }).toDays());
    try testing.expectEqual(@as(u8, 4), (Date{ .year = 1970, .month = 1, .day = 1 }).weekday()); // a Thursday
    try testing.expectEqual(@as(u8, 1), (Date{ .year = 2026, .month = 1, .day = 5 }).weekday()); // a Monday
    try testing.expectEqual(@as(u8, 1), (Date{ .year = 2026, .month = 10, .day = 19 }).weekday());
    // Round trips, before the epoch too.
    var d: i32 = -800000;
    while (d < 800000) : (d += 997) try testing.expectEqual(d, Date.fromDays(d).toDays());
    try testing.expect(Date.fromDays(-1).eql(.{ .year = 1969, .month = 12, .day = 31 }));
    try testing.expect((Date{ .year = 2024, .month = 2, .day = 28 }).addDays(1).eql(.{ .year = 2024, .month = 2, .day = 29 }));
    try testing.expect((Date{ .year = 2023, .month = 2, .day = 28 }).addDays(1).eql(.{ .year = 2023, .month = 3, .day = 1 }));
    try testing.expect((Date{ .year = 2026, .month = 1, .day = 31 }).addMonths(1).eql(.{ .year = 2026, .month = 2, .day = 28 }));
    try testing.expect((Date{ .year = 2026, .month = 1, .day = 15 }).addMonths(-1).eql(.{ .year = 2025, .month = 12, .day = 15 }));
    try testing.expect((Date{ .year = 2026, .month = 12, .day = 15 }).addMonths(13).eql(.{ .year = 2028, .month = 1, .day = 15 }));
    try testing.expect(date.isLeap(2000) and !date.isLeap(1900) and date.isLeap(2024));
    try testing.expect(!(Date{ .year = 2026, .month = 2, .day = 29 }).valid());
}

const Due = struct {
    day: Date = .{ .year = 2026, .month = 1, .day = 14 },
    monday_first: bool = false,
    changes: u32 = 0,
    fn view(s: *Due, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        if (date.calendar(c, &s.day, .{ .first_weekday = if (s.monday_first) 1 else 0, .today = .{ .year = 2026, .month = 1, .day = 20 } })) s.changes += 1;
        ui.text(c, "Elsewhere", .{});
    }
};

fn cellOf(t: *ui.Tester, label: []const u8) ?ui.Rect {
    // The last match: the month's own day, after the days of the month before.
    var found: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, label)) {
            found = n.rect;
        },
        else => {},
    };
    return found;
}

test "a calendar shows six weeks of its month, and a click chooses a day" {
    var s: Due = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Due.view), .{ .height = 420 });
    defer t.deinit();
    try testing.expect(t.hasText("January 2026"));
    // January 2026 starts on a Thursday: the grid starts on Sunday, Dec 28.
    const first = t.findText("28").?;
    const su = t.findText("Su").?;
    try testing.expectApproxEqAbs(su.x + su.w / 2, first.x + first.w / 2, 1);
    try t.clickText("22");
    try testing.expect(s.day.eql(.{ .year = 2026, .month = 1, .day = 22 }));
    // A day of the next month, in gray, chooses it and shows its month.
    const r = cellOf(&t, "7").?;
    t.click(r.x + r.w / 2, r.y + r.h / 2);
    try testing.expect(s.day.eql(.{ .year = 2026, .month = 2, .day = 7 }));
    try testing.expect(t.hasText("February 2026"));
    try testing.expectEqual(@as(u32, 2), s.changes);
}

test "a calendar's buttons and keys move by days, weeks and months" {
    var s: Due = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Due.view), .{ .height = 420 });
    defer t.deinit();
    try t.clickText("›");
    try testing.expect(s.day.eql(.{ .year = 2026, .month = 2, .day = 14 }));
    try t.clickText("‹");
    try t.clickText("‹");
    try testing.expect(s.day.eql(.{ .year = 2025, .month = 12, .day = 14 }));
    try testing.expect(t.hasText("December 2025"));
    // The buttons gave it the focus: the keys move the day.
    t.key(.right);
    try testing.expect(s.day.eql(.{ .year = 2025, .month = 12, .day = 15 }));
    t.key(.down);
    try testing.expect(s.day.eql(.{ .year = 2025, .month = 12, .day = 22 }));
    t.key(.up);
    t.key(.left);
    try testing.expect(s.day.eql(.{ .year = 2025, .month = 12, .day = 14 }));
    t.key(.end);
    try testing.expect(s.day.eql(.{ .year = 2025, .month = 12, .day = 31 }));
    t.key(.right);
    try testing.expect(s.day.eql(.{ .year = 2026, .month = 1, .day = 1 }));
    t.key(.page_down);
    try testing.expect(s.day.eql(.{ .year = 2026, .month = 2, .day = 1 }));
    t.key(.page_up);
    t.key(.page_up);
    try testing.expect(s.day.eql(.{ .year = 2025, .month = 12, .day = 1 }));
    t.key(.home);
    try testing.expect(s.day.eql(.{ .year = 2025, .month = 12, .day = 1 }));
    // Without the focus, keys do nothing.
    try t.clickText("Elsewhere");
    t.key(.right);
    try testing.expect(s.day.eql(.{ .year = 2025, .month = 12, .day = 1 }));
}

test "weeks start on the day the options say, and today is marked" {
    var s: Due = .{ .monday_first = true };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Due.view), .{ .height = 420 });
    defer t.deinit();
    // Monday first: the grid starts on Monday, Dec 29.
    const mo = t.findText("Mo").?;
    const first = t.findText("29").?;
    try testing.expectApproxEqAbs(mo.x + mo.w / 2, first.x + first.w / 2, 1);
    try testing.expect(mo.x < t.findText("Su").?.x);
    // Today, the 20th, has a ring of the accent.
    const today = cellOf(&t, "20").?;
    var ringed = false;
    for (t.ctx.nodes.items) |n| if (n.style.border) |b| {
        if (std.meta.eql(b, t.theme.accent) and n.rect.contains(.{ .x = today.x + 1, .y = today.y + 1 }) and n.rect.w < 40) ringed = true;
    };
    try testing.expect(ringed);
}

const Meeting = struct {
    day: Date = .{ .year = 2026, .month = 1, .day = 5 },
    at: time.Time = .{ .hour = 15, .minute = 4 },
    twelve: bool = false,
    format: date.DateFormat = .month_day_year,
    changes: u32 = 0,
    fn view(s: *Meeting, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        if (date.dateInput(c, &s.day, .{ .format = s.format })) s.changes += 1;
        if (time.timeInput(c, &s.at, .{ .twelve_hour = s.twelve })) s.changes += 1;
        ui.text(c, "Elsewhere", .{});
    }
};

test "a date input opens its calendar, and a click there chooses and closes" {
    var s: Meeting = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Meeting.view), .{ .height = 480 });
    defer t.deinit();
    try testing.expect(t.hasText("1/5/2026"));
    try testing.expect(!t.hasText("January 2026"));
    try t.clickText("1/5/2026");
    try testing.expect(t.hasText("January 2026"));
    try t.clickText("21");
    try testing.expect(s.day.eql(.{ .year = 2026, .month = 1, .day = 21 }));
    try testing.expect(!t.hasText("January 2026"));
    try testing.expect(t.hasText("1/21/2026"));
    // A click on the field again closes it; one outside too.
    try t.clickText("1/21/2026");
    try t.clickText("1/21/2026");
    try testing.expect(!t.hasText("January 2026"));
    try t.clickText("1/21/2026");
    t.click(400, 460);
    try testing.expect(!t.hasText("January 2026"));
    try testing.expectEqual(@as(u32, 1), s.changes);
}

test "a date input's keys: Enter opens, the arrows move, Enter chooses, Escape closes" {
    var s: Meeting = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Meeting.view), .{ .height = 480 });
    defer t.deinit();
    try t.clickText("1/5/2026");
    t.key(.escape);
    try testing.expect(!t.hasText("January 2026"));
    t.key(.enter);
    try testing.expect(t.hasText("January 2026"));
    // The cursor moves; the date waits for Enter.
    t.key(.down);
    t.key(.right);
    try testing.expect(s.day.eql(.{ .year = 2026, .month = 1, .day = 5 }));
    t.key(.page_down);
    try testing.expect(t.hasText("February 2026"));
    t.key(.enter);
    try testing.expect(s.day.eql(.{ .year = 2026, .month = 2, .day = 13 }));
    try testing.expect(!t.hasText("February 2026"));
    // Space opens it too; Escape leaves the date.
    t.typeText(" ");
    try testing.expect(t.hasText("February 2026"));
    t.key(.left);
    t.key(.escape);
    try testing.expect(!t.hasText("February 2026"));
    try testing.expect(s.day.eql(.{ .year = 2026, .month = 2, .day = 13 }));
}

test "date formats" {
    var s: Meeting = .{ .format = .day_month_year };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Meeting.view), .{});
    defer t.deinit();
    try testing.expect(t.hasText("05/01/2026"));
    s.format = .year_month_day;
    t.frame();
    try testing.expect(t.hasText("2026/1/5"));
}

test "a time input's segments step round the clock and move with the arrows" {
    var s: Meeting = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Meeting.view), .{});
    defer t.deinit();
    try testing.expect(t.hasText("15") and t.hasText("04"));
    try t.clickText("15");
    t.key(.up);
    try testing.expectEqual(time.Time{ .hour = 16, .minute = 4 }, s.at);
    for (0..8) |_| t.key(.up);
    try testing.expectEqual(@as(u8, 0), s.at.hour);
    t.key(.down);
    try testing.expectEqual(@as(u8, 23), s.at.hour);
    t.key(.right);
    t.key(.down);
    t.key(.down);
    t.key(.down);
    t.key(.down);
    t.key(.down);
    try testing.expectEqual(time.Time{ .hour = 23, .minute = 59 }, s.at);
    t.key(.left);
    t.key(.up);
    try testing.expectEqual(time.Time{ .hour = 0, .minute = 59 }, s.at);
    try testing.expect(t.hasText("00") and t.hasText("59"));
}

test "digits typed set the hours, then go on to the minutes" {
    var s: Meeting = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Meeting.view), .{});
    defer t.deinit();
    try t.clickText("15");
    t.typeText("0");
    t.typeText("9");
    try testing.expectEqual(@as(u8, 9), s.at.hour);
    // On to the minutes: two digits.
    t.typeText("3");
    t.typeText("7");
    try testing.expectEqual(time.Time{ .hour = 9, .minute = 37 }, s.at);
    // A third digit starts again.
    t.typeText("5");
    try testing.expectEqual(@as(u8, 5), s.at.minute);
    // A first digit no second can follow (3 of the hours) goes on at once.
    try t.clickText("09");
    t.typeText("3");
    t.typeText("12");
    try testing.expectEqual(time.Time{ .hour = 3, .minute = 12 }, s.at);
    // Typed at once.
    try t.clickText("03");
    t.typeText("2245");
    try testing.expectEqual(time.Time{ .hour = 22, .minute = 45 }, s.at);
    // Not digits: nothing.
    t.typeText("x");
    try testing.expectEqual(time.Time{ .hour = 22, .minute = 45 }, s.at);
}

test "twelve hours: the half of the day steps and follows A and P" {
    var s: Meeting = .{ .twelve = true };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Meeting.view), .{});
    defer t.deinit();
    try testing.expect(t.hasText("3") and t.hasText("04") and t.hasText("PM"));
    try t.clickText("3");
    // Round the twelve hours, within the half of the day.
    for (0..9) |_| t.key(.up);
    try testing.expectEqual(@as(u8, 12), s.at.hour);
    try testing.expect(t.hasText("12") and t.hasText("PM"));
    t.key(.up);
    try testing.expectEqual(@as(u8, 13), s.at.hour);
    t.typeText("11");
    try testing.expectEqual(@as(u8, 23), s.at.hour);
    try t.clickText("PM");
    t.typeText("a");
    try testing.expectEqual(@as(u8, 11), s.at.hour);
    try testing.expect(t.hasText("AM"));
    t.typeText("p");
    try testing.expectEqual(@as(u8, 23), s.at.hour);
    t.key(.down);
    try testing.expectEqual(@as(u8, 11), s.at.hour);
    // Left from the half of the day reaches the minutes.
    t.key(.left);
    t.key(.up);
    try testing.expectEqual(time.Time{ .hour = 11, .minute = 5 }, s.at);
}
