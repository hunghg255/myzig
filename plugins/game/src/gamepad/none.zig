//! Platforms without a gamepad backend yet (macOS: GameController.framework
//! is left to do): no pads.
const State = @import("gamepad.zig").State;

pub const Device = struct { key: u32 = 0 };

pub fn scan(known: []const Device, out: []Device) usize {
    _ = known;
    _ = out;
    return 0;
}

pub fn name(_: *const Device) []const u8 {
    return "";
}

pub fn read(_: *Device, _: *State) bool {
    return false;
}

pub fn close(_: *Device) void {}
