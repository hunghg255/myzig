//! myzig's own strings: what its controls and menus say ("Undo", "Next
//! month", "Quit Notes", the names assistive technology reads), in the
//! language the app shows, from mygo's catalog of its own strings and its
//! translations (en.json, the source, and zh-Hans.json, zh-Hant.json).
//!
//! English is always there. A translation is compiled in only for an app
//! that ships its language, so an app carries none it does not show: the
//! languages of the app's catalog, which its root file names
//!
//!     pub const myzig_catalog = L; // an i18n.Catalog
//!
//! (an app with zh-TW.json gets zh-Hant), and any it names itself:
//!
//!     pub const myzig_languages = .{"zh-Hans"};
//!
//! An app changes myzig's strings, or translates them to its other
//! languages, with keys `myzig.<key>` in its catalog: `"myzig.undo":
//! "Rückgängig"`, `"myzig.menuQuitApp": "{app} beenden"`. A string resolves
//! in the app's language, its fallbacks and the app's source language among
//! the app's overrides, then among myzig's translations, then in English.
//! Saying one costs a lookup and allocates nothing (`text`).
const std = @import("std");
const root = @import("root");
const i18n = @import("../i18n/i18n.zig");
const own = @import("own.zig");
const Writer = std.Io.Writer;

pub const namespace = own.namespace;
pub const translations = own.translations;
pub const For = own.For;

/// The app's catalog and languages, as its root file names them.
const Default = own.For(if (@hasDecl(root, "myzig_catalog")) root.myzig_catalog else null, blk: {
    var out: []const []const u8 = &.{};
    if (@hasDecl(root, "myzig_languages")) for (root.myzig_languages) |l| {
        out = out ++ .{@as([]const u8, l)};
    };
    break :blk out;
});

pub const Strings = Default.Strings;
pub const Key = Default.Key;
pub const languages = Default.languages;
pub const textIn = Default.textIn;
pub const text = Default.text;
pub const printIn = Default.printIn;
pub const allocIn = Default.allocIn;
pub const t = Default.t;

test "myzig's strings" {
    try std.testing.expectEqualStrings("Undo", textIn("en", .undo));
    try std.testing.expectEqualStrings("Next month", textIn("de", .nextMonth)); // no German: English
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try printIn(&w, "en", .menuQuitApp, .{ .app = "Notes" });
    try std.testing.expectEqualStrings("Quit Notes", w.buffered());
    w = .fixed(&buf);
    try printIn(&w, "en", .colorValue, .{ .saturation = 0.5, .brightness = 1 });
    try std.testing.expectEqualStrings("50% saturation, 100% brightness", w.buffered());
}

test "every translation has every string, with the source's arguments" {
    // Checked at compile time as an app's catalogs are; a translation that
    // lacks strings says English there, which this forbids for myzig's own.
    const All = i18n.Catalog(.{ .files = @as([]const [2][]const u8, &[_][2][]const u8{.{ "en", @embedFile("en.json") }} ++ own.translation_files) });
    inline for (All.missing, 0..) |m, i| {
        if (m.len > 0) std.debug.print("{s} lacks {s}\n", .{ All.languages[i], m[0] });
        try std.testing.expectEqual(@as(usize, 0), m.len);
    }
    try std.testing.expectEqualStrings("撤销", All.textIn("zh-CN", .undo));
    try std.testing.expectEqualStrings("復原", All.textIn("zh-TW", .undo));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("退出Notes", try All.bufPrintIn(&buf, "zh-Hans", .menuQuitApp, .{ .app = "Notes" }));
}
