//! Scales: data onto a plot, in fractions of it, as mygo's `ui/chart`
//! (after d3): positions go from 0 to 1, along x from the left edge and
//! along y from the bottom up, the way values grow. `Linear` maps numbers
//! and picks round ticks (1, 2 or 5 times a power of ten apart); `Band`
//! gives each label a band, as the bars of a bar chart.
const std = @import("std");

/// A stretch along an axis, in fractions of the plot.
pub const Span = struct {
    lo: f32,
    hi: f32,

    pub fn mid(s: Span) f32 {
        return (s.lo + s.hi) / 2;
    }
};

/// A value an axis marks: where it is, and its label.
pub const Tick = struct {
    at: f32,
    value: f64,
    label: []const u8,
};

/// The smallest and largest of `values` (NaNs left out), 0 and 1 for none.
pub fn extent(values: []const f64) [2]f64 {
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    for (values) |v| {
        if (std.math.isNan(v)) continue;
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    if (lo > hi) return .{ 0, 1 };
    return .{ lo, hi };
}

pub const Linear = struct {
    lo: f64,
    hi: f64,
    /// Values outside the domain stay at its ends.
    clamp: bool = false,

    pub fn init(lo: f64, hi: f64) Linear {
        return .{ .lo = lo, .hi = hi };
    }

    pub fn at(s: Linear, v: f64) f32 {
        if (s.hi == s.lo) return 0.5;
        var f = (v - s.lo) / (s.hi - s.lo);
        if (s.clamp) f = std.math.clamp(f, 0, 1);
        return @floatCast(f);
    }

    pub fn span(s: Linear, a: f64, b: f64) Span {
        return .{ .lo = s.at(a), .hi = s.at(b) };
    }

    pub fn invert(s: Linear, f: f32) f64 {
        var v = s.lo + @as(f64, f) * (s.hi - s.lo);
        if (s.clamp) v = std.math.clamp(v, @min(s.lo, s.hi), @max(s.lo, s.hi));
        return v;
    }

    /// The domain rounded out to the round values of about `count` ticks:
    /// 0 to 87 becomes 0 to 90 for 10, and 0 to 100 for 5.
    pub fn nice(s: Linear, count: u32) Linear {
        var lo = @min(s.lo, s.hi);
        var hi = @max(s.lo, s.hi);
        var prev: f64 = 0;
        for (0..10) |_| {
            const step = spec(lo, hi, @floatFromInt(count)).inc;
            if (step == prev) break;
            if (step > 0) {
                lo = @floor(lo / step) * step;
                hi = @ceil(hi / step) * step;
            } else if (step < 0) {
                lo = @ceil(lo * step) / step;
                hi = @floor(hi * step) / step;
            } else return s;
            prev = step;
        }
        var out = s;
        if (s.hi < s.lo) {
            out.lo = hi;
            out.hi = lo;
        } else {
            out.lo = lo;
            out.hi = hi;
        }
        return out;
    }

    /// The decimals labels of `count` ticks need.
    pub fn decimals(s: Linear, count: u32) u8 {
        const step = @abs(stepOf(s.lo, s.hi, @floatFromInt(count)));
        if (!(step > 0 and step < 1)) return 0;
        var d: u8 = @intFromFloat(@max(0, -@floor(std.math.log10(step) + 1e-9)));
        const p = std.math.pow(f64, 10, @floatFromInt(d));
        if (@abs(step * p - @round(step * p)) > 1e-9) d += 1;
        return d;
    }

    /// About `count` round values within the domain, labeled with as many
    /// decimals as their step needs (labels in `gpa`, with the slice).
    pub fn ticks(s: Linear, gpa: std.mem.Allocator, count: u32) ![]Tick {
        const lo = @min(s.lo, s.hi);
        const hi = @max(s.lo, s.hi);
        if (count == 0 or !std.math.isFinite(lo) or !std.math.isFinite(hi)) return &.{};
        const dec = s.decimals(count);
        var out: std.ArrayList(Tick) = .empty;
        if (lo == hi) {
            try out.append(gpa, .{ .at = s.at(lo), .value = lo, .label = try format(gpa, lo, dec) });
            return out.items;
        }
        const sp = spec(lo, hi, @floatFromInt(count));
        if (!(sp.last >= sp.first) or !std.math.isFinite(sp.inc)) return &.{};
        const n: usize = @intFromFloat(sp.last - sp.first + 1);
        for (0..n) |k| {
            const kf: f64 = @floatFromInt(k);
            const v = if (sp.inc < 0) (sp.first + kf) / -sp.inc else (sp.first + kf) * sp.inc;
            try out.append(gpa, .{ .at = s.at(v), .value = v, .label = try format(gpa, v, dec) });
        }
        if (s.hi < s.lo) std.mem.reverse(Tick, out.items);
        return out.items;
    }
};

/// A number with `dec` decimals, never "-0".
pub fn format(gpa: std.mem.Allocator, v_in: f64, dec: u8) ![]const u8 {
    const v = if (v_in == 0) 0 else v_in;
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ v, dec }) catch return "?";
    if (std.mem.eql(u8, s, "-0") or (s.len > 1 and s[0] == '-' and std.mem.trim(u8, s[1..], "0.").len == 0)) return gpa.dupe(u8, s[1..]);
    return gpa.dupe(u8, s);
}

/// A value for reading: `dec` decimals, or (null) up to two, without
/// trailing zeros.
pub fn formatValue(gpa: std.mem.Allocator, v: f64, dec: ?u8) ![]const u8 {
    if (dec) |d| return format(gpa, v, d);
    const s = try format(gpa, v, 2);
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    const t = std.mem.trimEnd(u8, s, "0");
    return if (t[t.len - 1] == '.') t[0 .. t.len - 1] else t;
}

