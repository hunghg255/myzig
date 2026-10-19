//! The emitters: a checked program (`ir.Program`) as HLSL (Direct3D 11,
//! shader model 4), GLSL (OpenGL 3.3 and OpenGL ES 3.0, WebGL 2) and Metal,
//! each an `effect_color` for the renderers' effect pass (`effect.zig`):
//! the shader's `fragment` drawn over the backdrop.
//!
//! Every function takes the pass's `EffectIn` first (Metal: and the
//! backdrop's texture), from which the uniforms and builtins read; names
//! take prefixes (`u_` functions, `v<slot>_` locals) that keep them clear
//! of each language's own; expressions are parenthesized whole.
const std = @import("std");
const ir = @import("ir.zig");
const lex = @import("lex.zig");

pub const Dialect = enum { hlsl, glsl, msl };

/// Text written into a fixed buffer (no allocator, so it runs at
/// compile time too), in chunks: at compile time, writing into one large
/// array of bytes costs in proportion to its size, into a small one little.
pub const Out = struct {
    pub const chunk = 256;
    pub const chunks = 192;
    buf: [chunks][chunk]u8 = undefined,
    len: usize = 0,
    over: bool = false,

    pub fn put(o: *Out, s_in: []const u8) void {
        if (o.len + s_in.len > chunk * chunks) {
            o.over = true;
            return;
        }
        var s = s_in;
        while (s.len > 0) {
            const at = o.len % chunk;
            const n = @min(chunk - at, s.len);
            @memcpy(o.buf[o.len / chunk][at..][0..n], s[0..n]);
            o.len += n;
            s = s[n..];
        }
    }

    pub fn int(o: *Out, v_in: u64) void {
        var tmp: [20]u8 = undefined;
        var i: usize = tmp.len;
        var v = v_in;
        while (true) {
            i -= 1;
            tmp[i] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
            if (v == 0) break;
        }
        o.put(tmp[i..]);
    }

    /// The text (at run time).
    pub fn text(o: *const Out) []const u8 {
        const flat: *const [chunk * chunks]u8 = @ptrCast(&o.buf);
        return flat[0..o.len];
    }

    /// The text as an array (at compile time).
    pub fn array(comptime o: *const Out) [o.len]u8 {
        const k = (o.len + chunk - 1) / chunk;
        const flat: [k * chunk]u8 = @bitCast(o.buf[0..k].*);
        return flat[0..o.len].*;
    }
};

