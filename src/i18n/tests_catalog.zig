//! Catalogs read from embedded ARB files: lookups, fallbacks, plural rules
//! of the message's language, numbers of the locale asked for, pseudo
//! locales, and the checks a catalog makes at compile time.
//!
//! What does not compile (each a compile error naming the catalog's file,
//! the key and the reason; Zig cannot test that a call fails to compile, so
//! the checks themselves are tested below through the functions that
//! return their reasons):
//!
//!     L.text(.titel)                         // no member 'titel' in Key
//!     L.text(.greeting)                      // greeting has arguments
//!     L.printIn(w, "de", .greeting, .{})     // needs the argument name
//!     L.printIn(w, "de", .greeting, .{ .name = "Ada", .x = 1 })   // has no argument x
//!     L.printIn(w, "de", .filesSelected, .{ .count = "3" })       // takes an integer
//!     L.printIn(w, "de", .due, .{ .day = 3 })                     // takes an i18n.DateTime
//!     de.json with a key en.json lacks, or an argument its message lacks
//!     a message that does not parse; `"{n, plural, one {#}}"` (no other)
//!     an untyped argument counted by plural and declared "String"
//!     de-de.json (not a canonical tag), "@@locale": "fr" in de.json
const std = @import("std");
const i18n = @import("i18n.zig");
const args = @import("args.zig");
const msg = @import("message.zig");

const L = i18n.Catalog(.{
    .source = "en",
    .files = .{
        .en = @embedFile("testdata/locales/en.json"),
        .de = @embedFile("testdata/locales/de.json"),
        .ru = @embedFile("testdata/locales/ru.json"),
        .ar = @embedFile("testdata/locales/ar.json"),
        .@"zh-Hant" = @embedFile("testdata/locales/zh-Hant.json"),
    },
    .pseudo = true,
});

fn say(locale: []const u8, comptime key: L.Key, a: anytype) ![]const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    return L.bufPrintIn(&S.buf, locale, key, a);
}

test "languages and keys" {
    try std.testing.expectEqual(@as(usize, 5), L.languages.len);
    try std.testing.expectEqualStrings("en", L.languages[0]);
    try std.testing.expect(@hasField(L.Key, "filesSelected"));
    try std.testing.expect(!@hasField(L.Key, "myzig.undo"));
    // What the translations lack, which says English.
    try std.testing.expectEqual(@as(usize, 0), L.missing[0].len);
    try std.testing.expectEqualStrings("onlyEnglish", L.missing[1][0]);
}

test "messages without arguments are static text" {
    try std.testing.expectEqualStrings("Notizen", L.textIn("de", .title));
    try std.testing.expectEqualStrings("Notizen", L.textIn("de-AT", .title));
    try std.testing.expectEqualStrings("筆記", L.textIn("zh-TW", .title));
    try std.testing.expectEqualStrings("Notes", L.textIn("zh-CN", .title)); // no zh-Hans: English
    try std.testing.expectEqualStrings("Only in English", L.textIn("de", .onlyEnglish));
    try std.testing.expectEqualStrings("Notes", L.textIn("ja", .title));
    try std.testing.expectEqualStrings("Type {name} to don't confirm", L.textIn("en", .quoted));
    // The same pointer each time: nothing is formatted.
    try std.testing.expectEqual(L.textIn("de", .title).ptr, L.textIn("de", .title).ptr);
    try std.testing.expectEqualStrings("[Ñöţéš one]", L.textIn("en-XA", .title));
}

test "the language the app shows" {
    defer i18n.setLocale("en");
    try std.testing.expectEqualStrings("Notes", L.text(.title));
    const gen = i18n.localeGeneration();
    i18n.setLocale("ru_RU.UTF-8");
    try std.testing.expectEqualStrings("ru-RU", i18n.locale());
    try std.testing.expectEqualStrings("Заметки", L.text(.title));
    try std.testing.expect(i18n.localeGeneration() != gen);
}

test "arguments, plurals and fallbacks" {
    try std.testing.expectEqualStrings("Hello, Ada!", try say("en", .greeting, .{ .name = "Ada" }));
    try std.testing.expectEqualStrings("Hallo, Ada!", try say("de", .greeting, .{ .name = "Ada" }));
    try std.testing.expectEqualStrings("Hello, Ada!", try say("ru", .greeting, .{ .name = "Ada" }));
    try std.testing.expectEqualStrings("No files selected", try say("en", .filesSelected, .{ .count = 0 }));
    try std.testing.expectEqualStrings("1 file selected", try say("en", .filesSelected, .{ .count = 1 }));
    try std.testing.expectEqualStrings("1,000 files selected", try say("en", .filesSelected, .{ .count = 1000 }));
    try std.testing.expectEqualStrings("1.000 Dateien ausgewählt", try say("de", .filesSelected, .{ .count = 1000 }));
    // Numbers in the conventions of the locale asked for: de-CH groups with '.
    try std.testing.expectEqualStrings("1'000 Dateien ausgewählt", try say("de-CH", .filesSelected, .{ .count = @as(usize, 1000) }));
    try std.testing.expectEqualStrings("Выбран 21 файл", try say("ru", .filesSelected, .{ .count = 21 }));
    try std.testing.expectEqualStrings("Выбрано 3 файла", try say("ru", .filesSelected, .{ .count = 3 }));
    try std.testing.expectEqualStrings("Выбрано 11 файлов", try say("ru", .filesSelected, .{ .count = 11 }));
    try std.testing.expectEqualStrings("ملفان", try say("ar", .filesSelected, .{ .count = 2 }));
    try std.testing.expectEqualStrings("١١ ملفًا", try say("ar-EG", .filesSelected, .{ .count = 11 }));
    try std.testing.expectEqualStrings("已選取 3 個檔案", try say("zh-HK", .filesSelected, .{ .count = 3 }));
    try std.testing.expectEqualStrings("22nd place", try say("en", .place, .{ .n = 22 }));
    try std.testing.expectEqualStrings("3. Platz", try say("de", .place, .{ .n = 3 }));
}

