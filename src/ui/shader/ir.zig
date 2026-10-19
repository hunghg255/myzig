//! What a shader is made of once parsed (`parse.zig`) and checked
//! (`check.zig`): one array of nodes, statements and expressions alike,
//! with lists of children in another, the functions, the uniforms and the
//! types of every function's locals. Everything is in fixed arrays, no
//! allocator: the same code runs at compile time (`comptime`) and at run
//! time, and the emitters (`emit.zig`) and the CPU twin (`cpu.zig`) read it.
const std = @import("std");

pub const max_nodes = 4096;
pub const max_list = 4096;
pub const max_fns = 64;
pub const max_slots = 1024;
pub const max_uniforms = 16;
pub const max_params = 8;
/// Floats of the effect's parameters the uniforms may take; the last of
/// the sixteen holds the pixels a point.
pub const uniform_floats = 15;

/// The types of values. `lit_int` and `lit_float` are untyped constants
/// (number literals and what is made of them alone), which take the type
/// their use needs, as Zig's comptime numbers do.
pub const Type = enum(u8) {
    void,
    bool,
    i32,
    u32,
    f32,
    vec2,
    vec3,
    vec4,
    lit_int,
    lit_float,

    pub fn width(t: Type) u8 {
        return switch (t) {
            .vec2 => 2,
            .vec3 => 3,
            .vec4 => 4,
            .void => 0,
            else => 1,
        };
    }

    pub fn isVec(t: Type) bool {
        return t == .vec2 or t == .vec3 or t == .vec4;
    }

    /// Floats: scalars and vectors.
    pub fn isFloat(t: Type) bool {
        return t == .f32 or t.isVec();
    }

    pub fn isInt(t: Type) bool {
        return t == .i32 or t == .u32;
    }

    pub fn isLit(t: Type) bool {
        return t == .lit_int or t == .lit_float;
    }

    pub fn isNumber(t: Type) bool {
        return t.isFloat() or t.isInt() or t.isLit();
    }

    pub fn vec(n: u8) Type {
        return switch (n) {
            1 => .f32,
            2 => .vec2,
            3 => .vec3,
            else => .vec4,
        };
    }

    /// The name a shader writes it with.
    pub fn name(t: Type) []const u8 {
        return switch (t) {
            .lit_int => "comptime_int",
            .lit_float => "comptime_float",
            else => @tagName(t),
        };
    }

    pub fn parse(s: []const u8) ?Type {
        inline for (.{ Type.bool, .i32, .u32, .f32, .vec2, .vec3, .vec4 }) |t| {
            if (std.mem.eql(u8, s, @tagName(t))) return t;
        }
        return null;
    }
};

pub const Op = enum(u8) {
    none,
    add,
    sub,
    mul,
    div,
    rem,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    @"and",
    @"or",
    neg,
    not,
    bit_not,

    pub fn isCompare(o: Op) bool {
        return @backingInt(o) >= @backingInt(Op.eq) and @backingInt(o) <= @backingInt(Op.ge);
    }

    pub fn text(o: Op) []const u8 {
        return switch (o) {
            .add => "+",
            .sub, .neg => "-",
            .mul => "*",
            .div => "/",
            .rem => "%",
            .bit_and => "&",
            .bit_or => "|",
            .bit_xor => "^",
            .shl => "<<",
            .shr => ">>",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .@"and" => "&&",
            .@"or" => "||",
            .not => "!",
            .bit_not => "~",
            .none => "",
        };
    }
};

pub const Tag = enum(u8) {
    // Expressions.
    /// A number or bool; `str` is its source text.
    lit,
    /// A name, until checked: then `local`, `uniform` or a copy of a constant.
    ident,
    /// Local `a` of the function (its slot).
    local,
    /// Uniform `a` (its index in `Program.uniforms`).
    uniform,
    unary,
    binary,
    /// A call of name `str`, args `a..a+b` in `list`, until checked.
    call,
    /// Builtin `c` (`Builtin`) of args `a..a+b`.
    builtin,
    /// Function `c` of args `a..a+b`.
    user_call,
    /// A vector of type `ty` made of args `a..a+b` (one scalar: all of it).
    construct,
    /// `a` converted to `ty`.
    convert,
    /// `a`'s field `str`, until checked: then `swizzle`.
    field,
    /// Components of `a`: `c` holds them, two bits each; `ty` their count.
    swizzle,
    /// Scalar `a` as a vector of type `ty`.
    splat,
    // Statements.
    /// Statements `a..a+b` of `list`.
    block,
    /// Local `a` (slot) set first to `b`; `c` is 1 for `var`.
    decl,
    /// `a` (a local or its swizzle) set by `op` (none: plain) to `b`.
    assign,
    /// If `a` then block `b`, else `c` (0: none; a block or an `if_`).
    if_,
    /// While `a`: block `c`, then `b` (0: none) each time round.
    loop,
    /// For local `a` from `b` up to (not with) `c`: block `d`.
    range,
    break_,
    continue_,
    /// Returns `a` (0: nothing).
    ret,
    /// Call `a`, for what it does.
    expr_stmt,
};

/// A piece of source: offset and length.
pub const Str = struct {
    at: u32 = 0,
    len: u32 = 0,
};

