// Generated from mygo's i18n/testdata/messages.json by src/i18n/gen/messages.py. Do not edit.
//! Messages and what they format to, which mygo's Go and its pages both check.
const std = @import("std");
const args = @import("args.zig");
const fm = @import("format_message.zig");
const msg = @import("message.zig");

fn expect(locale: []const u8, comptime message: []const u8, a: anytype, want: []const u8) !void {
    var buf: [512]u8 = undefined;
    const got = try fm.bufFormatMessage(&buf, locale, message, a);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("{s} in {s}: got \"{s}\", want \"{s}\"\n", .{ message, locale, got, want });
        return error.TestUnexpectedResult;
    }
}

test "messages as mygo formats them" {
    try expect("en", "Hello", .{}, "Hello");
    try expect("en", "", .{}, "");
    try expect("en", "Hello, {name}!", .{ .name = "Ada" }, "Hello, Ada!");
    try expect("en", "Hello, { name }!", .{ .name = "Ada" }, "Hello, Ada!");
    try expect("en", "{a}{b}", .{ .a = "x", .b = "y" }, "xy");
    try expect("en", "Is {ok}", .{ .ok = true }, "Is true");
    try expect("en", "{n} items", .{ .n = 5 }, "5 items");
    try expect("en", "{n} items", .{ .n = @as(f64, 2.5) }, "2.5 items");
    try expect("en", "{n} items", .{ .n = "1.50" }, "1.50 items");
    try expect("en", "{n, number}", .{ .n = -3 }, "-3");
    try expect("en", "{n, number, percent}", .{ .n = @as(f64, 0.25) }, "25%");
    try expect("en", "{n, number, integer}", .{ .n = @as(f64, 2.5) }, "2");
    try expect("en", "{n, number, integer}", .{ .n = @as(f64, 3.5) }, "4");
    try expect("en", "{n}", .{ .n = @as(f64, 1234.5) }, "1,234.5");
    try expect("de", "{n}", .{ .n = @as(f64, 1234.5) }, "1.234,5");
    try expect("hi", "{n}", .{ .n = 1234567 }, "12,34,567");
    try expect("es", "{n}", .{ .n = 1234 }, "1234");
    try expect("es", "{n}", .{ .n = 12345 }, "12.345");
    try expect("en", "{n}", .{ .n = @as(f64, 2.0005) }, "2.001");
    try expect("en", "{n, number}", .{ .n = args.exact("1234.50") }, "1,234.50");
    try expect("de", "{n, number, percent}", .{ .n = @as(f64, 0.25) }, "25\u{a0}%");
    try expect("en", "{n, number, ::.00}", .{ .n = @as(f64, 1.5) }, "1.50");
    try expect("en", "{n, number, ::percent .0}", .{ .n = @as(f64, 0.256) }, "25.6%");
    try expect("en", "{n, number, ::group-off}", .{ .n = 12345 }, "12345");
    try expect("en", "{n, plural, one {# file} other {# files}}", .{ .n = @as(f64, 1.0004) }, "1 file");
    try expect("de", "{n, plural, one {# Datei} other {# Dateien}}", .{ .n = 1000 }, "1.000 Dateien");
    try expect("en", "don't", .{}, "don't");
    try expect("en", "don''t", .{}, "don't");
    try expect("en", "''", .{}, "'");
    try expect("en", "'", .{}, "'");
    try expect("en", "a'b", .{}, "a'b");
    try expect("en", "'{'", .{}, "{");
    try expect("en", "'}'", .{}, "}");
    try expect("en", "'{name}'", .{}, "{name}");
    try expect("en", "'{name}' is {name}", .{ .name = "Ada" }, "{name} is Ada");
    try expect("en", "'{it''s}'", .{}, "{it's}");
    try expect("en", "'{unterminated", .{}, "{unterminated");
    try expect("en", "# is #", .{}, "# is #");
    try expect("en", "'#'", .{}, "'#'");
    try expect("en", "{n, plural, other {'#' is #}}", .{ .n = 3 }, "# is 3");
    try expect("en", "{n, plural, other {'{'#'}'}}", .{ .n = 3 }, "{3}");
    try expect("en", "{n, plural, other {it''s #}}", .{ .n = 3 }, "it's 3");
    try expect("en", "{n, plural, other {it's #}}", .{ .n = 3 }, "it's 3");
    try expect("en", "{n, plural, one {# file} other {# files}}", .{ .n = 1 }, "1 file");
    try expect("en", "{n, plural, one {# file} other {# files}}", .{ .n = 0 }, "0 files");
    try expect("en", "{n, plural, one {# file} other {# files}}", .{ .n = 2 }, "2 files");
    try expect("en", "{n, plural, one {# file} other {# files}}", .{ .n = args.exact("1.0") }, "1.0 files");
    try expect("en", "{n, plural, one {# file} other {# files}}", .{ .n = @as(f64, 1.5) }, "1.5 files");
    try expect("en", "{n, plural, one {# file} other {# files}}", .{ .n = -1 }, "-1 file");
    try expect("en", "{n, plural, =0 {No files} one {# file} other {# files}}", .{ .n = 0 }, "No files");
    try expect("en", "{n, plural, =1 {Exactly one} one {# file} other {# files}}", .{ .n = 1 }, "Exactly one");
    try expect("en", "{n, plural, =1 {Exactly one} other {# files}}", .{ .n = args.exact("1.0") }, "Exactly one");
    try expect("en", "{n, plural, =1.5 {One and a half} other {# files}}", .{ .n = @as(f64, 1.5) }, "One and a half");
    try expect("en", "{n, plural, =1 {Exactly one} other {# files}}", .{ .n = -1 }, "-1 files");
    try expect("en", "{ n , plural , one { # file } other { # files } }", .{ .n = 1 }, " 1 file ");
    try expect("en", "{n,plural,one{# file}other{# files}}", .{ .n = 7 }, "7 files");
    try expect("ru", "{n, plural, one {# файл} few {# файла} many {# файлов} other {# файла}}", .{ .n = 1 }, "1 файл");
    try expect("ru", "{n, plural, one {# файл} few {# файла} many {# файлов} other {# файла}}", .{ .n = 3 }, "3 файла");
    try expect("ru", "{n, plural, one {# файл} few {# файла} many {# файлов} other {# файла}}", .{ .n = 11 }, "11 файлов");
    try expect("ru", "{n, plural, one {# файл} few {# файла} many {# файлов} other {# файла}}", .{ .n = 21 }, "21 файл");
    try expect("ru", "{n, plural, one {# файл} few {# файла} many {# файлов} other {# файла}}", .{ .n = 22 }, "22 файла");
    try expect("fr", "{n, plural, one {# fichier} many {# de fichiers} other {# fichiers}}", .{ .n = 0 }, "0 fichier");
    try expect("zh-Hans", "{n, plural, other {# 个文件}}", .{ .n = 1 }, "1 个文件");
    try expect("zh-Hant-TW", "{n, plural, one {# file} other {# files}}", .{ .n = 1 }, "1 files");
    try expect("en", "{n, plural, offset:2 other {#}}", .{ .n = args.exact("3.50") }, "1.50");
    try expect("en", "{n, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}", .{ .n = 1 }, "1st");
    try expect("en", "{n, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}", .{ .n = 22 }, "22nd");
    try expect("en", "{n, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}", .{ .n = 103 }, "103rd");
    try expect("en", "{n, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}", .{ .n = 111 }, "111th");
    try expect("de", "{n, selectordinal, other {#.}}", .{ .n = 3 }, "3.");
    try expect("en", "{g, select, other {#}}", .{ .g = "x" }, "#");
    try expect("en", "{g, select, female {{n, plural, one {She has # file} other {She has # files}}} other {{n, plural, one {They have # file} other {They have # files}}}}", .{ .g = "female", .n = 1 }, "She has 1 file");
    try expect("en", "{g, select, female {{n, plural, one {She has # file} other {She has # files}}} other {{n, plural, one {They have # file} other {They have # files}}}}", .{ .g = "x", .n = 4 }, "They have 4 files");
    try expect("en", "{n, plural, one {{g, select, female {# woman} other {# person #}}} other {# people}}", .{ .g = "female", .n = 1 }, "# woman");
    try expect("en", "{n, plural, one {{g, select, female {# woman} other {# person}}} other {{m, plural, one {# of #} other {#s}}}}", .{ .g = "x", .n = 5, .m = 1 }, "1 of 1");
    try expect("en", "{n, plural, one {a {n} b} other {c {n} d #}}", .{ .n = 2 }, "c 2 d 2");
    try expect("en-XA", "Select files", .{}, "[Šéļéçţ ƒîļéš one two]");
    try expect("en-XA", "Hello, {name}!", .{ .name = "Ada" }, "[Ĥéļļö, Ada! one]");
    try expect("en-XA", "{n, plural, one {# file} other {# files}}", .{ .n = 2 }, "[2 ƒîļéš one]");
    try expect("ar-XB", "Select files", .{}, "\u{200f}\u{202e}Select\u{202c}\u{200f} \u{200f}\u{202e}files\u{202c}\u{200f}");
    try expect("ar-XB", "Hi {name}", .{ .name = "Ada" }, "\u{200f}\u{202e}Hi\u{202c}\u{200f} \u{200f}Ada\u{200f}");
}

test "messages that do not parse" {
    inline for (.{
        "{",
        "}",
        "a } b",
        "{}",
        "{ }",
        "{name",
        "{name, }",
        "{name, foo}",
        "{name, number, }",
        "{name, number",
        "{n, plural}",
        "{n, plural,}",
        "{n, plural, one {x}}",
        "{n, plural, single {x} other {y}}",
        "{n, plural, one {x} one {y} other {z}}",
        "{n, plural, =x {a} other {b}}",
        "{n, plural, = 1 {a} other {b}}",
        "{n, plural, one x other {y}}",
        "{n, plural, one {x} other {y}",
        "{n, plural, offset: {x} other {y}}",
        "{n, select, a {x}}",
        "{n, select, a {x} a {y} other {z}}",
        "{n, select, other {x} {y}}",
        "{01}",
        "{a-b}",
        "{n, plural, other {{}}}",
    }) |m| try std.testing.expect(comptime msg.parse(m) == .err);
}
