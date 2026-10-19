//! Tags, negotiation, parents and directions, with mygo's cases.
const std = @import("std");
const tag = @import("tag.zig");
const match = @import("match.zig");
const data = @import("locale_data.zig");

fn norm(s: []const u8) []const u8 {
    const S = struct {
        threadlocal var t: tag.Tag = .{};
    };
    S.t = tag.normalize(s) orelse return "";
    return S.t.slice();
}

test "normalize" {
    const cases = [_][2][]const u8{
        .{ "en-us", "en-US" },            .{ "zh_CN.UTF-8", "zh-CN" },     .{ "zh_TW", "zh-TW" },
        .{ "sr_RS@latin", "sr-Latn-RS" }, .{ "sr_RS@euro", "sr-RS" },      .{ "de_DE.utf8@euro", "de-DE" },
        .{ "iw", "he" },                  .{ "in", "id" },                 .{ "nb", "nb" },
        .{ "zh-Hant-HK", "zh-Hant-HK" },  .{ "es-419", "es-419" },         .{ "C", "" },
        .{ "POSIX", "" },                 .{ "C.UTF-8", "" },              .{ "", "" },
        .{ "und", "" },                   .{ "x", "" },                    .{ " en ", "en" },
        .{ "sh", "sr-Latn" },             .{ "mo", "ro-MD" },              .{ "tl", "fil" },
        .{ "EN-latn-us", "en-Latn-US" },  .{ "zh-Hant-tw", "zh-Hant-TW" }, .{ "en-US-u-hc-h23", "en-US-u-hc-h23" },
        .{ "de-DE-1996", "de-DE-1996" },  .{ "in-ID", "id-ID" },           .{ "x-foo", "" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], norm(c[0]));
    const t = tag.normalize("zh-Hant-TW-u-hc-h23").?;
    try std.testing.expectEqualStrings("zh", t.language());
    try std.testing.expectEqualStrings("Hant", t.script().?);
    try std.testing.expectEqualStrings("TW", t.region().?);
    try std.testing.expectEqualStrings("h23", t.unicodeKey("hc").?);
    try std.testing.expectEqualStrings("zh-Hant-TW", t.withoutExtensions().slice());
    try std.testing.expect(tag.normalize("es-419").?.script() == null);
    try std.testing.expectEqualStrings("419", tag.normalize("es-419").?.region().?);
}

fn matched(preferred: []const []const u8, supported: []const []const u8) []const u8 {
    return if (match.match(preferred, supported)) |i| supported[i] else "";
}

test "match" {
    const C = struct { []const []const u8, []const []const u8, []const u8 };
    const cases = [_]C{
        .{ &.{"zh-TW"}, &.{ "en", "zh-Hans", "zh-Hant" }, "zh-Hant" },
        .{ &.{"zh-HK"}, &.{ "en", "zh-TW" }, "zh-TW" },
        .{ &.{"zh-TW"}, &.{ "en", "zh-Hans" }, "" },
        .{ &.{"zh"}, &.{ "en", "zh-Hant", "zh-Hans" }, "zh-Hans" },
        .{ &.{"zh_CN.UTF-8"}, &.{ "en", "zh-Hans" }, "zh-Hans" },
        .{ &.{"es-MX"}, &.{ "en", "es-ES" }, "es-ES" },
        .{ &.{"es-MX"}, &.{ "en", "es-ES", "es-419" }, "es-419" },
        .{ &.{"es-MX"}, &.{ "es", "es-419" }, "es-419" },
        .{ &.{"pt-PT"}, &.{ "en", "pt-BR" }, "pt-BR" },
        .{ &.{"pt"}, &.{ "pt-PT", "pt-BR" }, "pt-BR" },
        .{ &.{"en-AU"}, &.{ "zh-Hans", "en-US", "en-GB" }, "en-GB" },
        .{ &.{"en"}, &.{ "en-GB", "en-US" }, "en-US" },
        .{ &.{"en-US"}, &.{ "en-GB", "en" }, "en" },
        .{ &.{ "fr-CA", "de" }, &.{ "en", "de", "fr" }, "fr" },
        .{ &.{ "fr-CA", "de" }, &.{ "en", "de" }, "de" },
        .{ &.{"ja"}, &.{ "en", "zh-Hans" }, "" },
        .{ &.{ "ja", "zh-Hans" }, &.{ "en", "zh-Hans" }, "zh-Hans" },
        .{ &.{"nb-NO"}, &.{ "en", "no" }, "no" },
        .{ &.{"no"}, &.{ "en", "nb" }, "nb" },
        .{ &.{"iw"}, &.{ "en", "he" }, "he" },
        .{ &.{"sr-Cyrl"}, &.{ "en", "sr-Latn" }, "" },
        .{ &.{"sr_RS@latin"}, &.{ "en", "sr-Latn" }, "sr-Latn" },
        .{ &.{"en-XA"}, &.{ "en", "en-XA" }, "en-XA" },
        .{ &.{"C"}, &.{"en"}, "" },
        .{ &.{}, &.{"en"}, "" },
        .{ &.{"en"}, &.{}, "" },
        // The tag as the app spells it.
        .{ &.{"en-gb"}, &.{ "zh-hans", "en-gb" }, "en-gb" },
    };
    for (cases) |c| {
        const got = matched(c[0], c[1]);
        if (!std.mem.eql(u8, got, c[2])) {
            std.debug.print("match({any}, {any}) = {s}, want {s}\n", .{ c[0], c[1], got, c[2] });
            return error.TestUnexpectedResult;
        }
    }
}

