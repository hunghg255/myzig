//! `zig build check-msl`: myzig's Metal Shading Language checked by the
//! clang inside Zig, where no Mac (and no Metal compiler) is. Each source
//! is assembled as the Metal renderer hands it to Metal (`metal.zig`,
//! `metal_fx.zig`): `shader.metal` minified; `metal_fx.metal` minified
//! alone (the passes' library) and followed by each effect's color and
//! the effect's entry point (`effect_main`, read from `metal_fx.zig`):
//! the plain backdrop, the glass plugin's, and every shader the shader
//! compiler makes for the GPU tests and the examples. Each is checked as
//! C++14 against `metal_stdlib`, a stand-in that declares Metal's types
//! and functions with their overloads.
//!
//!     check <zig> <out dir>     (run from the repository's root)
//!
//! The assembled sources land in the out dir (`<name>.metal`, and the
//! `<name>.cpp` clang reads, where the diagnostics point).
//!
//! What it cannot check (it is not Apple's compiler): address spaces
//! (`constant` and the others are erased, so a constant pointer passed
//! where a thread one is wanted passes), the attributes (`[[buffer(0)]]`
//! and the others are ignored: indices, `[[stage_in]]` matching the vertex
//! output), Metal's restrictions on C++ (no recursion, lambdas or virtual
//! functions), comparisons of vectors (clang gives int vectors, which
//! convert to Metal's bool vectors), and anything of the pipeline's
//! (pixel formats, buffer layouts against `gpu.Instance`).
const std = @import("std");
const ui = @import("myzig").ui;

const tests = @import("test_shaders");
const Effect = @TypeOf(tests.rings.effect);

/// The effects every shader of the compiler and the plugins make.
const effects = blk: {
    var list: []const *const Effect = &.{&@import("glass").glass};
    for (tests.all) |s| list = list ++ .{&s.effect};
    const chat = @import("chat_glow");
    const effort = @import("effort_slider");
    const compiled = [_]*const ui.shader.Shader{
        &@import("blackhole").hole,
        &chat.orb,
        &chat.ring,
        &chat.edge,
        &chat.shimmer,
        &effort.track_shader,
        &effort.brain_shader,
        &@import("mayoi").street,
        &@import("wind").shader,
        &@import("coverage.zig").shader,
    };
    for (compiled) |s| list = list ++ .{&s.effect};
    break :blk list;
};

// `zig c++ -fsyntax-only` fails renaming the object it didn't make:
// `zig clang` runs clang's driver as it is.
const clang_flags = [_][]const u8{
    "clang",
    "-fsyntax-only",
    "-x",
    "c++",
    "-std=c++14",
    "-fno-exceptions",
    "-fno-rtti",
    // Metal's vectors don't convert implicitly, and its literals are floats.
    "-flax-vector-conversions=none",
    "-Xclang",
    "-cl-single-precision-constant",
    "-Wall",
    "-Wextra",
    "-Wno-unknown-attributes",
    "-Wno-unused-function",
    "-Wno-unused-parameter",
    // The emitter parenthesizes every expression.
    "-Wno-parentheses-equality",
    "-ferror-limit=50",
    "-Itools/msl",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: check <zig> <out dir>\n", .{});
        std.process.exit(2);
    }
    const zig = args[1];
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, args[2]);
    var out = try cwd.openDir(io, args[2], .{});
    defer out.close(io);

    const read = struct {
        fn f(i: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
            return std.Io.Dir.cwd().readFileAlloc(i, path, a, .limited(4 << 20));
        }
    }.f;
    const shader = try read(io, arena, "src/ui/shader.metal");
    const fx = try minify(arena, try read(io, arena, "src/ui/metal_fx.metal"));
    const fx_zig = try read(io, arena, "src/ui/metal_fx.zig");
    const effect_main = try multiline(arena, fx_zig, "effect_main");
    const plain_color = try multiline(arena, fx_zig, "plain_color");

    var sources: std.ArrayList([2][]const u8) = .empty;
    try sources.append(arena, .{ "shader", shader });
    try sources.append(arena, .{ "shader.min", try minify(arena, shader) });
    try sources.append(arena, .{ "fx-passes", fx });
    // As `effectPipeline` joins them: the passes, "\n", the color, the entry.
    try sources.append(arena, .{ "fx-plain", try std.mem.concat(arena, u8, &.{ fx, "\n", plain_color, effect_main }) });
    for (effects) |e| {
        if (e.msl.len == 0) continue;
        try sources.append(arena, .{ try std.fmt.allocPrint(arena, "fx-{s}", .{e.name}), try std.mem.concat(arena, u8, &.{ fx, "\n", e.msl, effect_main }) });
    }

    var failed: usize = 0;
    for (sources.items) |s| {
        const metal = try std.fmt.allocPrint(arena, "{s}.metal", .{s[0]});
        try out.writeFile(io, .{ .sub_path = metal, .data = s[1] });
        const cpp_name = try std.fmt.allocPrint(arena, "{s}.cpp", .{s[0]});
        try out.writeFile(io, .{ .sub_path = cpp_name, .data = try constructors(arena, s[1]) });
        const cpp = try std.fs.path.join(arena, &.{ args[2], cpp_name });
        const argv = try std.mem.concat(arena, []const u8, &.{ &.{zig}, &clang_flags, &.{cpp} });
        const r = try std.process.run(arena, io, .{ .argv = argv });
        const ok = r.term == .exited and r.term.exited == 0;
        if (!ok) failed += 1;
        const warned = std.mem.indexOf(u8, r.stderr, "warning:") != null;
        std.debug.print("{s} {s}\n", .{ if (!ok) "FAIL" else if (warned) "warn" else "ok  ", s[0] });
        if (r.stderr.len > 0) std.debug.print("{s}", .{r.stderr});
    }
    std.debug.print("{d} Metal sources checked, {d} failed (out: {s})\n", .{ sources.items.len, failed, args[2] });
    if (failed > 0) std.process.exit(1);
}

