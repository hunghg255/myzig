//! Gamepads on Linux through evdev: the /dev/input/event* devices whose
//! keys include the gamepad buttons, read without blocking. Xbox
//! controllers report X and Y as BTN_X and BTN_Y (BTN_NORTH and BTN_WEST's
//! codes), which this reads in place: West and North.
const std = @import("std");
const linux = std.os.linux;
const gp = @import("gamepad.zig");

const AbsInfo = extern struct { value: i32, minimum: i32, maximum: i32, fuzz: i32, flat: i32, resolution: i32 };
const InputEvent = extern struct { sec: isize, usec: isize, type: u16, code: u16, value: i32 };

const EV_KEY = 0x01;
const EV_ABS = 0x03;
const BTN_GAMEPAD = 0x130;

fn ior(nr: u32, size: u32) u32 {
    return (2 << 30) | (size << 16) | (0x45 << 8) | nr;
}

pub const Device = struct {
    fd: i32,
    /// Which event node: the key of a pad already open.
    index: u8,
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    abs: [0x12]AbsInfo = undefined,
    state: gp.State = .{},
};

pub fn scan(known: []const Device, out: []Device) usize {
    var n: usize = 0;
    nodes: for (0..32) |i| {
        if (n == out.len) break;
        for (known) |k| if (k.index == i) continue :nodes;
        var path: [32]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "/dev/input/event{d}\x00", .{i}) catch continue;
        const rc = linux.open(@ptrCast(p.ptr), .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) continue;
        const fd: i32 = @intCast(rc);
        var keys: [0x300 / 8]u8 = @splat(0);
        if (linux.errno(linux.ioctl(fd, ior(0x20 + EV_KEY, keys.len), @intFromPtr(&keys))) != .SUCCESS or keys[BTN_GAMEPAD / 8] & (1 << (BTN_GAMEPAD % 8)) == 0) {
            _ = linux.close(fd);
            continue;
        }
        var d: Device = .{ .fd = fd, .index = @intCast(i) };
        const nl = linux.ioctl(fd, ior(0x06, d.name_buf.len), @intFromPtr(&d.name_buf));
        if (linux.errno(nl) == .SUCCESS) d.name_len = std.mem.indexOfScalar(u8, &d.name_buf, 0) orelse d.name_buf.len;
        for (&d.abs, 0..) |*a, code| {
            a.* = .{ .value = 0, .minimum = -1, .maximum = 1, .fuzz = 0, .flat = 0, .resolution = 0 };
            _ = linux.ioctl(fd, ior(0x40 + @as(u32, @intCast(code)), @sizeOf(AbsInfo)), @intFromPtr(a));
        }
        out[n] = d;
        n += 1;
    }
    return n;
}

pub fn name(d: *const Device) []const u8 {
    return if (d.name_len > 0) d.name_buf[0..d.name_len] else "Gamepad";
}

/// Applies what arrived since the last read; false once unplugged.
pub fn read(d: *Device, s: *gp.State) bool {
    var events: [64]InputEvent = undefined;
    while (true) {
        const rc = linux.read(d.fd, @ptrCast(&events), @sizeOf(@TypeOf(events)));
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => break,
            else => return false, // ENODEV: unplugged
        }
        if (rc == 0) break;
        for (events[0 .. rc / @sizeOf(InputEvent)]) |e| apply(d, e);
    }
    s.* = d.state;
    return true;
}

pub fn close(d: *Device) void {
    _ = linux.close(d.fd);
}

fn apply(d: *Device, e: InputEvent) void {
    const s = &d.state;
    switch (e.type) {
        EV_KEY => if (button(e.code)) |b| {
            s.buttons[@intFromEnum(b)] = if (e.value != 0) 1 else 0;
        },
        EV_ABS => if (e.code < d.abs.len) {
            const a = d.abs[e.code];
            const v = norm(e.value, a);
            switch (e.code) {
                0x00 => s.axes[0] = v * 2 - 1,
                0x01 => s.axes[1] = v * 2 - 1,
                0x03 => s.axes[2] = v * 2 - 1,
                0x04 => s.axes[3] = v * 2 - 1,
                0x02 => s.buttons[@intFromEnum(gp.Button.left_trigger)] = v,
                0x05 => s.buttons[@intFromEnum(gp.Button.right_trigger)] = v,
                0x10 => {
                    s.buttons[@intFromEnum(gp.Button.left)] = if (e.value < 0) 1 else 0;
                    s.buttons[@intFromEnum(gp.Button.right)] = if (e.value > 0) 1 else 0;
                },
                0x11 => {
                    s.buttons[@intFromEnum(gp.Button.up)] = if (e.value < 0) 1 else 0;
                    s.buttons[@intFromEnum(gp.Button.down)] = if (e.value > 0) 1 else 0;
                },
                else => {},
            }
        },
        else => {},
    }
}

/// 0 to 1 over the axis's range.
fn norm(v: i32, a: AbsInfo) f32 {
    if (a.maximum <= a.minimum) return 0;
    const f = (@as(f32, @floatFromInt(v)) - @as(f32, @floatFromInt(a.minimum))) / @as(f32, @floatFromInt(a.maximum - a.minimum));
    return std.math.clamp(f, 0, 1);
}

fn button(code: u16) ?gp.Button {
    return switch (code) {
        0x130 => .south,
        0x131 => .east,
        0x133 => .west, // BTN_X (BTN_NORTH's code): in place
        0x134 => .north, // BTN_Y
        0x136 => .left_shoulder,
        0x137 => .right_shoulder,
        0x138 => .left_trigger,
        0x139 => .right_trigger,
        0x13a => .back,
        0x13b => .start,
        0x13c => .guide,
        0x13d => .left_stick,
        0x13e => .right_stick,
        0x220 => .up,
        0x221 => .down,
        0x222 => .left,
        0x223 => .right,
        else => null,
    };
}

test "evdev events in the standard layout" {
    var d: Device = .{ .fd = -1, .index = 0 };
    for (&d.abs) |*a| a.* = .{ .value = 0, .minimum = -32768, .maximum = 32767, .fuzz = 0, .flat = 0, .resolution = 0 };
    d.abs[2] = .{ .value = 0, .minimum = 0, .maximum = 255, .fuzz = 0, .flat = 0, .resolution = 0 };
    apply(&d, .{ .sec = 0, .usec = 0, .type = EV_KEY, .code = 0x133, .value = 1 });
    apply(&d, .{ .sec = 0, .usec = 0, .type = EV_ABS, .code = 0x00, .value = 32767 });
    apply(&d, .{ .sec = 0, .usec = 0, .type = EV_ABS, .code = 0x02, .value = 255 });
    apply(&d, .{ .sec = 0, .usec = 0, .type = EV_ABS, .code = 0x11, .value = -1 });
    try std.testing.expect(d.state.pressed(.west) and d.state.pressed(.up) and d.state.pressed(.left_trigger));
    try std.testing.expectApproxEqAbs(@as(f32, 1), d.state.axis(.left_x), 1e-4);
}
