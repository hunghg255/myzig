//! Numbers, dates and names against what mygo writes (`tests_number_cases.zig`,
//! `tests_date_cases.zig`, generated from mygo, whose formatting matches ICU's).
const std = @import("std");
const number = @import("number.zig");
const date = @import("date.zig");
const ncases = @import("tests_number_cases.zig");
const dcases = @import("tests_date_cases.zig");

test "numbers as ICU writes them" {
    var failed: usize = 0;
    for (ncases.nums) |c| {
        const o: number.NumberOptions = switch (c.kind) {
            .plain => .{},
            .percent => .{ .percent = true },
            .min2 => .{ .min_fraction = 2 },
            .no_group => .{ .grouping = false },
            .half_even => .{ .integer = true, .half_even = true },
            .integer => .{ .integer = true },
        };
        var buf: [128]u8 = undefined;
        const got = try number.bufFormatNumber(&buf, c.locale, c.value, o);
        if (!std.mem.eql(u8, got, c.want)) {
            std.debug.print("{s} {s} {s}: got \"{s}\", want \"{s}\"\n", .{ c.locale, c.value, @tagName(c.kind), got, c.want });
            failed += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "numbers of Zig types" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1.234.567,891", try number.bufFormatNumber(&buf, "de", @as(f64, 1234567.891), .{}));
    try std.testing.expectEqualStrings("12,34,567", try number.bufFormatNumber(&buf, "hi", 1234567, .{}));
    try std.testing.expectEqualStrings("۲۵٪", try number.bufFormatNumber(&buf, "fa", 0.25, .{ .percent = true }));
    try std.testing.expectEqualStrings("25%", try number.bufFormatNumber(&buf, "fa-u-nu-latn", 0.25, .{ .percent = true }));
    try std.testing.expectEqualStrings("1.50", try number.bufFormatNumber(&buf, "en", 1.5, .{ .min_fraction = 2 }));
    try std.testing.expectEqualStrings("1.01", try number.bufFormatNumber(&buf, "en", 1.005, .{ .max_fraction = 2 }));
    try std.testing.expectEqualStrings("07", try number.bufFormatNumber(&buf, "en", 7, .{ .min_integer = 2 }));
    try std.testing.expectEqualStrings("-9,223,372,036,854,775,808", try number.bufFormatNumber(&buf, "en", @as(i64, std.math.minInt(i64)), .{}));
    try std.testing.expectEqualStrings("NaN", try number.bufFormatNumber(&buf, "en", std.math.nan(f64), .{}));
    try std.testing.expectEqualStrings("-∞", try number.bufFormatNumber(&buf, "en", -std.math.inf(f64), .{}));
    try std.testing.expectEqualStrings("1,000", try number.bufFormatNumber(&buf, "en", 999.9996, .{}));
    try std.testing.expectEqualStrings("1234", try number.bufFormatNumber(&buf, "es", 1234, .{}));
    try std.testing.expectEqualStrings("12.345", try number.bufFormatNumber(&buf, "es", 12345, .{}));
    // A locale without data formats as its nearest, else as English.
    try std.testing.expectEqualStrings("1\u{202f}234,5", try number.bufFormatNumber(&buf, "fr-LU", 1234.5, .{}));
    try std.testing.expectEqualStrings("1,234.5", try number.bufFormatNumber(&buf, "xx", 1234.5, .{}));
}

test "dates as ICU writes them" {
    var failed: usize = 0;
    for (dcases.dates) |c| {
        var buf: [200]u8 = undefined;
        const o: date.DateOptions = .{ .date = @fromBackingInt(@intCast(c.date)), .time = @fromBackingInt(@intCast(c.time)), .skeleton = c.skeleton, .hour_cycle = c.hour_cycle };
        const got = try date.bufFormatDate(&buf, c.locale, .{ .unix = c.unix }, o);
        if (!std.mem.eql(u8, got, c.want)) {
            std.debug.print("{s} {d} date {d} time {d} {s} hc {d}: got \"{s}\", want \"{s}\"\n", .{ c.locale, c.unix, c.date, c.time, c.skeleton, c.hour_cycle, got, c.want });
            failed += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "civil dates" {
    const t = date.DateTime.utc(2026, 1, 5, 13, 7, 9);
    try std.testing.expectEqual(@as(i64, 1767618429), t.unix);
    const c = t.civil();
    try std.testing.expectEqual(@as(u3, 1), c.weekday); // a Monday
    try std.testing.expectEqual(@as(i32, 2026), c.year);
    const leap = date.DateTime.utc(2024, 2, 29, 23, 59, 59).civil();
    try std.testing.expectEqual(@as(u5, 29), leap.day);
    const before = (date.DateTime{ .unix = -1 }).civil();
    try std.testing.expectEqual(@as(i32, 1969), before.year);
    try std.testing.expectEqual(@as(u5, 23), before.hour);
}

test "time zones" {
    var buf: [100]u8 = undefined;
    const t = date.DateTime.utc(2026, 1, 5, 13, 7, 9);
    const in_china: date.DateTime = .{ .unix = t.unix, .offset_minutes = 8 * 60 };
    try std.testing.expectEqualStrings("9:07:09 PM GMT+8", try date.bufFormatDate(&buf, "en", in_china, .{ .time = .long }));
    const in_india: date.DateTime = .{ .unix = t.unix, .offset_minutes = 5 * 60 + 30 };
    try std.testing.expectEqualStrings("6:37:09 PM GMT+5:30", try date.bufFormatDate(&buf, "en", in_india, .{ .time = .long }));
    try std.testing.expectEqualStrings("1:07:09 PM UTC", try date.bufFormatDate(&buf, "en", t, .{ .time = .long }));
    try std.testing.expectEqualStrings("1:07:09 PM GMT", try date.bufFormatDate(&buf, "en", .{ .unix = t.unix, .offset_minutes = 0 }, .{ .time = .long }));
}

test "names of months, weekdays and day periods" {
    const t = std.testing;
    try t.expectEqualStrings("January", date.months("en", .wide, false)[0]);
    try t.expectEqualStrings("января", date.months("ru", .wide, false)[0]);
    try t.expectEqualStrings("январь", date.months("ru", .wide, true)[0]);
    try t.expectEqualStrings("Jan", date.months("en", .abbreviated, false)[0]);
    try t.expectEqualStrings("Sunday", date.weekdays("en", .wide, false)[0]);
    try t.expectEqualStrings("Mo", date.weekdays("en", .short, true)[1]);
    try t.expectEqualStrings("M", date.weekdays("en", .narrow, true)[1]);
    try t.expectEqualStrings("Montag", date.weekdays("de", .wide, false)[1]);
    try t.expectEqualStrings("上午", date.dayPeriods("zh", .abbreviated)[0]);
    try t.expectEqualStrings("PM", date.dayPeriods("en", .abbreviated)[1]);
    try t.expectEqualStrings("1月", date.months("ja", .wide, true)[0]);
}

test "patterns" {
    try std.testing.expectEqualStrings("MMM d, y", date.pattern("en", .{ .skeleton = "yMMMd" }).slice());
    try std.testing.expectEqualStrings("d. MMM y", date.pattern("de", .{ .skeleton = "yMMMd" }).slice());
    try std.testing.expectEqualStrings("HH:mm", date.pattern("en", .{ .skeleton = "jm", .hour_cycle = 24 }).slice());
    try std.testing.expect(date.isSkeleton("yMMMd"));
    try std.testing.expect(!date.isSkeleton("yQQQ"));
}
