//! Writes parsed messages (`message.zig`) with the values of their
//! arguments: plural cases picked on the number as `#` writes it by the
//! rules of the message's language, numbers and dates in the conventions of
//! the locale asked for. Not generic, so a catalog's messages share it.
const std = @import("std");
const msg = @import("message.zig");
const plural = @import("plural.zig");
const number = @import("number.zig");
const data = @import("locale_data.zig");
const pseudo = @import("pseudo.zig");
const DateTime = @import("date.zig").DateTime;
const Writer = std.Io.Writer;

/// The value of an argument.
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    uint: u64,
    float: f64,
    /// A decimal number written as it is, which keeps its fraction digits:
    /// "1.50" has two, in its plural category too.
    exact: []const u8,
    time: DateTime,

    fn decimal(v: Value) ?number.Decimal {
        return switch (v) {
            .int => |n| number.Decimal.of(n),
            .uint => |n| number.Decimal.of(n),
            .float => |n| if (std.math.isNan(n) or std.math.isInf(n)) null else number.Decimal.of(n),
            .exact => |s| number.Decimal.of(s),
            .string, .time => null,
        };
    }
};

/// How a message is written: in `locale`'s conventions, by the plural
/// rules of `plural_lang`, the language the message is written in.
pub const Ctx = struct {
    locale: []const u8,
    key: data.Key,
    plural_lang: []const u8,
    values: []const Value,
    pseudo: pseudo.Method = .none,
    /// Letters written so far, for the padding of en-XA.
    letters: usize = 0,
    /// The formatting of dates, which only catalogs whose messages have
    /// dates link (`date.zig` and its data).
    dates: ?*const fn (w: *Writer, key: *const data.Key, t: DateTime, s: msg.DateStyle, kind: msg.ArgKind) Writer.Error!void = null,
};

/// The number of the plural case being written, for #.
const Pound = struct { d: number.Decimal, exact: bool };

pub fn write(w: *Writer, ctx: *Ctx, nodes: []const msg.Node) Writer.Error!void {
    try writeNodes(w, ctx, nodes, null);
}

fn writeNodes(w: *Writer, ctx: *Ctx, nodes: []const msg.Node, pound: ?*const Pound) Writer.Error!void {
    for (nodes) |*n| switch (n.*) {
        .text => |t| ctx.letters += try pseudo.text(w, ctx.pseudo, t),
        .pound => if (pound) |p| {
            try placeholderStart(w, ctx);
            try writeNumber(w, ctx, &p.d, p.exact, .{});
            try placeholderEnd(w, ctx);
        } else try w.writeByte('#'),
        .arg => |*a| try writeArg(w, ctx, a),
        .choice => |*c| try writeChoice(w, ctx, c, pound),
    };
}

fn placeholderStart(w: *Writer, ctx: *const Ctx) Writer.Error!void {
    if (ctx.pseudo == .bidi) try w.writeAll(pseudo.rlm);
}

fn placeholderEnd(w: *Writer, ctx: *const Ctx) Writer.Error!void {
    if (ctx.pseudo == .bidi) try w.writeAll(pseudo.rlm);
}

fn writeNumber(w: *Writer, ctx: *const Ctx, d: *const number.Decimal, exact: bool, st: msg.NumberStyle) Writer.Error!void {
    var o: number.NumberOptions = .{ .percent = st.percent, .integer = st.integer, .grouping = st.grouping };
    // Integers and percents round half to even, as ICU's MessageFormat does.
    if (st.percent or st.integer) o.half_even = true;
    if (st.max_fraction) |max| {
        o.min_fraction = st.min_fraction orelse 0;
        o.max_fraction = max;
    } else if (exact and !st.integer and !st.percent) {
        const f: u8 = @intCast(@min(d.frac().len, 100));
        o.min_fraction = f;
        o.max_fraction = f;
    }
    try number.formatDecimal(w, ctx.key.system(), d, o);
}

fn writeArg(w: *Writer, ctx: *Ctx, a: *const msg.Arg) Writer.Error!void {
    const v = ctx.values[a.index];
    try placeholderStart(w, ctx);
    defer placeholderEnd(w, ctx) catch {};
    switch (v) {
        .string => |s| try w.writeAll(s),
        .time => |t| if (ctx.dates) |f| {
            try f(w, &ctx.key, t, a.date, a.kind);
        } else try w.print("{d}", .{t.unix}),
        else => {
            const d = v.decimal() orelse return w.writeAll(ctx.key.system().nan);
            try writeNumber(w, ctx, &d, v == .exact, a.number);
        },
    }
}

