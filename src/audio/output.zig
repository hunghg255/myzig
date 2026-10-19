//! The system's audio output, opened by the engine's thread while anything
//! plays: WASAPI in shared mode on Windows, PulseAudio's simple API (which
//! PipeWire serves too) or else ALSA on Linux, an Audio Queue on macOS,
//! each loaded at run time. Where none opens, a null device plays nothing,
//! on time, so players still end when they would have; it gives up after
//! a while so that the real one is tried again.
const std = @import("std");
const builtin = @import("builtin");
const mixer = @import("mixer.zig");

/// Frames per write: 10 ms.
pub const frames_per_write: usize = mixer.rate / 100;

const backend = switch (builtin.os.tag) {
    .windows => @import("wasapi.zig"),
    .linux => @import("pulse.zig"),
    .macos => @import("audioqueue.zig"),
    else => NoBackend,
};

const NoBackend = struct {
    pub const Device = NoDevice;
    pub fn open() !NoDevice {
        return error.Unsupported;
    }
};
const NoDevice = struct {
    pub fn write(_: *NoDevice, _: []const f32) !void {}
    pub fn close(_: *NoDevice) void {}
};

pub const Device = struct {
    impl: union(enum) {
        real: backend.Device,
        none: NullDevice,
    },
    /// A device of the system's (not the null one).
    real: bool,

    /// Plays interleaved stereo frames after those written before, waiting
    /// while the device holds enough already. An error closes it.
    pub fn write(d: *Device, samples: []const f32) !void {
        switch (d.impl) {
            .real => |*r| try r.write(samples),
            .none => |*n| try n.write(samples),
        }
    }

    pub fn close(d: *Device) void {
        switch (d.impl) {
            .real => |*r| r.close(),
            .none => {},
        }
    }

    pub fn nullDevice(io: std.Io, retry: bool) Device {
        const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
        return .{ .impl = .{ .none = .{ .io = io, .next = now, .retry_at = if (retry) now + 2 * std.time.ns_per_s else null } }, .real = false };
    }
};

pub fn open(io: std.Io) !Device {
    _ = io;
    return .{ .impl = .{ .real = try backend.open() }, .real = true };
}

/// Plays nothing, on time.
pub const NullDevice = struct {
    io: std.Io,
    next: i96,
    retry_at: ?i96,

    pub fn write(d: *NullDevice, samples: []const f32) !void {
        const now = std.Io.Timestamp.now(d.io, .awake).nanoseconds;
        if (d.retry_at) |r| if (now > r) return error.Retry;
        // Behind, as after a sleep: don't hurry to catch up.
        if (now - d.next > 100 * std.time.ns_per_ms) d.next = now;
        d.next += @divTrunc(@as(i96, @intCast(samples.len / mixer.channels)) * std.time.ns_per_s, mixer.rate);
        const wait = d.next - now;
        if (wait > 0) d.io.sleep(.fromNanoseconds(wait), .awake) catch {};
    }
};
