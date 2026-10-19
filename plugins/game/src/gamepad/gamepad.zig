//! Game controllers, read in one standard layout (the W3C Gamepad API's
//! and SDL's): buttons by place, two sticks, analog triggers, a d-pad.
//! XInput on Windows (Xbox controllers and those acting as one), evdev on
//! Linux (what the kernel reports as gamepads, readable at the seat).
//! macOS has none yet (GameController.framework is left to do).
//!
//!     var pads: gamepad.Pads = .{};
//!     defer pads.deinit();
//!     pads.update(now_seconds); // once a frame
//!     if (pads.list().len > 0) {
//!         const s = pads.list()[0].state;
//!         const x, const y = s.leftStick(); // -1..1, right and down, with a dead zone
//!         if (s.justPressed(last, .south)) jump();
//!         last = s;
//!     }
const std = @import("std");
const builtin = @import("builtin");

pub const Button = enum(u5) {
    south, east, west, north,
    left_shoulder, right_shoulder, left_trigger, right_trigger,
    back, start, left_stick, right_stick,
    up, down, left, right, guide,
};

pub const Axis = enum(u2) { left_x, left_y, right_x, right_y };

pub const button_count = 17;
/// A stick at rest reads nothing within this radius.
pub const deadzone: f32 = 0.15;
/// A button (a trigger) counts as pressed a quarter of the way.
pub const press_threshold: f32 = 0.25;

/// A pad's controls at one moment.
pub const State = struct {
    buttons: [button_count]f32 = @splat(0),
    axes: [4]f32 = @splat(0),

    /// 0 to 1; the triggers by how far they are pulled.
    pub fn value(s: State, b: Button) f32 {
        return s.buttons[@intFromEnum(b)];
    }
    pub fn pressed(s: State, b: Button) bool {
        return s.value(b) >= press_threshold;
    }
    pub fn justPressed(s: State, last: State, b: Button) bool {
        return s.pressed(b) and !last.pressed(b);
    }
    pub fn justReleased(s: State, last: State, b: Button) bool {
        return !s.pressed(b) and last.pressed(b);
    }
    /// -1 to 1, right and down positive, as the pad reports it.
    pub fn axis(s: State, a: Axis) f32 {
        return s.axes[@intFromEnum(a)];
    }
    pub fn leftStick(s: State) [2]f32 {
        return radial(s.axes[0], s.axes[1]);
    }
    pub fn rightStick(s: State) [2]f32 {
        return radial(s.axes[2], s.axes[3]);
    }
};

/// A radial dead zone, rescaled, so that a stick leans as far every way.
pub fn radial(x: f32, y: f32) [2]f32 {
    const m = @sqrt(x * x + y * y);
    if (m <= deadzone) return .{ 0, 0 };
    const k = @min(1, (m - deadzone) / (1 - deadzone)) / m;
    return .{ x * k, y * k };
}

pub const Pad = struct {
    /// Unique while the app runs: plugged in again, a pad is a new one.
    id: u32,
    name: []const u8,
    state: State = .{},
    connected: bool = true,
    device: backend.Device,
};

const backend = switch (builtin.os.tag) {
    .windows => @import("xinput.zig"),
    .linux => @import("evdev.zig"),
    else => @import("none.zig"),
};

/// The pads connected, in the order they connected.
pub const Pads = struct {
    pads: [8]Pad = undefined,
    len: usize = 0,
    next_id: u32 = 1,
    last_scan: f64 = -1e9,

    pub fn deinit(p: *Pads) void {
        for (p.pads[0..p.len]) |*pad| backend.close(&pad.device);
        p.len = 0;
    }

    /// Reads every pad now, and looks for new ones at most once a second
    /// (`now` in seconds, any clock). A pad that stopped answering leaves.
    pub fn update(p: *Pads, now: f64) void {
        var i: usize = 0;
        while (i < p.len) {
            const pad = &p.pads[i];
            if (backend.read(&pad.device, &pad.state)) {
                i += 1;
            } else {
                pad.connected = false;
                backend.close(&pad.device);
                std.mem.copyForwards(Pad, p.pads[i .. p.len - 1], p.pads[i + 1 .. p.len]);
                p.len -= 1;
            }
        }
        if (now - p.last_scan < 1) return;
        p.last_scan = now;
        var found: [8]backend.Device = undefined;
        var keys: [8]backend.Device = undefined;
        for (p.pads[0..p.len], 0..) |pad, k| keys[k] = pad.device;
        const n = backend.scan(keys[0..p.len], &found);
        for (found[0..n]) |d| {
            if (p.len == p.pads.len) {
                var dev = d;
                backend.close(&dev);
                continue;
            }
            p.pads[p.len] = .{ .id = p.next_id, .name = backend.name(&d), .device = d };
            p.next_id += 1;
            _ = backend.read(&p.pads[p.len].device, &p.pads[p.len].state);
            p.len += 1;
        }
    }

    pub fn list(p: *Pads) []Pad {
        return p.pads[0..p.len];
    }
};

test "a radial dead zone: nothing at rest, full at the edge, every way alike" {
    try std.testing.expectEqual([2]f32{ 0, 0 }, radial(0.1, -0.1));
    const full = radial(1, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), full[0], 1e-5);
    const diag = radial(0.5, 0.5);
    const m = @sqrt(diag[0] * diag[0] + diag[1] * diag[1]);
    try std.testing.expectApproxEqAbs((@sqrt(@as(f32, 0.5)) - deadzone) / (1 - deadzone), m, 1e-5);
}

test "buttons: pressed a quarter of the way, just pressed and released against the last state" {
    var last: State = .{};
    var s: State = .{};
    s.buttons[@intFromEnum(Button.right_trigger)] = 0.3;
    try std.testing.expect(s.pressed(.right_trigger) and s.justPressed(last, .right_trigger));
    last = s;
    s.buttons[@intFromEnum(Button.right_trigger)] = 0.1;
    try std.testing.expect(s.justReleased(last, .right_trigger));
}

test {
    _ = backend;
}