const e10 = @sqrt(50.0);
const e5 = @sqrt(10.0);
const e2 = @sqrt(2.0);

const Spec = struct { first: f64, last: f64, inc: f64 };

/// The first and last tick's index and the step between ticks, negative
/// for the inverse of a step below 1, so that ticks such as 0.3 come out
/// exact: d3-array's tickSpec.
fn spec(lo: f64, hi: f64, count: f64) Spec {
    const step = (hi - lo) / @max(0, count);
    const power = @floor(std.math.log10(step));
    const e = step / std.math.pow(f64, 10, power);
    const factor: f64 = if (e >= e10) 10 else if (e >= e5) 5 else if (e >= e2) 2 else 1;
    var first: f64 = undefined;
    var last: f64 = undefined;
    var inc: f64 = undefined;
    if (power < 0) {
        inc = std.math.pow(f64, 10, -power) / factor;
        first = @round(lo * inc);
        last = @round(hi * inc);
        if (first / inc < lo) first += 1;
        if (last / inc > hi) last -= 1;
        inc = -inc;
    } else {
        inc = std.math.pow(f64, 10, power) * factor;
        first = @round(lo / inc);
        last = @round(hi / inc);
        if (first * inc < lo) first += 1;
        if (last * inc > hi) last -= 1;
    }
    if (last < first and 0.5 <= count and count < 2) return spec(lo, hi, count * 2);
    return .{ .first = first, .last = last, .inc = inc };
}

fn stepOf(lo_in: f64, hi_in: f64, count: f64) f64 {
    const lo = @min(lo_in, hi_in);
    const hi = @max(lo_in, hi_in);
    var inc = spec(lo, hi, count).inc;
    if (inc < 0) inc = 1 / -inc;
    return if (hi_in < lo_in) -inc else inc;
}

/// A band for each of `count` labels, as d3's scaleBand.
pub const Band = struct {
    count: usize,
    /// Room between bands, and before the first and after the last, in
    /// fractions of a band's step.
    inner: f32 = 0,
    outer: f32 = 0,
    /// Where the bands sit in the room the outer padding leaves.
    @"align": f32 = 0.5,

    pub fn init(count: usize) Band {
        return .{ .count = count };
    }

    pub fn padding(b: Band, inner: f32, outer: f32) Band {
        var o = b;
        o.inner = std.math.clamp(inner, 0, 1);
        o.outer = @max(0, outer);
        return o;
    }

    fn step(b: Band) [2]f32 {
        const n: f32 = @floatFromInt(b.count);
        const st = 1 / @max(1, n - b.inner + 2 * b.outer);
        return .{ st, (1 - st * (n - b.inner)) * b.@"align" };
    }

    pub fn band(b: Band, i: usize) Span {
        const s = b.step();
        const lo = s[1] + s[0] * @as(f32, @floatFromInt(i));
        return .{ .lo = lo, .hi = lo + b.width() };
    }

    pub fn width(b: Band) f32 {
        return b.step()[0] * (1 - b.inner);
    }

    pub fn at(b: Band, i: usize) f32 {
        return b.band(i).mid();
    }

    /// The band whose step holds `f` (the room between bars belongs to a bar).
    pub fn index(b: Band, f: f32) ?usize {
        if (b.count == 0) return null;
        const s = b.step();
        const k = (f - s[1] + s[0] * b.inner / 2) / s[0];
        if (k < 0 or k >= @as(f32, @floatFromInt(b.count))) return null;
        return @intFromFloat(k);
    }

    /// A tick in the middle of each band, labeled with `labels`.
    pub fn ticks(b: Band, gpa: std.mem.Allocator, labels: []const []const u8) ![]Tick {
        const out = try gpa.alloc(Tick, @min(b.count, labels.len));
        for (out, 0..) |*t, i| t.* = .{ .at = b.at(i), .value = @floatFromInt(i), .label = labels[i] };
        return out;
    }
};

test "nice domains and round ticks, as d3 picks them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const y = Linear.init(0, 87).nice(10);
    try std.testing.expectEqual(@as(f64, 90), y.hi);
    try std.testing.expectEqual(@as(f64, 100), Linear.init(0, 87).nice(5).hi);
    const t = try Linear.init(0, 100).ticks(a, 5);
    try std.testing.expectEqual(@as(usize, 6), t.len);
    try std.testing.expectEqualStrings("40", t[2].label);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), t[2].at, 1e-6);
    const small = try Linear.init(0, 1).ticks(a, 5);
    try std.testing.expectEqualStrings("0.2", small[1].label);
    const odd = try Linear.init(-0.3, 0.3).ticks(a, 6);
    try std.testing.expectEqualStrings("-0.3", odd[0].label);
    try std.testing.expectEqualStrings("0.0", odd[3].label);
    const big = try Linear.init(0, 2500).ticks(a, 4);
    try std.testing.expectEqualStrings("500", big[1].label);
    try std.testing.expectEqual(@as(f64, 2500), big[big.len - 1].value);
}

test "bands, their padding, and the band under a point" {
    const b = Band.init(4).padding(0.2, 0.1);
    try std.testing.expectApproxEqAbs(b.band(1).lo - b.band(0).hi, b.width() * 0.25, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), (b.at(1) + b.at(2)) / 2, 1e-5);
    try std.testing.expectEqual(@as(?usize, 2), b.index(b.at(2)));
    try std.testing.expectEqual(@as(?usize, null), b.index(-0.5));
}
