//! Global shortcuts on Linux under X11: the key is grabbed on the root
//! window (with Caps Lock and Num Lock on or off), and its presses arrive
//! through a GDK event filter. Wayland compositors grab nothing for apps:
//! there, `register` fails with `error.Unsupported` (the desktop portal's
//! GlobalShortcuts is not done yet).
const std = @import("std");
const gtk = @import("gtk.zig");
const hotkeys = @import("../hotkeys.zig");

const Display = anyopaque;
const Api = struct {
    XStringToKeysym: *const fn (name: [*:0]const u8) callconv(.c) c_ulong,
    XKeysymToKeycode: *const fn (d: *Display, sym: c_ulong) callconv(.c) u8,
    XGrabKey: *const fn (d: *Display, code: c_int, mods: c_uint, win: c_ulong, owner: c_int, pointer: c_int, keyboard: c_int) callconv(.c) c_int,
    XUngrabKey: *const fn (d: *Display, code: c_int, mods: c_uint, win: c_ulong) callconv(.c) c_int,
    XDefaultRootWindow: *const fn (d: *Display) callconv(.c) c_ulong,
    XFlush: *const fn (d: *Display) callconv(.c) c_int,
};
const GdkApi = struct {
    gdk_x11_display_get_type: *const fn () callconv(.c) usize,
    gdk_x11_display_get_xdisplay: *const fn (d: *anyopaque) callconv(.c) *Display,
    gdk_x11_display_error_trap_push: *const fn (d: *anyopaque) callconv(.c) void,
    gdk_x11_display_error_trap_pop: *const fn (d: *anyopaque) callconv(.c) c_int,
    gdk_window_add_filter: *const fn (w: ?*anyopaque, f: Filter, data: ?*anyopaque) callconv(.c) void,
    g_type_check_instance_is_a: *const fn (obj: *anyopaque, t: usize) callconv(.c) c_int,
};
const Filter = *const fn (xevent: *anyopaque, event: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int;

var x: Api = undefined;
var g: GdkApi = undefined;
var state: enum { untried, ok, unsupported } = .untried;

/// The handler of presses: the app's, which looks the shortcut up.
pub const Pressed = *const fn (ctx: *anyopaque, keycode: u8, mods: u32) void;
var pressed: ?struct { ctx: *anyopaque, func: Pressed } = null;

fn load() bool {
    if (state != .untried) return state == .ok;
    state = .unsupported;
    if (!gtk.load()) return false;
    const lib = std.c.dlopen("libX11.so.6", .{ .NOW = true }) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |name| @field(x, name) = @ptrCast(@alignCast(std.c.dlsym(lib, name) orelse return false));
    const gdk = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .GLOBAL = true }) orelse return false;
    inline for (@typeInfo(GdkApi).@"struct".field_names) |name| @field(g, name) = @ptrCast(@alignCast(std.c.dlsym(gdk, name) orelse return false));
    // GDK on an X server, not Wayland.
    const d = gtk.api.gdk_display_get_default() orelse return false;
    if (g.g_type_check_instance_is_a(d, g.gdk_x11_display_get_type()) == 0) return false;
    g.gdk_window_add_filter(null, filter, null);
    state = .ok;
    return true;
}

/// Lock and Num Lock: grabbed on and off, ignored when matching.
const lock_mask: u32 = 1 << 1;
const num_mask: u32 = 1 << 4;
const ignored = [_]u32{ 0, lock_mask, num_mask, lock_mask | num_mask };

/// Where presses go; once, at the app's first shortcut.
pub fn listen(ctx: *anyopaque, func: Pressed) void {
    pressed = .{ .ctx = ctx, .func = func };
}

pub const Grab = struct { keycode: u8, mods: u32 };

pub fn register(a: hotkeys.Accelerator) hotkeys.Error!Grab {
    var buf: [16]u8 = undefined;
    const name = hotkeys.x11Key(a.key, &buf) orelse return error.UnsupportedKey;
    if (!load()) return error.Unsupported;
    const gd = gtk.api.gdk_display_get_default().?;
    const d = g.gdk_x11_display_get_xdisplay(gd);
    const sym = x.XStringToKeysym(name);
    if (sym == 0) return error.UnsupportedKey;
    const code = x.XKeysymToKeycode(d, sym);
    if (code == 0) return error.UnsupportedKey;
    const mods = hotkeys.x11Mods(a);
    const root = x.XDefaultRootWindow(d);
    // Another client's grab is an X error (BadAccess), trapped.
    g.gdk_x11_display_error_trap_push(gd);
    for (ignored) |extra| _ = x.XGrabKey(d, code, mods | extra, root, 0, 1, 1); // GrabModeAsync
    _ = x.XFlush(d);
    if (g.gdk_x11_display_error_trap_pop(gd) != 0) {
        unregister(.{ .keycode = code, .mods = mods });
        return error.Unavailable;
    }
    return .{ .keycode = code, .mods = mods };
}

pub fn unregister(grab: Grab) void {
    if (state != .ok) return;
    const gd = gtk.api.gdk_display_get_default() orelse return;
    const d = g.gdk_x11_display_get_xdisplay(gd);
    const root = x.XDefaultRootWindow(d);
    g.gdk_x11_display_error_trap_push(gd);
    for (ignored) |extra| _ = x.XUngrabKey(d, grab.keycode, grab.mods | extra, root);
    _ = x.XFlush(d);
    _ = g.gdk_x11_display_error_trap_pop(gd);
}

/// An X key press's keycode and modifiers, without Lock and Num Lock.
pub fn keyOf(xevent: *const anyopaque) ?Grab {
    const bytes: [*]const u8 = @ptrCast(xevent);
    const kind = std.mem.readInt(c_int, bytes[0..4], .little);
    if (kind != 2) return null; // KeyPress
    // XKeyEvent: state at 80, keycode at 84.
    const st = std.mem.readInt(c_uint, bytes[80..84], .little);
    const code = std.mem.readInt(c_uint, bytes[84..88], .little);
    return .{ .keycode = @truncate(code), .mods = st & ~(lock_mask | num_mask) & 0xFF };
}

fn filter(xevent: *anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const k = keyOf(xevent) orelse return 0; // GDK_FILTER_CONTINUE
    const p = pressed orelse return 0;
    p.func(p.ctx, k.keycode, k.mods);
    return 0;
}

test "an X key press's key, without Caps Lock and Num Lock" {
    var ev: [192]u8 = @splat(0);
    std.mem.writeInt(c_int, ev[0..4], 2, .little);
    std.mem.writeInt(c_uint, ev[80..84], (1 << 3) | lock_mask | num_mask, .little);
    std.mem.writeInt(c_uint, ev[84..88], 65, .little);
    const k = keyOf(&ev).?;
    try std.testing.expectEqual(@as(u8, 65), k.keycode);
    try std.testing.expectEqual(@as(u32, 1 << 3), k.mods);
    std.mem.writeInt(c_int, ev[0..4], 3, .little); // KeyRelease
    try std.testing.expect(keyOf(&ev) == null);
}

test "a global shortcut grabs its key on the X server, and lets it go" {
    if (!gtk.load() or gtk.api.gtk_init_check(null, null) == 0) return error.SkipZigTest;
    const a = @import("../menu_types.zig").parseAccelerator("Ctrl+Alt+Shift+F12");
    const grab = register(a) catch |e| {
        if (e == error.Unsupported) return error.SkipZigTest;
        return e;
    };
    unregister(grab);
}
