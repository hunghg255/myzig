//! The parser: source to `ir.Program`'s nodes, in Zig's syntax.
//!
//!     uniform time: f32;
//!     const tau = 6.2831853;
//!
//!     fn wave(x: f32) f32 {
//!         return 0.5 + 0.5 * sin(x * tau + time);
//!     }
//!
//!     pub fn fragment(pos: vec2) vec4 {
//!         var v = wave(pos.x / 40);
//!         if (pos.y > 20) {
//!             v *= 0.5;
//!         }
//!         return vec4(v * 0.2, v * 0.4, v, 1);
//!     }
//!
//! Blocks of `if`, `else`, `while` and `for` take braces, always.
const std = @import("std");
const ir = @import("ir.zig");
const lex = @import("lex.zig");

const Kind = lex.Kind;
const Error = error{Shader};

pub const Parser = struct {
    p: *ir.Program,
    tok: lex.Token,

    pub fn init(p: *ir.Program) Parser {
        return .{ .p = p, .tok = lex.next(p.src, 0) };
    }

    fn advance(ps: *Parser) lex.Token {
        const t = ps.tok;
        ps.tok = lex.next(ps.p.src, t.at + t.len);
        return t;
    }

    fn peek(ps: *const Parser, k: Kind) bool {
        return ps.tok.kind == k;
    }

    fn accept(ps: *Parser, k: Kind) bool {
        if (ps.tok.kind != k) return false;
        _ = ps.advance();
        return true;
    }

    fn expect(ps: *Parser, k: Kind, what: []const u8) Error!lex.Token {
        if (ps.tok.kind != k) return ps.p.fail(ps.tok.at, "expected {s}, found '{s}'", .{ what, ps.tokText() });
        return ps.advance();
    }

    fn tokText(ps: *const Parser) []const u8 {
        if (ps.tok.kind == .eof) return "end of file";
        return ps.p.src[ps.tok.at..][0..ps.tok.len];
    }

    fn str(t: lex.Token) ir.Str {
        return .{ .at = t.at, .len = t.len };
    }

    fn name(ps: *Parser) Error!lex.Token {
        const t = try ps.expect(.ident, "a name");
        const s = ps.p.src[t.at..][0..t.len];
        if (std.mem.indexOf(u8, s, "__") != null or s[0] == '_')
            return ps.p.fail(t.at, "names may not start with '_' or hold '__': '{s}'", .{s});
        return t;
    }

    fn typeName(ps: *Parser) Error!ir.Type {
        const t = try ps.expect(.ident, "a type");
        const s = ps.p.src[t.at..][0..t.len];
        if (std.mem.eql(u8, s, "void")) return .void;
        return ir.Type.parse(s) orelse ps.p.fail(t.at, "unknown type '{s}' (bool, i32, u32, f32, vec2, vec3, vec4)", .{s});
    }

    /// The whole source: uniforms, constants and functions.
    pub fn file(ps: *Parser) Error!void {
        const p = ps.p;
        while (!ps.peek(.eof)) {
            if (ps.accept(.kw_uniform)) {
                const n = try ps.name();
                _ = try ps.expect(.colon, "':' and the uniform's type");
                const ty = try ps.typeName();
                if (ty == .void) return p.fail(n.at, "a uniform needs a type", .{});
                _ = try ps.expect(.semicolon, "';'");
                if (p.n_uniforms >= ir.max_uniforms) return p.fail(n.at, "too many uniforms", .{});
                p.uniforms[p.n_uniforms] = .{ .name = str(n), .ty = ty, .offset = 0 };
                p.n_uniforms += 1;
            } else if (ps.accept(.kw_const)) {
                const n = try ps.name();
                var ty: ir.Type = .void;
                if (ps.accept(.colon)) ty = try ps.typeName();
                _ = try ps.expect(.eq, "'='");
                var value = try ps.expr();
                if (ty != .void) value = try p.add(.{ .tag = .convert, .ty = ty, .a = value, .str = str(n) });
                _ = try ps.expect(.semicolon, "';'");
                if (p.n_consts >= p.consts.len) return p.fail(n.at, "too many constants", .{});
                p.consts[p.n_consts] = .{ .name = str(n), .value = value };
                p.n_consts += 1;
            } else {
                _ = ps.accept(.kw_pub);
                try ps.function();
            }
        }
    }

    fn function(ps: *Parser) Error!void {
        const p = ps.p;
        _ = try ps.expect(.kw_fn, "'fn', 'const' or 'uniform'");
        const n = try ps.name();
        if (p.n_fns >= ir.max_fns) return p.fail(n.at, "too many functions", .{});
        var f: ir.Fn = .{ .name = str(n) };
        _ = try ps.expect(.lparen, "'('");
        while (!ps.accept(.rparen)) {
            if (f.n_params > 0) _ = try ps.expect(.comma, "',' or ')'");
            if (ps.accept(.rparen)) break;
            const pn = try ps.name();
            _ = try ps.expect(.colon, "':' and the parameter's type");
            const ty = try ps.typeName();
            if (ty == .void) return p.fail(pn.at, "a parameter needs a type", .{});
            if (f.n_params >= ir.max_params) return p.fail(pn.at, "too many parameters", .{});
            f.params[f.n_params] = ty;
            f.param_names[f.n_params] = str(pn);
            f.n_params += 1;
        }
        f.ret = try ps.typeName();
        f.body = try ps.block();
        p.fns[p.n_fns] = f;
        p.n_fns += 1;
    }

    fn block(ps: *Parser) Error!u16 {
        const open = try ps.expect(.lbrace, "'{'");
        var items: [256]u16 = undefined;
        var n: usize = 0;
        while (!ps.accept(.rbrace)) {
            if (ps.peek(.eof)) return ps.p.fail(open.at, "this '{{' is not closed", .{});
            if (n == items.len) return ps.p.fail(ps.tok.at, "too many statements in a block", .{});
            items[n] = try ps.statement();
            n += 1;
        }
        const at = try ps.p.addList(items[0..n]);
        return ps.p.add(.{ .tag = .block, .a = at, .b = @intCast(n), .str = str(open) });
    }

    fn statement(ps: *Parser) Error!u16 {
        const p = ps.p;
        const t = ps.tok;
        switch (t.kind) {
            .kw_const, .kw_var => {
                _ = ps.advance();
                const n = try ps.name();
                var ty: ir.Type = .void;
                if (ps.accept(.colon)) {
                    ty = try ps.typeName();
                    if (ty == .void) return p.fail(n.at, "a variable needs a type", .{});
                }
                _ = try ps.expect(.eq, "'=' and a value");
                const value = try ps.expr();
                _ = try ps.expect(.semicolon, "';'");
                return p.add(.{ .tag = .decl, .ty = ty, .b = value, .c = @intFromBool(t.kind == .kw_var), .str = str(n) });
            },
            .kw_if => return ps.ifStatement(),
            .kw_while => {
                _ = ps.advance();
                _ = try ps.expect(.lparen, "'('");
                const cond = try ps.expr();
                _ = try ps.expect(.rparen, "')'");
                var cont: u16 = 0;
                if (ps.accept(.colon)) {
                    _ = try ps.expect(.lparen, "'('");
                    cont = try ps.simple(false);
                    _ = try ps.expect(.rparen, "')'");
                }
                const body = try ps.block();
                return p.add(.{ .tag = .loop, .a = cond, .b = cont, .c = body, .str = str(t) });
            },
            .kw_for => {
                _ = ps.advance();
                _ = try ps.expect(.lparen, "'('");
                const lo = try ps.expr();
                _ = try ps.expect(.dot2, "'..'");
                const hi = try ps.expr();
                _ = try ps.expect(.rparen, "')'");
                _ = try ps.expect(.pipe, "'|' and the counter's name");
                const n = try ps.name();
                _ = try ps.expect(.pipe, "'|'");
                const body = try ps.block();
                return p.add(.{ .tag = .range, .b = lo, .c = hi, .d = body, .str = str(n) });
            },
            .kw_break, .kw_continue => {
                _ = ps.advance();
                _ = try ps.expect(.semicolon, "';'");
                return p.add(.{ .tag = if (t.kind == .kw_break) .break_ else .continue_, .str = str(t) });
            },
            .kw_return => {
                _ = ps.advance();
                var value: u16 = 0;
                if (!ps.peek(.semicolon)) value = try ps.expr();
                _ = try ps.expect(.semicolon, "';'");
                return p.add(.{ .tag = .ret, .a = value, .str = str(t) });
            },
            .lbrace => return ps.block(),
            else => return ps.simple(true),
        }
    }

    fn ifStatement(ps: *Parser) Error!u16 {
        const t = try ps.expect(.kw_if, "'if'");
        _ = try ps.expect(.lparen, "'('");
        const cond = try ps.expr();
        _ = try ps.expect(.rparen, "')'");
        const then = try ps.block();
        var other: u16 = 0;
        if (ps.accept(.kw_else)) other = if (ps.peek(.kw_if)) try ps.ifStatement() else try ps.block();
        return ps.p.add(.{ .tag = .if_, .a = cond, .b = then, .c = other, .str = str(t) });
    }

    /// An assignment, or a call for what it does; with `semi`, its ';'.
    fn simple(ps: *Parser, semi: bool) Error!u16 {
        const p = ps.p;
        const start = ps.tok;
        const target = try ps.expr();
        const op: ?ir.Op = switch (ps.tok.kind) {
            .eq => .none,
            .plus_eq => .add,
            .minus_eq => .sub,
            .star_eq => .mul,
            .slash_eq => .div,
            .percent_eq => .rem,
            .amp_eq => .bit_and,
            .pipe_eq => .bit_or,
            .caret_eq => .bit_xor,
            .shl_eq => .shl,
            .shr_eq => .shr,
            else => null,
        };
        var n: u16 = undefined;
        if (op) |o| {
            const at = ps.advance();
            const value = try ps.expr();
            n = try p.add(.{ .tag = .assign, .op = o, .a = target, .b = value, .str = str(at) });
        } else {
            if (p.nodes[target].tag != .call) return p.fail(start.at, "expected a statement: an assignment or a call", .{});
            n = try p.add(.{ .tag = .expr_stmt, .a = target, .str = str(start) });
        }
        if (semi) _ = try ps.expect(.semicolon, "';'");
        return n;
    }

    pub fn expr(ps: *Parser) Error!u16 {
        return ps.binary(0);
    }

    const levels = [_][]const struct { Kind, ir.Op }{
        &.{.{ .kw_or, .@"or" }},
        &.{.{ .kw_and, .@"and" }},
        &.{ .{ .eq2, .eq }, .{ .ne, .ne }, .{ .lt, .lt }, .{ .le, .le }, .{ .gt, .gt }, .{ .ge, .ge } },
        &.{ .{ .amp, .bit_and }, .{ .caret, .bit_xor }, .{ .pipe, .bit_or } },
        &.{ .{ .shl, .shl }, .{ .shr, .shr } },
        &.{ .{ .plus, .add }, .{ .minus, .sub } },
        &.{ .{ .star, .mul }, .{ .slash, .div }, .{ .percent, .rem } },
    };

    fn opAt(ps: *const Parser, level: usize) ?ir.Op {
        for (levels[level]) |e| if (ps.tok.kind == e[0]) return e[1];
        return null;
    }

    fn binary(ps: *Parser, level: usize) Error!u16 {
        if (level == levels.len) return ps.unary();
        var left = try ps.binary(level + 1);
        while (ps.opAt(level)) |op| {
            const t = ps.advance();
            const right = try ps.binary(level + 1);
            left = try ps.p.add(.{ .tag = .binary, .op = op, .a = left, .b = right, .str = str(t) });
            // Comparisons don't chain, as in Zig.
            if (level == 2 and ps.opAt(level) != null) return ps.p.fail(ps.tok.at, "comparisons don't chain: use 'and'", .{});
        }
        return left;
    }

    fn unary(ps: *Parser) Error!u16 {
        const op: ?ir.Op = switch (ps.tok.kind) {
            .minus => .neg,
            .bang => .not,
            .tilde => .bit_not,
            else => null,
        };
        if (op) |o| {
            const t = ps.advance();
            const a = try ps.unary();
            return ps.p.add(.{ .tag = .unary, .op = o, .a = a, .str = str(t) });
        }
        return ps.postfix();
    }

    fn postfix(ps: *Parser) Error!u16 {
        const p = ps.p;
        var n = try ps.primary();
        while (true) {
            if (ps.peek(.dot)) {
                _ = ps.advance();
                const f = try ps.expect(.ident, "a field after '.'");
                n = try p.add(.{ .tag = .field, .a = n, .str = str(f) });
            } else if (ps.peek(.lparen)) {
                if (p.nodes[n].tag != .ident) return p.fail(ps.tok.at, "only functions, types and builtins are called", .{});
                _ = ps.advance();
                var items: [16]u16 = undefined;
                var k: usize = 0;
                while (!ps.accept(.rparen)) {
                    if (k > 0) _ = try ps.expect(.comma, "',' or ')'");
                    if (ps.accept(.rparen)) break;
                    if (k == items.len) return p.fail(ps.tok.at, "too many arguments", .{});
                    items[k] = try ps.expr();
                    k += 1;
                }
                const at = try p.addList(items[0..k]);
                const callee = p.nodes[n];
                p.nodes[n] = .{ .tag = .call, .a = at, .b = @intCast(k), .str = callee.str };
            } else return n;
        }
    }

    fn primary(ps: *Parser) Error!u16 {
        const p = ps.p;
        const t = ps.tok;
        switch (t.kind) {
            .int => {
                _ = ps.advance();
                if (lex.intValue(p.src[t.at..][0..t.len]) == null) return p.fail(t.at, "this number is too large", .{});
                return p.add(.{ .tag = .lit, .ty = .lit_int, .str = str(t) });
            },
            .float => {
                _ = ps.advance();
                return p.add(.{ .tag = .lit, .ty = .lit_float, .str = str(t) });
            },
            .kw_true, .kw_false => {
                _ = ps.advance();
                return p.add(.{ .tag = .lit, .ty = .bool, .str = str(t) });
            },
            .ident => {
                _ = ps.advance();
                return p.add(.{ .tag = .ident, .str = str(t) });
            },
            .lparen => {
                _ = ps.advance();
                const e = try ps.expr();
                _ = try ps.expect(.rparen, "')'");
                return e;
            },
            else => return p.fail(t.at, "expected a value, found '{s}'", .{ps.tokText()}),
        }
    }
};

