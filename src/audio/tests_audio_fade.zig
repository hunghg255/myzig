//! Volume fades through a manual engine: frames pulled by the test.
const std = @import("std");
const audio = @import("audio.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;

/// A second of a 300 Hz sine at 48 kHz, amplitude 0.5, made in memory.
fn sine(e: *audio.Engine) !*audio.Sound {
    const s = try gpa.alloc(f32, 48000 * 2);
    for (s, 0..) |*x, i| x.* = 0.5 * @sin(2 * std.math.pi * 300 * @as(f32, @floatFromInt(i)) / 48000);
    return e.newSound(48000, 1, s);
}

fn pull(e: *audio.Engine, frames: usize) ![]f32 {
    const out = try gpa.alloc(f32, frames * 2);
    var at: usize = 0;
    while (at < out.len) : (at += 480 * 2) _ = e.render(out[at..@min(out.len, at + 480 * 2)]);
    return out;
}

/// The left channel's RMS over frames [a, b).
fn rms(s: []const f32, a: usize, b: usize) f32 {
    var sum: f64 = 0;
    for (a..b) |f| sum += s[f * 2] * s[f * 2];
    return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(b - a))));
}

const full: f32 = 0.5 / std.math.sqrt2;

test "audio: a fade in rises from silence in a straight line; a fade to a volume lands on it" {
    const e = try audio.Engine.create(gpa, io, .{ .device = .manual });
    defer e.destroy();
    const s = try sine(e);
    defer s.release();
    const p = try e.newPlayer(s);
    defer p.release();
    p.fadeIn(0.5);
    const out = try pull(e, 36000);
    defer gpa.free(out);
    // Tenths of the half second: each louder, about as loud as the line says.
    var last: f32 = 0;
    for (0..10) |k| {
        const r = rms(out, k * 2400, (k + 1) * 2400);
        try std.testing.expect(r > last);
        try std.testing.expectApproxEqAbs(full * (@as(f32, @floatFromInt(k)) + 0.5) / 10, r, 0.01);
        last = r;
    }
    try std.testing.expectApproxEqAbs(full, rms(out, 24000, 36000), 0.005);
    _ = p.fadeTo(0.5, 0.1);
    const half = try pull(e, 9600);
    defer gpa.free(half);
    try std.testing.expectApproxEqAbs(full / 2, rms(half, 4800, 9600), 0.005);
}

test "audio: a fade out ends in silence and a pause; playing again plays at the volume it had" {
    const e = try audio.Engine.create(gpa, io, .{ .device = .manual });
    defer e.destroy();
    const s = try sine(e);
    defer s.release();
    const p = try e.newPlayer(s);
    defer p.release();
    _ = p.setVolume(0.8);
    p.play();
    const before = try pull(e, 2400);
    defer gpa.free(before);
    p.fadeOut(0.2);
    const out = try pull(e, 14400);
    defer gpa.free(out);
    try std.testing.expect(rms(out, 0, 2400) > rms(out, 4800, 7200));
    try std.testing.expectEqual(@as(f32, 0), rms(out, 9840, 14400));
    try std.testing.expect(!p.playing());
    p.play();
    const again = try pull(e, 4800);
    defer gpa.free(again);
    try std.testing.expectApproxEqAbs(full * 0.8, rms(again, 480, 4800), 0.005);
}