test "fallbacks" {
    const langs = [_][]const u8{ "en", "en-GB", "zh-Hant", "de" };
    const f = match.fallbacks("en-AU", &langs, "en");
    try std.testing.expectEqualSlices(u8, &.{0}, f.items()); // en, en-AU's parent, before its sibling en-GB
    const us_gb = [_][]const u8{ "en-US", "en-GB" };
    try std.testing.expectEqualSlices(u8, &.{ 1, 0 }, match.fallbacks("en-AU", &us_gb, "en-US").items());
    const z = match.fallbacks("zh-TW", &langs, "en");
    try std.testing.expectEqualSlices(u8, &.{ 2, 0 }, z.items());
    const d = match.fallbacks("de-CH", &langs, "en");
    try std.testing.expectEqualSlices(u8, &.{ 3, 0 }, d.items());
    const j = match.fallbacks("ja", &langs, "en");
    try std.testing.expectEqualSlices(u8, &.{0}, j.items());
}

test "direction" {
    const rtl = [_][]const u8{ "ar", "ar-EG", "he", "iw", "fa", "ur", "ps", "yi", "dv", "ug", "ckb", "az-Arab", "ar-XB", "pa-Arab", "nqo", "pa-PK" };
    const ltr = [_][]const u8{ "en", "zh", "ja", "az", "ku", "en-XA", "", "C", "pa", "de-CH" };
    for (rtl) |t| try std.testing.expectEqual(tag.Direction.rtl, tag.direction(t));
    for (ltr) |t| try std.testing.expectEqual(tag.Direction.ltr, tag.direction(t));
}

test "base" {
    const cases = [_][2][]const u8{ .{ "zh-Hant-TW", "zh" }, .{ "iw", "he" }, .{ "en", "en" }, .{ "sr_RS@latin", "sr" } };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], tag.base(c[0]).?.slice());
    try std.testing.expect(tag.base("") == null);
}

fn parentOf(s: []const u8) []const u8 {
    const S = struct {
        threadlocal var t: tag.Tag = .{};
    };
    S.t = tag.parent(s) orelse return "";
    return S.t.slice();
}

test "parent" {
    const cases = [_][2][]const u8{
        .{ "en-AU", "en-001" },          .{ "en-001", "en" },          .{ "en-GB", "en-001" },         .{ "en-CH", "en-150" },
        .{ "en-150", "en-001" },         .{ "en", "" },                .{ "en-US", "en" },             .{ "de-CH", "de" },
        .{ "zh-Hant-MO", "zh-Hant-HK" }, .{ "zh-Hant-HK", "zh-Hant" }, .{ "zh-Hant", "" },             .{ "zh-Hans", "zh" },
        .{ "zh-Hans-CN", "zh-Hans" },    .{ "sr-Latn", "" },           .{ "sr-Latn-RS", "sr-Latn" },   .{ "sr-Cyrl", "sr" },
        .{ "ja-Latn", "" },              .{ "nb", "no" },              .{ "pt-AO", "pt-PT" },          .{ "pt-PT", "pt" },
        .{ "es-MX", "es-419" },          .{ "es-419", "es" },          .{ "ca-ES-valencia", "ca-ES" }, .{ "de-DE-u-co-phonebk", "de" },
        .{ "en-XA", "en" },              .{ "ar-XB", "ar" },           .{ "", "" },                    .{ "C", "" },
    };
    for (cases) |c| {
        const got = parentOf(c[0]);
        if (!std.mem.eql(u8, got, c[1])) {
            std.debug.print("parent({s}) = {s}, want {s}\n", .{ c[0], got, c[1] });
            return error.TestUnexpectedResult;
        }
    }
    const ch = tag.chain("zh-Hant-MO");
    try std.testing.expectEqual(@as(usize, 3), ch.len);
    try std.testing.expectEqualStrings("zh-Hant", ch.items()[2].slice());
    try std.testing.expectEqual(@as(usize, 0), tag.chain("x").len);
}

