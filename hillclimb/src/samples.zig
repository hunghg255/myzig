//! Timing buffers for the build, layout and paint phases of a run.
const std = @import("std");

/// The caller frees each buffer with `gpa`.
pub fn allocPhases(gpa: std.mem.Allocator, frames: usize) std.mem.Allocator.Error![3][]f64 {
    var phases: [3][]f64 = undefined;
    for (&phases, 0..) |*phase, i| {
        errdefer for (phases[0..i]) |allocated| gpa.free(allocated);
        phase.* = try gpa.alloc(f64, frames);
    }
    return phases;
}

fn checkPhases(gpa: std.mem.Allocator) !void {
    const phases = try allocPhases(gpa, 7);
    defer for (phases) |phase| gpa.free(phase);
    for (phases, 0..) |phase, i| {
        try std.testing.expectEqual(@as(usize, 7), phase.len);
        @memset(phase, @as(f64, @floatFromInt(i)));
    }
    // Each phase owns a distinct writable buffer.
    for (phases, 0..) |phase, i| {
        for (phase) |value| try std.testing.expectEqual(@as(f64, @floatFromInt(i)), value);
    }
}

test "phase samples release earlier buffers when any allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkPhases, .{});
}
