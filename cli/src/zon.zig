//! A reader of ZON (and, through std.json, JSON) into one dynamic value,
//! which the configuration is read from. Written here rather than with
//! std.zon so that it reads the same across Zig versions, and tells where
//! a mistake is.
const std = @import("std");

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    /// Strings, and enum literals (`.foo` reads as "foo").
    string: []const u8,
    list: []const Value,
    object: []const Field,

    pub fn get(v: Value, key: []const u8) ?Value {
        if (v != .object) return null;
        for (v.object) |f| if (std.mem.eql(u8, f.key, key)) return f.value;
        return null;
    }
};

pub const Field = struct { key: []const u8, value: Value };

pub const Error = error{ OutOfMemory, Syntax };

/// Where parsing stopped, for messages.
pub const Diagnostic = struct {
    line: usize = 0,
    column: usize = 0,
    message: []const u8 = "",
};

const Parser = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    diag: *Diagnostic,

    fn fail(p: *Parser, message: []const u8) Error {
        var line: usize = 1;
        var col: usize = 1;
        for (p.src[0..@min(p.pos, p.src.len)]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else col += 1;
        }
        p.diag.* = .{ .line = line, .column = col, .message = message };
        return error.Syntax;
    }

    fn skip(p: *Parser) void {
        while (p.pos < p.src.len) {
            const c = p.src[p.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                p.pos += 1;
            } else if (std.mem.startsWith(u8, p.src[p.pos..], "//")) {
                while (p.pos < p.src.len and p.src[p.pos] != '\n') p.pos += 1;
            } else break;
        }
    }

    fn peek(p: *Parser) u8 {
        p.skip();
        return if (p.pos < p.src.len) p.src[p.pos] else 0;
    }

    fn eat(p: *Parser, s: []const u8) bool {
        p.skip();
        if (!std.mem.startsWith(u8, p.src[p.pos..], s)) return false;
        p.pos += s.len;
        return true;
    }

    fn ident(p: *Parser) ![]const u8 {
        p.skip();
        if (std.mem.startsWith(u8, p.src[p.pos..], "@\"")) {
            p.pos += 1;
            return p.string();
        }
        const start = p.pos;
        while (p.pos < p.src.len and (std.ascii.isAlphanumeric(p.src[p.pos]) or p.src[p.pos] == '_')) p.pos += 1;
        if (p.pos == start) return p.fail("expected a name");
        return p.src[start..p.pos];
    }

    fn value(p: *Parser) Error!Value {
        const c = p.peek();
        if (c == '.') {
            p.pos += 1;
            if (p.peek() == '{') {
                p.pos += 1;
                return p.container();
            }
            return .{ .string = try p.ident() };
        }
        if (c == '"') return .{ .string = try p.string() };
        if (c == '\\') return .{ .string = try p.multiline() };
        if (c == '-' or std.ascii.isDigit(c)) return p.number();
        const word = try p.ident();
        if (std.mem.eql(u8, word, "true")) return .{ .bool = true };
        if (std.mem.eql(u8, word, "false")) return .{ .bool = false };
        if (std.mem.eql(u8, word, "null")) return .null;
        return p.fail("expected a value");
    }

    /// After `.{`: fields (`.name = value`) or a list of values.
    fn container(p: *Parser) Error!Value {
        var fields: std.ArrayList(Field) = .empty;
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            if (p.eat("}")) break;
            const save = p.pos;
            var is_field = false;
            if (p.eat(".")) {
                if (p.peek() != '{') {
                    const name = p.ident() catch null;
                    if (name) |n| if (p.eat("=")) {
                        is_field = true;
                        if (items.items.len > 0) return p.fail("a list cannot have fields");
                        try fields.append(p.gpa, .{ .key = n, .value = try p.value() });
                    };
                }
            }
            if (!is_field) {
                p.pos = save;
                if (fields.items.len > 0) return p.fail("expected a field (.name = value)");
                try items.append(p.gpa, try p.value());
            }
            if (p.eat(",")) continue;
            if (p.eat("}")) break;
            return p.fail("expected , or }");
        }
        if (items.items.len > 0) return .{ .list = try items.toOwnedSlice(p.gpa) };
        return .{ .object = try fields.toOwnedSlice(p.gpa) };
    }

    fn string(p: *Parser) Error![]const u8 {
        if (!p.eat("\"")) return p.fail("expected a string");
        var out: std.ArrayList(u8) = .empty;
        while (p.pos < p.src.len) {
            const c = p.src[p.pos];
            p.pos += 1;
            switch (c) {
                '"' => return out.toOwnedSlice(p.gpa),
                '\n' => return p.fail("unterminated string"),
                '\\' => {
                    if (p.pos >= p.src.len) break;
                    const e = p.src[p.pos];
                    p.pos += 1;
                    switch (e) {
                        'n' => try out.append(p.gpa, '\n'),
                        't' => try out.append(p.gpa, '\t'),
                        'r' => try out.append(p.gpa, '\r'),
                        '\\', '"', '\'' => try out.append(p.gpa, e),
                        'x' => {
                            if (p.pos + 2 > p.src.len) return p.fail("bad \\x escape");
                            const b = std.fmt.parseInt(u8, p.src[p.pos..][0..2], 16) catch return p.fail("bad \\x escape");
                            try out.append(p.gpa, b);
                            p.pos += 2;
                        },
                        'u' => {
                            const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, '}') orelse return p.fail("bad \\u escape");
                            if (p.src[p.pos] != '{') return p.fail("bad \\u escape");
                            const cp = std.fmt.parseInt(u21, p.src[p.pos + 1 .. end], 16) catch return p.fail("bad \\u escape");
                            var buf: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(cp, &buf) catch return p.fail("bad \\u escape");
                            try out.appendSlice(p.gpa, buf[0..n]);
                            p.pos = end + 1;
                        },
                        else => return p.fail("unknown escape"),
                    }
                },
                else => try out.append(p.gpa, c),
            }
        }
        return p.fail("unterminated string");
    }

    /// Lines of `\\text`, joined by newlines.
    fn multiline(p: *Parser) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var first = true;
        while (p.eat("\\\\")) {
            if (!first) try out.append(p.gpa, '\n');
            first = false;
            const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, '\n') orelse p.src.len;
            try out.appendSlice(p.gpa, std.mem.trimEnd(u8, p.src[p.pos..end], "\r"));
            p.pos = end;
        }
        return out.toOwnedSlice(p.gpa);
    }

    fn number(p: *Parser) Error!Value {
        const start = p.pos;
        if (p.src[p.pos] == '-') p.pos += 1;
        while (p.pos < p.src.len and (std.ascii.isAlphanumeric(p.src[p.pos]) or p.src[p.pos] == '_' or p.src[p.pos] == '.' or
            ((p.src[p.pos] == '+' or p.src[p.pos] == '-') and (p.src[p.pos - 1] == 'e' or p.src[p.pos - 1] == 'E')))) p.pos += 1;
        const text = p.src[start..p.pos];
        if (std.fmt.parseInt(i64, text, 0)) |v| return .{ .int = v } else |_| {}
        if (std.fmt.parseFloat(f64, text)) |v| return .{ .float = v } else |_| {}
        return p.fail("bad number");
    }
};

