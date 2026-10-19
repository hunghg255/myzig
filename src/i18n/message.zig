//! ICU MessageFormat, parsed at compile time, as ICU's MessagePattern reads
//! it (apostrophe mode DOUBLE_OPTIONAL, `#` only in a plural's own cases):
//!
//!     Hello, {name}!
//!     {count, plural, =0 {No files} one {# file} other {# files}}
//!     {n, plural, offset:1 =0 {Nobody} =1 {{host}} one {{host} and # other} other {{host} and # others}}
//!     {place, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}
//!     {gender, select, female {She} male {He} other {They}} replied.
//!     {price, number} {ratio, number, percent} {n, number, ::.00 group-off}
//!     {day, date, short} {day, time, short} {day, date, ::yMMMd}
//!
//! An apostrophe quotes the next brace (or `#` in a plural case) up to the
//! next lone apostrophe: '{' says {, and two apostrophes say one. Any other
//! apostrophe is itself, so "don't" needs no quoting.
const std = @import("std");
const Plural = @import("plural.zig").Plural;
const date = @import("date.zig");

pub const Node = union(enum) {
    text: []const u8,
    /// # in a plural case: the number less the offset.
    pound,
    arg: Arg,
    choice: Choice,
};

pub const ArgKind = enum { plain, number, date, time };

/// An argument written in place: {name}, {name, number, ...}, {name, date, ...}.
pub const Arg = struct {
    name: []const u8,
    /// Index into the catalog's arguments of the message, set by the catalog.
    index: u8 = 0,
    kind: ArgKind = .plain,
    number: NumberStyle = .{},
    date: DateStyle = .{},
};

/// The ICU number styles myzig reads: integer, percent, and of the
/// skeletons (::...) percent, integer, precision-integer, group-off and
/// fraction precisions (.00, .0#). Others write the default.
pub const NumberStyle = struct {
    percent: bool = false,
    integer: bool = false,
    grouping: bool = true,
    min_fraction: ?u8 = null,
    max_fraction: ?u8 = null,
};

/// A style of dates and times (short to full), or a skeleton.
pub const DateStyle = struct {
    style: date.Style = .medium,
    skeleton: []const u8 = "",
};

pub const ChoiceKind = enum { plural, selectordinal, select };

/// A plural, selectordinal or select argument and its cases.
pub const Choice = struct {
    name: []const u8,
    index: u8 = 0,
    kind: ChoiceKind,
    offset: i64 = 0,
    cases: []const Case,
};

pub const Case = struct {
    key: Key,
    nodes: []const Node,

    pub const Key = union(enum) {
        /// =N: the number N itself, as written.
        exact: []const u8,
        category: Plural,
        /// A select case, or `other`.
        word: []const u8,
    };
};

/// Where and why a message does not parse.
pub const Error = struct { offset: usize, why: []const u8 };

pub const Result = union(enum) {
    ok: []const Node,
    err: Error,
};

