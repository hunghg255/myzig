//! A JSON reader that runs at compile time, for the catalogs embedded with
//! @embedFile: objects, strings (with every escape), and the other values
//! skipped. std.json allocates, which compile time cannot.
const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    object: []const Member,
    /// Numbers, booleans, null and arrays, which catalogs do not read.
    other,

    pub fn get(v: Value, key: []const u8) ?Value {
        if (v != .object) return null;
        for (v.object) |m| if (std.mem.eql(u8, m.key, key)) return m.value;
        return null;
    }
};

pub const Member = struct { key: []const u8, value: Value };

pub const Error = struct { offset: usize, why: []const u8 };

pub const Result = union(enum) { ok: Value, err: Error };

pub fn parse(comptime s: []const u8) Result {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var p: Parser = .{ .s = s };
        // A byte order mark.
        if (std.mem.startsWith(u8, s, "\u{feff}")) p.i = 3;
        const v = p.value(0) catch return .{ .err = p.err };
        p.space();
        if (p.i != s.len) return .{ .err = .{ .offset = p.i, .why = "text after the value" } };
        return .{ .ok = v };
    }
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    err: Error = .{ .offset = 0, .why = "" },

    fn fail(p: *Parser, why: []const u8) error{Json} {
        p.err = .{ .offset = p.i, .why = why };
        return error.Json;
    }

    fn space(p: *Parser) void {
        while (p.i < p.s.len and std.mem.indexOfScalar(u8, " \t\r\n", p.s[p.i]) != null) p.i += 1;
    }

    fn value(p: *Parser, depth: usize) error{Json}!Value {
        if (depth > 64) return p.fail("nested too deep");
        p.space();
        if (p.i >= p.s.len) return p.fail("expected a value");
        switch (p.s[p.i]) {
            '{' => {
                p.i += 1;
                var members: []const Member = &.{};
                p.space();
                if (p.i < p.s.len and p.s[p.i] == '}') {
                    p.i += 1;
                    return .{ .object = members };
                }
                while (true) {
                    p.space();
                    if (p.i >= p.s.len or p.s[p.i] != '"') return p.fail("expected a key");
                    const key = try p.string();
                    p.space();
                    if (p.i >= p.s.len or p.s[p.i] != ':') return p.fail("expected :");
                    p.i += 1;
                    const v = try p.value(depth + 1);
                    for (members) |m| if (std.mem.eql(u8, m.key, key)) return p.fail("a key comes twice");
                    members = members ++ .{Member{ .key = key, .value = v }};
                    p.space();
                    if (p.i < p.s.len and p.s[p.i] == ',') {
                        p.i += 1;
                        continue;
                    }
                    if (p.i < p.s.len and p.s[p.i] == '}') {
                        p.i += 1;
                        return .{ .object = members };
                    }
                    return p.fail("expected , or }");
                }
            },
            '[' => {
                p.i += 1;
                p.space();
                if (p.i < p.s.len and p.s[p.i] == ']') {
                    p.i += 1;
                    return .other;
                }
                while (true) {
                    _ = try p.value(depth + 1);
                    p.space();
                    if (p.i < p.s.len and p.s[p.i] == ',') {
                        p.i += 1;
                        continue;
                    }
                    if (p.i < p.s.len and p.s[p.i] == ']') {
                        p.i += 1;
                        return .other;
                    }
                    return p.fail("expected , or ]");
                }
            },
            '"' => return .{ .string = try p.string() },
            else => {
                const start = p.i;
                while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or std.mem.indexOfScalar(u8, "+-.", p.s[p.i]) != null)) p.i += 1;
                const word = p.s[start..p.i];
                if (word.len == 0) return p.fail("expected a value");
                const ok = std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "false") or std.mem.eql(u8, word, "null") or
                    std.ascii.isDigit(word[0]) or word[0] == '-';
                if (!ok) return p.fail("expected a value");
                return .other;
            },
        }
    }

    fn string(p: *Parser) error{Json}![]const u8 {
        p.i += 1; // "
        var out: []const u8 = "";
        while (true) {
            const start = p.i;
            while (p.i < p.s.len and p.s[p.i] != '"' and p.s[p.i] != '\\') {
                if (p.s[p.i] < 0x20) return p.fail("a control character in a string");
                p.i += 1;
            }
            out = out ++ p.s[start..p.i];
            if (p.i >= p.s.len) return p.fail("unclosed string");
            if (p.s[p.i] == '"') {
                p.i += 1;
                return out;
            }
            p.i += 1; // backslash
            if (p.i >= p.s.len) return p.fail("unclosed string");
            const c = p.s[p.i];
            p.i += 1;
            out = out ++ switch (c) {
                '"' => "\"",
                '\\' => "\\",
                '/' => "/",
                'b' => "\x08",
                'f' => "\x0c",
                'n' => "\n",
                'r' => "\r",
                't' => "\t",
                'u' => try p.unicode(),
                else => return p.fail("an unknown escape"),
            };
        }
    }

    fn hex4(p: *Parser) error{Json}!u21 {
        if (p.i + 4 > p.s.len) return p.fail("a short \\u escape");
        const v = std.fmt.parseInt(u16, p.s[p.i .. p.i + 4], 16) catch return p.fail("a bad \\u escape");
        p.i += 4;
        return v;
    }

    fn unicode(p: *Parser) error{Json}![]const u8 {
        var cp = try p.hex4();
        if (cp >= 0xd800 and cp < 0xdc00) {
            if (!std.mem.startsWith(u8, p.s[p.i..], "\\u")) return p.fail("a lone surrogate");
            p.i += 2;
            const lo = try p.hex4();
            if (lo < 0xdc00 or lo > 0xdfff) return p.fail("a lone surrogate");
            cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
        } else if (cp >= 0xdc00 and cp <= 0xdfff) return p.fail("a lone surrogate");
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        const out = buf[0..n].*;
        return &out;
    }
};
