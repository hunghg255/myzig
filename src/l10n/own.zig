//! myzig's own strings for an app: its catalog's overrides and the
//! translations it ships (see l10n.zig).
const std = @import("std");
const i18n = @import("../i18n/i18n.zig");
const catalog = @import("../i18n/catalog.zig");
const render = @import("../i18n/render.zig");
const args_mod = @import("../i18n/args.zig");
const data = @import("../i18n/locale_data.zig");
const Writer = std.Io.Writer;

/// The namespace of the keys with which apps change myzig's strings.
pub const namespace = "myzig";

/// The languages myzig is translated to, besides English.
pub const translations = [_][]const u8{ "zh-Hans", "zh-Hant" };

pub const translation_files = [_][2][]const u8{
    .{ "zh-Hans", @embedFile("zh-Hans.json") },
    .{ "zh-Hant", @embedFile("zh-Hant.json") },
};

fn wanted(comptime App: ?type, comptime extra: []const []const u8, comptime lang: []const u8) bool {
    for (extra) |l| if (std.mem.eql(u8, l, lang)) return true;
    if (App) |A| for (A.languages) |l| {
        if (i18n.matchOne(l, &translations)) |i| if (std.mem.eql(u8, translations[i], lang)) return true;
    };
    return false;
}

fn filesFor(comptime App: ?type, comptime extra: []const []const u8) []const [2][]const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: []const [2][]const u8 = &.{.{ "en", @embedFile("en.json") }};
        for (translation_files) |f| if (wanted(App, extra, f[0])) {
            out = out ++ .{f};
        };
        return out;
    }
}

/// myzig's strings for an app whose catalog is `App` (or null) and that
/// ships the translations `extra` too.
pub fn For(comptime App: ?type, comptime extra: []const []const u8) type {
    return struct {
        /// myzig's strings in English and the translations the app ships.
        pub const Strings = i18n.Catalog(.{ .source = "en", .files = filesFor(App, extra) });
        pub const Key = Strings.Key;
        /// The languages of myzig's strings in this app, English first.
        pub const languages = Strings.languages;

        /// The app's override of `key` in each of its languages, its arguments
        /// indexed as myzig's own message's.
        fn overrides(comptime key: Key) [if (App) |A| A.languages.len else 0]?catalog.Message {
            const A = App orelse return .{};
            const params = Strings.arguments[@intFromEnum(key)];
            var out: [A.languages.len]?catalog.Message = undefined;
            for (0..A.languages.len) |li| {
                out[li] = if (A.override(namespace ++ "." ++ @tagName(key), li)) |m| blk: {
                    for (@import("../i18n/message.zig").args(m.nodes)) |u| if (catalog.paramIndex(params, u.name) == null)
                        @compileError("i18n: the app's myzig." ++ @tagName(key) ++ " has the argument " ++ u.name ++ ", which myzig's does not");
                    break :blk .{ .nodes = catalog.indexArgs(m.nodes, params), .plain = m.plain };
                } else null;
            }
            return out;
        }

        fn hasOverrides(comptime key: Key) bool {
            for (overrides(key)) |o| if (o != null) return true;
            return false;
        }

        /// The app's language for `locale` that overrides `key`, or null.
        fn overrideFor(locale: []const u8, comptime key: Key) ?usize {
            const A = App orelse return null;
            const ov = comptime overrides(key);
            for (A.resolve(locale).items()) |li| if (ov[li] != null) return li;
            return null;
        }

        /// myzig's string of `key`, which has no arguments, in `locale`.
        pub fn textIn(locale: []const u8, comptime key: Key) []const u8 {
            if (comptime hasOverrides(key)) if (overrideFor(locale, key)) |li| {
                const plains = comptime blk: {
                    const ov = overrides(key);
                    var out: [ov.len][]const u8 = undefined;
                    for (ov, 0..) |o, i| out[i] = if (o) |m| m.plain orelse "" else "";
                    break :blk out;
                };
                return plains[li];
            };
            return Strings.textIn(locale, key);
        }

        /// `textIn` the language the app shows.
        pub fn text(comptime key: Key) []const u8 {
            return textIn(i18n.locale(), key);
        }

        /// Writes myzig's string of `key` with `args` in `locale`.
        pub fn printIn(w: *Writer, locale: []const u8, comptime key: Key, args: anytype) Writer.Error!void {
            if (comptime hasOverrides(key)) if (overrideFor(locale, key)) |li| {
                const ps = comptime Strings.arguments[@intFromEnum(key)];
                var values: [ps.len]render.Value = undefined;
                inline for (ps, 0..) |p, i| values[i] = args_mod.value(@field(args, p.name));
                const nodes = comptime blk: {
                    const ov = overrides(key);
                    var out: [ov.len][]const @import("../i18n/message.zig").Node = undefined;
                    for (ov, 0..) |o, i| out[i] = if (o) |m| m.nodes else &.{};
                    break :blk out;
                };
                var ctx: render.Ctx = .{ .locale = locale, .key = data.keyOf(locale), .plural_lang = App.?.languages[li], .values = &values };
                return render.write(w, &ctx, nodes[li]);
            };
            return Strings.printIn(w, locale, key, args);
        }

        pub fn allocIn(gpa: std.mem.Allocator, locale: []const u8, comptime key: Key, args: anytype) error{OutOfMemory}![]u8 {
            var aw: Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            printIn(&aw.writer, locale, key, args) catch return error.OutOfMemory;
            return aw.toOwnedSlice();
        }

        /// For native UI: in the frame's memory of `c` and its language.
        pub fn t(c: anytype, comptime key: Key, args: anytype) []const u8 {
            const C = @typeInfo(@TypeOf(c)).pointer.child;
            const locale = if (@hasDecl(C, "locale")) c.locale() else i18n.locale();
            if (Strings.arguments[@intFromEnum(key)].len == 0) return textIn(locale, key);
            return allocIn(c.alloc(), locale, key, args) catch "…";
        }
    };
}