/// Parses a message at compile time; `Result.err` says what is wrong, so
/// that catalogs say it as a compile error and tests can check it.
pub fn parse(comptime s: []const u8) Result {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var p: Parser = .{ .s = s };
        const nodes = p.message(0, false) catch return .{ .err = p.err };
        if (p.i < s.len) return .{ .err = .{ .offset = p.i, .why = "unmatched }" } };
        return .{ .ok = nodes };
    }
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    err: Error = .{ .offset = 0, .why = "" },

    fn fail(p: *Parser, why: []const u8) error{Syntax} {
        p.err = .{ .offset = p.i, .why = why };
        return error.Syntax;
    }

    fn at(p: *const Parser, c: u8) bool {
        return p.i < p.s.len and p.s[p.i] == c;
    }

    /// Text and arguments up to a } that it leaves, or the end.
    fn message(p: *Parser, depth: usize, in_plural: bool) error{Syntax}![]const Node {
        if (depth > 32) return p.fail("arguments nest too deep");
        var nodes: []const Node = &.{};
        var text: []const u8 = "";
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == '\'') {
                text = text ++ p.quoted(in_plural);
            } else if (c == '{') {
                if (text.len > 0) nodes = nodes ++ .{Node{ .text = text }};
                text = "";
                nodes = nodes ++ .{try p.argument(depth)};
            } else if (c == '}') {
                break;
            } else if (c == '#' and in_plural) {
                if (text.len > 0) nodes = nodes ++ .{Node{ .text = text }};
                text = "";
                nodes = nodes ++ .{Node.pound};
                p.i += 1;
            } else {
                // A run of plain bytes at once.
                const start = p.i;
                while (p.i < p.s.len and !(p.s[p.i] == '\'' or p.s[p.i] == '{' or p.s[p.i] == '}' or (p.s[p.i] == '#' and in_plural))) p.i += 1;
                text = text ++ p.s[start..p.i];
            }
        }
        if (text.len > 0) nodes = nodes ++ .{Node{ .text = text }};
        return nodes;
    }

    /// An apostrophe: two say one, one before a brace (or # in a plural
    /// case) quotes up to the next lone one or the end, any other is itself.
    fn quoted(p: *Parser, in_plural: bool) []const u8 {
        p.i += 1;
        if (p.at('\'')) {
            p.i += 1;
            return "'";
        }
        if (!(p.at('{') or p.at('}') or (in_plural and p.at('#')))) return "'";
        var out: []const u8 = "";
        while (p.i < p.s.len) {
            if (p.s[p.i] == '\'') {
                if (p.i + 1 < p.s.len and p.s[p.i + 1] == '\'') {
                    out = out ++ "'";
                    p.i += 2;
                    continue;
                }
                p.i += 1;
                return out;
            }
            out = out ++ p.s[p.i .. p.i + 1];
            p.i += 1;
        }
        return out;
    }

    /// Pattern_White_Space: ASCII spaces, LRM and RLM, line separators.
    fn space(p: *Parser) void {
        while (p.i < p.s.len) {
            const rest = p.s[p.i..];
            if (std.mem.indexOfScalar(u8, " \t\n\r\x0b\x0c", rest[0]) != null) {
                p.i += 1;
            } else if (std.mem.startsWith(u8, rest, "\u{200e}") or std.mem.startsWith(u8, rest, "\u{200f}") or
                std.mem.startsWith(u8, rest, "\u{2028}") or std.mem.startsWith(u8, rest, "\u{2029}"))
            {
                p.i += 3;
            } else return;
        }
    }

    /// A name or keyword: letters, digits, _ and -.
    fn word(p: *Parser) []const u8 {
        const start = p.i;
        while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or p.s[p.i] == '_' or p.s[p.i] == '-')) p.i += 1;
        return p.s[start..p.i];
    }

    fn argument(p: *Parser, depth: usize) error{Syntax}!Node {
        p.i += 1; // {
        p.space();
        const name = p.word();
        if (name.len == 0) return p.fail("an argument has no name");
        if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_' or std.mem.indexOfScalar(u8, name, '-') != null)
            return p.fail("an argument's name is a letter or _, then letters, digits and _");
        p.space();
        if (p.i >= p.s.len) return p.fail("unclosed argument");
        if (p.at('}')) {
            p.i += 1;
            return .{ .arg = .{ .name = name } };
        }
        if (!p.at(',')) return p.fail("expected , or } after the argument's name");
        p.i += 1;
        p.space();
        const typ = p.word();
        p.space();
        if (std.mem.eql(u8, typ, "number") or std.mem.eql(u8, typ, "date") or std.mem.eql(u8, typ, "time")) {
            var a: Arg = .{ .name = name, .kind = std.meta.stringToEnum(ArgKind, typ).? };
            if (p.at(',')) {
                p.i += 1;
                const st = try p.style();
                if (st.len == 0) return p.fail("an argument has an empty style");
                if (a.kind == .number) a.number = try p.numberStyle(st) else a.date = try p.dateStyle(st);
            }
            if (!p.at('}')) return p.fail("unclosed argument");
            p.i += 1;
            return .{ .arg = a };
        }
        const kind = std.meta.stringToEnum(ChoiceKind, typ) orelse
            return p.fail(if (typ.len == 0) "an argument has no type" else "unknown argument type (want number, date, time, plural, selectordinal or select)");
        if (!p.at(',')) return p.fail("expected , after the argument's type");
        p.i += 1;
        const is_plural = kind != .select;
        var ch: Choice = .{ .name = name, .kind = kind, .cases = &.{} };
        p.space();
        if (is_plural and std.mem.startsWith(u8, p.s[p.i..], "offset:")) {
            p.i += "offset:".len;
            p.space();
            const start = p.i;
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
            if (start == p.i or p.i - start > 15) return p.fail("offset: needs a number");
            ch.offset = std.fmt.parseInt(i64, p.s[start..p.i], 10) catch unreachable;
        }
        var has_other = false;
        while (true) {
            p.space();
            if (p.i >= p.s.len) return p.fail("unclosed plural or select argument");
            if (p.at('}')) {
                p.i += 1;
                break;
            }
            var key: Case.Key = undefined;
            if (is_plural and p.at('=')) {
                p.i += 1;
                const start = p.i;
                while (p.i < p.s.len and (std.ascii.isDigit(p.s[p.i]) or p.s[p.i] == '.')) p.i += 1;
                const v = p.s[start..p.i];
                if (v.len == 0 or v[0] == '.' or v[v.len - 1] == '.' or std.mem.count(u8, v, ".") > 1)
                    return p.fail("=N needs a number");
                key = .{ .exact = v };
            } else {
                const w = p.word();
                if (w.len == 0) return p.fail("expected a case");
                if (std.mem.eql(u8, w, "other")) has_other = true;
                if (is_plural) {
                    key = .{ .category = Plural.parse(w) orelse return p.fail("not a plural category (zero, one, two, few, many, other)") };
                } else key = .{ .word = w };
            }
            for (ch.cases) |prev| if (keyEql(prev.key, key)) return p.fail("a case comes twice");
            p.space();
            if (!p.at('{')) return p.fail("expected { after a case");
            p.i += 1;
            const nodes = try p.message(depth + 1, is_plural);
            if (!p.at('}')) return p.fail("unclosed case");
            p.i += 1;
            ch.cases = ch.cases ++ .{Case{ .key = key, .nodes = nodes }};
        }
        if (!has_other) return p.fail("a plural or select argument has no other case");
        return .{ .choice = ch };
    }

    /// The style of a number, date or time up to its }.
    fn style(p: *Parser) error{Syntax}![]const u8 {
        const start = p.i;
        var depth: usize = 0;
        while (p.i < p.s.len) : (p.i += 1) {
            switch (p.s[p.i]) {
                '\'' => {
                    const end = std.mem.indexOfScalarPos(u8, p.s, p.i + 1, '\'') orelse return p.fail("unclosed quote in a style");
                    p.i = end;
                },
                '{' => depth += 1,
                '}' => {
                    if (depth == 0) return std.mem.trim(u8, p.s[start..p.i], " \t\n\r");
                    depth -= 1;
                },
                else => {},
            }
        }
        return p.fail("unclosed style");
    }

    fn numberStyle(p: *Parser, st: []const u8) error{Syntax}!NumberStyle {
        var n: NumberStyle = .{};
        const stems = if (std.mem.startsWith(u8, st, "::")) st[2..] else st;
        var it = std.mem.tokenizeAny(u8, stems, " \t");
        while (it.next()) |stem| {
            if (std.mem.eql(u8, stem, "integer") or std.mem.eql(u8, stem, "precision-integer")) {
                n.integer = true;
            } else if (std.mem.eql(u8, stem, "percent")) {
                n.percent = true;
            } else if (std.mem.eql(u8, stem, "group-off")) {
                n.grouping = false;
            } else if (stem.len > 1 and stem[0] == '.' and std.mem.trim(u8, stem[1..], "0#").len == 0) {
                n.min_fraction = @intCast(std.mem.count(u8, stem, "0"));
                n.max_fraction = @intCast(stem.len - 1);
            } else if (!std.mem.startsWith(u8, st, "::")) {
                return p.fail("unknown number style (want integer, percent or a ::skeleton)");
            }
        }
        return n;
    }

    fn dateStyle(p: *Parser, st: []const u8) error{Syntax}!DateStyle {
        if (std.mem.startsWith(u8, st, "::")) {
            const skel = std.mem.trim(u8, st[2..], " ");
            if (!date.isSkeleton(skel)) return p.fail("a skeleton of dates myzig has no patterns of (see i18n.date.skeletons)");
            return .{ .skeleton = skel };
        }
        return .{ .style = date.Style.parse(st) orelse return p.fail("unknown date style (want short, medium, long, full or a ::skeleton)") };
    }
};

