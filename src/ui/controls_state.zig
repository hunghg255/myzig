//! What the form controls share: small numbers a widget keeps across
//! frames (a popover open, a knob dragged, an arrow held), kept beside the
//! animations so that they are forgotten with the widget, and the arithmetic
//! of values between bounds.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

fn slotKey(id: u64, salt: u32) u64 {
    var h = std.hash.Wyhash.init(id);
    h.update("myzig.controls");
    h.update(std.mem.asBytes(&salt));
    return h.final();
}

/// The number widget `id` keeps under `salt`, or `default` the first time.
pub fn get(c: *Context, id: u64, salt: u32, default: f32) f32 {
    const gop = c.anims.getOrPut(c.gpa, slotKey(id, salt)) catch return default;
    if (!gop.found_existing) gop.value_ptr.* = .{ .value = default, .frame = c.frame };
    gop.value_ptr.frame = c.frame;
    return gop.value_ptr.value;
}

pub fn put(c: *Context, id: u64, salt: u32, v: f32) void {
    const gop = c.anims.getOrPut(c.gpa, slotKey(id, salt)) catch return;
    gop.value_ptr.* = .{ .value = v, .frame = c.frame };
}

pub fn getBool(c: *Context, id: u64, salt: u32) bool {
    return get(c, id, salt, 0) != 0;
}

pub fn putBool(c: *Context, id: u64, salt: u32, v: bool) void {
    put(c, id, salt, if (v) 1 else 0);
}

/// Where `v` lies between `lo` and `hi`, from 0 to 1.
pub fn fraction(v: f64, lo: f64, hi: f64) f32 {
    if (hi <= lo) return 0;
    return @floatCast(std.math.clamp((v - lo) / (hi - lo), 0, 1));
}

/// `v` within the bounds, on `lo` plus a multiple of `step` (any value for
/// a step of 0).
pub fn snap(v: f64, lo: f64, hi: f64, step: f64) f64 {
    var x = std.math.clamp(v, lo, hi);
    if (step > 0) {
        x = lo + @round((x - lo) / step) * step;
        if (x > hi + step * 1e-9) x -= step;
        x = std.math.clamp(x, lo, hi);
        // Rounded to the step's decimals: 0.1 + 0.2 is 0.3.
        const p = std.math.pow(f64, 10, @floatFromInt(decimalsOf(step)));
        x = @round(x * p) / p;
    }
    return x;
}

/// The decimals of `step` as written: 1 has none, 0.05 two.
pub fn decimalsOf(step: f64) u8 {
    var d: u8 = 0;
    var s = @abs(step);
    while (d < 6 and @abs(s - @round(s)) > 1e-9 * @max(1, s)) : (d += 1) s *= 10;
    return d;
}

/// `v` with `decimals` decimals, in the frame's memory.
pub fn formatNumber(c: *Context, v: f64, decimals: u8) []const u8 {
    return std.fmt.allocPrint(c.alloc(), "{d:.[1]}", .{ v, decimals }) catch "";
}

/// The key of this event, for a widget with the keyboard focus; taken, so
/// that the frame built again does not see it twice.
pub fn takeKey(c: *Context) ?ctx_mod.Key {
    const k = c.input.key orelse return null;
    c.input.key = null;
    return k;
}

/// Whether Space was typed in this event (it comes as text).
pub fn takeSpace(c: *Context) bool {
    if (!std.mem.eql(u8, c.input.chars, " ")) return false;
    c.input.chars = "";
    return true;
}

/// A ring around a box with the keyboard focus.
pub fn focusRing(c: *Context, index: u32, focused: bool) void {
    if (!focused) return;
    const n = c.node(index);
    n.style.border = c.theme.accent;
    n.style.border_width = 2;
    n.style.shadow = .{ .color = c.theme.accent.alpha(0.25), .blur = 6, .y = 0 };
}

/// The color the theme lacks for warnings: Apple's orange.
pub fn warning(c: *Context) types.Color {
    return if (c.theme.dark) .hex(0xff9f0a) else .hex(0xff9500);
}

test "snap and decimals" {
    try std.testing.expectEqual(@as(u8, 0), decimalsOf(1));
    try std.testing.expectEqual(@as(u8, 2), decimalsOf(0.05));
    try std.testing.expectEqual(@as(u8, 1), decimalsOf(2.5));
    try std.testing.expectEqual(@as(f64, 0.3), snap(0.1 + 0.2, 0, 1, 0.1));
    try std.testing.expectEqual(@as(f64, 30), snap(27, 0, 100, 10));
    try std.testing.expectEqual(@as(f64, 95), snap(99, 5, 99, 10));
    try std.testing.expectEqual(@as(f64, 99), snap(120, 0, 99, 0));
    try std.testing.expectEqual(@as(f32, 0.25), fraction(25, 0, 100));
    try std.testing.expectEqual(@as(f32, 0), fraction(5, 5, 5));
}
