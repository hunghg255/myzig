//! Compiles `d3d11.hlsl` ahead of time into `d3d11.cso`, which the
//! Direct3D renderer embeds: windows open without loading the shader
//! compiler (about 100 ms). Run on Windows after changing the shader:
//!
//!     zig run src/ui/d3d11_gen.zig
//!
//! The file is the source's hash (8 bytes, little endian), the vertex
//! shader's length (4 bytes), then the vertex and the pixel shader's
//! bytecode. A renderer whose embedded hash is not its source's compiles
//! the source when it starts instead.
const std = @import("std");
const d3d = @import("d3d11_api.zig");

pub const source = @embedFile("d3d11.hlsl");

/// The source's hash, carriage returns left out: a checkout with Windows
/// line endings is the same source.
pub fn sourceHash() u64 {
    var h: std.hash.Wyhash = .init(0xd3d11);
    var lines = std.mem.splitScalar(u8, source, 0x0d);
    while (lines.next()) |part| h.update(part);
    return h.final();
}

pub const Code = struct { vs: []const u8, ps: []const u8 };

/// The bytecode `d3d11.cso` holds, when it is the source's.
/// `sourceHash()` at compile time: apps don't carry the source to hash it.
pub const source_hash: u64 = blk: {
    @setEvalBranchQuota(source.len * 50 + 10_000);
    break :blk sourceHash();
};

pub fn embedded(cso: []const u8) ?Code {
    if (cso.len < 12 or std.mem.readInt(u64, cso[0..8], .little) != source_hash) return null;
    const n = std.mem.readInt(u32, cso[8..12], .little);
    if (12 + n > cso.len) return null;
    return .{ .vs = cso[12..][0..n], .ps = cso[12 + n ..] };
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const vs = try d3d.compile(gpa, source, "vs", "vs_4_0");
    const ps = try d3d.compile(gpa, source, "ps", "ps_4_0");
    var out: std.ArrayList(u8) = .empty;
    var head: [12]u8 = undefined;
    std.mem.writeInt(u64, head[0..8], sourceHash(), .little);
    std.mem.writeInt(u32, head[8..12], @intCast(vs.len), .little);
    try out.appendSlice(gpa, &head);
    try out.appendSlice(gpa, vs);
    try out.appendSlice(gpa, ps);
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "src/ui/d3d11.cso", .data = out.items });
}
