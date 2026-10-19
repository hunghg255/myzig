//! Catalogs of messages, checked and parsed at compile time: an ARB file
//! (JSON) per language, embedded with @embedFile, whose keys name messages
//! of ICU MessageFormat. A key the source catalog lacks, an argument a call
//! leaves out or adds, a value of the wrong type, a message that does not
//! parse, a translation with a key or an argument the source does not have:
//! each is a compile error.
//!
//!     const L = i18n.Catalog(.{
//!         .source = "en",
//!         .files = .{ .en = @embedFile("locales/en.json"), .de = @embedFile("locales/de.json") },
//!     });
//!     L.text(.title)                                    // in the language the app shows
//!     L.t(c, .filesSelected, .{ .count = n })           // into the frame's memory
//!     try L.printIn(w, "de", .greeting, .{ .name = "Ada" });
const std = @import("std");
const json = @import("json_ct.zig");
const msg = @import("message.zig");
const args_mod = @import("args.zig");
const render = @import("render.zig");
const match = @import("match.zig");
const tag = @import("tag.zig");
const data = @import("locale_data.zig");
const pseudo = @import("pseudo.zig");
const shown = @import("shown.zig");
const Writer = std.Io.Writer;

/// A message of a catalog in a language.
pub const Message = struct {
    nodes: []const msg.Node,
    /// The text of a message without arguments.
    plain: ?[]const u8,
};

/// An argument of a key: its name and type, in the order of the source's
/// placeholders, then of its message.
pub const Param = struct { name: []const u8, type: args_mod.Type };

/// A catalog's parsed file.
const File = struct {
    lang: []const u8,
    keys: []const []const u8,
    messages: []const Message,
    meta: json.Value,
};

fn fail(comptime file: []const u8, comptime fmt: []const u8, comptime a: anytype) noreturn {
    @compileError(std.fmt.comptimePrint("i18n: {s}.json: " ++ fmt, .{file} ++ a));
}

fn readFile(comptime lang: []const u8, comptime text: []const u8) File {
    comptime {
        @setEvalBranchQuota(10_000_000);
        const t = tag.Tag.parse(lang) orelse fail(lang, "the file is not named after a language", .{});
        if (!t.eql(lang)) fail(lang, "the file is named after {s}, whose canonical tag is {s}", .{ lang, t.slice() });
        const root = switch (json.parse(text)) {
            .ok => |v| v,
            .err => |e| fail(lang, "not JSON at byte {d}: {s}", .{ e.offset, e.why }),
        };
        if (root != .object) fail(lang, "the file is not a JSON object", .{});
        var keys: []const []const u8 = &.{};
        var messages: []const Message = &.{};
        for (root.object) |m| {
            if (m.key.len > 0 and m.key[0] == '@') {
                if (std.mem.eql(u8, m.key, "@@locale") and (m.value != .string or !std.mem.eql(u8, m.value.string, lang)))
                    fail(lang, "@@locale is not {s}", .{lang});
                continue;
            }
            if (!validKey(m.key)) fail(lang, "\"{s}\" is not a key: a letter, then letters, digits and _ (or <namespace>.<key>)", .{m.key});
            if (m.value != .string) fail(lang, "the message of {s} is not a string", .{m.key});
            const nodes = switch (msg.parse(m.value.string)) {
                .ok => |n| n,
                .err => |e| fail(lang, "the message of {s} does not parse at byte {d}: {s}", .{ m.key, e.offset, e.why }),
            };
            keys = keys ++ .{m.key};
            messages = messages ++ .{Message{ .nodes = nodes, .plain = msg.plainText(nodes) }};
        }
        return .{ .lang = lang, .keys = keys, .messages = messages, .meta = root };
    }
}

