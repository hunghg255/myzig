//! Plural rules: every sample CLDR gives of every category of every
//! language (testdata/plural_samples.txt, CLDR 48.2), and named cases.
const std = @import("std");
const plural = @import("plural.zig");
const Operands = plural.Operands;
const Plural = plural.Plural;

fn category(tag: []const u8, n: anytype, ordinal: bool) Plural {
    const o = Operands.of(n).?;
    return if (ordinal) plural.ordinalCategory(tag, o) else plural.cardinalCategory(tag, o);
}

test "operands" {
    const cases = .{
        .{ "1.50", Operands{ .i = 1, .v = 2, .w = 1, .f = 50, .t = 5 } },
        .{ "-1.50", Operands{ .i = 1, .v = 2, .w = 1, .f = 50, .t = 5 } },
        .{ "1.0", Operands{ .i = 1, .v = 1 } },
        .{ "1.230", Operands{ .i = 1, .v = 3, .w = 2, .f = 230, .t = 23 } },
        .{ "0.001", Operands{ .v = 3, .w = 3, .f = 1, .t = 1 } },
        .{ "1.2c6", Operands{ .i = 1200000, .c = 6 } },
        .{ "1.2e6", Operands{ .i = 1200000, .c = 6 } },
        .{ "1.234c2", Operands{ .i = 123, .v = 1, .w = 1, .f = 4, .t = 4, .c = 2 } },
        .{ ".5", Operands{ .v = 1, .w = 1, .f = 5, .t = 5 } },
        .{ "1000000000000000000001", Operands{ .i = 1 + 1_000_000_000_000_000_000 } },
        .{ "1.0000000000000000000000", Operands{ .i = 1, .v = 22 } },
    };
    inline for (cases) |c| try std.testing.expectEqual(c[1], Operands.parse(c[0]).?);
    try std.testing.expectEqual(Operands{ .i = 5 }, Operands.of(-5).?);
    try std.testing.expectEqual(Operands{ .i = 1, .v = 1, .w = 1, .f = 5, .t = 5 }, Operands.of(1.5).?);
    try std.testing.expectEqual(Operands{ .v = 2, .w = 2, .f = 25, .t = 25 }, Operands.of(@as(f64, 0.25)).?);
    try std.testing.expectEqual(Operands{ .i = 1 }, Operands.of(@as(f64, 1.0)).?);
    try std.testing.expectEqual(Operands{ .i = 9223372036854775808 % 1_000_000_000_000_000_000 + 1_000_000_000_000_000_000 }, Operands.of(@as(i64, std.math.minInt(i64))).?);
    for ([_][]const u8{ "", "-", "1.", "1.2.3", "abc", "1e", "1c-2", " ", "1,5" }) |bad| {
        try std.testing.expect(Operands.parse(bad) == null);
    }
    try std.testing.expect(Operands.of(std.math.nan(f64)) == null);
}

test "categories" {
    const C = struct { []const u8, bool, []const Plural };
    const cases = [_]C{
        .{ "en", false, &.{ .one, .other } },
        .{ "en-GB", false, &.{ .one, .other } },
        .{ "en", true, &.{ .one, .two, .few, .other } },
        .{ "ja", false, &.{.other} },
        .{ "zh-Hant-TW", false, &.{.other} },
        .{ "ar", false, &.{ .zero, .one, .two, .few, .many, .other } },
        .{ "ru", false, &.{ .one, .few, .many, .other } },
        .{ "fr", false, &.{ .one, .many, .other } },
        .{ "pt-PT", false, &.{ .one, .many, .other } },
        .{ "xx", false, &.{.other} },
        .{ "", false, &.{.other} },
        .{ "de-DE-u-nu-latn", false, &.{ .one, .other } },
    };
    for (cases) |c| {
        const set = if (c[1]) plural.ordinalCategories(c[0]) else plural.cardinalCategories(c[0]);
        try std.testing.expectEqual(c[2].len, set.count());
        for (c[2]) |p| try std.testing.expect(set.has(p));
    }
}