test "the region's week and clock" {
    try std.testing.expectEqual(@as(u3, 0), data.firstWeekday("en"));
    try std.testing.expectEqual(@as(u3, 1), data.firstWeekday("en-GB"));
    try std.testing.expectEqual(@as(u3, 1), data.firstWeekday("de"));
    try std.testing.expectEqual(@as(u3, 6), data.firstWeekday("fa"));
    try std.testing.expectEqual(@as(u3, 1), data.firstWeekday("en-US-u-fw-mon"));
    try std.testing.expectEqual(@as(u8, 12), data.hourCycle("en"));
    try std.testing.expectEqual(@as(u8, 24), data.hourCycle("en-GB"));
    try std.testing.expectEqual(@as(u8, 12), data.hourCycle("ko"));
    try std.testing.expectEqual(@as(u8, 24), data.hourCycle("de"));
    try std.testing.expectEqual(@as(u8, 24), data.hourCycle("en-US-u-hc-h23"));
}

test "autonyms" {
    const cases = [_][2][]const u8{
        .{ "en", "English" },                  .{ "de", "Deutsch" },
        .{ "zh", "中文" },
        .{ "zh-Hant", "繁體中文" },
        .{ "zh-TW", "繁體中文" },
        .{ "en-XA", "en-XA" },
        .{ "zh-Hans", "简体中文" },
        .{ "de-CH", "Schweizer Hochdeutsch" },
        .{ "pt-BR", "português (Brasil)" },
        .{ "de-AT", "Österreichisches Deutsch" },
        .{ "xx", "" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], data.autonym(c[0]));
}

/// mygo's stripExtensions before it scanned: split on "-", cut at the
/// first one-letter subtag after the first.
fn splitStrip(s: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, s, '-');
    var end: usize = 0;
    var first = true;
    while (it.next()) |p| {
        if (!first and p.len == 1) return s[0..end];
        end += p.len + @intFromBool(!first);
        first = false;
    }
    return s;
}

test "extensions are stripped by a scan, as by splitting" {
    const cases = [_][2][]const u8{
        .{ "en-US-u-hc-h23", "en-US" },  .{ "zh-Hant-TW-x-private", "zh-Hant-TW" }, .{ "en", "en" },
        .{ "de-DE-1996", "de-DE-1996" }, .{ "en-x", "en" },                         .{ "a-b", "a" },
        .{ "en--u", "en-" },             .{ "", "" },                               .{ "-u", "" },
        .{ "en-US-", "en-US-" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], c[0][0..tag.extensionsStart(c[0])]);
    // Every string of up to six of "a", "b", "-" (and so every shape of
    // subtags) strips as the split did.
    const alphabet = "ab-";
    var buf: [6]u8 = undefined;
    for (0..7) |len| {
        var n: usize = 1;
        for (0..len) |_| n *= alphabet.len;
        for (0..n) |code| {
            var x = code;
            for (buf[0..len]) |*ch| {
                ch.* = alphabet[x % alphabet.len];
                x /= alphabet.len;
            }
            const s = buf[0..len];
            try std.testing.expectEqualStrings(splitStrip(s), s[0..tag.extensionsStart(s)]);
        }
    }
}

test "normalize keeps what it read, and reads each locale as parse does" {
    const locales = [_][]const u8{ "de-CH", "de", "en-us", "zh_TW.UTF-8", "C", "de-CH", "ar-XB", "en-us", "x", "sr_RS@latin", "de" };
    for (0..3) |_| for (locales) |l| {
        const want = tag.Tag.parse(l);
        const got = tag.normalize(l);
        try std.testing.expectEqual(want == null, got == null);
        if (want) |w| try std.testing.expectEqualStrings(w.slice(), got.?.slice());
    };
    // Longer than a tag: not kept, still read.
    var long: [73]u8 = @splat('a');
    long[2] = '-';
    try std.testing.expect(tag.normalize(&long) == null);
}
