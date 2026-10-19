//! The shading language's tokens, read one at a time from the source.
const std = @import("std");

pub const Kind = enum(u8) {
    eof,
    ident,
    int,
    float,
    // Keywords.
    kw_fn,
    kw_pub,
    kw_const,
    kw_var,
    kw_uniform,
    kw_return,
    kw_if,
    kw_else,
    kw_while,
    kw_for,
    kw_break,
    kw_continue,
    kw_and,
    kw_or,
    kw_true,
    kw_false,
    // Punctuation.
    lparen,
    rparen,
    lbrace,
    rbrace,
    comma,
    semicolon,
    colon,
    dot,
    dot2,
    pipe,
    eq,
    plus,
    minus,
    star,
    slash,
    percent,
    amp,
    caret,
    tilde,
    bang,
    shl,
    shr,
    eq2,
    ne,
    lt,
    le,
    gt,
    ge,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    percent_eq,
    amp_eq,
    pipe_eq,
    caret_eq,
    shl_eq,
    shr_eq,
    invalid,
};

pub const Token = struct {
    kind: Kind,
    at: u32,
    len: u32,
};

/// The keyword `word` is, or `ident`: one comparison at most (this runs
/// at compile time, where every step counts).
fn keyword(word: []const u8) Kind {
    const k: Kind, const s: []const u8 = switch (word[0]) {
        'f' => if (word.len == 2) .{ .kw_fn, "fn" } else if (word.len == 3) .{ .kw_for, "for" } else .{ .kw_false, "false" },
        'p' => .{ .kw_pub, "pub" },
        'c' => if (word.len == 5) .{ .kw_const, "const" } else .{ .kw_continue, "continue" },
        'v' => .{ .kw_var, "var" },
        'u' => .{ .kw_uniform, "uniform" },
        'r' => .{ .kw_return, "return" },
        'i' => .{ .kw_if, "if" },
        'e' => .{ .kw_else, "else" },
        'w' => .{ .kw_while, "while" },
        'b' => .{ .kw_break, "break" },
        'a' => .{ .kw_and, "and" },
        'o' => .{ .kw_or, "or" },
        't' => .{ .kw_true, "true" },
        else => return .ident,
    };
    return if (std.mem.eql(u8, word, s)) k else .ident;
}

