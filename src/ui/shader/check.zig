//! The checker: names to locals, uniforms and functions, every expression
//! typed, untyped constants given the type their use needs, calls to
//! builtins made explicit (scalars spread to vectors), and the functions
//! ordered callees first. Errors stop at the first, with where it is.
//! Expressions are checked in `check_expr.zig`.
const std = @import("std");
const ir = @import("ir.zig");
const ex = @import("check_expr.zig");

const Error = error{Shader};

const Local = struct { name: ir.Str, slot: u16, mutable: bool };

pub const Checker = struct {
    p: *ir.Program,
    /// The function being checked.
    f: u8 = 0,
    scope: [256]Local = undefined,
    n_scope: u16 = 0,
    loops: u8 = 0,
    /// Which functions call which.
    calls: [ir.max_fns]u64 = @splat(0),
    /// How deep constants are copied into constants.
    depth: u8 = 0,

    pub fn local(c: *const Checker, name: []const u8) ?Local {
        var i = c.n_scope;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, c.p.text(c.scope[i].name), name)) return c.scope[i];
        }
        return null;
    }

    pub fn uniform(c: *const Checker, name: []const u8) ?u16 {
        for (c.p.uniforms[0..c.p.n_uniforms], 0..) |u, i| {
            if (std.mem.eql(u8, c.p.text(u.name), name)) return @intCast(i);
        }
        return null;
    }

    pub fn constant(c: *const Checker, name: []const u8) ?u16 {
        for (c.p.consts[0..c.p.n_consts]) |k| {
            if (std.mem.eql(u8, c.p.text(k.name), name)) return k.value;
        }
        return null;
    }

    /// Whether `name` is taken at the top level (or is a type or builtin).
    fn global(c: *const Checker, name: []const u8) bool {
        return c.uniform(name) != null or c.constant(name) != null or c.p.fnNamed(name) != null or
            ir.Type.parse(name) != null or ir.Builtin.parse(name) != null or std.mem.eql(u8, name, "void");
    }

    fn declare(c: *Checker, name: ir.Str, ty: ir.Type, mutable: bool) Error!u16 {
        const p = c.p;
        const s = p.text(name);
        if (c.local(s) != null or c.global(s)) return p.fail(name.at, "'{s}' shadows another declaration", .{s});
        const f = &p.fns[c.f];
        if (p.n_slots >= ir.max_slots or c.n_scope >= c.scope.len) return p.fail(name.at, "too many variables", .{});
        p.slots[p.n_slots] = ty;
        p.n_slots += 1;
        const slot = f.n_slots;
        f.n_slots += 1;
        c.scope[c.n_scope] = .{ .name = name, .slot = slot, .mutable = mutable };
        c.n_scope += 1;
        return slot;
    }

    pub fn slotType(c: *const Checker, slot: u16) ir.Type {
        return c.p.slots[c.p.fns[c.f].slot0 + slot];
    }

    pub fn noteCall(c: *Checker, callee: u8) void {
        c.calls[c.f] |= @as(u64, 1) << @intCast(callee);
    }

    fn function(c: *Checker, fi: u8) Error!void {
        const p = c.p;
        c.f = fi;
        const f = &p.fns[fi];
        f.slot0 = p.n_slots;
        f.n_slots = 0;
        c.n_scope = 0;
        for (0..f.n_params) |k| _ = try c.declare(f.param_names[k], f.params[k], false);
        try c.block(f.body);
        if (f.ret != .void and !c.returns(f.body))
            return p.fail(f.name.at, "'{s}' must end by returning a {s}", .{ p.text(f.name), f.ret.name() });
    }

    /// Whether statement `n` returns on every path.
    fn returns(c: *const Checker, n: u16) bool {
        const node = c.p.nodes[n];
        return switch (node.tag) {
            .ret => true,
            .block => node.b > 0 and c.returns(c.p.list[node.a + node.b - 1]),
            .if_ => node.c != 0 and c.returns(node.b) and c.returns(node.c),
            else => false,
        };
    }

    fn block(c: *Checker, n: u16) Error!void {
        const mark = c.n_scope;
        defer c.n_scope = mark;
        const node = c.p.nodes[n];
        for (c.p.args(&node)) |s| try c.statement(s);
    }

    fn statement(c: *Checker, n: u16) Error!void {
        const p = c.p;
        const node = p.nodes[n];
        switch (node.tag) {
            .block => try c.block(n),
            .decl => {
                var value = try ex.expr(c, node.b);
                const vt = p.nodes[value].ty;
                if (vt == .void) return p.fail(node.str.at, "'{s}' is given no value", .{p.text(node.str)});
                const ty: ir.Type = if (node.ty != .void) node.ty else switch (vt) {
                    .lit_int => .i32,
                    .lit_float => .f32,
                    else => vt,
                };
                value = try ex.coerce(c, value, ty);
                const slot = try c.declare(node.str, ty, node.c == 1);
                p.nodes[n].a = slot;
                p.nodes[n].b = value;
                p.nodes[n].ty = ty;
            },
            .assign => try c.assign(n),
            .if_ => {
                p.nodes[n].a = try ex.coerce(c, try ex.expr(c, node.a), .bool);
                try c.block(node.b);
                if (node.c != 0) try c.statement(node.c);
            },
            .loop => {
                p.nodes[n].a = try ex.coerce(c, try ex.expr(c, node.a), .bool);
                c.loops += 1;
                defer c.loops -= 1;
                if (node.b != 0) try c.statement(node.b);
                try c.block(node.c);
            },
            .range => {
                p.nodes[n].b = try ex.coerce(c, try ex.expr(c, node.b), .i32);
                p.nodes[n].c = try ex.coerce(c, try ex.expr(c, node.c), .i32);
                const mark = c.n_scope;
                defer c.n_scope = mark;
                p.nodes[n].a = try c.declare(node.str, .i32, false);
                c.loops += 1;
                defer c.loops -= 1;
                try c.block(node.d);
            },
            .break_, .continue_ => if (c.loops == 0) return p.fail(node.str.at, "'{s}' outside of a loop", .{p.text(node.str)}),
            .ret => {
                const want = p.fns[c.f].ret;
                if (node.a == 0) {
                    if (want != .void) return p.fail(node.str.at, "expected a {s} to return", .{want.name()});
                } else {
                    if (want == .void) return p.fail(node.str.at, "'{s}' returns nothing", .{p.text(p.fns[c.f].name)});
                    p.nodes[n].a = try ex.coerce(c, try ex.expr(c, node.a), want);
                }
            },
            .expr_stmt => {
                const e = try ex.expr(c, node.a);
                if (p.nodes[e].tag != .user_call or p.nodes[e].ty != .void)
                    return p.fail(node.str.at, "this value is not used: only functions returning void are called alone", .{});
                p.nodes[n].a = e;
            },
            else => unreachable,
        }
    }

    fn assign(c: *Checker, n: u16) Error!void {
        const p = c.p;
        const node = p.nodes[n];
        const target = try ex.expr(c, node.a);
        p.nodes[n].a = target;
        const t = p.nodes[target];
        // A variable, or components of one, each once.
        const base = if (t.tag == .swizzle) p.nodes[t.a] else t;
        if (base.tag != .local) return p.fail(node.str.at, "only variables are assigned to", .{});
        var mutable = false;
        for (c.scope[0..c.n_scope]) |l| {
            if (l.slot == base.a) mutable = l.mutable;
        }
        if (!mutable) return p.fail(t.str.at, "'{s}' is a constant: declare it with 'var'", .{p.text(base.str)});
        if (t.tag == .swizzle) {
            var seen: u8 = 0;
            for (0..t.d) |k| {
                const bit = @as(u8, 1) << @intCast((t.c >> @intCast(2 * k)) & 3);
                if (seen & bit != 0) return p.fail(t.str.at, "a component is assigned twice", .{});
                seen |= bit;
            }
        }
        if (node.op == .none) {
            p.nodes[n].b = try ex.coerce(c, try ex.expr(c, node.b), t.ty);
            return;
        }
        p.nodes[n].b = try ex.compound(c, node.op, t.ty, try ex.expr(c, node.b), node.str.at);
    }

    /// Orders the functions callees first, from `fragment`; finds recursion.
    fn order(c: *Checker, fi: u8, state: *[ir.max_fns]u8, next: *u8) Error!void {
        const p = c.p;
        if (state[fi] == 2) return;
        if (state[fi] == 1) return p.fail(p.fns[fi].name.at, "'{s}' calls itself: shaders don't recurse", .{p.text(p.fns[fi].name)});
        state[fi] = 1;
        for (0..p.n_fns) |k| {
            if (c.calls[fi] & (@as(u64, 1) << @intCast(k)) != 0) try c.order(@intCast(k), state, next);
        }
        state[fi] = 2;
        p.fns[fi].order = next.*;
        p.fns[fi].reached = true;
        next.* += 1;
    }
};

