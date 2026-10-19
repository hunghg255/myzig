//! The part of the client that gives pages a catalog's messages.
const std = @import("std");
const i18n = @import("i18n.zig");

const L = i18n.Catalog(.{
    .files = .{
        .en = @embedFile("testdata/locales/en.json"),
        .de = @embedFile("testdata/locales/de.json"),
        .@"zh-Hant" = @embedFile("testdata/locales/zh-Hant.json"),
    },
});

test "typed functions per key" {
    const client = i18n.Page(L).client;
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;
    try std.testing.expect(has(client.dts, "  greeting(name: string): string;\n"));
    try std.testing.expect(has(client.dts, "  filesSelected(count: number): string;\n"));
    try std.testing.expect(has(client.dts, "  due(day: Date): string;\n"));
    try std.testing.expect(has(client.dts, "  title(): string;\n"));
    try std.testing.expect(has(client.dts, "export declare function messagesIn(locale: string): Messages;"));
    // The messages of every language, parsed, and each language's fallbacks.
    try std.testing.expect(has(client.js, "export const languages = Object.freeze([\"en\",\"de\",\"zh-Hant\"]);"));
    try std.testing.expect(has(client.js, "chains: [[0],[1,0],[2,0]]"));
    try std.testing.expect(has(client.js, "title:[\"Notes\",\"Notizen\",\"筆記\"]"));
    try std.testing.expect(has(client.js, "[4,0,0,0,[[\"=0\",\"No files selected\"],[\"one\",[[1],\" file selected\"]],[\"other\",[[1],\" files selected\"]]]]"));
    try std.testing.expect(has(client.js, "[3,0,{dateStyle:'medium'}]"));
    try std.testing.expect(has(client.js, "onlyEnglish:[\"Only in English\",null,null]"));
}
