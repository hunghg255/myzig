//! What the CPU twin (`cpu.zig`) computes: every value four lanes of 32
//! bits (`V`), floats, ints, uints and bools alike, read as their type
//! wants; scalars in lane 0. The functions are `inline`: called with the
//! types and operators known at compile time, only the arithmetic is
//! left. They follow Direct3D 11's rules where languages differ: ints
//! wrap, shifts take five bits, float to integer conversions saturate
//! (NaN to 0), division by zero gives all ones, `round` ties to even.
const std = @import("std");
const ir = @import("ir.zig");

pub const V = @Vector(4, u32);
pub const F = @Vector(4, f32);
const I = @Vector(4, i32);

pub inline fn f(v: V) F {
    return @bitCast(v);
}

pub inline fn fromF(x: F) V {
    return @bitCast(x);
}

pub inline fn scalar(x: f32) V {
    return fromF(@splat(x));
}

pub inline fn s0(v: V) f32 {
    return f(v)[0];
}

pub inline fn boolean(b: bool) V {
    return @splat(@intFromBool(b));
}

pub inline fn splat(v: V) V {
    return @splat(v[0]);
}

/// Lanes of `x` past the type's width don't count: dot products sum
/// only `n`.
inline fn sum(x: F, comptime n: u8) f32 {
    var t: f32 = x[0];
    inline for (1..n) |k| t += x[k];
    return t;
}

fn lanes(comptime func: anytype, x: F) F {
    var r: F = undefined;
    inline for (0..4) |k| r[k] = func(x[k]);
    return r;
}

fn lanes2(comptime func: anytype, x: F, y: F) F {
    var r: F = undefined;
    inline for (0..4) |k| r[k] = func(x[k], y[k]);
    return r;
}

fn pow1(x: f32, y: f32) f32 {
    // As GPUs: exp2(y log2 x), NaN below zero.
    if (x == 0) return if (y > 0) 0 else if (y == 0) std.math.nan(f32) else std.math.inf(f32);
    return @exp2(y * @log2(x));
}

fn atan2_1(y: f32, x: f32) f32 {
    return std.math.atan2(y, x);
}

fn sign1(x: f32) f32 {
    return if (x > 0) 1 else if (x < 0) -1 else 0;
}

fn roundEven(x: f32) f32 {
    const r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5) return 2 * @round(x * 0.5);
    return r;
}

/// Float to integer, as Direct3D converts: toward zero, saturating, NaN 0.
pub inline fn toInt(x: f32, comptime ty: ir.Type) u32 {
    if (ty == .i32) {
        if (!(x == x)) return 0;
        if (x >= 2147483647.0) return @bitCast(@as(i32, std.math.maxInt(i32)));
        if (x <= -2147483648.0) return @bitCast(@as(i32, std.math.minInt(i32)));
        return @bitCast(@as(i32, @intFromFloat(@trunc(x))));
    }
    if (!(x > 0)) return 0;
    if (x >= 4294967295.0) return std.math.maxInt(u32);
    return @intFromFloat(@trunc(x));
}

pub inline fn convert(comptime from: ir.Type, comptime to: ir.Type, v: V) V {
    if (from == to) return v;
    return switch (to) {
        .f32 => switch (from) {
            .i32 => scalar(@floatFromInt(@as(i32, @bitCast(v[0])))),
            .u32 => scalar(@floatFromInt(v[0])),
            .bool => scalar(@floatFromInt(v[0])),
            else => unreachable,
        },
        .i32, .u32 => switch (from) {
            .f32 => @splat(toInt(s0(v), to)),
            .i32, .u32, .bool => v,
            else => unreachable,
        },
        else => unreachable,
    };
}

pub inline fn unary(comptime op: ir.Op, comptime ty: ir.Type, a: V) V {
    return switch (op) {
        .neg => if (comptime ty.isFloat()) fromF(-f(a)) else @as(V, @splat(0)) -% a,
        .not => a ^ @as(V, @splat(1)),
        .bit_not => ~a,
        else => unreachable,
    };
}

/// `a op b`, of types `ta` and `tb` (a scalar float spreads to a vector).
pub inline fn binary(comptime op: ir.Op, comptime ta: ir.Type, comptime tb: ir.Type, a_in: V, b_in: V) V {
    const a = if (ta == .f32 and comptime tb.isVec()) splat(a_in) else a_in;
    const b = if (tb == .f32 and comptime ta.isVec()) splat(b_in) else b_in;
    if (comptime ta.isFloat()) {
        const x = f(a);
        const y = f(b);
        return switch (op) {
            .add => fromF(x + y),
            .sub => fromF(x - y),
            .mul => fromF(x * y),
            .div => fromF(x / y),
            .eq => boolean(x[0] == y[0]),
            .ne => boolean(x[0] != y[0]),
            .lt => boolean(x[0] < y[0]),
            .le => boolean(x[0] <= y[0]),
            .gt => boolean(x[0] > y[0]),
            .ge => boolean(x[0] >= y[0]),
            else => unreachable,
        };
    }
    if (ta == .bool) return switch (op) {
        .eq => boolean(a[0] == b[0]),
        .ne => boolean(a[0] != b[0]),
        else => unreachable,
    };
    const signed = ta == .i32;
    const x = a[0];
    const y = b[0];
    const xi: i32 = @bitCast(x);
    const yi: i32 = @bitCast(y);
    const r: u32 = switch (op) {
        .add => x +% y,
        .sub => x -% y,
        .mul => x *% y,
        .div => if (y == 0) std.math.maxInt(u32) else if (signed) (if (xi == std.math.minInt(i32) and yi == -1) x else @bitCast(@divTrunc(xi, yi))) else x / y,
        .rem => if (y == 0) std.math.maxInt(u32) else if (signed) (if (yi == -1) 0 else @bitCast(@rem(xi, yi))) else x % y,
        .bit_and => x & y,
        .bit_or => x | y,
        .bit_xor => x ^ y,
        .shl => x << @intCast(y & 31),
        .shr => if (signed) @bitCast(xi >> @intCast(y & 31)) else x >> @intCast(y & 31),
        .eq => @intFromBool(x == y),
        .ne => @intFromBool(x != y),
        .lt => @intFromBool(if (signed) xi < yi else x < y),
        .le => @intFromBool(if (signed) xi <= yi else x <= y),
        .gt => @intFromBool(if (signed) xi > yi else x > y),
        .ge => @intFromBool(if (signed) xi >= yi else x >= y),
        else => unreachable,
    };
    return @splat(r);
}