test "plural categories of a dozen languages" {
    const t = std.testing;
    // English: one, other; ordinals 1st 2nd 3rd 4th.
    try t.expectEqual(Plural.one, category("en", 1, false));
    try t.expectEqual(Plural.other, category("en", "1.0", false));
    try t.expectEqual(Plural.other, category("en", 0, false));
    try t.expectEqual(Plural.two, category("en", 22, true));
    try t.expectEqual(Plural.few, category("en", 103, true));
    try t.expectEqual(Plural.other, category("en", 113, true));
    // French: 0 and 1.5 are one; millions are many, also in compact notation.
    try t.expectEqual(Plural.one, category("fr", 0, false));
    try t.expectEqual(Plural.one, category("fr", 1.5, false));
    try t.expectEqual(Plural.many, category("fr", 1000000, false));
    try t.expectEqual(Plural.many, category("fr", "1.2c6", false));
    try t.expectEqual(Plural.other, category("fr", "1c3", false));
    // Russian and Ukrainian.
    for ([_][]const u8{ "ru", "uk" }) |l| {
        try t.expectEqual(Plural.one, category(l, 21, false));
        try t.expectEqual(Plural.few, category(l, 3, false));
        try t.expectEqual(Plural.many, category(l, 11, false));
        try t.expectEqual(Plural.other, category(l, 1.5, false));
    }
    // Polish, with a number of more than 18 digits.
    try t.expectEqual(Plural.few, category("pl", 22, false));
    try t.expectEqual(Plural.many, category("pl", "1000000000000000000021", false));
    // Arabic: six categories.
    try t.expectEqual(Plural.zero, category("ar", 0, false));
    try t.expectEqual(Plural.two, category("ar", 2, false));
    try t.expectEqual(Plural.few, category("ar", 103, false));
    try t.expectEqual(Plural.many, category("ar", 111, false));
    try t.expectEqual(Plural.other, category("ar", 102, false));
    try t.expectEqual(Plural.one, category("ar", "1.0", false));
    // Czech: decimals are many.
    try t.expectEqual(Plural.few, category("cs", 4, false));
    try t.expectEqual(Plural.many, category("cs", 1.5, false));
    // Welsh: zero, one, two, few (3), many (6).
    try t.expectEqual(Plural.few, category("cy", 3, false));
    try t.expectEqual(Plural.many, category("cy", 6, false));
    // Latvian: visible fraction digits count.
    try t.expectEqual(Plural.one, category("lv", "0.1", false));
    try t.expectEqual(Plural.other, category("lv", "0.10", false));
    try t.expectEqual(Plural.zero, category("lv", 10, false));
    // Lithuanian, Hebrew, Irish, Slovenian.
    try t.expectEqual(Plural.many, category("lt", 1.5, false));
    try t.expectEqual(Plural.two, category("he", 2, false));
    try t.expectEqual(Plural.many, category("ga", 7, false));
    try t.expectEqual(Plural.two, category("sl", 102, false));
    // Portuguese: Brazil's 0 is one, Portugal's is other.
    try t.expectEqual(Plural.one, category("pt", 0, false));
    try t.expectEqual(Plural.other, category("pt-PT", 0, false));
    // Japanese and Chinese: other only.
    try t.expectEqual(Plural.other, category("ja", 1, false));
    try t.expectEqual(Plural.other, category("zh-Hant", 1, false));
    // Old codes and POSIX locales.
    try t.expectEqual(Plural.two, category("iw", 2, false));
    try t.expectEqual(Plural.few, category("ru_RU.UTF-8", 2, false));
}

/// Writes out the samples of a rule ("@integer 0, 2~16, 100, … @decimal
/// 0.0~1.5"), ranges by ones or tenths, calling `f` with each.
fn expand(samples: []const u8, ctx: anytype, f: fn (@TypeOf(ctx), []const u8) anyerror!void) !usize {
    var count: usize = 0;
    var groups = std.mem.tokenizeScalar(u8, samples, '@');
    while (groups.next()) |group| {
        const g = std.mem.trim(u8, group, " ");
        const sp = std.mem.indexOfScalar(u8, g, ' ') orelse continue;
        var items = std.mem.tokenizeScalar(u8, g[sp + 1 ..], ',');
        while (items.next()) |raw| {
            const item = std.mem.trim(u8, raw, " ");
            if (item.len == 0 or std.mem.eql(u8, item, "…")) continue;
            const tilde = std.mem.indexOfScalar(u8, item, '~') orelse {
                try f(ctx, item);
                count += 1;
                continue;
            };
            const lo = item[0..tilde];
            const frac = if (std.mem.indexOfScalar(u8, lo, '.')) |p| lo.len - p - 1 else 0;
            const a = try digitsOf(lo);
            const z = try digitsOf(item[tilde + 1 ..]);
            var n = a;
            while (n <= z) : (n += 1) {
                var buf: [32]u8 = undefined;
                var s = try std.fmt.bufPrint(&buf, "{d}", .{n});
                var out: [40]u8 = undefined;
                if (frac > 0) {
                    var padded: [40]u8 = undefined;
                    const zeros = (frac + 1) -| s.len;
                    @memset(padded[0..zeros], '0');
                    @memcpy(padded[zeros..][0..s.len], s);
                    const all = padded[0 .. zeros + s.len];
                    const ip = all.len - frac;
                    s = try std.fmt.bufPrint(&out, "{s}.{s}", .{ all[0..ip], all[ip..] });
                }
                try f(ctx, s);
                count += 1;
            }
        }
    }
    return count;
}

fn digitsOf(s: []const u8) !u64 {
    var v: u64 = 0;
    for (s) |c| if (c != '.') {
        v = v * 10 + (c - '0');
    };
    return v;
}

const Check = struct {
    langs: []const u8,
    want: Plural,
    ordinal: bool,
    checked: *usize,

    fn one(c: *const Check, sample: []const u8) anyerror!void {
        var it = std.mem.tokenizeScalar(u8, c.langs, ',');
        while (it.next()) |lang| {
            const got = category(lang, sample, c.ordinal);
            if (got != c.want) {
                std.debug.print("{s} {s} {s} = {s}, want {s}\n", .{ lang, if (c.ordinal) "ordinal" else "cardinal", sample, @tagName(got), @tagName(c.want) });
                return error.TestUnexpectedResult;
            }
            c.checked.* += 1;
        }
    }
};

test "every sample of CLDR's plural rules" {
    const text = @embedFile("testdata/plural_samples.txt");
    var checked: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, ' ');
        const kind = f.next().?;
        const langs = f.next().?;
        const want = Plural.parse(f.next().?).?;
        const check: Check = .{ .langs = langs, .want = want, .ordinal = std.mem.eql(u8, kind, "ordinal"), .checked = &checked };
        _ = try expand(f.rest(), &check, Check.one);
    }
    try std.testing.expect(checked > 10000);
}
