//! Whether the desktop asks for less motion (`motion.reduced`): Windows'
//! "Show animations in Windows" (client area animations), macOS's Reduce
//! motion, GTK's gtk-enable-animations. Asked once; elsewhere, no.
const std = @import("std");
const builtin = @import("builtin");

extern "user32" fn SystemParametersInfoW(action: u32, param: u32, out: ?*anyopaque, flags: u32) callconv(.winapi) i32;

pub fn prefersReducedMotion() bool {
    return switch (builtin.os.tag) {
        .windows => windows(),
        .macos => macos(),
        .linux => linux(),
        else => false,
    };
}

fn windows() bool {
    const get_client_area_animation = 0x1042;
    var on: i32 = 1;
    if (SystemParametersInfoW(get_client_area_animation, 0, &on, 0) == 0) return false;
    return on == 0;
}

fn macos() bool {
    const objc = @import("../objc.zig");
    const ws = objc.msg(?objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{}) orelse return false;
    return objc.msg(bool, ws, "accessibilityDisplayShouldReduceMotion", .{});
}

fn linux() bool {
    if (builtin.link_libc == false) return false;
    // GTK, if the app loaded it: its setting.
    const self = std.c.dlopen(null, .{ .LAZY = true }) orelse return false;
    const get_default: *const fn () callconv(.c) ?*anyopaque = @ptrCast(@alignCast(std.c.dlsym(self, "gtk_settings_get_default") orelse return false));
    const object_get: *const fn (obj: *anyopaque, name: [*:0]const u8, ...) callconv(.c) void = @ptrCast(@alignCast(std.c.dlsym(self, "g_object_get") orelse return false));
    const settings = get_default() orelse return false;
    var on: c_int = 1;
    object_get(settings, "gtk-enable-animations", &on, @as(?*anyopaque, null));
    return on == 0;
}