/// A builtin of the math (not the shader's own): args of type `ty`
/// (`gen`, as checked) and result type `ret`.
pub inline fn math(comptime b: ir.Builtin, comptime ty: ir.Type, args: []const V) V {
    const n = comptime ty.width();
    if (comptime ty.isInt()) return intMath(b, ty, args);
    const x = f(args[0]);
    return fromF(switch (b) {
        .sin => @sin(x),
        .cos => @cos(x),
        .tan => @tan(x),
        .asin => lanes(std.math.asin, x),
        .acos => lanes(std.math.acos, x),
        .atan => lanes(std.math.atan, x),
        .sinh => lanes(std.math.sinh, x),
        .cosh => lanes(std.math.cosh, x),
        .tanh => lanes(std.math.tanh, x),
        .exp => @exp(x),
        .exp2 => @exp2(x),
        .log => @log(x),
        .log2 => @log2(x),
        .sqrt => @sqrt(x),
        .inversesqrt => @as(F, @splat(1)) / @sqrt(x),
        .abs => @abs(x),
        .sign => lanes(sign1, x),
        .floor => @floor(x),
        .ceil => @ceil(x),
        .fract => x - @floor(x),
        .round => lanes(roundEven, x),
        .trunc => @trunc(x),
        .normalize => x / @as(F, @splat(@sqrt(sum(x * x, n)))),
        .pow => lanes2(pow1, x, f(args[1])),
        .atan2 => lanes2(atan2_1, x, f(args[1])),
        .mod => x - f(args[1]) * @floor(x / f(args[1])),
        .min => @min(x, f(args[1])),
        .max => @max(x, f(args[1])),
        .step => @select(f32, f(args[1]) < x, @as(F, @splat(0)), @as(F, @splat(1))),
        .clamp => @min(@max(x, f(args[1])), f(args[2])),
        .mix => x + (f(args[1]) - x) * f(args[2]),
        .smoothstep => blk: {
            const t = @min(@max((f(args[2]) - x) / (f(args[1]) - x), @as(F, @splat(0))), @as(F, @splat(1)));
            break :blk t * t * (@as(F, @splat(3)) - @as(F, @splat(2)) * t);
        },
        .length => @splat(@sqrt(sum(x * x, n))),
        .distance => blk: {
            const d = x - f(args[1]);
            break :blk @splat(@sqrt(sum(d * d, n)));
        },
        .dot => @splat(sum(x * f(args[1]), n)),
        .cross => blk: {
            const y = f(args[1]);
            break :blk .{ x[1] * y[2] - x[2] * y[1], x[2] * y[0] - x[0] * y[2], x[0] * y[1] - x[1] * y[0], 0 };
        },
        .reflect => blk: {
            const nn = f(args[1]);
            break :blk x - @as(F, @splat(2 * sum(nn * x, n))) * nn;
        },
        else => unreachable,
    });
}

inline fn intMath(comptime b: ir.Builtin, comptime ty: ir.Type, args: []const V) V {
    const signed = ty == .i32;
    const x = args[0][0];
    const xi: i32 = @bitCast(x);
    const r: u32 = switch (b) {
        .abs => if (signed) @bitCast(if (xi == std.math.minInt(i32)) xi else @as(i32, @intCast(@abs(xi)))) else x,
        .sign => if (signed) @bitCast(@as(i32, if (xi > 0) 1 else if (xi < 0) -1 else 0)) else @intFromBool(x > 0),
        .min => if (signed) @bitCast(@min(xi, @as(i32, @bitCast(args[1][0])))) else @min(x, args[1][0]),
        .max => if (signed) @bitCast(@max(xi, @as(i32, @bitCast(args[1][0])))) else @max(x, args[1][0]),
        .clamp => if (signed)
            @bitCast(@min(@max(xi, @as(i32, @bitCast(args[1][0]))), @as(i32, @bitCast(args[2][0]))))
        else
            @min(@max(x, args[1][0]), args[2][0]),
        else => unreachable,
    };
    return @splat(r);
}

test "integers wrap and convert as Direct3D's" {
    const big: V = @splat(0xffff_ffff);
    try std.testing.expectEqual(@as(u32, 0), binary(.add, .u32, .u32, big, @splat(1))[0]);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), binary(.shl, .u32, .u32, @splat(1), @splat(63))[0]);
    try std.testing.expectEqual(@as(u32, 0), toInt(-3.5, .u32));
    try std.testing.expectEqual(@as(i32, -3), @as(i32, @bitCast(toInt(-3.5, .i32))));
    try std.testing.expectEqual(@as(u32, 0), toInt(std.math.nan(f32), .i32));
    try std.testing.expectEqual(@as(f32, 2), roundEven(2.5));
    try std.testing.expectEqual(@as(f32, -4), roundEven(-3.5));
}