fn writeChoice(w: *Writer, ctx: *Ctx, c: *const msg.Choice, pound: ?*const Pound) Writer.Error!void {
    const v = ctx.values[c.index];
    if (c.kind == .select) {
        // A number selects the case of its digits: {n, select, 1 {...}}.
        var buf: [440]u8 = undefined;
        const key: []const u8 = switch (v) {
            .string => |s| s,
            .time => "",
            else => if (v.decimal()) |d| (if (d.frac().len > 0)
                std.fmt.bufPrint(&buf, "{s}{s}.{s}", .{ if (d.neg) "-" else "", d.int(), d.frac() }) catch ""
            else
                std.fmt.bufPrint(&buf, "{s}{s}", .{ if (d.neg) "-" else "", d.int() }) catch "") else "",
        };
        return writeNodes(w, ctx, findCase(c.cases, .{ .word = key }).nodes, pound);
    }
    const d = v.decimal() orelse return writeNodes(w, ctx, findCase(c.cases, .{ .category = .other }).nodes, pound);
    // An exact case matches the number itself, a category the number less
    // the offset, as # writes it: 1.0004 is written "1", whose case is one.
    if (!d.neg) if (operandsOf(&d)) |o| for (c.cases) |*cs| switch (cs.key) {
        .exact => |e| {
            const x = plural.Operands.parse(e).?;
            if (x.i == o.i and x.t == o.t and x.w == o.w) return writeNodes(w, ctx, cs.nodes, &.{ .d = d, .exact = v == .exact });
        },
        else => {},
    };
    var shown: Pound = .{ .d = d, .exact = v == .exact };
    if (c.offset != 0) shown.d = minus(&d, c.offset, v);
    var buf: [440]u8 = undefined;
    const bounds: [2]u8 = if (shown.exact) .{ @intCast(@min(shown.d.frac().len, 255)), 255 } else .{ 0, 3 };
    const r = number.round(&buf, &shown.d, false, bounds, false);
    var text: [450]u8 = undefined;
    const s = if (r.digits.len > r.int_len)
        std.fmt.bufPrint(&text, "{s}.{s}", .{ r.digits[0..r.int_len], r.digits[r.int_len..] }) catch unreachable
    else
        r.digits;
    const o = plural.Operands.parse(s) orelse plural.Operands{};
    const cat = if (c.kind == .plural) plural.cardinalCategory(ctx.plural_lang, o) else plural.ordinalCategory(ctx.plural_lang, o);
    try writeNodes(w, ctx, findCase(c.cases, .{ .category = cat }).nodes, &shown);
}

fn operandsOf(d: *const number.Decimal) ?plural.Operands {
    var text: [420]u8 = undefined;
    const s = if (d.frac().len > 0)
        std.fmt.bufPrint(&text, "{s}.{s}", .{ d.int(), d.frac() }) catch return null
    else
        d.int();
    return plural.Operands.parse(s);
}

/// `d` less `offset`, with as many fraction digits as it has.
fn minus(d: *const number.Decimal, offset: i64, v: Value) number.Decimal {
    switch (v) {
        .int => |n| return number.Decimal.of(n -| offset).?,
        .uint => |n| return number.Decimal.of(@as(i128, n) - offset).?,
        else => {},
    }
    var text: [420]u8 = undefined;
    const s = std.fmt.bufPrint(&text, "{s}{s}.{s}0", .{ if (d.neg) "-" else "", d.int(), d.frac() }) catch return d.*;
    const x = (std.fmt.parseFloat(f64, s) catch return d.*) - @as(f64, @floatFromInt(offset));
    var out: [440]u8 = undefined;
    var r = std.fmt.bufPrint(&out, "{d}", .{x}) catch return d.*;
    // As many fraction digits as d has: 2.50 less 1 is 1.50.
    const have = if (std.mem.indexOfScalar(u8, r, '.')) |p| r.len - p - 1 else 0;
    if (have < d.frac().len and r.len + d.frac().len + 1 < out.len) {
        var n = r.len;
        if (have == 0) {
            out[n] = '.';
            n += 1;
        }
        for (have..d.frac().len) |_| {
            out[n] = '0';
            n += 1;
        }
        r = out[0..n];
    }
    return number.Decimal.of(r) orelse d.*;
}

fn findCase(cases: []const msg.Case, key: msg.Case.Key) *const msg.Case {
    var other: ?*const msg.Case = null;
    for (cases) |*c| {
        switch (c.key) {
            .category => |p| {
                if (key == .category and key.category == p) return c;
                if (p == .other) other = c;
            },
            .word => |s| {
                if (key == .word and std.mem.eql(u8, s, key.word)) return c;
                if (std.mem.eql(u8, s, "other")) other = c;
            },
            .exact => {},
        }
    }
    return other.?;
}
