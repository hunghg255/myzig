//! Copies a file of `src/ui/shader/` (the GPU tests' shaders) for the MSL
//! check (`check.zig`), its import of `shader.zig` made one of myzig's
//! module: a module of its own could not reach `../effect.zig`.
//!
//!     rehome <in> <out>
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: rehome <in> <out>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const src = try cwd.readFileAlloc(io, args[1], arena, .limited(1 << 20));
    const out = try std.mem.replaceOwned(u8, arena, src, "@import(\"shader.zig\")", "@import(\"myzig\").ui.shader");
    if (std.mem.eql(u8, out, src)) {
        std.debug.print("rehome: {s} does not import shader.zig\n", .{args[1]});
        std.process.exit(1);
    }
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out });
}
