//! The CPU twin: a checked program (`ir.Program`, known at compile time)
//! turned into Zig code, a function per node, which the compiler then
//! compiles as any other: no interpreter at run time. It computes what
//! the GPUs' code does (`emit.zig`), with `ops.zig`'s arithmetic, and
//! draws the fragment over the backdrop as their `effect_color` does.
const std = @import("std");
const ir = @import("ir.zig");
const ops = @import("ops.zig");
const Input = @import("../effect.zig").Input;

const V = ops.V;
const Flow = enum { normal, brk, cont, ret };

pub fn Twin(comptime p: *const ir.Program) type {
    return struct {
        const State = struct {
            slots: [@max(p.n_slots, 1)]V,
            ret: V,
            in: *const Input,
        };

        /// The effect's color at a pixel: premultiplied, opaque, each
        /// channel rounded to 8 bits as the GPUs' targets hold it.
        pub fn color(in: *const Input) [3]f32 {
            var s: State = .{ .slots = undefined, .ret = @splat(0), .in = in };
            const f = comptime p.fns[p.entry];
            if (f.n_params == 1) {
                const k = in.params[3][3];
                s.slots[f.slot0] = ops.fromF(.{ (in.p[0] - in.rect[0]) / k, (in.p[1] - in.rect[1]) / k, 0, 0 });
            }
            _ = block(f.body, f.slot0, &s);
            const c = ops.f(s.ret);
            const b = in.sample(in.p[0], in.p[1]);
            var out: [3]f32 = undefined;
            inline for (0..3) |i| {
                const v = c[i] + b[i] * (1 - c[3]);
                // NaN to 0, as saturate makes it.
                const sat = @min(@max(v, 0), 1);
                out[i] = @floor(sat * 255 + 0.5) / 255;
            }
            return out;
        }

        fn block(comptime n: u16, comptime base: u16, s: *State) Flow {
            const node = comptime p.nodes[n];
            const items = comptime p.list[node.a..][0..node.b].*;
            inline for (items) |st| {
                const flow = stmt(st, base, s);
                if (flow != .normal) return flow;
            }
            return .normal;
        }

        fn stmt(comptime n: u16, comptime base: u16, s: *State) Flow {
            const node = comptime p.nodes[n];
            switch (node.tag) {
                .block => return block(n, base, s),
                .decl => s.slots[base + node.a] = expr(node.b, base, s),
                .assign => assign(node, base, s),
                .if_ => {
                    if (expr(node.a, base, s)[0] != 0) return block(node.b, base, s);
                    if (node.c != 0) return stmt(node.c, base, s);
                },
                .loop => while (expr(node.a, base, s)[0] != 0) {
                    switch (block(node.c, base, s)) {
                        .brk => break,
                        .ret => return .ret,
                        else => {},
                    }
                    if (node.b != 0) assign(p.nodes[node.b], base, s);
                },
                .range => {
                    const lo: i32 = @bitCast(expr(node.b, base, s)[0]);
                    const hi: i32 = @bitCast(expr(node.c, base, s)[0]);
                    var i = lo;
                    while (i < hi) : (i += 1) {
                        s.slots[base + node.a] = @splat(@bitCast(i));
                        switch (block(node.d, base, s)) {
                            .brk => break,
                            .ret => return .ret,
                            else => {},
                        }
                    }
                },
                .break_ => return .brk,
                .continue_ => return .cont,
                .ret => {
                    if (node.a != 0) s.ret = expr(node.a, base, s);
                    return .ret;
                },
                .expr_stmt => _ = expr(node.a, base, s),
                else => unreachable,
            }
            return .normal;
        }

        fn assign(comptime node: ir.Node, comptime base: u16, s: *State) void {
            const t = comptime p.nodes[node.a];
            const value = expr(node.b, base, s);
            const slot = comptime base + (if (t.tag == .local) t.a else p.nodes[t.a].a);
            const old = if (t.tag == .local) s.slots[slot] else ops.V{ 0, 0, 0, 0 };
            if (t.tag == .local) {
                const ty = comptime p.nodes[node.a].ty;
                s.slots[slot] = if (node.op == .none) value else ops.binary(node.op, ty, comptime p.nodes[node.b].ty, old, value);
                return;
            }
            // Components of a vector.
            const whole = s.slots[slot];
            const part = comptime t.ty;
            const cur = swizzle(t, whole);
            const v = if (node.op == .none) value else ops.binary(node.op, part, comptime p.nodes[node.b].ty, cur, value);
            var out = whole;
            inline for (0..t.d) |k| out[(t.c >> (2 * k)) & 3] = v[k];
            s.slots[slot] = out;
        }

        inline fn swizzle(comptime t: ir.Node, v: V) V {
            var r: V = @splat(0);
            inline for (0..t.d) |k| r[k] = v[(t.c >> (2 * k)) & 3];
            return r;
        }

        fn expr(comptime n: u16, comptime base: u16, s: *State) V {
            const node = comptime p.nodes[n];
            switch (node.tag) {
                .lit => return comptime literal(node),
                .local => return s.slots[base + node.a],
                .uniform => return uniform(comptime p.uniforms[node.a], s.in),
                .unary => return ops.unary(node.op, node.ty, expr(node.a, base, s)),
                .binary => {
                    const ta = comptime p.nodes[node.a].ty;
                    if (node.op == .@"and") return if (expr(node.a, base, s)[0] != 0) expr(node.b, base, s) else ops.boolean(false);
                    if (node.op == .@"or") return if (expr(node.a, base, s)[0] != 0) ops.boolean(true) else expr(node.b, base, s);
                    return ops.binary(node.op, ta, comptime p.nodes[node.b].ty, expr(node.a, base, s), expr(node.b, base, s));
                },
                .swizzle => return swizzle(node, expr(node.a, base, s)),
                .splat => return ops.splat(expr(node.a, base, s)),
                .convert => return ops.convert(comptime p.nodes[node.a].ty, node.ty, expr(node.a, base, s)),
                .construct => {
                    const args = comptime p.list[node.a..][0..node.b].*;
                    if (args.len == 1 and p.nodes[args[0]].ty == .f32) return ops.splat(expr(args[0], base, s));
                    var r: V = @splat(0);
                    comptime var at = 0;
                    inline for (args) |a| {
                        const v = expr(a, base, s);
                        inline for (0..comptime p.nodes[a].ty.width()) |k| r[at + k] = v[k];
                        at += comptime p.nodes[a].ty.width();
                    }
                    return r;
                },
                .user_call => return call(node, base, s),
                .builtin => return builtin(node, base, s),
                else => unreachable,
            }
        }

        fn call(comptime node: ir.Node, comptime base: u16, s: *State) V {
            const f = comptime p.fns[node.c];
            const args = comptime p.list[node.a..][0..node.b].*;
            var tmp: [args.len]V = undefined;
            inline for (args, 0..) |a, k| tmp[k] = expr(a, base, s);
            inline for (0..args.len) |k| s.slots[f.slot0 + k] = tmp[k];
            _ = block(f.body, f.slot0, s);
            return s.ret;
        }

        fn builtin(comptime node: ir.Node, comptime base: u16, s: *State) V {
            const b: ir.Builtin = comptime @fromBackingInt(@intCast(node.c));
            const in = s.in;
            const k = in.params[3][3];
            switch (b) {
                .size => return ops.fromF(.{ in.rect[2] / k, in.rect[3] / k, 0, 0 }),
                .pixel_scale => return ops.scalar(k),
                .pixel => return ops.fromF(.{ in.p[0], in.p[1], 0, 0 }),
                .backdrop => {
                    const at = ops.f(expr(comptime p.list[node.a], base, s));
                    const c = in.sample(in.rect[0] + at[0] * k, in.rect[1] + at[1] * k);
                    return ops.fromF(.{ c[0], c[1], c[2], 1 });
                },
                else => {},
            }
            const args = comptime p.list[node.a..][0..node.b].*;
            var vals: [args.len]V = undefined;
            inline for (args, 0..) |a, i| vals[i] = expr(a, base, s);
            return ops.math(b, comptime p.nodes[args[0]].ty, &vals);
        }

        fn literal(comptime node: ir.Node) V {
            const text = p.text(node.str);
            return switch (node.ty) {
                .bool => ops.boolean(text[0] == 't'),
                .f32 => ops.scalar(if (std.mem.indexOfAny(u8, text, ".eE") != null and !(text.len > 1 and (text[1] == 'x' or text[1] == 'X')))
                    std.fmt.parseFloat(f32, text) catch unreachable
                else
                    @floatFromInt(@import("lex.zig").intValue(text).?)),
                .i32, .u32 => @splat(@intCast(@import("lex.zig").intValue(text).?)),
                else => unreachable,
            };
        }

        inline fn uniform(comptime u: ir.Uniform, in: *const Input) V {
            const flat: *const [16]f32 = @ptrCast(in.params);
            var r: V = @splat(0);
            inline for (0..comptime u.ty.width()) |k| r[k] = @bitCast(flat[u.offset + k]);
            return switch (u.ty) {
                .i32, .u32 => @splat(@as(u32, @bitCast(flat[u.offset]))),
                .bool => ops.boolean(flat[u.offset] != 0),
                else => r,
            };
        }
    };
}