fn validKey(k: []const u8) bool {
    var it = std.mem.splitScalar(u8, k, '.');
    var parts: usize = 0;
    while (it.next()) |p| : (parts += 1) {
        if (p.len == 0 or !std.ascii.isAlphabetic(p[0])) return false;
        for (p) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return parts <= 2;
}

fn indexOfKey(keys: []const []const u8, k: []const u8) ?usize {
    for (keys, 0..) |x, i| if (std.mem.eql(u8, x, k)) return i;
    return null;
}

/// Sets the index of every argument of `nodes` among `params`.
pub fn indexArgs(comptime nodes: []const msg.Node, comptime params: []const Param) []const msg.Node {
    comptime {
        var out: []const msg.Node = &.{};
        for (nodes) |n| {
            var c = n;
            switch (c) {
                .arg => |*a| a.index = paramIndex(params, a.name).?,
                .choice => |*ch| {
                    ch.index = paramIndex(params, ch.name).?;
                    var cases: []const msg.Case = &.{};
                    for (ch.cases) |cs| cases = cases ++ .{msg.Case{ .key = cs.key, .nodes = indexArgs(cs.nodes, params) }};
                    ch.cases = cases;
                },
                else => {},
            }
            out = out ++ .{c};
        }
        return out;
    }
}

pub fn paramIndex(params: []const Param, name: []const u8) ?u8 {
    for (params, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return @intCast(i);
    return null;
}

/// The arguments of a key of the source: its placeholders' metadata, then
/// the arguments of its message.
fn paramsOf(comptime file: *const File, comptime key: []const u8, comptime nodes: []const msg.Node) []const Param {
    comptime {
        var params: []const Param = &.{};
        const uses = msg.args(nodes);
        const meta = file.meta.get("@" ++ key);
        if (meta) |m| if (m.get("placeholders")) |ph| if (ph == .object) for (ph.object) |p| {
            const ty: args_mod.Type = blk: {
                if (p.value.get("type")) |t| if (t == .string) break :blk args_mod.Type.ofArb(t.string) orelse
                    fail(file.lang, "the placeholder {s} of {s} has the unknown type {s}", .{ p.key, key, t.string });
                const use = for (uses) |u| (if (std.mem.eql(u8, u.name, p.key)) break u.use) else .plain;
                break :blk args_mod.Type.implied(use);
            };
            params = params ++ .{Param{ .name = p.key, .type = ty }};
        };
        for (uses) |u| if (paramIndex(params, u.name) == null) {
            params = params ++ .{Param{ .name = u.name, .type = args_mod.Type.implied(u.use) }};
        };
        for (uses) |u| if (args_mod.misuse(params[paramIndex(params, u.name).?].type, u.use)) |why|
            fail(file.lang, "the argument {s} of {s} {s}", .{ u.name, key, why });
        return params;
    }
}

/// The files of a spec: a struct of a field per language, or a tuple or a
/// slice of pairs, `.{ .{ "en", @embedFile("en.json") }, ... }`, which code
/// can put together at compile time.
fn fileSources(comptime files: anytype) []const [2][]const u8 {
    comptime {
        const F = @TypeOf(files);
        var out: []const [2][]const u8 = &.{};
        if (@typeInfo(F) == .pointer) {
            for (files) |f| out = out ++ .{.{ f[0], f[1] }};
        } else if (@typeInfo(F).@"struct".is_tuple) {
            for (0..files.len) |i| out = out ++ .{.{ files[i][0], files[i][1] }};
        } else for (@typeInfo(F).@"struct".field_names) |f| {
            out = out ++ .{.{ f, @field(files, f) }};
        }
        return out;
    }
}

/// The catalog of `spec`: `.source` (default "en"), the source language, in
/// which every message is written and to which the others fall back;
/// `.files`, a field per language named after its BCP 47 tag
/// (`.en`, `.@"zh-Hant"`) holding its JSON, or a tuple of (tag, JSON) pairs; `.pseudo` (default false) to
/// say the source's messages in the pseudo locales en-XA and ar-XB.
pub fn Catalog(comptime spec: anytype) type {
    @setEvalBranchQuota(10_000_000);
    const source: []const u8 = if (@hasField(@TypeOf(spec), "source")) spec.source else "en";
    const with_pseudo: bool = @hasField(@TypeOf(spec), "pseudo") and spec.pseudo;
    const sources = comptime fileSources(spec.files);
    const file_names = comptime blk: {
        var out: []const []const u8 = &.{};
        for (sources) |f| out = out ++ .{f[0]};
        break :blk out;
    };
    if (indexOfKey(file_names, source) == null) @compileError("i18n: the catalog has no " ++ source ++ ".json, the messages of its source language");

    // The files, the source first.
    const files: []const File = comptime blk: {
        var out: []const File = &.{readFile(source, sources[indexOfKey(file_names, source).?][1])};
        for (sources) |f| if (!std.mem.eql(u8, f[0], source)) {
            out = out ++ .{readFile(f[0], f[1])};
        };
        break :blk out;
    };
    const src = &files[0];
    const own_keys: []const []const u8 = comptime blk: {
        var out: []const []const u8 = &.{};
        for (src.keys) |k| if (std.mem.indexOfScalar(u8, k, '.') == null) {
            out = out ++ .{k};
        };
        break :blk out;
    };
    const params: []const []const Param = comptime blk: {
        var out: []const []const Param = &.{};
        for (own_keys) |k| out = out ++ .{paramsOf(src, k, src.messages[indexOfKey(src.keys, k).?].nodes)};
        break :blk out;
    };
    // table[key][lang]: the message of a key in a language, its arguments
    // indexed by the source's.
    const table: []const []const ?Message = comptime blk: {
        for (files[1..]) |*f| for (f.keys, f.messages) |k, m| {
            if (std.mem.indexOfScalar(u8, k, '.') != null) continue;
            const ki = indexOfKey(own_keys, k) orelse fail(f.lang, "the key {s} is not in {s}.json, the source", .{ k, source });
            for (msg.args(m.nodes)) |u| {
                const pi = paramIndex(params[ki], u.name) orelse
                    fail(f.lang, "the message of {s} has the argument {s}, which the source's does not", .{ k, u.name });
                if (args_mod.misuse(params[ki][pi].type, u.use)) |why| fail(f.lang, "the argument {s} of {s} {s}", .{ u.name, k, why });
            }
        };
        var rows: []const []const ?Message = &.{};
        for (own_keys, 0..) |k, ki| {
            var row: []const ?Message = &.{};
            for (files) |*f| row = row ++ .{if (indexOfKey(f.keys, k)) |i| Message{
                .nodes = indexArgs(f.messages[i].nodes, params[ki]),
                .plain = f.messages[i].plain,
            } else null};
            rows = rows ++ .{row};
        }
        break :blk rows;
    };

    return struct {
        pub const source_language = source;
        /// The languages of the catalog, the source first.
        pub const languages: []const []const u8 = blk: {
            var out: []const []const u8 = &.{};
            for (files) |f| out = out ++ .{f.lang};
            break :blk out;
        };
        /// The keys of the catalog's messages.
        pub const Key = blk: {
            var names: [own_keys.len][]const u8 = undefined;
            var values: [own_keys.len]u16 = undefined;
            for (own_keys, 0..) |k, i| {
                names[i] = k;
                values[i] = i;
            }
            break :blk @Enum(u16, .exhaustive, &names, &values);
        };
        pub const keys = own_keys;
        pub const messages = table;
        pub const arguments = params;
        pub const pseudo_locales = with_pseudo;
        /// What a translation lacks, which says the source's message: keys
        /// by language (index into `languages`). mygo's warnings.
        pub const missing: []const []const []const u8 = blk: {
            var out: []const []const []const u8 = &.{};
            for (files, 0..) |_, li| {
                var m: []const []const u8 = &.{};
                for (own_keys, 0..) |k, ki| if (table[ki][li] == null) {
                    m = m ++ .{k};
                };
                out = out ++ .{m};
            }
            break :blk out;
        };

        /// The message of a namespaced key (`myzig.undo`) in language `li`,
        /// with which an app changes a library's message.
        pub fn override(comptime key: []const u8, comptime li: usize) ?Message {
            const f = &files[li];
            const i = indexOfKey(f.keys, key) orelse return null;
            return f.messages[i];
        }

        /// The language the message of `key` says in `locale`, an index into
        /// `languages`: of the catalog's languages the one that suits it
        /// best, else the source.
        pub fn languageOf(locale: []const u8, comptime key: Key) usize {
            // One language links no negotiation.
            if (languages.len == 1) return 0;
            const row = table[@intFromEnum(key)];
            for (resolve(locale).items()) |li| if (row[li] != null) return li;
            return 0;
        }

        // The last locale resolved, per thread. Declared in the catalog's
        // type (not in a function, whose types Zig shares between
        // catalogs), since its indices are this catalog's.
        threadlocal var cache_tag: [tag.max_len]u8 = undefined;
        threadlocal var cache_len: usize = std.math.maxInt(usize);
        threadlocal var cache_result: match.Fallbacks = .{};

        pub fn resolve(locale: []const u8) match.Fallbacks {
            if (cache_len == locale.len and std.mem.eql(u8, cache_tag[0..locale.len], locale)) return cache_result;
            const f = match.fallbacks(locale, languages, source);
            if (locale.len <= tag.max_len) {
                @memcpy(cache_tag[0..locale.len], locale);
                cache_len = locale.len;
                cache_result = f;
            }
            return f;
        }

        fn checkPlain(comptime key: Key) void {
            if (params[@intFromEnum(key)].len > 0)
                @compileError("i18n: the message " ++ @tagName(key) ++ " has arguments: format it with print, alloc or t");
        }

        /// The message of `key`, which has no arguments, in `locale`:
        /// static text, which costs a lookup and allocates nothing.
        pub fn textIn(locale: []const u8, comptime key: Key) []const u8 {
            comptime checkPlain(key);
            const row = comptime table[@intFromEnum(key)];
            if (with_pseudo) switch (pseudo.methodOf(locale)) {
                .none => {},
                .accents => return comptime pseudo.comptimeText(.accents, row[0].?.plain.?),
                .bidi => return comptime pseudo.comptimeText(.bidi, row[0].?.plain.?),
            };
            const plains = comptime blk: {
                var out: [row.len]?[]const u8 = undefined;
                for (row, 0..) |m, i| out[i] = if (m) |x| x.plain else null;
                break :blk out;
            };
            if (languages.len == 1) return plains[0].?;
            for (resolve(locale).items()) |li| if (plains[li]) |p| return p;
            return plains[0].?;
        }

        /// `textIn` the language the app shows.
        pub fn text(comptime key: Key) []const u8 {
            return textIn(shown.locale(), key);
        }

        /// Writes the message of `key` in `locale` with `args`, a struct
        /// of a field per argument: `.{ .count = 3 }`.
        pub fn printIn(w: *Writer, locale: []const u8, comptime key: Key, args: anytype) Writer.Error!void {
            const ps = comptime params[@intFromEnum(key)];
            const values = comptime_check: {
                const A = @TypeOf(args);
                const fields = @typeInfo(A).@"struct".field_names;
                inline for (ps) |p| if (!@hasField(A, p.name))
                    @compileError("i18n: the message " ++ @tagName(key) ++ " needs the argument " ++ p.name);
                inline for (fields) |f| if (comptime paramIndex(ps, f) == null)
                    @compileError("i18n: the message " ++ @tagName(key) ++ " has no argument " ++ f);
                var vs: [ps.len]render.Value = undefined;
                inline for (ps, 0..) |p, i| {
                    const V = @TypeOf(@field(args, p.name));
                    if (comptime args_mod.mismatch(p.type, V)) |why|
                        @compileError("i18n: the argument " ++ p.name ++ " of " ++ @tagName(key) ++ " " ++ why);
                    vs[i] = args_mod.value(@field(args, p.name));
                }
                break :comptime_check vs;
            };
            const row = comptime table[@intFromEnum(key)];
            const method: pseudo.Method = if (with_pseudo) pseudo.methodOf(locale) else .none;
            const li = if (method != .none) 0 else languageOf(locale, key);
            var ctx: render.Ctx = .{
                .locale = if (method != .none) source else locale,
                .key = data.keyOf(if (method != .none) source else locale),
                .plural_lang = languages[li],
                .values = &values,
                .pseudo = method,
                .dates = comptime if (usesDates(ps)) &@import("render_dates.zig").write else null,
            };
            const all = comptime blk: {
                var out: [row.len][]const msg.Node = undefined;
                for (row, 0..) |m, i| out[i] = if (m) |x| x.nodes else &.{};
                break :blk out;
            };
            try pseudo.begin(w, method);
            try render.write(w, &ctx, all[li]);
            try pseudo.end(w, method, ctx.letters);
        }

        pub fn print(w: *Writer, comptime key: Key, args: anytype) Writer.Error!void {
            return printIn(w, shown.locale(), key, args);
        }

        pub fn allocIn(gpa: std.mem.Allocator, locale: []const u8, comptime key: Key, args: anytype) error{OutOfMemory}![]u8 {
            var aw: Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            printIn(&aw.writer, locale, key, args) catch return error.OutOfMemory;
            return aw.toOwnedSlice();
        }

        pub fn alloc(gpa: std.mem.Allocator, comptime key: Key, args: anytype) error{OutOfMemory}![]u8 {
            return allocIn(gpa, shown.locale(), key, args);
        }

        pub fn bufPrintIn(buf: []u8, locale: []const u8, comptime key: Key, args: anytype) Writer.Error![]u8 {
            var w: Writer = .fixed(buf);
            try printIn(&w, locale, key, args);
            return w.buffered();
        }

        /// The message for native UI, in the memory of the frame of `c` (a
        /// `ui.Context`) and in its language (`c.locale()` when it has
        /// one, else the app's): `ui.text(c, .{}, L.t(c, .filesSelected, .{ .count = n }))`.
        pub fn t(c: anytype, comptime key: Key, args: anytype) []const u8 {
            const C = @typeInfo(@TypeOf(c)).pointer.child;
            const locale = if (@hasDecl(C, "locale")) c.locale() else shown.locale();
            if (params[@intFromEnum(key)].len == 0) return textIn(locale, key);
            return allocIn(c.alloc(), locale, key, args) catch "…";
        }
    };
}

/// Whether a key has an argument that may be a date, so that its catalog
/// links the formatting of dates.
fn usesDates(comptime ps: []const Param) bool {
    for (ps) |p| if (p.type == .date_time or p.type == .object) return true;
    return false;
}
