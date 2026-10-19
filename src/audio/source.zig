//! Where players' frames come from: a `Decoder` (a file decoded as it
//! plays, or sound an app makes as it plays, as a synthesizer), and a
//! `Sound`'s samples decoded once into memory, which any number of players
//! read at once.
const std = @import("std");

/// Decodes interleaved float frames: implement it for a format of your
/// own, or for sound the app computes as it plays.
pub const Decoder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    rate: u32,
    channels: u16,
    /// How many frames, or null for a stream of unknown length (endless).
    frames: ?u64,

    pub const VTable = struct {
        /// Fills `dst` (a whole number of frames) and returns how many
        /// frames it read: 0 only at the end.
        read: *const fn (ptr: *anyopaque, dst: []f32) anyerror!usize,
        seek: *const fn (ptr: *anyopaque, frame: u64) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn read(d: Decoder, dst: []f32) !usize {
        return d.vtable.read(d.ptr, dst);
    }
    pub fn seek(d: Decoder, frame: u64) !void {
        return d.vtable.seek(d.ptr, frame);
    }
    pub fn deinit(d: Decoder) void {
        d.vtable.deinit(d.ptr);
    }
};

/// Decoded samples, interleaved, kept while a player plays them: freed
/// with the last of `release` and its players.
pub const Sound = struct {
    gpa: std.mem.Allocator,
    samples: []f32,
    rate: u32,
    channels: u16,
    refs: std.atomic.Value(u32) = .init(1),

    /// Takes `samples` (allocated with `gpa`).
    pub fn create(gpa: std.mem.Allocator, rate: u32, channels: u16, samples: []f32) !*Sound {
        std.debug.assert(channels >= 1 and samples.len % channels == 0);
        const s = try gpa.create(Sound);
        s.* = .{ .gpa = gpa, .samples = samples, .rate = rate, .channels = channels };
        return s;
    }

    /// Decodes all of `d` (which it then closes).
    pub fn decode(gpa: std.mem.Allocator, d: Decoder) !*Sound {
        defer d.deinit();
        var all: std.ArrayList(f32) = .empty;
        errdefer all.deinit(gpa);
        if (d.frames) |n| try all.ensureTotalCapacity(gpa, @intCast(n * d.channels));
        var buf: [4096]f32 = undefined;
        const per = buf.len / d.channels * d.channels;
        while (true) {
            const n = try d.read(buf[0..per]);
            if (n == 0) break;
            try all.appendSlice(gpa, buf[0 .. n * d.channels]);
            if (all.items.len > 1 << 30) return error.TooLong;
        }
        return create(gpa, d.rate, d.channels, try all.toOwnedSlice(gpa));
    }

    pub fn frames(s: *const Sound) u64 {
        return s.samples.len / s.channels;
    }

    /// How long it plays, in seconds.
    pub fn duration(s: *const Sound) f64 {
        return @as(f64, @floatFromInt(s.frames())) / @as(f64, @floatFromInt(s.rate));
    }

    pub fn retain(s: *Sound) void {
        _ = s.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(s: *Sound) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        s.gpa.free(s.samples);
        s.gpa.destroy(s);
    }
};

/// A player's frames: a sound's, or a decoder's. Runs under the mixer's
/// lock, on the output's thread.
pub const Source = union(enum) {
    sound: struct { sound: *Sound, pos: u64 = 0 },
    stream: struct { decoder: Decoder, pos: u64 = 0, ended: bool = false },

    pub fn channels(s: *const Source) u16 {
        return switch (s.*) {
            .sound => |m| m.sound.channels,
            .stream => |st| st.decoder.channels,
        };
    }

    pub fn rate(s: *const Source) u32 {
        return switch (s.*) {
            .sound => |m| m.sound.rate,
            .stream => |st| st.decoder.rate,
        };
    }

    pub fn length(s: *const Source) ?u64 {
        return switch (s.*) {
            .sound => |m| m.sound.frames(),
            .stream => |st| st.decoder.frames,
        };
    }

    /// Reads frames into `dst`, going on from `loop_start` at `loop_end`
    /// (the end when null) when `loop`. Returns the frames read: fewer
    /// than fit only at the end.
    pub fn read(s: *Source, dst: []f32, loop: bool, loop_start: u64, loop_end: ?u64) usize {
        const ch = s.channels();
        const want = dst.len / ch;
        var n: usize = 0;
        var guard: u32 = 0;
        while (n < want) : (guard += 1) {
            if (guard > 64) break; // an empty loop
            const limit: ?u64 = if (loop) (loop_end orelse s.length()) else s.length();
            const pos = s.position();
            if (limit) |l| if (pos >= l) {
                if (!loop or l == 0) break;
                s.seek(if (loop_start < l) loop_start else 0);
                continue;
            };
            var take = want - n;
            if (limit) |l| take = @min(take, l - pos);
            const got = switch (s.*) {
                .sound => |*m| blk: {
                    const from = m.pos * ch;
                    const k = @min(take, m.sound.frames() - m.pos);
                    @memcpy(dst[n * ch ..][0 .. k * ch], m.sound.samples[from..][0 .. k * ch]);
                    m.pos += k;
                    break :blk k;
                },
                .stream => |*st| blk: {
                    const k = st.decoder.read(dst[n * ch ..][0 .. take * ch]) catch 0;
                    st.pos += k;
                    if (k == 0) st.ended = true;
                    break :blk k;
                },
            };
            n += got;
            if (got == 0) {
                // The end of a stream of unknown length.
                if (!loop) break;
                s.seek(loop_start);
            }
        }
        return n;
    }

    pub fn position(s: *const Source) u64 {
        return switch (s.*) {
            .sound => |m| m.pos,
            .stream => |st| st.pos,
        };
    }

    pub fn seek(s: *Source, frame: u64) void {
        switch (s.*) {
            .sound => |*m| m.pos = @min(frame, m.sound.frames()),
            .stream => |*st| {
                st.decoder.seek(frame) catch {};
                st.pos = frame;
                st.ended = false;
            },
        }
    }

    pub fn deinit(s: *Source) void {
        switch (s.*) {
            .sound => |m| m.sound.release(),
            .stream => |st| st.decoder.deinit(),
        }
    }
};

test "a sound's source loops a range" {
    const gpa = std.testing.allocator;
    const samples = try gpa.dupe(f32, &.{ 0, 1, 2, 3, 4, 5 });
    const s = try Sound.create(gpa, 10, 1, samples);
    var src: Source = .{ .sound = .{ .sound = s } };
    defer src.deinit();
    var out: [10]f32 = undefined;
    // An intro (0, 1), then 2..4 again and again.
    try std.testing.expectEqual(@as(usize, 10), src.read(&out, true, 2, 5));
    try std.testing.expectEqualSlices(f32, &.{ 0, 1, 2, 3, 4, 2, 3, 4, 2, 3 }, &out);
    src.seek(4);
    try std.testing.expectEqual(@as(usize, 2), src.read(&out, false, 0, null));
}