/// Parses ZON. Strings and lists are allocated with `gpa` (an arena).
pub fn parse(gpa: std.mem.Allocator, src: []const u8, diag: *Diagnostic) Error!Value {
    var p: Parser = .{ .gpa = gpa, .src = src, .diag = diag };
    const v = try p.value();
    if (p.peek() != 0) return p.fail("unexpected text after the value");
    return v;
}

/// Parses JSON into the same value.
pub fn parseJson(gpa: std.mem.Allocator, src: []const u8) !Value {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, gpa, src, .{});
    return fromJson(gpa, parsed);
}

fn fromJson(gpa: std.mem.Allocator, v: std.json.Value) error{OutOfMemory}!Value {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string, .string => |s| .{ .string = s },
        .array => |a| blk: {
            const items = try gpa.alloc(Value, a.items.len);
            for (a.items, items) |x, *y| y.* = try fromJson(gpa, x);
            break :blk .{ .list = items };
        },
        .object => |o| blk: {
            const fields = try gpa.alloc(Field, o.count());
            for (o.keys(), o.values(), fields) |k, x, *f| f.* = .{ .key = k, .value = try fromJson(gpa, x) };
            break :blk .{ .object = fields };
        },
    };
}

test parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const v = try parse(arena.allocator(),
        \\// The app.
        \\.{
        \\    .name = "My \"App\"\u{e9}",
        \\    .kind = .web,
        \\    .n = 0x10, .f = -1.5e2,
        \\    .on = true, .none = null,
        \\    .list = .{ "a", "b", },
        \\    .nested = .{ .x = .{} },
        \\    .text =
        \\        \\line one
        \\        \\line two
        \\    ,
        \\}
    , &d);
    try std.testing.expectEqualStrings("My \"App\"\u{e9}", v.get("name").?.string);
    try std.testing.expectEqualStrings("web", v.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 16), v.get("n").?.int);
    try std.testing.expectEqual(@as(f64, -150), v.get("f").?.float);
    try std.testing.expect(v.get("on").?.bool);
    try std.testing.expect(v.get("none").? == .null);
    try std.testing.expectEqual(@as(usize, 2), v.get("list").?.list.len);
    try std.testing.expectEqualStrings("b", v.get("list").?.list[1].string);
    try std.testing.expectEqual(@as(usize, 0), v.get("nested").?.get("x").?.object.len);
    try std.testing.expectEqualStrings("line one\nline two", v.get("text").?.string);
}

test "parse errors tell where" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    try std.testing.expectError(error.Syntax, parse(arena.allocator(), ".{\n  .name = \"x\"\n  .version = \"1\" }", &d));
    try std.testing.expectEqual(@as(usize, 3), d.line);
    try std.testing.expectError(error.Syntax, parse(arena.allocator(), ".{ .a = \"open }", &d));
}

test parseJson {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try parseJson(arena.allocator(), "{\"name\":\"A\",\"list\":[1,2.5],\"o\":{\"b\":false}}");
    try std.testing.expectEqualStrings("A", v.get("name").?.string);
    try std.testing.expectEqual(@as(f64, 2.5), v.get("list").?.list[1].float);
    try std.testing.expect(!v.get("o").?.get("b").?.bool);
}
