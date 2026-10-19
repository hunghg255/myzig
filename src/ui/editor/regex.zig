//! Regular expressions for the code editor's find bar, matched a line at
//! a time by a backtracking machine: literals and escapes (\d \w \s \b
//! and their negations, \t \n), `.`, classes ([a-z], [^…]), anchors (^ $),
//! groups (capturing and (?:…)), alternation, and the quantifiers * + ?
//! {n} {n,} {n,m}, greedy or lazy. A budget of steps keeps a pathological
//! pattern from hanging the editor: past it, a line doesn't match.
const std = @import("std");

/// The bytes a class matches.
const Class = [256]bool;

const Inst = union(enum) {
    char: u8,
    any,
    class: u16,
    split: [2]u32,
    jmp: u32,
    save: u8,
    bol,
    eol,
    word_boundary: bool,
    match,
};

pub const max_groups = 10;

pub const Regex = struct {
    gpa: std.mem.Allocator,
    prog: std.ArrayList(Inst) = .empty,
    classes: std.ArrayList(Class) = .empty,
    groups: u8 = 1,
    fold: bool = false,

    /// Compiles `pattern`; `fold` matches letters of either case.
    pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, fold: bool) !Regex {
        var re: Regex = .{ .gpa = gpa, .fold = fold };
        errdefer re.deinit();
        var p: Parser = .{ .re = &re, .s = pattern };
        try re.emit(.{ .save = 0 });
        try p.alternation();
        if (p.i != pattern.len) return error.BadPattern;
        try re.emit(.{ .save = 1 });
        try re.emit(.match);
        return re;
    }

    pub fn deinit(re: *Regex) void {
        re.prog.deinit(re.gpa);
        re.classes.deinit(re.gpa);
    }

    fn emit(re: *Regex, inst: Inst) !void {
        try re.prog.append(re.gpa, inst);
    }

    fn pc(re: *const Regex) u32 {
        return @intCast(re.prog.items.len);
    }

    /// The first match in `s` at or after `from`: its groups' byte ranges
    /// (null for groups that took no part).
    pub fn find(re: *const Regex, s: []const u8, from: usize) ?[max_groups]?[2]usize {
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(re.gpa);
        // Steps for the whole line, whatever the starts tried.
        var budget: usize = 1_000_000;
        var start = from;
        while (start <= s.len) : (start += 1) {
            if (budget == 0) return null;
            if (re.run(&stack, s, start, &budget)) |caps| {
                var out: [max_groups]?[2]usize = @splat(null);
                for (0..re.groups) |g| {
                    if (caps[2 * g] != none and caps[2 * g + 1] != none) out[g] = .{ caps[2 * g], caps[2 * g + 1] };
                }
                return out;
            }
        }
        return null;
    }

    const none = std.math.maxInt(usize);
    const Frame = union(enum) { branch: struct { pc: u32, pos: usize }, restore: struct { slot: u8, old: usize } };

    fn eq(re: *const Regex, a: u8, b: u8) bool {
        return a == b or (re.fold and std.ascii.toLower(a) == std.ascii.toLower(b));
    }

    fn run(re: *const Regex, stack: *std.ArrayList(Frame), s: []const u8, start: usize, budget: *usize) ?[2 * max_groups]usize {
        var caps: [2 * max_groups]usize = @splat(none);
        stack.clearRetainingCapacity();
        var pc_: u32 = 0;
        var pos = start;
        while (true) {
            if (budget.* == 0) return null;
            budget.* -= 1;
            const ok = switch (re.prog.items[pc_]) {
                .char => |ch| pos < s.len and re.eq(s[pos], ch),
                .any => pos < s.len and s[pos] != '\n',
                .class => |k| pos < s.len and (re.classes.items[k][s[pos]] or
                    (re.fold and (re.classes.items[k][std.ascii.toLower(s[pos])] or re.classes.items[k][std.ascii.toUpper(s[pos])]))),
                .split => |t| {
                    stack.append(re.gpa, .{ .branch = .{ .pc = t[1], .pos = pos } }) catch return null;
                    pc_ = t[0];
                    continue;
                },
                .jmp => |t| {
                    pc_ = t;
                    continue;
                },
                .save => |slot| {
                    stack.append(re.gpa, .{ .restore = .{ .slot = slot, .old = caps[slot] } }) catch return null;
                    caps[slot] = pos;
                    pc_ += 1;
                    continue;
                },
                .bol => pos == 0,
                .eol => pos == s.len,
                .word_boundary => |want| ((pos > 0 and isWord(s[pos - 1])) != (pos < s.len and isWord(s[pos]))) == want,
                .match => return caps,
            };
            const consumes = switch (re.prog.items[pc_]) {
                .char, .any, .class => true,
                else => false,
            };
            if (ok) {
                if (consumes) pos += 1;
                pc_ += 1;
                continue;
            }
            // Back to the last choice.
            while (true) {
                const f = stack.pop() orelse return null;
                switch (f) {
                    .restore => |r| caps[r.slot] = r.old,
                    .branch => |b| {
                        pc_ = b.pc;
                        pos = b.pos;
                        break;
                    },
                }
            }
        }
    }
};