/// What `shader_min.zig` makes of `src`: lines without `//` comments,
/// the spaces around them, and blank lines.
fn minify(a: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        var line = raw;
        if (std.mem.indexOf(u8, line, "//")) |at| line = line[0..at];
        line = std.mem.trim(u8, line, " \t\r");
        if (line.len == 0) continue;
        try out.appendSlice(a, line);
        try out.append(a, '\n');
    }
    return out.items;
}

/// The multiline string literal `const <name> =` in Zig source `src`.
fn multiline(a: std.mem.Allocator, src: []const u8, name: []const u8) ![]u8 {
    const head = try std.fmt.allocPrint(a, "const {s} =\n", .{name});
    const at = std.mem.indexOf(u8, src, head) orelse return error.NoSuchString;
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, src[at + head.len ..], '\n');
    var first = true;
    while (it.next()) |raw| {
        const line = std.mem.trimStart(u8, std.mem.trimEnd(u8, raw, "\r"), " ");
        if (!std.mem.startsWith(u8, line, "\\\\")) break;
        if (!first) try out.append(a, '\n');
        first = false;
        try out.appendSlice(a, line[2..]);
    }
    if (first) return error.NoSuchString;
    return out.items;
}

const vector_types = [_][]const u8{ "float", "half", "int", "uint", "short", "ushort", "char", "uchar", "bool" };

/// `src` with Metal's vector constructors (`float3(v.xy, 1.0)`), which
/// C++ has no syntax for, as calls of `metal_stdlib`'s `__mtl_ctor`.
fn constructors(a: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        if (!isIdent(src[i]) or (i > 0 and isIdent(src[i - 1]))) {
            try out.append(a, src[i]);
            i += 1;
            continue;
        }
        var end = i;
        while (end < src.len and isIdent(src[end])) end += 1;
        const word = src[i..end];
        if (end < src.len and src[end] == '(' and isVector(word)) {
            try out.print(a, "__mtl_ctor<{s}>", .{word});
        } else try out.appendSlice(a, word);
        i = end;
    }
    return out.items;
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn isVector(word: []const u8) bool {
    if (word.len < 2) return false;
    const n = word[word.len - 1];
    if (n < '2' or n > '4') return false;
    for (vector_types) |t| if (std.mem.eql(u8, word[0 .. word.len - 1], t)) return true;
    return false;
}

test "constructors become calls; declarations and longer names stay" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const got = try constructors(arena.allocator(), "float2 p = float2(1, 2); packed_float3(x); myfloat2(y); float4x4(z);");
    try std.testing.expectEqualStrings("float2 p = __mtl_ctor<float2>(1, 2); packed_float3(x); myfloat2(y); float4x4(z);", got);
}
