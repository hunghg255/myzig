//! Numbers in the way of a locale, as ICU and the browsers' Intl write them:
//! its decimal and grouping separators, its grouping (the Indian 12,34,567,
//! and none of four digits where it groups from five, as Spanish and Polish
//! do), its minus and percent signs, and the digits of its numbering system.
//! Rounding is decimal, on the digits as written, so 1.005 is "1.01".
const std = @import("std");
const data = @import("locale_data.zig");
const Writer = std.Io.Writer;

pub const NumberOptions = struct {
    /// Times 100 with the locale's percent sign where its pattern puts it:
    /// 0.25 is "25%" in English, "25 %" in German, "%25" in Turkish.
    percent: bool = false,
    /// Rounds to a whole number.
    integer: bool = false,
    /// Bounds of the digits after the decimal separator: 1.5 with
    /// `min_fraction` 2 is "1.50". Null `max_fraction` is the style's
    /// default (3, none for percents), or `min_fraction` when more.
    min_fraction: u8 = 0,
    max_fraction: ?u8 = null,
    /// Pads the integer part with zeros: 7 with 2 is "07".
    min_integer: u8 = 0,
    /// Separators of thousands; false writes "12345".
    grouping: bool = true,
    /// Halfway rounds to even ("2.5" is "2"), as ICU's MessageFormat does,
    /// rather than away from zero ("3"), as Intl does.
    half_even: bool = false,
};

/// A number as decimal digits: its sign, integer digits (without leading
/// zeros, "0" for none) and fraction digits. NaN and infinities are kinds.
pub const Decimal = struct {
    neg: bool = false,
    special: enum { none, nan, inf } = .none,
    buf: [400]u8 = undefined,
    int_at: u16 = 0,
    int_len: u16 = 0,
    frac_at: u16 = 0,
    frac_len: u16 = 0,

    pub fn int(d: *const Decimal) []const u8 {
        return if (d.int_len == 0) "0" else d.buf[d.int_at..][0..d.int_len];
    }

    pub fn frac(d: *const Decimal) []const u8 {
        return d.buf[d.frac_at..][0..d.frac_len];
    }

    /// The decimal of `n`: an integer, a float (its fewest digits that read
    /// back as it), or a string of a decimal number ("1234.5", "-0.25").
    /// Null for a string that is not one.
    pub fn of(n: anytype) ?Decimal {
        const T = @TypeOf(n);
        var d: Decimal = .{};
        const len = switch (@typeInfo(T)) {
            .int, .comptime_int => (std.fmt.bufPrint(&d.buf, "{d}", .{n}) catch unreachable).len,
            .float, .comptime_float => blk: {
                const x: f64 = n;
                if (std.math.isNan(x)) return .{ .special = .nan };
                if (std.math.isInf(x)) return .{ .special = .inf, .neg = x < 0 };
                break :blk (std.fmt.bufPrint(&d.buf, "{d}", .{x}) catch return null).len;
            },
            else => blk: {
                const s: []const u8 = n;
                if (s.len > d.buf.len) return null;
                @memcpy(d.buf[0..s.len], s);
                break :blk s.len;
            },
        };
        if (!d.split(len)) return null;
        return d;
    }

    fn split(d: *Decimal, len: usize) bool {
        var i: usize = 0;
        if (len > 0 and (d.buf[0] == '-' or d.buf[0] == '+')) {
            d.neg = d.buf[0] == '-';
            i = 1;
        }
        const s = d.buf[i..len];
        const point = std.mem.indexOfScalar(u8, s, '.');
        const int_end = point orelse s.len;
        const frac_len = if (point) |p| s.len - p - 1 else 0;
        if (int_end == 0 and frac_len == 0) return false;
        for (s[0..int_end]) |c| if (!std.ascii.isDigit(c)) return false;
        if (point) |p| for (s[p + 1 ..]) |c| if (!std.ascii.isDigit(c)) return false;
        var start: usize = 0;
        while (start < int_end and s[start] == '0') start += 1;
        d.int_at = @intCast(i + start);
        d.int_len = @intCast(int_end - start);
        d.frac_at = @intCast(i + int_end + 1);
        d.frac_len = @intCast(frac_len);
        return true;
    }
};

/// Writes `n` (see `Decimal.of`) in the way of `locale`.
pub fn formatNumber(w: *Writer, locale: []const u8, n: anytype, o: NumberOptions) Writer.Error!void {
    const k = data.keyOf(locale);
    const d = Decimal.of(n) orelse return w.writeAll("NaN");
    try formatDecimal(w, k.system(), &d, o);
}

/// `formatNumber` into `buf`.
pub fn bufFormatNumber(buf: []u8, locale: []const u8, n: anytype, o: NumberOptions) Writer.Error![]u8 {
    var w: Writer = .fixed(buf);
    try formatNumber(&w, locale, n, o);
    return w.buffered();
}

/// The fraction digits options round to: [min, max].
pub fn fractionBounds(sys: *const data.System, o: NumberOptions) [2]u8 {
    const pat = if (o.percent) &sys.pct else &sys.dec;
    if (o.integer) return .{ 0, 0 };
    var max = o.max_fraction orelse 0;
    if (max == 0 and o.min_fraction == 0 and o.max_fraction == null) max = pat.max_frac;
    return .{ o.min_fraction, @max(max, o.min_fraction) };
}

