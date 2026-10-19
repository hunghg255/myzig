//! Gamepads on Windows through XInput, loaded with LoadLibrary: Xbox
//! controllers and those that act as one (Steam Input makes others so).
//! `XInputGetStateEx` (ordinal 100 of xinput1_4.dll) also reads Guide.
const std = @import("std");
const gp = @import("gamepad.zig");

const Gamepad = extern struct {
    buttons: u16,
    left_trigger: u8,
    right_trigger: u8,
    lx: i16,
    ly: i16,
    rx: i16,
    ry: i16,
};
const XState = extern struct { packet: u32, pad: Gamepad, reserved: u32 = 0 };
const GetState = *const fn (slot: u32, state: *XState) callconv(.winapi) u32;

extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(lib: *anyopaque, name: ?*const anyopaque) callconv(.winapi) ?*anyopaque;

var get_state: ?GetState = null;
var loaded = false;

fn load() ?GetState {
    if (loaded) return get_state;
    loaded = true;
    const libs = [_][]const u8{ "xinput1_4.dll", "xinput1_3.dll", "xinput9_1_0.dll" };
    inline for (libs) |n| {
        if (LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral(n))) |lib| {
            // By ordinal first: the one that reads Guide.
            if (GetProcAddress(lib, @ptrFromInt(100))) |p| {
                get_state = @ptrCast(@alignCast(p));
                return get_state;
            }
            if (GetProcAddress(lib, "XInputGetState")) |p| {
                get_state = @ptrCast(@alignCast(p));
                return get_state;
            }
        }
    }
    return null;
}

pub const Device = struct { slot: u32 };

const names = [_][]const u8{ "Xbox Controller 1", "Xbox Controller 2", "Xbox Controller 3", "Xbox Controller 4" };

pub fn scan(known: []const Device, out: []Device) usize {
    const f = load() orelse return 0;
    var n: usize = 0;
    slots: for (0..4) |slot| {
        for (known) |k| if (k.slot == slot) continue :slots;
        var st: XState = undefined;
        if (f(@intCast(slot), &st) == 0 and n < out.len) {
            out[n] = .{ .slot = @intCast(slot) };
            n += 1;
        }
    }
    return n;
}

pub fn name(d: *const Device) []const u8 {
    return names[d.slot];
}

pub fn read(d: *Device, s: *gp.State) bool {
    const f = load() orelse return false;
    var st: XState = undefined;
    if (f(d.slot, &st) != 0) return false;
    toState(st.pad, s);
    return true;
}

pub fn close(_: *Device) void {}

/// XInput's report in the standard layout (its Y axes point up).
pub fn toState(g: Gamepad, s: *gp.State) void {
    const bits = [_]struct { u16, gp.Button }{
        .{ 0x1000, .south },          .{ 0x2000, .east },         .{ 0x4000, .west },        .{ 0x8000, .north },
        .{ 0x0100, .left_shoulder },  .{ 0x0200, .right_shoulder }, .{ 0x0020, .back },      .{ 0x0010, .start },
        .{ 0x0040, .left_stick },     .{ 0x0080, .right_stick },  .{ 0x0001, .up },          .{ 0x0002, .down },
        .{ 0x0004, .left },           .{ 0x0008, .right },        .{ 0x0400, .guide },
    };
    s.* = .{};
    for (bits) |b| s.buttons[@intFromEnum(b[1])] = if (g.buttons & b[0] != 0) 1 else 0;
    s.buttons[@intFromEnum(gp.Button.left_trigger)] = @as(f32, @floatFromInt(g.left_trigger)) / 255;
    s.buttons[@intFromEnum(gp.Button.right_trigger)] = @as(f32, @floatFromInt(g.right_trigger)) / 255;
    s.axes = .{ thumb(g.lx), -thumb(g.ly), thumb(g.rx), -thumb(g.ry) };
}

fn thumb(v: i16) f32 {
    return std.math.clamp(@as(f32, @floatFromInt(v)) / 32767, -1, 1);
}

test "XInput's report in the standard layout" {
    var s: gp.State = undefined;
    toState(.{ .buttons = 0x1000 | 0x0008 | 0x0400, .left_trigger = 255, .right_trigger = 0, .lx = 32767, .ly = 32767, .rx = -32768, .ry = 0 }, &s);
    try std.testing.expect(s.pressed(.south) and s.pressed(.right) and s.pressed(.guide) and !s.pressed(.east));
    try std.testing.expectEqual(@as(f32, 1), s.value(.left_trigger));
    try std.testing.expectEqual(@as(f32, 1), s.axis(.left_x));
    try std.testing.expectEqual(@as(f32, -1), s.axis(.left_y)); // up is negative
    try std.testing.expectEqual(@as(f32, -1), s.axis(.right_x));
}

test "reading pads where none may be connected" {
    var known: [0]Device = .{};
    var out: [4]Device = undefined;
    _ = scan(&known, &out);
}
