//! Plural categories of the Unicode CLDR: the form of a word a language uses
//! for a number. English has two for cardinal numbers ("1 file", "2 files")
//! and four for ordinal ones ("1st", "2nd", "3rd", "4th"); Japanese has one,
//! Arabic six. The rules are generated from CLDR (`plural_cardinal.zig`,
//! `plural_ordinal.zig`), a branch per distinct rule set.
const std = @import("std");
const tag_mod = @import("tag.zig");
const cardinal = @import("plural_cardinal.zig");
const ordinal = @import("plural_ordinal.zig");

pub const Plural = enum(u3) {
    zero,
    one,
    two,
    few,
    many,
    other,

    /// The category a keyword of messages names ("few"), or null.
    pub fn parse(keyword: []const u8) ?Plural {
        return std.meta.stringToEnum(Plural, keyword);
    }
};

/// A set of categories, a bit per `Plural`.
pub const Categories = struct {
    mask: u8,

    pub fn has(s: Categories, p: Plural) bool {
        return s.mask & (@as(u8, 1) << @intFromEnum(p)) != 0;
    }

    pub fn count(s: Categories) u8 {
        return @popCount(s.mask);
    }
};

/// The operands of a number that CLDR's rules read (UTS #35, Plural Operand
/// Meanings), of its absolute value as it is written: 1.50 has two visible
/// fraction digits that 1.5 does not. A part of more than 18 digits keeps
/// its last 18 plus 10^18, which equals no constant of the rules and keeps
/// their remainders right.
pub const Operands = struct {
    /// The integer digits: 3 for 3.25.
    i: u64 = 0,
    /// The visible fraction digits, with trailing zeros and without: 2 and 1 for 1.50.
    v: u64 = 0,
    w: u64 = 0,
    /// The fraction digits as an integer, with trailing zeros and without: 50 and 5 for 1.50.
    f: u64 = 0,
    t: u64 = 0,
    /// The exponent of compact notation: 6 for 1.2c6.
    c: u64 = 0,

    pub fn fromInt(n: anytype) Operands {
        const abs: u128 = @abs(@as(i128, n));
        return .{ .i = clamp(abs) };
    }

    /// The operands of a float as it is written in the fewest digits that
    /// read back as it (1.5, never 1.50); null for NaN and infinities.
    pub fn fromFloat(x: f64) ?Operands {
        if (std.math.isNan(x) or std.math.isInf(x)) return null;
        var buf: [400]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{x}) catch return null;
        return parse(s);
    }

    /// The operands of `n`: an integer, a float, a string of a decimal
    /// number, or Operands.
    pub fn of(n: anytype) ?Operands {
        const T = @TypeOf(n);
        if (T == Operands) return n;
        return switch (@typeInfo(T)) {
            .int, .comptime_int => fromInt(n),
            .float, .comptime_float => fromFloat(n),
            else => parse(n),
        };
    }

    /// Reads a decimal number: an optional sign, digits, an optional
    /// fraction, and an optional exponent of compact notation ("1.2c6",
    /// "1.2e6"). A minus sign is ignored.
    pub fn parse(text: []const u8) ?Operands {
        var s = std.mem.trim(u8, text, " ");
        if (s.len > 0 and (s[0] == '-' or s[0] == '+')) s = s[1..];
        var exp: usize = 0;
        if (std.mem.indexOfAny(u8, s, "ceCE")) |at| {
            exp = std.fmt.parseInt(u8, s[at + 1 ..], 10) catch return null;
            if (exp > 100) return null;
            s = s[0..at];
        }
        const point = std.mem.indexOfScalar(u8, s, '.');
        const int_part = if (point) |p| s[0..p] else s;
        const frac = if (point) |p| s[p + 1 ..] else "";
        if ((int_part.len == 0 and point == null) or (point != null and frac.len == 0)) return null;
        if (!digits(int_part) or !digits(frac)) return null;
        // The exponent moves the point to the right.
        const shift = @min(exp, frac.len);
        var o: Operands = .{ .c = exp, .v = frac.len - shift };
        o.i = valueOf(int_part, frac[0..shift], exp - shift);
        const rest = frac[shift..];
        o.f = valueOf(rest, "", 0);
        const trimmed = std.mem.trimEnd(u8, rest, "0");
        o.w = trimmed.len;
        o.t = valueOf(trimmed, "", 0);
        return o;
    }
};

const big: u64 = 1_000_000_000_000_000_000;

fn clamp(n: u128) u64 {
    return if (n >= big) @intCast(n % big + big) else @intCast(n);
}

fn digits(s: []const u8) bool {
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// The value of `a ++ b ++ "0" * zeros`, or its last 18 digits plus 10^18.
fn valueOf(a: []const u8, b: []const u8, zeros: usize) u64 {
    var v: u128 = 0;
    var many = false;
    for ([_][]const u8{ a, b }) |part| for (part) |c| {
        v = v * 10 + (c - '0');
        if (v >= big) {
            v %= big;
            many = true;
        }
    };
    for (0..zeros) |_| {
        v *= 10;
        if (v >= big) {
            v %= big;
            many = true;
        }
    }
    return @intCast(if (many) v + big else v);
}

/// The category of a cardinal number in the language of `tag`, as "1 file"
/// and "2 files". The rules are CLDR's for the tag, or for the tag without
/// its last subtags (pt-PT has its own, pt-BR is pt's); a language CLDR has
/// no rules for has the one category `other`.
pub fn cardinalCategory(tag: []const u8, n: Operands) Plural {
    return cardinal.rule(ruleSet(tag, &cardinal.langs, &cardinal.rules), &n);
}

/// The category of an ordinal number in the language of `tag`, as "1st" and "2nd".
pub fn ordinalCategory(tag: []const u8, n: Operands) Plural {
    return ordinal.rule(ruleSet(tag, &ordinal.langs, &ordinal.rules), &n);
}

/// The categories of cardinal numbers in the language of `tag`: one and
/// other for English.
pub fn cardinalCategories(tag: []const u8) Categories {
    return .{ .mask = cardinal.categories[ruleSet(tag, &cardinal.langs, &cardinal.rules)] };
}

pub fn ordinalCategories(tag: []const u8) Categories {
    return .{ .mask = ordinal.categories[ruleSet(tag, &ordinal.langs, &ordinal.rules)] };
}

/// The rule set of `tag`: that of the tag, or of the tag without its last
/// subtag, down to its language, as ICU looks rules up. Set 0 has `other` only.
pub fn ruleSet(tag: []const u8, langs: []const []const u8, rules: []const u8) u8 {
    const t = tag_mod.normalize(tag) orelse return 0;
    var s = t.withoutExtensions().slice();
    while (s.len > 0) {
        if (search(langs, s)) |i| return rules[i];
        s = s[0 .. std.mem.lastIndexOfScalar(u8, s, '-') orelse break];
    }
    return 0;
}

/// Finds `s` in a sorted list.
pub fn search(list: []const []const u8, s: []const u8) ?usize {
    var lo: usize = 0;
    var hi: usize = list.len;
    while (lo < hi) {
        const m = (lo + hi) / 2;
        switch (std.mem.order(u8, list[m], s)) {
            .lt => lo = m + 1,
            .gt => hi = m,
            .eq => return m,
        }
    }
    return null;
}