const Emitter = struct {
    p: *const ir.Program,
    d: Dialect,
    o: *Out,

    fn put(e: *Emitter, s: []const u8) void {
        e.o.put(s);
    }

    fn typeName(e: *Emitter, t: ir.Type) []const u8 {
        return switch (t) {
            .void => "void",
            .bool => "bool",
            .i32 => "int",
            .u32 => "uint",
            .f32, .lit_float, .lit_int => "float",
            .vec2 => if (e.d == .glsl) "vec2" else "float2",
            .vec3 => if (e.d == .glsl) "vec3" else "float3",
            .vec4 => if (e.d == .glsl) "vec4" else "float4",
        };
    }

    fn local(e: *Emitter, slot: u16, name: ir.Str) void {
        e.put("v");
        e.o.int(slot);
        e.put("_");
        e.put(e.p.text(name));
    }

    /// The context every function takes, and passes on.
    fn context(e: *Emitter, decl: bool) void {
        if (decl) {
            e.put(if (e.d == .msl) "EffectIn _i, texture2d<float> _bd" else "EffectIn _i");
        } else e.put(if (e.d == .msl) "_i, _bd" else "_i");
    }

    fn literal(e: *Emitter, n: ir.Node) void {
        const s = e.p.text(n.str);
        if (n.ty == .bool) return e.put(s);
        if (std.mem.indexOfAny(u8, s, ".eE") != null and !(s.len > 1 and (s[1] == 'x' or s[1] == 'X'))) {
            for (s) |ch| if (ch != '_') e.put(&.{ch});
            return;
        }
        e.o.int(lex.intValue(s).?);
        if (n.ty == .f32) e.put(".0");
        if (n.ty == .u32) e.put("u");
    }

    fn uniform(e: *Emitter, u: ir.Uniform) void {
        const comps = "xyzw";
        const w = u.ty.width();
        switch (u.ty) {
            .i32, .u32 => {
                // Their bits, as the app set them (`shader.zig`).
                const signed = u.ty == .i32;
                e.put(switch (e.d) {
                    .hlsl => if (signed) "asint(" else "asuint(",
                    .glsl => if (signed) "floatBitsToInt(" else "floatBitsToUint(",
                    .msl => if (signed) "as_type<int>(" else "as_type<uint>(",
                });
                e.param(u.offset);
                e.put(")");
            },
            .bool => {
                e.put("(");
                e.param(u.offset);
                e.put(" != 0.0)");
            },
            .f32 => e.param(u.offset),
            else => {
                // Within one float4, a swizzle; across two, built.
                if (u.offset / 4 == (u.offset + w - 1) / 4) {
                    e.put("_i.params[");
                    e.o.int(u.offset / 4);
                    e.put("].");
                    for (0..w) |k| e.put(&.{comps[(u.offset + k) % 4]});
                } else {
                    e.put(e.typeName(u.ty));
                    e.put("(");
                    for (0..w) |k| {
                        if (k > 0) e.put(", ");
                        e.param(@intCast(u.offset + k));
                    }
                    e.put(")");
                }
            },
        }
    }

    fn param(e: *Emitter, at: usize) void {
        e.put("_i.params[");
        e.o.int(at / 4);
        e.put("].");
        e.put(&.{"xyzw"[at % 4]});
    }

    fn args(e: *Emitter, n: ir.Node) void {
        for (e.p.args(&n), 0..) |a, k| {
            if (k > 0) e.put(", ");
            e.expr(a);
        }
    }

    fn expr(e: *Emitter, i: u16) void {
        const n = e.p.nodes[i];
        switch (n.tag) {
            .lit => e.literal(n),
            .local => e.local(n.a, n.str),
            .uniform => e.uniform(e.p.uniforms[n.a]),
            .unary => {
                e.put("(");
                e.put(n.op.text());
                e.expr(n.a);
                e.put(")");
            },
            .binary => {
                e.put("(");
                e.expr(n.a);
                e.put(" ");
                e.put(n.op.text());
                e.put(" ");
                e.expr(n.b);
                e.put(")");
            },
            .builtin => e.builtin(n),
            .user_call => {
                e.put("u_");
                e.put(e.p.text(e.p.fns[n.c].name));
                e.put("(");
                e.context(false);
                for (e.p.args(&n)) |a| {
                    e.put(", ");
                    e.expr(a);
                }
                e.put(")");
            },
            .construct => {
                if (n.b == 1 and e.p.nodes[e.p.list[n.a]].ty == .f32) return e.splat(n.ty, e.p.list[n.a]);
                e.put(e.typeName(n.ty));
                e.put("(");
                e.args(n);
                e.put(")");
            },
            .convert => {
                e.put(if (e.d == .hlsl) "((" else "");
                e.put(e.typeName(n.ty));
                e.put(if (e.d == .hlsl) ")(" else "(");
                e.expr(n.a);
                e.put(if (e.d == .hlsl) "))" else ")");
            },
            .swizzle => {
                e.put("(");
                e.expr(n.a);
                e.put(").");
                for (0..n.d) |k| e.put(&.{"xyzw"[(n.c >> @intCast(2 * k)) & 3]});
            },
            .splat => e.splat(n.ty, n.a),
            else => unreachable,
        }
    }

    fn splat(e: *Emitter, ty: ir.Type, a: u16) void {
        if (e.d == .hlsl) {
            e.put("((");
            e.put(e.typeName(ty));
            e.put(")(");
            e.expr(a);
            e.put("))");
        } else {
            e.put(e.typeName(ty));
            e.put("(");
            e.expr(a);
            e.put(")");
        }
    }

    fn builtin(e: *Emitter, n: ir.Node) void {
        const b: ir.Builtin = @fromBackingInt(@intCast(n.c));
        const a = e.p.args(&n);
        switch (b) {
            .size => return e.put("(_i.rect.zw / _i.params[3].w)"),
            .pixel_scale => return e.put("_i.params[3].w"),
            .pixel => return e.put("_i.p"),
            .backdrop => {
                e.put(e.typeName(.vec4));
                e.put(if (e.d == .msl) "(backdrop_at(_i, _bd, _i.rect.xy + " else "(backdrop_at(_i, _i.rect.xy + ");
                e.expr(a[0]);
                return e.put(" * _i.params[3].w), 1.0)");
            },
            .sign => if (n.ty == .i32) {
                e.put("(int(");
                e.expr(a[0]);
                e.put(" > 0) - int(");
                e.expr(a[0]);
                return e.put(" < 0))");
            } else if (n.ty == .u32 and e.d == .msl) {
                // Metal's sign() is of floats only.
                e.put("uint(");
                e.expr(a[0]);
                return e.put(" > 0u)");
            },
            // Metal's geometric functions are of vectors only: of scalars,
            // what they come to (as ops.zig computes them).
            .length, .distance, .dot, .normalize, .reflect => if (e.d == .msl and !e.p.nodes[a[0]].ty.isVec()) {
                return e.scalarGeometric(b, a);
            },
            else => {},
        }
        const name: []const u8 = switch (b) {
            .fract => if (e.d == .hlsl) "frac" else "fract",
            .mix => if (e.d == .hlsl) "lerp" else "mix",
            .atan2 => if (e.d == .glsl) "atan" else "atan2",
            .inversesqrt => if (e.d == .glsl) "inversesqrt" else "rsqrt",
            .mod => if (e.d == .glsl) "mod" else "mz_mod",
            .round => switch (e.d) {
                .hlsl => "round",
                .glsl => "roundEven",
                .msl => "rint",
            },
            else => @tagName(b),
        };
        e.put(name);
        e.put("(");
        e.args(n);
        e.put(")");
    }

    /// `b` of scalars `a`, as Metal has it only of vectors.
    fn scalarGeometric(e: *Emitter, b: ir.Builtin, a: []const u16) void {
        const x = a[0];
        const y = if (a.len > 1) a[1] else x;
        switch (b) {
            .length => e.call("abs(", &.{x}, &.{")"}),
            .distance => e.call("abs(", &.{ x, y }, &.{ " - ", ")" }),
            .dot => e.call("(", &.{ x, y }, &.{ " * ", ")" }),
            .normalize => e.call("(", &.{ x, x, x }, &.{ " / sqrt(", " * ", "))" }),
            .reflect => e.call("(", &.{ x, y, x, y }, &.{ " - 2.0 * (", " * ", ") * ", ")" }),
            else => unreachable,
        }
    }

    /// `head`, then each expression of `xs` followed by its text of `tails`.
    fn call(e: *Emitter, head: []const u8, xs: []const u16, tails: []const []const u8) void {
        e.put(head);
        for (xs, tails) |x, t| {
            e.expr(x);
            e.put(t);
        }
    }

    fn indent(e: *Emitter, depth: usize) void {
        for (0..depth) |_| e.put("    ");
    }

    fn block(e: *Emitter, i: u16, depth: usize) void {
        const n = e.p.nodes[i];
        e.put("{\n");
        for (e.p.args(&n)) |s| e.statement(s, depth + 1);
        e.indent(depth);
        e.put("}");
    }

    /// An assignment without its ';'.
    fn assignment(e: *Emitter, n: ir.Node) void {
        e.target(n.a);
        e.put(" ");
        e.put(n.op.text());
        e.put("= ");
        e.expr(n.b);
    }

    fn target(e: *Emitter, i: u16) void {
        const n = e.p.nodes[i];
        if (n.tag == .local) return e.local(n.a, n.str);
        const base = e.p.nodes[n.a];
        e.local(base.a, base.str);
        e.put(".");
        for (0..n.d) |k| e.put(&.{"xyzw"[(n.c >> @intCast(2 * k)) & 3]});
    }

    fn statement(e: *Emitter, i: u16, depth: usize) void {
        const n = e.p.nodes[i];
        e.indent(depth);
        switch (n.tag) {
            .block => e.block(i, depth),
            .decl => {
                e.put(e.typeName(n.ty));
                e.put(" ");
                e.local(n.a, n.str);
                e.put(" = ");
                e.expr(n.b);
                e.put(";");
            },
            .assign => {
                e.assignment(n);
                e.put(";");
            },
            .if_ => {
                var at = n;
                while (true) {
                    e.put("if (");
                    e.expr(at.a);
                    e.put(") ");
                    e.block(at.b, depth);
                    if (at.c == 0) break;
                    e.put(" else ");
                    const other = e.p.nodes[at.c];
                    if (other.tag != .if_) {
                        e.block(at.c, depth);
                        break;
                    }
                    at = other;
                }
            },
            .loop => {
                if (e.d == .hlsl) e.put("[loop] ");
                e.put("for (; ");
                e.expr(n.a);
                e.put("; ");
                if (n.b != 0) e.assignment(e.p.nodes[n.b]);
                e.put(") ");
                e.block(n.c, depth);
            },
            .range => {
                e.put("{\n");
                e.indent(depth + 1);
                e.put("int e");
                e.o.int(n.a);
                e.put(" = ");
                e.expr(n.c);
                e.put(";\n");
                e.indent(depth + 1);
                if (e.d == .hlsl) e.put("[loop] ");
                e.put("for (int ");
                e.local(n.a, n.str);
                e.put(" = ");
                e.expr(n.b);
                e.put("; ");
                e.local(n.a, n.str);
                e.put(" < e");
                e.o.int(n.a);
                e.put("; ");
                e.local(n.a, n.str);
                e.put("++) ");
                e.block(n.d, depth + 1);
                e.put("\n");
                e.indent(depth);
                e.put("}");
            },
            .break_ => e.put("break;"),
            .continue_ => e.put("continue;"),
            .ret => {
                if (n.a == 0) e.put("return;") else {
                    e.put("return ");
                    e.expr(n.a);
                    e.put(";");
                }
            },
            .expr_stmt => {
                e.expr(n.a);
                e.put(";");
            },
            else => unreachable,
        }
        e.put("\n");
    }

    fn function(e: *Emitter, f: ir.Fn) void {
        if (e.d == .msl) e.put("static ");
        e.put(e.typeName(f.ret));
        e.put(" u_");
        e.put(e.p.text(f.name));
        e.put("(");
        e.context(true);
        for (0..f.n_params) |k| {
            e.put(", ");
            e.put(e.typeName(f.params[k]));
            e.put(" ");
            e.local(@intCast(k), f.param_names[k]);
        }
        e.put(") ");
        e.block(f.body, 0);
        e.put("\n\n");
    }

    fn prelude(e: *Emitter) void {
        if (e.d == .glsl) return;
        for ([_]ir.Type{ .f32, .vec2, .vec3, .vec4 }) |t| {
            const name = e.typeName(t);
            if (e.d == .msl) e.put("static ");
            e.put(name);
            e.put(" mz_mod(");
            e.put(name);
            e.put(" x, ");
            e.put(name);
            e.put(" y) { return x - y * floor(x / y); }\n");
        }
        e.put("\n");
    }

    fn entry(e: *Emitter) void {
        const f = e.p.fns[e.p.entry];
        const v3 = e.typeName(.vec3);
        const v4 = e.typeName(.vec4);
        if (e.d == .msl) e.put("static ");
        e.put(v3);
        e.put(if (e.d == .msl) " effect_color(EffectIn _i, texture2d<float> _bd) {\n" else " effect_color(EffectIn _i) {\n");
        e.put("    ");
        e.put(v4);
        e.put(" c = u_fragment(");
        e.context(false);
        if (f.n_params == 1) e.put(", (_i.p - _i.rect.xy) / _i.params[3].w");
        e.put(");\n");
        e.put(if (e.d == .msl) "    return c.rgb + backdrop_at(_i, _bd, _i.p) * (1.0 - c.a);\n}\n" else "    return c.rgb + backdrop_at(_i, _i.p) * (1.0 - c.a);\n}\n");
    }
};

/// Writes `p` in dialect `d` to `o`: helpers, the functions `fragment`
/// reaches (callees first) and `effect_color`.
pub fn emit(p: *const ir.Program, d: Dialect, o: *Out) void {
    var e: Emitter = .{ .p = p, .d = d, .o = o };
    e.put("// Made by myzig's shader compiler.\n");
    e.prelude();
    var k: u8 = 0;
    while (k < p.n_fns) : (k += 1) {
        for (p.fns[0..p.n_fns]) |f| {
            if (f.reached and f.order == k) e.function(f);
        }
    }
    e.entry();
}