/// Parses `p.src` into `p`.
pub fn parse(p: *ir.Program) Error!void {
    var ps: Parser = .init(p);
    try ps.file();
}

test "parses a shader" {
    const src =
        \\uniform time: f32;
        \\const k = 2;
        \\fn f(x: f32, y: f32) f32 { return x * y + -k; }
        \\pub fn fragment(pos: vec2) vec4 {
        \\    var v = f(pos.x, 2.5);
        \\    for (0..4) |i| { v += 1; }
        \\    while (v > 1) : (v -= 1) { if (v > 9) { break; } else if (v < 0) { continue; } }
        \\    return vec4(v, v, v, 1);
        \\}
    ;
    const p = try std.testing.allocator.create(ir.Program);
    defer std.testing.allocator.destroy(p);
    p.* = .{ .src = src };
    try parse(p);
    try std.testing.expectEqual(@as(u8, 2), p.n_fns);
    try std.testing.expectEqual(@as(u8, 1), p.n_uniforms);
    try std.testing.expectEqualStrings("fragment", p.text(p.fns[1].name));
}

test "reports where parsing fails" {
    const p = try std.testing.allocator.create(ir.Program);
    defer std.testing.allocator.destroy(p);
    p.* = .{ .src = "fn f() f32 {\n  return 1 +;\n}" };
    try std.testing.expectError(error.Shader, parse(p));
    try std.testing.expectEqual([2]u32{ 2, 13 }, ir.lineCol(p.src, p.err.at));
}