fn keyEql(a: Case.Key, b: Case.Key) bool {
    return switch (a) {
        .exact => |x| b == .exact and std.mem.eql(u8, x, b.exact),
        .category => |x| b == .category and x == b.category,
        .word => |x| b == .word and std.mem.eql(u8, x, b.word),
    };
}

/// An argument of a message and how it is used: the kind of its first use
/// other than {name}.
pub const Use = enum { plain, number, date, plural, select };

pub const ArgUse = struct { name: []const u8, use: Use };

/// The arguments of `nodes`, nested ones too, in the order they come, each once.
pub fn args(comptime nodes: []const Node) []const ArgUse {
    comptime {
        var out: []const ArgUse = &.{};
        for (nodes) |n| switch (n) {
            .text, .pound => {},
            .arg => |a| out = addUse(out, a.name, switch (a.kind) {
                .plain => .plain,
                .number => .number,
                .date, .time => .date,
            }),
            .choice => |c| {
                out = addUse(out, c.name, if (c.kind == .select) .select else .plural);
                for (c.cases) |cs| for (args(cs.nodes)) |u| {
                    out = addUse(out, u.name, u.use);
                };
            },
        };
        return out;
    }
}

fn addUse(comptime list: []const ArgUse, comptime name: []const u8, comptime use: Use) []const ArgUse {
    for (list, 0..) |u, i| if (std.mem.eql(u8, u.name, name)) {
        if (u.use != .plain or use == .plain) return list;
        var copy = list[0..list.len].*;
        copy[i].use = use;
        const done = copy;
        return &done;
    };
    return list ++ .{ArgUse{ .name = name, .use = use }};
}

/// The text of a message without arguments, or null when it has some.
pub fn plainText(comptime nodes: []const Node) ?[]const u8 {
    comptime {
        var s: []const u8 = "";
        for (nodes) |n| switch (n) {
            .text => |t| s = s ++ t,
            else => return null,
        };
        return s;
    }
}