pub fn isWord(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

const Parser = struct {
    re: *Regex,
    s: []const u8,
    i: usize = 0,

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    const Error = error{ BadPattern, OutOfMemory };

    fn alternation(p: *Parser) Error!void {
        const start = p.re.pc();
        try p.sequence();
        if (p.peek() != '|') return;
        p.i += 1;
        // split(first, second) before the first branch, a jump after it.
        try p.re.prog.insert(p.re.gpa, start, .{ .split = .{ 0, 0 } });
        shift(p.re, start + 1, 1);
        try p.re.emit(.{ .jmp = 0 });
        const jmp_at = p.re.pc() - 1;
        const second = p.re.pc();
        try p.alternation();
        p.re.prog.items[start] = .{ .split = .{ start + 1, second } };
        p.re.prog.items[jmp_at] = .{ .jmp = p.re.pc() };
    }

    fn sequence(p: *Parser) Error!void {
        while (p.peek()) |ch| {
            if (ch == '|' or ch == ')') return;
            try p.repeat();
        }
    }

    fn repeat(p: *Parser) Error!void {
        const start = p.re.pc();
        try p.atom();
        const atom_end = p.re.pc();
        const ch = p.peek() orelse return;
        var min: u32 = 0;
        var max: ?u32 = null;
        switch (ch) {
            '*' => {},
            '+' => min = 1,
            '?' => max = 1,
            '{' => {
                const close = std.mem.indexOfScalarPos(u8, p.s, p.i, '}') orelse return;
                const body = p.s[p.i + 1 .. close];
                const comma = std.mem.indexOfScalar(u8, body, ',');
                min = std.fmt.parseInt(u32, body[0 .. comma orelse body.len], 10) catch return error.BadPattern;
                max = if (comma) |cm| (if (cm + 1 == body.len) null else std.fmt.parseInt(u32, body[cm + 1 ..], 10) catch return error.BadPattern) else min;
                if (min > 1000 or (max != null and max.? > 1000)) return error.BadPattern;
                p.i = close;
            },
            else => return,
        }
        p.i += 1;
        var greedy = true;
        if (p.peek() == '?') {
            greedy = false;
            p.i += 1;
        }
        // The atom's code, repeated: `min` copies, then optional ones.
        const body = try p.re.gpa.dupe(Inst, p.re.prog.items[start..atom_end]);
        defer p.re.gpa.free(body);
        p.re.prog.shrinkRetainingCapacity(start);
        for (0..min) |_| try p.copy(body, start);
        if (max) |mx| {
            var ends: std.ArrayList(u32) = .empty;
            defer ends.deinit(p.re.gpa);
            for (min..mx) |_| {
                try ends.append(p.re.gpa, p.re.pc());
                try p.re.emit(.{ .split = .{ 0, 0 } });
                try p.copy(body, start);
            }
            const end = p.re.pc();
            for (ends.items) |at| p.re.prog.items[at] = if (greedy) .{ .split = .{ at + 1, end } } else .{ .split = .{ end, at + 1 } };
        } else {
            const loop = p.re.pc();
            try p.re.emit(.{ .split = .{ 0, 0 } });
            try p.copy(body, start);
            try p.re.emit(.{ .jmp = loop });
            const end = p.re.pc();
            p.re.prog.items[loop] = if (greedy) .{ .split = .{ loop + 1, end } } else .{ .split = .{ end, loop + 1 } };
        }
    }

    /// Appends code compiled at address `from`, its jumps moved with it
    /// (they all land inside it, or at its end).
    fn copy(p: *Parser, body: []const Inst, from: u32) !void {
        const base = p.re.pc();
        for (body) |inst| try p.re.emit(switch (inst) {
            .split => |t| .{ .split = .{ t[0] - from + base, t[1] - from + base } },
            .jmp => |t| .{ .jmp = t - from + base },
            else => inst,
        });
    }

    fn atom(p: *Parser) Error!void {
        const ch = p.peek() orelse return error.BadPattern;
        p.i += 1;
        switch (ch) {
            '.' => try p.re.emit(.any),
            '^' => try p.re.emit(.bol),
            '$' => try p.re.emit(.eol),
            '(' => {
                var group: ?u8 = null;
                if (std.mem.startsWith(u8, p.s[p.i..], "?:")) {
                    p.i += 2;
                } else {
                    if (p.re.groups >= max_groups) return error.BadPattern;
                    group = p.re.groups;
                    p.re.groups += 1;
                }
                if (group) |g| try p.re.emit(.{ .save = 2 * g });
                try p.alternation();
                if (p.peek() != ')') return error.BadPattern;
                p.i += 1;
                if (group) |g| try p.re.emit(.{ .save = 2 * g + 1 });
            },
            '[' => try p.class(),
            '\\' => try p.escape(false),
            '*', '+', '?', ')' => return error.BadPattern,
            else => try p.re.emit(.{ .char = ch }),
        }
    }

    fn newClass(p: *Parser) !u16 {
        try p.re.classes.append(p.re.gpa, @as(Class, @splat(false)));
        return @intCast(p.re.classes.items.len - 1);
    }

    fn escapeClass(set: *Class, e: u8) bool {
        switch (std.ascii.toLower(e)) {
            'd' => for ('0'..'9' + 1) |b| {
                set[b] = true;
            },
            'w' => for (0..256) |b| {
                if (isWord(@intCast(b))) set[b] = true;
            },
            's' => for (" \t\r\n\x0b\x0c") |b| {
                set[b] = true;
            },
            else => return false,
        }
        if (std.ascii.isUpper(e)) for (set) |*b| {
            b.* = !b.*;
        };
        return true;
    }

    fn escape(p: *Parser, _: bool) !void {
        const e = p.peek() orelse return error.BadPattern;
        p.i += 1;
        switch (e) {
            'b' => return p.re.emit(.{ .word_boundary = true }),
            'B' => return p.re.emit(.{ .word_boundary = false }),
            't' => return p.re.emit(.{ .char = '\t' }),
            'n' => return p.re.emit(.{ .char = '\n' }),
            else => {},
        }
        var set: Class = @as(Class, @splat(false));
        if (escapeClass(&set, e)) {
            const k = try p.newClass();
            p.re.classes.items[k] = set;
            return p.re.emit(.{ .class = k });
        }
        try p.re.emit(.{ .char = e });
    }

    fn class(p: *Parser) !void {
        var set: Class = @as(Class, @splat(false));
        var negate = false;
        if (p.peek() == '^') {
            negate = true;
            p.i += 1;
        }
        var first = true;
        while (p.peek()) |ch| {
            if (ch == ']' and !first) break;
            first = false;
            p.i += 1;
            var lo = ch;
            if (ch == '\\') {
                const e = p.peek() orelse return error.BadPattern;
                p.i += 1;
                if (escapeClass(&set, e)) continue;
                lo = switch (e) {
                    't' => '\t',
                    'n' => '\n',
                    else => e,
                };
            }
            if (p.peek() == '-' and p.i + 1 < p.s.len and p.s[p.i + 1] != ']') {
                const hi = p.s[p.i + 1];
                p.i += 2;
                if (hi < lo) return error.BadPattern;
                for (lo..@as(usize, hi) + 1) |b| {
                    set[b] = true;
                }
            } else set[lo] = true;
        }
        if (p.peek() != ']') return error.BadPattern;
        p.i += 1;
        if (negate) for (&set) |*b| {
            b.* = !b.*;
        };
        const k = try p.newClass();
        p.re.classes.items[k] = set;
        try p.re.emit(.{ .class = k });
    }
};

/// Moves the jumps at or past `from` by `by` (code was inserted).
fn shift(re: *Regex, from: u32, by: u32) void {
    for (re.prog.items[from..]) |*inst| switch (inst.*) {
        .split => |t| inst.* = .{ .split = .{ if (t[0] >= from - by) t[0] + by else t[0], if (t[1] >= from - by) t[1] + by else t[1] } },
        .jmp => |t| inst.* = .{ .jmp = if (t >= from - by) t + by else t },
        else => {},
    };
}

const testing = std.testing;

fn expectMatch(pattern: []const u8, s: []const u8, want: ?[2]usize) !void {
    var re = try Regex.compile(testing.allocator, pattern, false);
    defer re.deinit();
    const m = re.find(s, 0);
    if (want) |w| {
        try testing.expectEqual(w, m.?[0].?);
    } else try testing.expect(m == null);
}

test "regular expressions" {
    try expectMatch("b+", "aabbbc", .{ 2, 5 });
    try expectMatch("a.c", "xxabc", .{ 2, 5 });
    try expectMatch("^ab", "cab", null);
    try expectMatch("ab$", "cab", .{ 1, 3 });
    try expectMatch("[0-9]+", "id 42!", .{ 3, 5 });
    try expectMatch("[^a-z ]+", "ab 12x", .{ 3, 5 });
    try expectMatch("\\bfoo\\b", "foobar foo", .{ 7, 10 });
    try expectMatch("colou?r", "the color", .{ 4, 9 });
    try expectMatch("(ab)+c", "xababc", .{ 1, 6 });
    try expectMatch("cat|dog", "hotdog", .{ 3, 6 });
    try expectMatch("a(b|c)*d", "xabcbcd", .{ 1, 7 });
    try expectMatch("x{2,3}", "xxxxx", .{ 0, 3 });
    try expectMatch("<.+?>", "<a><b>", .{ 0, 3 });
    try expectMatch("\\d\\s\\w", "a 1 b", .{ 2, 5 });
    try expectMatch("(?:ab){2}", "abab", .{ 0, 4 });
    try testing.expectError(error.BadPattern, Regex.compile(testing.allocator, "(ab", false));
    try testing.expectError(error.BadPattern, Regex.compile(testing.allocator, "*a", false));
    var re = try Regex.compile(testing.allocator, "(\\w+)@(\\w+)", true);
    defer re.deinit();
    const m = re.find("mail ADA@host", 0).?;
    try testing.expectEqual([2]usize{ 5, 8 }, m[1].?);
    try testing.expectEqual([2]usize{ 9, 13 }, m[2].?);
    // A pathological pattern gives up rather than hanging.
    var bad = try Regex.compile(testing.allocator, "(a*)*b", false);
    defer bad.deinit();
    try testing.expect(bad.find("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0) == null);
}
