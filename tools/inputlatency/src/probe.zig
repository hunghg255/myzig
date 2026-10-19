//! The probe: a square in the window's top left corner whose color tells
//! the number of the last event handled (or frame built), as read back
//! from the desktop (Windows). Six bits of it, three in red and three in
//! green, in steps of 32 a channel, which survive a few levels of error
//! (composition, color conversion); blue tells that the probe shows.
//! `Unwrap` turns the six bits back into the number, which only grows.
const std = @import("std");
const myzig = @import("myzig");

/// Where it is, in points of the view, and how large.
pub const origin: f32 = 8;
pub const side: f32 = 32;
/// The point read, in points of the view.
pub const sample: f32 = origin + side / 2;

const blue: u8 = 200;

/// The levels of the six bits of `seq`: red, green, blue.
pub fn levels(seq: u64) [3]u8 {
    const v: u8 = @intCast(seq & 63);
    return .{ (v & 7) * 32 + 16, (v >> 3) * 32 + 16, blue };
}

pub fn color(seq: u64) myzig.ui.Color {
    const l = levels(seq);
    return .{ .r = @as(f32, @floatFromInt(l[0])) / 255, .g = @as(f32, @floatFromInt(l[1])) / 255, .b = @as(f32, @floatFromInt(l[2])) / 255 };
}

/// The six bits a pixel shows, or null when it is not the probe's.
pub fn decode(r: u8, g: u8, b: u8) ?u6 {
    if (@abs(@as(i16, b) - blue) > 24) return null;
    const lo = r / 32;
    const hi = g / 32;
    return @intCast(@as(u8, hi) << 3 | lo);
}

/// Numbers from their six bits: the least at or after the last seen.
pub const Unwrap = struct {
    last: u64 = 0,

    pub fn next(u: *Unwrap, bits: u6) u64 {
        const base = u.last & ~@as(u64, 63);
        var n = base | bits;
        if (n < u.last) n += 64;
        u.last = n;
        return n;
    }
};

test "a number's color reads back as its bits, within a few levels" {
    for (0..200) |seq| {
        const l = levels(seq);
        for ([_]i16{ -12, 0, 12 }) |err| {
            const r: u8 = @intCast(@as(i16, l[0]) + err);
            const g: u8 = @intCast(@as(i16, l[1]) - err);
            try std.testing.expectEqual(@as(?u6, @intCast(seq & 63)), decode(r, g, l[2]));
        }
    }
    // Another color: not the probe.
    try std.testing.expectEqual(@as(?u6, null), decode(255, 255, 255));
}

test "bits unwrap into numbers that only grow" {
    var u: Unwrap = .{};
    try std.testing.expectEqual(@as(u64, 5), u.next(5));
    try std.testing.expectEqual(@as(u64, 5), u.next(5));
    try std.testing.expectEqual(@as(u64, 63), u.next(63));
    // Past 63: the next lap.
    try std.testing.expectEqual(@as(u64, 66), u.next(2));
    try std.testing.expectEqual(@as(u64, 127), u.next(63));
    try std.testing.expectEqual(@as(u64, 128), u.next(0));
}