pub fn check(p: *ir.Program) Error!void {
    var c: Checker = .{ .p = p };
    // Uniforms, packed one float after another.
    var floats: u8 = 0;
    for (p.uniforms[0..p.n_uniforms], 0..) |*u, i| {
        for (p.uniforms[0..i]) |o| if (std.mem.eql(u8, p.text(o.name), p.text(u.name))) return p.fail(u.name.at, "'{s}' is declared twice", .{p.text(u.name)});
        u.offset = floats;
        floats += u.ty.width();
        if (floats > ir.uniform_floats) return p.fail(u.name.at, "the uniforms take more than {d} floats", .{ir.uniform_floats});
    }
    for (p.consts[0..p.n_consts], 0..) |k, i| {
        const s = p.text(k.name);
        for (p.consts[0..i]) |o| if (std.mem.eql(u8, p.text(o.name), s)) return p.fail(k.name.at, "'{s}' is declared twice", .{s});
        if (c.uniform(s) != null or ir.Type.parse(s) != null or ir.Builtin.parse(s) != null) return p.fail(k.name.at, "'{s}' shadows another declaration", .{s});
    }
    for (p.fns[0..p.n_fns], 0..) |f, i| {
        const s = p.text(f.name);
        for (p.fns[0..i]) |o| if (std.mem.eql(u8, p.text(o.name), s)) return p.fail(f.name.at, "'{s}' is declared twice", .{s});
        if (c.uniform(s) != null or c.constant(s) != null or ir.Type.parse(s) != null or ir.Builtin.parse(s) != null)
            return p.fail(f.name.at, "'{s}' shadows another declaration", .{s});
    }
    const entry = p.fnNamed("fragment") orelse return p.fail(0, "a shader needs 'pub fn fragment(pos: vec2) vec4'", .{});
    const ef = p.fns[entry];
    if (ef.ret != .vec4 or ef.n_params > 1 or (ef.n_params == 1 and ef.params[0] != .vec2))
        return p.fail(ef.name.at, "'fragment' is 'fn fragment(pos: vec2) vec4' or 'fn fragment() vec4'", .{});
    p.entry = entry;
    for (0..p.n_fns) |i| try c.function(@intCast(i));
    var state: [ir.max_fns]u8 = @splat(0);
    var next: u8 = 0;
    try c.order(entry, &state, &next);
}

/// Parses and checks `src` into `p`.
pub fn compile(p: *ir.Program, src: []const u8) Error!void {
    p.* = .{ .src = src };
    try @import("parse.zig").parse(p);
    try check(p);
}
