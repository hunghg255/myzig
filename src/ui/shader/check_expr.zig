//! The checker's expressions (`check.zig`): each typed in place, an
//! untyped constant converted where its use needs a type, builtins' and
//! constructors' arguments made to match.
const std = @import("std");
const ir = @import("ir.zig");
const lex = @import("lex.zig");
const Checker = @import("check.zig").Checker;

const Error = error{Shader};
const T = ir.Type;

/// Checks expression `n`; returns the node it became (constants are
/// copied in).
pub fn expr(c: *Checker, n: u16) Error!u16 {
    const p = c.p;
    const node = p.nodes[n];
    switch (node.tag) {
        .lit => {},
        .ident => {
            const s = p.text(node.str);
            if (c.local(s)) |l| {
                p.nodes[n] = .{ .tag = .local, .ty = c.slotType(l.slot), .a = l.slot, .str = node.str };
            } else if (c.uniform(s)) |u| {
                p.nodes[n] = .{ .tag = .uniform, .ty = p.uniforms[u].ty, .a = u, .str = node.str };
            } else if (c.constant(s)) |v| {
                if (c.depth > 16) return p.fail(node.str.at, "'{s}' is defined by itself", .{s});
                c.depth += 1;
                defer c.depth -= 1;
                return expr(c, try clone(c, v));
            } else return p.fail(node.str.at, "'{s}' is not declared", .{s});
        },
        .unary => {
            const a = try expr(c, node.a);
            const t = p.nodes[a].ty;
            p.nodes[n].a = a;
            const ok = switch (node.op) {
                .neg => t.isNumber(),
                .not => t == .bool,
                else => t.isInt() or t == .lit_int,
            };
            if (!ok) return p.fail(node.str.at, "'{s}' does not apply to a {s}", .{ node.op.text(), t.name() });
            p.nodes[n].ty = t;
        },
        .binary => try binary(c, n),
        .call => return call(c, n),
        // A typed constant: its value must be of the type.
        .convert => return coerce(c, try expr(c, node.a), node.ty),
        .field => {
            const a = try expr(c, node.a);
            const t = p.nodes[a].ty;
            if (!t.isVec()) return p.fail(node.str.at, "a {s} has no fields: only vectors have components", .{t.name()});
            const s = p.text(node.str);
            if (s.len > 4) return p.fail(node.str.at, "at most four components: '{s}'", .{s});
            var packed_: u16 = 0;
            const sets = [_][]const u8{ "xyzw", "rgba" };
            const set: []const u8 = if (std.mem.indexOfScalar(u8, sets[0], s[0]) != null) sets[0] else sets[1];
            for (s, 0..) |ch, k| {
                const i = std.mem.indexOfScalar(u8, set, ch) orelse return p.fail(node.str.at, "'{s}' is not a vector's components (xyzw or rgba)", .{s});
                if (i >= t.width()) return p.fail(node.str.at, "a {s} has no component '{c}'", .{ t.name(), ch });
                packed_ |= @as(u16, @intCast(i)) << @intCast(2 * k);
            }
            p.nodes[n] = .{ .tag = .swizzle, .ty = T.vec(@intCast(s.len)), .a = a, .c = packed_, .d = @intCast(s.len), .str = node.str };
        },
        else => unreachable,
    }
    return n;
}

/// A copy of the unchecked expression `n`.
fn clone(c: *Checker, n: u16) Error!u16 {
    const p = c.p;
    var node = p.nodes[n];
    switch (node.tag) {
        .unary, .field => node.a = try clone(c, node.a),
        .binary => {
            node.a = try clone(c, node.a);
            node.b = try clone(c, node.b);
        },
        .convert => node.a = try clone(c, node.a),
        .call => {
            var items: [16]u16 = undefined;
            for (p.args(&node), 0..) |a, k| items[k] = try clone(c, a);
            node.a = try p.addList(items[0..node.b]);
        },
        else => {},
    }
    return p.add(node);
}

/// The default type of an untyped constant.
fn concrete(t: T) T {
    return switch (t) {
        .lit_int => .i32,
        .lit_float => .f32,
        else => t,
    };
}

/// Makes expression `n` a `want`: an untyped constant takes the type, a
/// scalar float spreads to a vector; anything else must be a `want`.
pub fn coerce(c: *Checker, n: u16, want: T) Error!u16 {
    const p = c.p;
    const t = p.nodes[n].ty;
    if (t == want) return n;
    if (t.isLit()) {
        if (want.isVec()) {
            try settle(c, n, .f32);
            return p.add(.{ .tag = .splat, .ty = want, .a = n, .str = p.nodes[n].str });
        }
        try settle(c, n, want);
        return n;
    }
    if (t == .f32 and want.isVec()) return p.add(.{ .tag = .splat, .ty = want, .a = n, .str = p.nodes[n].str });
    return p.fail(p.nodes[n].str.at, "expected a {s}, found a {s}", .{ want.name(), t.name() });
}