test "select on strings, enums and bools" {
    const Gender = enum { female, male, other };
    try std.testing.expectEqualStrings("She replied.", try say("en", .replied, .{ .gender = "female" }));
    try std.testing.expectEqualStrings("Er antwortete.", try say("de", .replied, .{ .gender = Gender.male }));
    try std.testing.expectEqualStrings("They replied.", try say("en", .replied, .{ .gender = .robot }));
}

test "numbers and dates of messages" {
    try std.testing.expectEqualStrings("Total: 1,234.50", try say("en", .price, .{ .amount = 1234.5 }));
    try std.testing.expectEqualStrings("Summe: 1.234,50", try say("de", .price, .{ .amount = args.exact("1234.5") }));
    const day = i18n.DateTime.utc(2026, 1, 5, 13, 7, 9);
    try std.testing.expectEqualStrings("Due Jan 5, 2026", try say("en", .due, .{ .day = day }));
    try std.testing.expectEqualStrings("Fällig am 05.01.2026", try say("de", .due, .{ .day = day }));
}

test "pseudo locales" {
    try std.testing.expectEqualStrings("[Ĥéļļö, Ada! one]", try say("en-XA", .greeting, .{ .name = "Ada" }));
    try std.testing.expectEqualStrings("\u{200f}\u{202e}Hello,\u{202c}\u{200f} \u{200f}Ada\u{200f}\u{200f}\u{202e}!\u{202c}\u{200f}", try say("ar-XB", .greeting, .{ .name = "Ada" }));
    try std.testing.expectEqual(i18n.Direction.rtl, i18n.direction("ar-XB"));
}

test "alloc and the frame of a view" {
    const gpa = std.testing.allocator;
    const s = try L.allocIn(gpa, "de", .greeting, .{ .name = "Ada" });
    defer gpa.free(s);
    try std.testing.expectEqualStrings("Hallo, Ada!", s);

    // A stand-in of ui.Context: frame memory and a language.
    const View = struct {
        arena: std.heap.ArenaAllocator,
        pub fn alloc(v: *@This()) std.mem.Allocator {
            return v.arena.allocator();
        }
        pub fn locale(_: *@This()) []const u8 {
            return "de";
        }
    };
    var v: View = .{ .arena = .init(gpa) };
    defer v.arena.deinit();
    try std.testing.expectEqualStrings("2 Dateien ausgewählt", L.t(&v, .filesSelected, .{ .count = 2 }));
    try std.testing.expectEqualStrings("Notizen", L.t(&v, .title, .{}));
}

test "overrides of a library's strings" {
    try std.testing.expectEqualStrings("復原（筆記）", L.override("myzig.undo", 4).?.plain.?);
    try std.testing.expect(L.override("myzig.undo", 0) == null);
}

test "the checks catalogs make" {
    // Arguments used as their types cannot be.
    try std.testing.expect(args.misuse(.string, .plural) != null);
    try std.testing.expect(args.misuse(.int, .date) != null);
    try std.testing.expect(args.misuse(.int, .plural) == null);
    // Values of the wrong type.
    try std.testing.expect(args.mismatch(.int, []const u8) != null);
    try std.testing.expect(args.mismatch(.int, f64) != null);
    try std.testing.expect(args.mismatch(.number, f64) == null);
    try std.testing.expect(args.mismatch(.string, u32) != null);
    try std.testing.expect(args.mismatch(.date_time, i64) != null);
    try std.testing.expect(args.mismatch(.string, *const [3:0]u8) == null);
    // Messages that do not parse say where and why.
    const bad = comptime msg.parse("{n, plural, one {#}}");
    try std.testing.expect(bad == .err);
    try std.testing.expectEqualStrings("a plural or select argument has no other case", bad.err.why);
    try std.testing.expect(comptime msg.parse("{d, date, ::yQQQ}") == .err);
    try std.testing.expect(comptime msg.parse("{n, number, money}") == .err);
    // A JSON file that is not.
    try std.testing.expect(comptime @import("json_ct.zig").parse("{\"a\": }") == .err);
    try std.testing.expect(comptime @import("json_ct.zig").parse("{\"a\": \"\\u00e9\\ud83d\\ude00\"}").ok.get("a").?.string.len == 6);
}

test "catalogs keep their own resolved languages" {
    const M = i18n.Catalog(.{ .files = .{
        .en = @embedFile("testdata/locales/en.json"),
        .@"zh-Hant" = @embedFile("testdata/locales/zh-Hant.json"),
    } });
    // The same locale in two catalogs, whose languages differ.
    try std.testing.expectEqualStrings("Notes", L.textIn("ja", .title));
    try std.testing.expectEqualStrings("筆記", M.textIn("zh-TW", .title));
    try std.testing.expectEqualStrings("筆記", L.textIn("zh-TW", .title));
    try std.testing.expectEqualStrings("Заметки", L.textIn("ru", .title));
    try std.testing.expectEqualStrings("Notes", M.textIn("ru", .title));
}