/// The punctuation at `s` and its length.
fn punct(s: []const u8) struct { Kind, u32 } {
    const n1: u8 = if (s.len > 1) s[1] else 0;
    const n2: u8 = if (s.len > 2) s[2] else 0;
    const eq = n1 == '=';
    return switch (s[0]) {
        '(' => .{ .lparen, 1 },
        ')' => .{ .rparen, 1 },
        '{' => .{ .lbrace, 1 },
        '}' => .{ .rbrace, 1 },
        ',' => .{ .comma, 1 },
        ';' => .{ .semicolon, 1 },
        ':' => .{ .colon, 1 },
        '~' => .{ .tilde, 1 },
        '.' => if (n1 == '.') .{ .dot2, 2 } else .{ .dot, 1 },
        '=' => if (eq) .{ .eq2, 2 } else .{ .eq, 1 },
        '!' => if (eq) .{ .ne, 2 } else .{ .bang, 1 },
        '+' => if (eq) .{ .plus_eq, 2 } else .{ .plus, 1 },
        '-' => if (eq) .{ .minus_eq, 2 } else .{ .minus, 1 },
        '*' => if (eq) .{ .star_eq, 2 } else .{ .star, 1 },
        '/' => if (eq) .{ .slash_eq, 2 } else .{ .slash, 1 },
        '%' => if (eq) .{ .percent_eq, 2 } else .{ .percent, 1 },
        '&' => if (eq) .{ .amp_eq, 2 } else .{ .amp, 1 },
        '|' => if (eq) .{ .pipe_eq, 2 } else .{ .pipe, 1 },
        '^' => if (eq) .{ .caret_eq, 2 } else .{ .caret, 1 },
        '<' => if (n1 == '<') (if (n2 == '=') .{ .shl_eq, 3 } else .{ .shl, 2 }) else if (eq) .{ .le, 2 } else .{ .lt, 1 },
        '>' => if (n1 == '>') (if (n2 == '=') .{ .shr_eq, 3 } else .{ .shr, 2 }) else if (eq) .{ .ge, 2 } else .{ .gt, 1 },
        else => .{ .invalid, 1 },
    };
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// The token at `at` (after spaces and `//` comments).
pub fn next(src: []const u8, at_in: u32) Token {
    var i: usize = at_in;
    while (i < src.len) {
        if (src[i] == ' ' or src[i] == '\t' or src[i] == '\n' or src[i] == '\r') {
            i += 1;
        } else if (src[i] == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
        } else break;
    }
    const start: u32 = @intCast(i);
    if (i >= src.len) return .{ .kind = .eof, .at = start, .len = 0 };
    const ch = src[i];
    if (std.ascii.isAlphabetic(ch) or ch == '_') {
        while (i < src.len and isIdent(src[i])) i += 1;
        const word = src[start..i];
        return .{ .kind = keyword(word), .at = start, .len = @intCast(word.len) };
    }
    if (std.ascii.isDigit(ch)) return number(src, start);
    const k, const len = punct(src[i..]);
    return .{ .kind = k, .at = start, .len = len };
}

/// An int (decimal or 0x hex, `_` between digits) or a float (digits, a
/// point and digits, an exponent).
fn number(src: []const u8, start: u32) Token {
    var i: usize = start;
    if (src[i] == '0' and i + 1 < src.len and (src[i + 1] == 'x' or src[i + 1] == 'X')) {
        i += 2;
        while (i < src.len and (std.ascii.isHex(src[i]) or src[i] == '_')) i += 1;
        return .{ .kind = .int, .at = start, .len = @intCast(i - start) };
    }
    var kind: Kind = .int;
    while (i < src.len and (std.ascii.isDigit(src[i]) or src[i] == '_')) i += 1;
    // A point followed by a digit (not `0..n`).
    if (i + 1 < src.len and src[i] == '.' and std.ascii.isDigit(src[i + 1])) {
        kind = .float;
        i += 1;
        while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
    }
    if (i < src.len and (src[i] == 'e' or src[i] == 'E')) {
        var j = i + 1;
        if (j < src.len and (src[j] == '+' or src[j] == '-')) j += 1;
        if (j < src.len and std.ascii.isDigit(src[j])) {
            kind = .float;
            i = j;
            while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
        }
    }
    return .{ .kind = kind, .at = start, .len = @intCast(i - start) };
}

/// An int literal's value; null past 64 bits.
pub fn intValue(s: []const u8) ?u64 {
    var v: u64 = 0;
    var base: u64 = 10;
    var digits = s;
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        base = 16;
        digits = s[2..];
    }
    for (digits) |ch| {
        if (ch == '_') continue;
        const d: u64 = std.fmt.charToDigit(ch, @intCast(base)) catch return null;
        v = std.math.mul(u64, v, base) catch return null;
        v = std.math.add(u64, v, d) catch return null;
    }
    return v;
}

test "tokens" {
    const src = "fn f(x: f32) vec2 { // note\n return 0x1F + 2.5e3 + 1.5 >> 0..4; }";
    var at: u32 = 0;
    var kinds: [32]Kind = undefined;
    var n: usize = 0;
    while (true) {
        const t = next(src, at);
        kinds[n] = t.kind;
        n += 1;
        at = t.at + t.len;
        if (t.kind == .eof) break;
    }
    try std.testing.expectEqualSlices(Kind, &.{ .kw_fn, .ident, .lparen, .ident, .colon, .ident, .rparen, .ident, .lbrace, .kw_return, .int, .plus, .float, .plus, .float, .shr, .int, .dot2, .int, .semicolon, .rbrace, .eof }, kinds[0..n]);
    try std.testing.expectEqual(@as(?u64, 31), intValue("0x1F"));
    try std.testing.expectEqual(@as(?u64, 1000000), intValue("1_000_000"));
}
