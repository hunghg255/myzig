//! The texts of the update window, after mygo's updater plugin: English,
//! Chinese (Simplified and Traditional), Dutch, French, German, Italian,
//! Japanese, Korean, Polish, Portuguese (Brazil), Russian, Spanish, Turkish
//! and Ukrainian, a catalog of `locales/*.json` checked at compile time
//! (`myzig.i18n.Catalog`), with their decimal marks ("1,5 MB"). Other
//! languages get English.
//!
//! A window speaks the language the app shows when its check begins
//! (`i18n.locale()`, or the language the app names), and keeps it while it
//! is open: `Texts` holds that language. After `i18n.setLocale`, the next
//! window takes the new one, as does `menuItem`.
const std = @import("std");
const myzig = @import("myzig");
const i18n = myzig.i18n;

pub const L = i18n.Catalog(.{ .files = .{
    .en = @embedFile("locales/en.json"),
    .de = @embedFile("locales/de.json"),
    .es = @embedFile("locales/es.json"),
    .fr = @embedFile("locales/fr.json"),
    .it = @embedFile("locales/it.json"),
    .ja = @embedFile("locales/ja.json"),
    .ko = @embedFile("locales/ko.json"),
    .nl = @embedFile("locales/nl.json"),
    .pl = @embedFile("locales/pl.json"),
    .@"pt-BR" = @embedFile("locales/pt-BR.json"),
    .ru = @embedFile("locales/ru.json"),
    .tr = @embedFile("locales/tr.json"),
    .uk = @embedFile("locales/uk.json"),
    .@"zh-Hans" = @embedFile("locales/zh-Hans.json"),
    .@"zh-Hant" = @embedFile("locales/zh-Hant.json"),
} });

pub const Key = L.Key;

/// The label of a "Check for Updates…" menu item in the language the app
/// shows now (`language` when not empty): an app that rebuilds its menu
/// when its language changes gets the item in the new one.
pub fn menuItem(language: []const u8) []const u8 {
    return L.textIn(if (language.len > 0) language else i18n.locale(), .menuItem);
}

/// The texts of one window, in the language it opened in.
pub const Texts = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    /// The texts of `language`, or of the language the app shows now
    /// when it is empty.
    pub fn init(lang: []const u8) Texts {
        const l = if (lang.len > 0) lang else i18n.locale();
        var t: Texts = .{};
        t.len = @min(l.len, t.buf.len);
        @memcpy(t.buf[0..t.len], l[0..t.len]);
        return t;
    }

    /// The locale the window speaks.
    pub fn locale(t: *const Texts) []const u8 {
        return t.buf[0..t.len];
    }

    /// The language of the catalog it speaks: "zh-Hans" for zh-CN, "en"
    /// for a language the plugin does not have.
    pub fn language(t: *const Texts) []const u8 {
        return L.languages[L.languageOf(t.locale(), .title)];
    }

    /// Whether the window is laid out from the right (a language written
    /// right to left that it speaks).
    pub fn rtl(t: *const Texts) bool {
        return i18n.direction(t.language()) == .rtl;
    }

    pub fn text(t: *const Texts, comptime key: Key) []const u8 {
        return L.textIn(t.locale(), key);
    }

    /// A message with arguments, in `gpa` (a frame's memory).
    pub fn print(t: *const Texts, gpa: std.mem.Allocator, comptime key: Key, args: anytype) []const u8 {
        return L.allocIn(gpa, t.locale(), key, args) catch "…";
    }

    /// A size in decimal megabytes, as Finder writes it: "12.3 MB", "12,3 Mo".
    pub fn megabytes(t: *const Texts, gpa: std.mem.Allocator, bytes: u64) []const u8 {
        const mb = @as(f64, @floatFromInt(bytes)) / 1e6;
        return t.print(gpa, .megabytes, .{ .size = mb });
    }
};

test "the window's languages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const en: Texts = .init("en-US");
    try std.testing.expectEqualStrings("Software Update", en.text(.title));
    try std.testing.expectEqualStrings("1.5 MB", en.megabytes(a, 1_500_000));
    try std.testing.expectEqualStrings("Notes 2.0 is now available—you have 1.0. Would you like to install it now?", en.print(a, .availableMessage, .{ .app = "Notes", .version = "2.0", .current = "1.0" }));
    const de: Texts = .init("de-CH");
    try std.testing.expectEqualStrings("de", de.language());
    // In the locale's conventions: Swiss German writes a point.
    try std.testing.expectEqualStrings("12.3 MB", de.megabytes(a, 12_345_678));
    try std.testing.expectEqualStrings("12,3 MB", Texts.init("de-DE").megabytes(a, 12_345_678));
    const fr: Texts = .init("fr_FR.UTF-8");
    try std.testing.expect(std.mem.indexOf(u8, fr.megabytes(a, 1_500_000), "1,5") != null);
    const tw: Texts = .init("zh-TW");
    try std.testing.expectEqualStrings("zh-Hant", tw.language());
    const cn: Texts = .init("zh-CN");
    try std.testing.expectEqualStrings("软件更新", cn.text(.title));
    const pt: Texts = .init("pt-PT");
    try std.testing.expectEqualStrings("pt-BR", pt.language());
    const sv: Texts = .init("sv");
    try std.testing.expectEqualStrings("Software Update", sv.text(.title));
    try std.testing.expect(!(Texts.init("ar")).rtl()); // no Arabic: English, left to right
    try std.testing.expectEqualStrings("检查更新…", menuItem("zh-Hans"));
}

test "every language has every text, with English's arguments" {
    inline for (L.missing, 0..) |m, i| {
        if (m.len > 0) std.debug.print("{s} lacks {s}\n", .{ L.languages[i], m[0] });
        try std.testing.expectEqual(@as(usize, 0), m.len);
    }
    try std.testing.expectEqual(@as(usize, 15), L.languages.len);
}
