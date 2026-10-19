//! The game loop's clock and input: steps of fixed length (`rate` a
//! second, 60 by default) whatever the display's rate, catching up a
//! quarter of a second at most after a pause, and the player's input as a
//! step sees it.
const std = @import("std");

pub const default_rate = 60;
/// The most time steps catch up on after a pause (a window out of sight).
pub const max_catch_up: f64 = 0.25;

/// Accumulates frame time into whole steps.
pub const Clock = struct {
    rate: u32 = default_rate,
    lag: f64 = 0,

    /// Adds a frame of `dt` seconds: how many steps to run now.
    pub fn advance(c: *Clock, dt: f64) u32 {
        c.lag += std.math.clamp(dt, 0, max_catch_up);
        const step = 1.0 / @as(f64, @floatFromInt(c.rate));
        var n: u32 = 0;
        // A hair of tolerance, so that 1/60 s frames make one step each.
        while (c.lag >= step - 1e-9) : (n += 1) c.lag -= step;
        if (c.lag < 0) c.lag = 0;
        return n;
    }

    /// How far the frame is into the next step, 0 to 1: for drawing what
    /// moves between its last two places.
    pub fn alpha(c: *const Clock) f32 {
        const step = 1.0 / @as(f64, @floatFromInt(c.rate));
        return @floatCast(std.math.clamp(c.lag / step, 0, 1));
    }
};

/// Keys by position: `w` is the key in W's place, as WASD wants.
pub const Key = enum(u8) {
    a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z,
    @"0", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9",
    space, enter, escape, tab, backspace, up, down, left, right, shift, ctrl, alt,

    /// The key of a typed character, if it is one of these.
    pub fn fromChar(ch: u8) ?Key {
        return switch (std.ascii.toLower(ch)) {
            'a'...'z' => |l| @enumFromInt(l - 'a'),
            '0'...'9' => |d| @enumFromInt(26 + d - '0'),
            ' ' => .space,
            else => null,
        };
    }
};

const key_count = @typeInfo(Key).@"enum".field_names.len;
comptime {
    std.debug.assert(key_count <= 64);
}
/// A set of keys, a bit each.
const KeySet = u64;

fn bit(i: usize) u64 {
    return @as(u64, 1) << @intCast(i);
}

/// The player's input as a step sees it.
pub const Input = struct {
    down_keys: KeySet = 0,
    pressed_keys: KeySet = 0,
    released_keys: KeySet = 0,
    /// Keys that came as presses alone (myzig's ui reports no releases
    /// for typed keys): released after the step that saw them.
    taps: KeySet = 0,
    pointer: [2]f32 = .{ 0, 0 },
    over: bool = false,
    buttons: [3]bool = .{ false, false, false },
    buttons_pressed: [3]bool = .{ false, false, false },
    buttons_released: [3]bool = .{ false, false, false },
    wheel: [2]f32 = .{ 0, 0 },
    size: [2]f32 = .{ 0, 0 },
    focused: bool = true,

    /// Key `k` is held.
    pub fn down(in: *const Input, k: Key) bool {
        return in.down_keys & bit(@intFromEnum(k)) != 0;
    }
    /// `k` was pressed since the step before, even between two steps.
    pub fn pressed(in: *const Input, k: Key) bool {
        return in.pressed_keys & bit(@intFromEnum(k)) != 0;
    }
    pub fn released(in: *const Input, k: Key) bool {
        return in.released_keys & bit(@intFromEnum(k)) != 0;
    }
    pub fn pointerDown(in: *const Input, b: usize) bool {
        return b < 3 and in.buttons[b];
    }
    pub fn pointerPressed(in: *const Input, b: usize) bool {
        return b < 3 and in.buttons_pressed[b];
    }
    pub fn pointerReleased(in: *const Input, b: usize) bool {
        return b < 3 and in.buttons_released[b];
    }

    /// A key went down (from the platform, or a test).
    pub fn keyDown(in: *Input, k: Key) void {
        const i = @intFromEnum(k);
        if (in.down_keys & bit(i) == 0) in.pressed_keys |= bit(i);
        in.down_keys |= bit(i);
    }

    pub fn keyUp(in: *Input, k: Key) void {
        const i = @intFromEnum(k);
        if (in.down_keys & bit(i) != 0) in.released_keys |= bit(i);
        in.down_keys &= ~bit(i);
        in.taps &= ~bit(i);
    }

    /// A press whose release never comes: held for the next step only.
    pub fn tap(in: *Input, k: Key) void {
        in.keyDown(k);
        in.taps |= bit(@intFromEnum(k));
    }

    pub fn button(in: *Input, b: usize, is_down: bool) void {
        if (b >= 3) return;
        if (is_down and !in.buttons[b]) in.buttons_pressed[b] = true;
        if (!is_down and in.buttons[b]) in.buttons_released[b] = true;
        in.buttons[b] = is_down;
    }

    /// Lets go of everything held, as when the window loses the keyboard
    /// and the releases never come.
    pub fn releaseAll(in: *Input) void {
        in.released_keys |= in.down_keys;
        in.down_keys = 0;
        in.taps = 0;
        for (0..3) |b| in.button(b, false);
    }

    /// After a step: edges are cleared, taps released.
    pub fn endStep(in: *Input) void {
        in.pressed_keys = 0;
        in.released_keys = in.taps;
        in.down_keys &= ~in.taps;
        in.taps = 0;
        in.buttons_pressed = .{ false, false, false };
        in.buttons_released = .{ false, false, false };
        in.wheel = .{ 0, 0 };
    }
};

test "steps are fixed: 60 a second at 60 Hz and at 120 Hz, catching up a quarter second at most" {
    var c: Clock = .{};
    var steps: u32 = 0;
    for (0..60) |_| steps += c.advance(1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 60), steps);
    c = .{};
    steps = 0;
    for (0..120) |_| steps += c.advance(1.0 / 120.0);
    try std.testing.expectEqual(@as(u32, 60), steps);
    c = .{};
    try std.testing.expectEqual(@as(u32, 15), c.advance(5.0));
    c = .{ .rate = 30 };
    _ = c.advance(1.0 / 60.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), c.alpha(), 1e-4);
}

test "presses are seen by the next step, even between steps; taps release after it" {
    var in: Input = .{};
    in.keyDown(.w);
    in.keyUp(.w); // within one frame
    try std.testing.expect(in.pressed(.w) and in.released(.w) and !in.down(.w));
    in.endStep();
    try std.testing.expect(!in.pressed(.w));
    in.tap(.space);
    try std.testing.expect(in.down(.space) and in.pressed(.space));
    in.endStep();
    try std.testing.expect(!in.down(.space) and in.released(.space));
    in.keyDown(.a);
    in.button(0, true);
    in.releaseAll();
    try std.testing.expect(!in.down(.a) and in.released(.a) and in.pointerReleased(0));
    try std.testing.expectEqual(Key.w, Key.fromChar('W').?);
    try std.testing.expectEqual(Key.@"7", Key.fromChar('7').?);
}
