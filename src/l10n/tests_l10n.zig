//! myzig's strings in an app: the translations its languages link, and
//! the overrides of its catalog (`myzig.<key>`).
const std = @import("std");
const i18n = @import("../i18n/i18n.zig");

/// An app's catalog, as its root file names it (`pub const myzig_catalog`).
const App = i18n.Catalog(.{ .files = .{
    .en = @embedFile("../i18n/testdata/locales/en.json"),
    .@"zh-Hant" = @embedFile("../i18n/testdata/locales/zh-Hant.json"),
} });

test "an app's languages link myzig's translations, and its overrides win" {
    const l10n = @import("l10n.zig").For(App, &.{});
    try std.testing.expectEqual(@as(usize, 2), l10n.languages.len);
    try std.testing.expectEqualStrings("zh-Hant", l10n.languages[1]);
    try std.testing.expectEqualStrings("復原（筆記）", l10n.textIn("zh-TW", .undo));
    try std.testing.expectEqualStrings("剪下", l10n.textIn("zh-TW", .cut));
    try std.testing.expectEqualStrings("Undo", l10n.textIn("en", .undo));
    try std.testing.expectEqualStrings("Cut", l10n.textIn("zh-CN", .cut)); // zh-Hans is not linked
}

test "languages an app names itself" {
    const l10n = @import("l10n.zig").For(null, &.{"zh-Hans"});
    try std.testing.expectEqualStrings("剪切", l10n.textIn("zh-CN", .cut));
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try l10n.printIn(&w, "zh-Hans", .removeToken, .{ .token = "Ada" });
    try std.testing.expectEqualStrings("移除Ada", w.buffered());
}

test "without translations, English, and nothing negotiated" {
    const l10n = @import("l10n.zig").For(null, &.{});
    try std.testing.expectEqual(@as(usize, 1), l10n.languages.len);
    try std.testing.expectEqualStrings("Cut", l10n.textIn("zh-CN", .cut));
}
