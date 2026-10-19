//! A GDK key event's physical key (`ui.KeyCode`): its hardware keycode,
//! an X11 one (evdev's code plus 8) under X11 and XWayland and Wayland's
//! GDK alike. Looked up in GDK, which GTK loaded, the first time.
const std = @import("std");
const keycode = @import("../ui/keycode.zig");

const GetKeycode = *const fn (e: *anyopaque, code: *u16) callconv(.c) c_int;
var get: ?GetKeycode = null;
var looked = false;

/// The physical key of the key event `e` (a `GdkEvent`).
pub fn of(e: *anyopaque) keycode.KeyCode {
    if (!looked) {
        looked = true;
        const lib = std.c.dlopen("libgdk-3.so.0", .{ .NOW = true }) orelse return .unknown;
        get = @ptrCast(@alignCast(std.c.dlsym(lib, "gdk_event_get_keycode")));
    }
    const f = get orelse return .unknown;
    var code: u16 = 0;
    if (f(e, &code) == 0 or code < 8) return .unknown;
    return keycode.fromEvdev(code - 8);
}