/// The digits of `d` as options round them, into `buf`: integer digits,
/// then fraction digits, with `int_len` the integer ones.
pub const Rounded = struct { digits: []const u8, int_len: usize };

pub fn round(buf: []u8, d: *const Decimal, percent: bool, bounds: [2]u8, half_even: bool) Rounded {
    var n: usize = 0;
    const int_digits = d.int();
    var int_len = int_digits.len;
    for (int_digits) |c| {
        buf[n] = c;
        n += 1;
    }
    var frac = d.frac();
    if (percent) {
        // Times 100: two fraction digits move into the integer part.
        var moved: usize = 0;
        while (moved < 2) : (moved += 1) {
            buf[n] = if (frac.len > 0) frac[0] else '0';
            if (frac.len > 0) frac = frac[1..];
            n += 1;
            int_len += 1;
        }
        // Leading zeros of the integer part go.
        var lead: usize = 0;
        while (lead + 1 < int_len and buf[lead] == '0') lead += 1;
        std.mem.copyForwards(u8, buf[0 .. n - lead], buf[lead..n]);
        n -= lead;
        int_len -= lead;
    }
    const max = bounds[1];
    var keep = frac;
    var up = false;
    if (frac.len > max) {
        keep = frac[0..max];
        const drop = frac[max..];
        if (drop[0] > '5') up = true else if (drop[0] == '5') {
            const more = std.mem.trim(u8, drop[1..], "0").len > 0;
            if (more or !half_even) up = true else {
                const last = if (keep.len > 0) keep[keep.len - 1] else buf[n - 1];
                up = (last - '0') % 2 == 1;
            }
        }
    }
    for (keep) |c| {
        buf[n] = c;
        n += 1;
    }
    if (up) {
        var i = n;
        while (i > 0) {
            i -= 1;
            if (buf[i] == '9') {
                buf[i] = '0';
                continue;
            }
            buf[i] += 1;
            break;
        } else {
            std.mem.copyBackwards(u8, buf[1 .. n + 1], buf[0..n]);
            buf[0] = '1';
            n += 1;
            int_len += 1;
        }
    }
    // Trailing zeros beyond the minimum go; then zeros up to it come.
    while (n - int_len > bounds[0] and buf[n - 1] == '0') n -= 1;
    while (n - int_len < bounds[0]) : (n += 1) buf[n] = '0';
    return .{ .digits = buf[0..n], .int_len = int_len };
}

pub fn formatDecimal(w: *Writer, sys: *const data.System, d: *const Decimal, o: NumberOptions) Writer.Error!void {
    const pat = if (o.percent) &sys.pct else &sys.dec;
    switch (d.special) {
        .none => {},
        .nan => return w.print("{s}{s}{s}", .{ pat.prefix, sys.nan, pat.suffix }),
        .inf => return if (d.neg)
            w.print("{s}{s}{s}", .{ pat.neg_prefix, sys.infinity, pat.neg_suffix })
        else
            w.print("{s}{s}{s}", .{ pat.prefix, sys.infinity, pat.suffix }),
    }
    var buf: [440]u8 = undefined;
    const r = round(&buf, d, o.percent, fractionBounds(sys, o), o.half_even);
    try w.writeAll(if (d.neg) pat.neg_prefix else pat.prefix);
    try writeInteger(w, sys, pat, r.digits[0..r.int_len], o.grouping, o.min_integer);
    if (r.digits.len > r.int_len) {
        try w.writeAll(sys.decimal);
        try writeDigits(w, sys, r.digits[r.int_len..]);
    }
    try w.writeAll(if (d.neg) pat.neg_suffix else pat.suffix);
}

/// Writes ASCII digits in the system's.
pub fn writeDigits(w: *Writer, sys: *const data.System, digits: []const u8) Writer.Error!void {
    if (sys.zero == '0') return w.writeAll(digits);
    for (digits) |c| {
        var u: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(sys.zero + (c - '0'), &u) catch unreachable;
        try w.writeAll(u[0..len]);
    }
}

fn writeInteger(w: *Writer, sys: *const data.System, p: *const data.Affixes, digits: []const u8, group: bool, min_int: u8) Writer.Error!void {
    const want = @max(p.min_int, min_int);
    var pad: usize = if (digits.len < want) want - digits.len else 0;
    const n = digits.len + pad;
    if (!group or p.primary == 0 or n < p.primary + sys.min_grouping) {
        while (pad > 0) : (pad -= 1) try writeDigits(w, sys, "0");
        return writeDigits(w, sys, digits);
    }
    // The digits, padded, grouped from the right.
    var all: [440]u8 = undefined;
    @memset(all[0..pad], '0');
    @memcpy(all[pad..n], digits);
    var first = (n - p.primary) % p.secondary;
    if (first == 0) first = p.secondary;
    var pos: usize = 0;
    var size: usize = first;
    while (pos < n) {
        try writeDigits(w, sys, all[pos..][0..size]);
        pos += size;
        if (pos < n) try w.writeAll(sys.group);
        size = if (n - pos == p.primary) p.primary else p.secondary;
    }
}