/// Gives the untyped constant expression `n` the scalar type `want`.
fn settle(c: *Checker, n: u16, want: T) Error!void {
    const p = c.p;
    const node = p.nodes[n];
    if (!node.ty.isLit()) return;
    switch (node.tag) {
        .lit => {
            if (want == .bool) return p.fail(node.str.at, "expected a bool, found a number", .{});
            if (node.ty == .lit_float and want != .f32) return p.fail(node.str.at, "'{s}' is not an integer", .{p.text(node.str)});
            if (node.ty == .lit_int and want != .f32) {
                const v = lex.intValue(p.text(node.str)).?;
                const most: u64 = if (want == .i32) std.math.maxInt(i32) else std.math.maxInt(u32);
                if (v > most) return p.fail(node.str.at, "{d} does not fit in a {s}", .{ v, want.name() });
            }
        },
        .unary => {
            if (node.op == .bit_not and want == .f32) return p.fail(node.str.at, "'~' needs an integer", .{});
            try settle(c, node.a, want);
        },
        .binary => {
            if (node.op.isCompare() or node.op == .@"and" or node.op == .@"or") return;
            const ints = p.nodes[node.a].ty == .lit_int and p.nodes[node.b].ty == .lit_int;
            if (want == .f32 and ints and (node.op == .div or node.op == .rem))
                return p.fail(node.str.at, "integer division of constants: write them as floats (1.0 / 2.0)", .{});
            if (want == .f32 and !(node.op == .add or node.op == .sub or node.op == .mul or node.op == .div))
                return p.fail(node.str.at, "'{s}' needs integers", .{node.op.text()});
            try settle(c, node.a, want);
            try settle(c, node.b, want);
        },
        else => {},
    }
    p.nodes[n].ty = want;
}

/// The type `op` gives `a` and `b` (checked), converting either.
fn binary(c: *Checker, n: u16) Error!void {
    const p = c.p;
    const node = p.nodes[n];
    var a = try expr(c, node.a);
    var b = try expr(c, node.b);
    const ta = p.nodes[a].ty;
    const tb = p.nodes[b].ty;
    const op = node.op;
    const at = node.str.at;
    var ty: T = undefined;
    if (op == .@"and" or op == .@"or") {
        a = try coerce(c, a, .bool);
        b = try coerce(c, b, .bool);
        ty = .bool;
    } else if (op == .shl or op == .shr) {
        if (!(ta.isInt() or ta == .lit_int) or !(tb.isInt() or tb == .lit_int)) return p.fail(at, "'{s}' needs integers", .{op.text()});
        if (ta == .lit_int and tb != .lit_int) a = try coerce(c, a, tb);
        ty = p.nodes[a].ty;
        if (ty != .lit_int) b = try toType(c, b, ty);
    } else if (ta.isLit() and tb.isLit()) {
        if (op.isCompare()) {
            const k: T = if (ta == .lit_float or tb == .lit_float) .f32 else .i32;
            a = try coerce(c, a, k);
            b = try coerce(c, b, k);
            ty = .bool;
        } else {
            if ((op == .rem or op == .bit_and or op == .bit_or or op == .bit_xor) and (ta == .lit_float or tb == .lit_float))
                return p.fail(at, "'{s}' needs integers", .{op.text()});
            ty = if (ta == .lit_float or tb == .lit_float) .lit_float else .lit_int;
        }
    } else {
        // An untyped side takes the other's (scalar) type.
        if (ta.isLit()) a = try coerce(c, a, if (tb.isVec()) .f32 else tb);
        if (tb.isLit()) b = try coerce(c, b, if (ta.isVec()) .f32 else ta);
        const x = p.nodes[a].ty;
        const y = p.nodes[b].ty;
        if (op.isCompare()) {
            if (x != y or x.isVec() or (x == .bool and op != .eq and op != .ne))
                return p.fail(at, "'{s}' compares two scalars of a type, not a {s} and a {s}", .{ op.text(), x.name(), y.name() });
            ty = .bool;
        } else {
            ty = try arithmetic(c, op, x, y, at);
        }
    }
    p.nodes[n].a = a;
    p.nodes[n].b = b;
    p.nodes[n].ty = ty;
}