pub const Node = struct {
    tag: Tag,
    ty: Type = .void,
    op: Op = .none,
    a: u16 = 0,
    b: u16 = 0,
    c: u16 = 0,
    d: u16 = 0,
    /// Where it is in the source, for errors; and its text, for names
    /// and literals.
    str: Str = .{},
};

pub const Fn = struct {
    name: Str,
    params: [max_params]Type = @splat(.void),
    param_names: [max_params]Str = @splat(.{}),
    n_params: u8 = 0,
    ret: Type = .void,
    /// Its body's block.
    body: u16 = 0,
    /// Its locals' types: `Program.slots[slot0..slot0+n_slots]`, params first.
    slot0: u16 = 0,
    n_slots: u16 = 0,
    /// Order of emission (callees first), set by the checker; 0xff: unused.
    order: u8 = 0xff,
    reached: bool = false,
};

pub const Uniform = struct {
    name: Str,
    ty: Type,
    /// The first float of the effect's parameters it takes.
    offset: u8,
};

/// A uniform as the app sees it, with its name copied out of the source.
pub const UniformInfo = struct {
    name: []const u8,
    ty: Type,
    offset: u8,
};

/// The builtins: GLSL's functions, and the shader's own.
pub const Builtin = enum(u8) {
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    sinh,
    cosh,
    tanh,
    exp,
    exp2,
    log,
    log2,
    sqrt,
    inversesqrt,
    abs,
    sign,
    floor,
    ceil,
    fract,
    round,
    trunc,
    normalize,
    pow,
    atan2,
    mod,
    min,
    max,
    step,
    clamp,
    mix,
    smoothstep,
    length,
    distance,
    dot,
    cross,
    reflect,
    /// The box's size in points.
    size,
    /// Pixels a point.
    pixel_scale,
    /// The pixel's center in the frame's pixels.
    pixel,
    /// What is drawn under the box (blurred by the effect's blur) at a
    /// point of the box: premultiplied, opaque.
    backdrop,

    pub fn parse(s: []const u8) ?Builtin {
        return std.meta.stringToEnum(Builtin, s);
    }
};

pub const Error = struct {
    at: u32 = 0,
    msg: [160]u8 = undefined,
    len: u8 = 0,

    pub fn text(e: *const Error) []const u8 {
        return e.msg[0..e.len];
    }
};

/// The line and column (from 1) of offset `at` in `src`.
pub fn lineCol(src: []const u8, at: u32) [2]u32 {
    var line: u32 = 1;
    var col: u32 = 1;
    for (src[0..@min(at, src.len)]) |ch| {
        if (ch == '\n') {
            line += 1;
            col = 1;
        } else col += 1;
    }
    return .{ line, col };
}

/// A program as the parser and checker build it.
pub const Program = struct {
    src: []const u8,
    nodes: [max_nodes]Node = undefined,
    n_nodes: u16 = 1,
    list: [max_list]u16 = undefined,
    n_list: u16 = 0,
    fns: [max_fns]Fn = undefined,
    n_fns: u8 = 0,
    uniforms: [max_uniforms]Uniform = undefined,
    n_uniforms: u8 = 0,
    /// Global constants: name and value node, by order of declaration.
    consts: [max_uniforms * 4]struct { name: Str, value: u16 } = undefined,
    n_consts: u8 = 0,
    slots: [max_slots]Type = undefined,
    n_slots: u16 = 0,
    /// The function `fragment`.
    entry: u8 = 0,
    err: Error = .{},

    pub fn text(p: *const Program, s: Str) []const u8 {
        return p.src[s.at..][0..s.len];
    }

    pub fn args(p: *const Program, n: *const Node) []const u16 {
        return p.list[n.a..][0..n.b];
    }

    pub fn add(p: *Program, n: Node) error{Shader}!u16 {
        if (p.n_nodes >= max_nodes) return p.fail(n.str.at, "the shader is too long", .{});
        p.nodes[p.n_nodes] = n;
        p.n_nodes += 1;
        return p.n_nodes - 1;
    }

    pub fn addList(p: *Program, items: []const u16) error{Shader}!u16 {
        if (@as(usize, p.n_list) + items.len > max_list) return p.fail(0, "the shader is too long", .{});
        const at = p.n_list;
        @memcpy(p.list[at..][0..items.len], items);
        p.n_list += @intCast(items.len);
        return at;
    }

    /// Records the first error, at offset `at`.
    pub fn fail(p: *Program, at: u32, comptime fmt: []const u8, a: anytype) error{Shader} {
        if (p.err.len == 0) {
            const s = std.fmt.bufPrint(&p.err.msg, fmt, a) catch p.err.msg[0..];
            p.err.len = @intCast(s.len);
            p.err.at = at;
        }
        return error.Shader;
    }

    pub fn fnNamed(p: *const Program, name: []const u8) ?u8 {
        for (p.fns[0..p.n_fns], 0..) |f, i| {
            if (std.mem.eql(u8, p.text(f.name), name)) return @intCast(i);
        }
        return null;
    }
};

test "types and their widths" {
    try std.testing.expectEqual(@as(u8, 3), Type.vec3.width());
    try std.testing.expectEqual(Type.vec2, Type.parse("vec2").?);
    try std.testing.expect(Type.parse("float") == null);
    try std.testing.expectEqual(Builtin.smoothstep, Builtin.parse("smoothstep").?);
    try std.testing.expectEqual([2]u32{ 2, 3 }, lineCol("ab\ncd", 5));
}
