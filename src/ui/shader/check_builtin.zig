//! The builtins' signatures, and calls to them checked: GLSL's functions
//! over a "generic" type (a float or a vector of floats, some also
//! integers), with the arguments that may be scalars spread to the
//! vector, as every backend then takes them.
const std = @import("std");
const ir = @import("ir.zig");
const Checker = @import("check.zig").Checker;
const coerce = @import("check_expr.zig").coerce;

const Error = error{Shader};
const T = ir.Type;
const B = ir.Builtin;

const Arg = enum { gen, gen_or_scalar, vec2 };
const Ret = enum { same, f32, vec2, vec3, vec4 };

const Sig = struct {
    args: []const Arg,
    ret: Ret = .same,
    /// Integers too, not only floats.
    ints: bool = false,
};

fn sig(b: B) Sig {
    return switch (b) {
        .abs, .sign => .{ .args = &.{.gen}, .ints = true },
        .pow, .atan2, .reflect => .{ .args = &.{ .gen, .gen } },
        .mod => .{ .args = &.{ .gen, .gen_or_scalar } },
        .min, .max => .{ .args = &.{ .gen, .gen_or_scalar }, .ints = true },
        .step => .{ .args = &.{ .gen_or_scalar, .gen } },
        .clamp => .{ .args = &.{ .gen, .gen_or_scalar, .gen_or_scalar }, .ints = true },
        .mix => .{ .args = &.{ .gen, .gen, .gen_or_scalar } },
        .smoothstep => .{ .args = &.{ .gen_or_scalar, .gen_or_scalar, .gen } },
        .length => .{ .args = &.{.gen}, .ret = .f32 },
        .distance, .dot => .{ .args = &.{ .gen, .gen }, .ret = .f32 },
        .cross => .{ .args = &.{ .gen, .gen }, .ret = .vec3 },
        .size, .pixel => .{ .args = &.{}, .ret = .vec2 },
        .pixel_scale => .{ .args = &.{}, .ret = .f32 },
        .backdrop => .{ .args = &.{.vec2}, .ret = .vec4 },
        else => .{ .args = &.{.gen} },
    };
}

pub fn builtin(c: *Checker, n: u16, b: B, args: []u16) Error!u16 {
    const p = c.p;
    const at = p.nodes[n].str.at;
    const name = @tagName(b);
    const s = sig(b);
    if (args.len != s.args.len) return p.fail(at, "{s}() takes {d} arguments, not {d}", .{ name, s.args.len, args.len });
    // The generic type: the vector among the arguments, else a scalar.
    var gen: T = .void;
    var lit: T = .void;
    for (args, s.args) |a, kind| {
        const t = p.nodes[a].ty;
        if (kind == .vec2) continue;
        if (t.isLit()) {
            if (lit != .lit_float) lit = t;
        } else if (t.isVec()) {
            if (gen.isVec() and gen != t) return p.fail(at, "{s}() of a {s} and a {s}", .{ name, gen.name(), t.name() });
            gen = t;
        } else if (gen == .void) gen = t;
    }
    if (gen == .void) gen = switch (lit) {
        .lit_int => if (s.ints) .i32 else .f32,
        else => .f32,
    };
    if (b == .cross and gen != .vec3) return p.fail(at, "cross() is of two vec3s", .{});
    if (!(gen.isFloat() or (s.ints and gen.isInt())))
        return p.fail(at, "{s}() needs floats{s}, not a {s}", .{ name, if (s.ints) " or integers" else "", gen.name() });
    const scalar: T = if (gen.isVec()) .f32 else gen;
    for (args, s.args) |*a, kind| {
        switch (kind) {
            .vec2 => a.* = try coerce(c, a.*, .vec2),
            .gen => {
                if (gen.isVec() and !p.nodes[a.*].ty.isVec() and !p.nodes[a.*].ty.isLit())
                    return p.fail(p.nodes[a.*].str.at, "{s}() needs a {s} here, not a {s}", .{ name, gen.name(), p.nodes[a.*].ty.name() });
                a.* = try coerce(c, a.*, gen);
            },
            .gen_or_scalar => {
                const t = p.nodes[a.*].ty;
                a.* = if (gen.isVec() and !t.isVec()) try coerce(c, try coerce(c, a.*, scalar), gen) else try coerce(c, a.*, gen);
            },
        }
    }
    const ret: T = switch (s.ret) {
        .same => gen,
        .f32 => .f32,
        .vec2 => .vec2,
        .vec3 => .vec3,
        .vec4 => .vec4,
    };
    p.nodes[n] = .{ .tag = .builtin, .ty = ret, .a = try p.addList(args), .b = @intCast(args.len), .c = @backingInt(b), .str = p.nodes[n].str };
    return n;
}