/// The type of `x op y` for arithmetic and bitwise ops.
fn arithmetic(c: *Checker, op: ir.Op, x: T, y: T, at: u32) Error!T {
    const p = c.p;
    if (x == .bool or y == .bool) return p.fail(at, "'{s}' does not apply to bools", .{op.text()});
    switch (op) {
        .rem => {
            if (x.isFloat() or y.isFloat()) return p.fail(at, "'%' is for integers: use mod(a, b) for floats", .{});
            if (x != y) return p.fail(at, "mismatched types {s} and {s}", .{ x.name(), y.name() });
            return x;
        },
        .bit_and, .bit_or, .bit_xor => {
            if (!x.isInt() or x != y) return p.fail(at, "'{s}' needs two integers of a type, not a {s} and a {s}", .{ op.text(), x.name(), y.name() });
            return x;
        },
        else => {
            if (x == y) return x;
            if (x == .f32 and y.isVec()) return y;
            if (y == .f32 and x.isVec()) return x;
            return p.fail(at, "mismatched types {s} and {s}: convert with f32(), i32() or u32()", .{ x.name(), y.name() });
        },
    }
}

/// The value of `target op= value`, checked: `value` (checked) converted.
pub fn compound(c: *Checker, op: ir.Op, target: T, value_in: u16, at: u32) Error!u16 {
    const p = c.p;
    var value = value_in;
    if (op == .shl or op == .shr) {
        if (!target.isInt()) return p.fail(at, "'{s}' needs integers", .{op.text()});
        return toType(c, value, target);
    }
    if (p.nodes[value].ty.isLit()) value = try coerce(c, value, if (target.isVec()) .f32 else target);
    const ty = try arithmetic(c, op, target, p.nodes[value].ty, at);
    if (ty != target) return p.fail(at, "a {s} {s}= {s} is not a {s}", .{ target.name(), op.text(), p.nodes[value].ty.name(), target.name() });
    return value;
}

/// An integer `n` as integer type `want`, converted if need be.
fn toType(c: *Checker, n: u16, want: T) Error!u16 {
    const p = c.p;
    const t = p.nodes[n].ty;
    if (t.isLit()) return coerce(c, n, want);
    if (t == want) return n;
    return p.add(.{ .tag = .convert, .ty = want, .a = n, .str = p.nodes[n].str });
}

fn call(c: *Checker, n: u16) Error!u16 {
    const p = c.p;
    const node = p.nodes[n];
    const s = p.text(node.str);
    var args: [16]u16 = undefined;
    const k = node.b;
    for (p.args(&node), 0..) |a, i| args[i] = try expr(c, a);
    if (T.parse(s)) |ty| {
        if (ty.isVec()) return construct(c, n, ty, args[0..k]);
        if (k != 1) return p.fail(node.str.at, "{s}() converts one value", .{s});
        const t = p.nodes[args[0]].ty;
        if (t.isLit()) {
            if (ty == .bool) return p.fail(node.str.at, "bool() converts no numbers: compare instead", .{});
            return coerce(c, args[0], ty);
        }
        if (t.isVec() or t == .void or (ty == .bool)) return p.fail(node.str.at, "{s}() converts a scalar, not a {s}", .{ s, t.name() });
        p.nodes[n] = .{ .tag = .convert, .ty = ty, .a = args[0], .str = node.str };
        return n;
    }
    if (p.fnNamed(s)) |fi| {
        const f = p.fns[fi];
        if (k != f.n_params) return p.fail(node.str.at, "'{s}' takes {d} arguments, not {d}", .{ s, f.n_params, k });
        for (0..k) |i| args[i] = try coerce(c, args[i], f.params[i]);
        c.noteCall(fi);
        p.nodes[n] = .{ .tag = .user_call, .ty = f.ret, .a = try p.addList(args[0..k]), .b = k, .c = fi, .str = node.str };
        return n;
    }
    if (ir.Builtin.parse(s)) |b| return @import("check_builtin.zig").builtin(c, n, b, args[0..k]);
    return p.fail(node.str.at, "'{s}' is not a function, a type or a builtin", .{s});
}

/// A vector made of floats and vectors, or one float spread.
fn construct(c: *Checker, n: u16, ty: T, args: []u16) Error!u16 {
    const p = c.p;
    const at = p.nodes[n].str.at;
    var width: u8 = 0;
    for (args) |*a| {
        const t = p.nodes[a.*].ty;
        if (t.isLit()) a.* = try coerce(c, a.*, .f32);
        const u = p.nodes[a.*].ty;
        if (!u.isFloat()) return p.fail(at, "{s}() is made of floats and vectors, not a {s}: convert with f32()", .{ ty.name(), u.name() });
        width += u.width();
    }
    if (!(width == ty.width() or (args.len == 1 and width == 1)))
        return p.fail(at, "{s}() needs {d} components, not {d}", .{ ty.name(), ty.width(), width });
    p.nodes[n] = .{ .tag = .construct, .ty = ty, .a = try p.addList(args), .b = @intCast(args.len), .str = p.nodes[n].str };
    return n;
}
