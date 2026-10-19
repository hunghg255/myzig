//! The GTK and GDK functions windows need beyond showing content (their
//! frame, flyouts, moving them, the monitors' work areas), looked up the
//! first time they are used, as `gtk.zig` looks up its own.
const std = @import("std");
const gtk = @import("gtk.zig");

pub const Api = struct {
    gtk_window_set_decorated: *const fn (w: *gtk.Widget, on: c_int) callconv(.c) void,
    gtk_window_close: *const fn (w: *gtk.Widget) callconv(.c) void,
    gtk_window_set_skip_taskbar_hint: *const fn (w: *gtk.Widget, on: c_int) callconv(.c) void,
    gtk_window_set_skip_pager_hint: *const fn (w: *gtk.Widget, on: c_int) callconv(.c) void,
    gtk_window_set_urgency_hint: *const fn (w: *gtk.Widget, on: c_int) callconv(.c) void,
    gtk_window_set_type_hint: *const fn (w: *gtk.Widget, hint: c_int) callconv(.c) void,
    gtk_window_set_transient_for: *const fn (w: *gtk.Widget, parent: ?*gtk.Widget) callconv(.c) void,
    gtk_window_set_accept_focus: *const fn (w: *gtk.Widget, on: c_int) callconv(.c) void,
    gtk_window_set_titlebar: *const fn (w: *gtk.Widget, bar: ?*gtk.Widget) callconv(.c) void,
    gtk_window_begin_move_drag: *const fn (w: *gtk.Widget, button: c_int, x: c_int, y: c_int, time: u32) callconv(.c) void,
    gtk_window_is_maximized: *const fn (w: *gtk.Widget) callconv(.c) c_int,
    gtk_header_bar_new: *const fn () callconv(.c) *gtk.Widget,
    gtk_header_bar_set_show_close_button: *const fn (bar: *gtk.Widget, on: c_int) callconv(.c) void,
    gtk_header_bar_set_title: *const fn (bar: *gtk.Widget, title: ?[*:0]const u8) callconv(.c) void,
    gtk_widget_show: *const fn (w: *gtk.Widget) callconv(.c) void,
    gtk_widget_realize: *const fn (w: *gtk.Widget) callconv(.c) void,
    gtk_window_get_title: *const fn (w: *gtk.Widget) callconv(.c) ?[*:0]const u8,
    gtk_window_get_decorated: *const fn (w: *gtk.Widget) callconv(.c) c_int,
    gtk_window_get_skip_taskbar_hint: *const fn (w: *gtk.Widget) callconv(.c) c_int,
    gtk_get_current_event: *const fn () callconv(.c) ?*gtk.Event,
    gdk_event_free: *const fn (e: *gtk.Event) callconv(.c) void,
    gdk_event_get_root_coords: *const fn (e: *gtk.Event, x: *f64, y: *f64) callconv(.c) c_int,
    gdk_event_get_time: *const fn (e: *gtk.Event) callconv(.c) u32,
    gdk_window_get_origin: *const fn (w: *anyopaque, x: *c_int, y: *c_int) callconv(.c) c_int,
    gdk_display_get_monitor_at_point: *const fn (d: *anyopaque, x: c_int, y: c_int) callconv(.c) ?*anyopaque,
    gdk_display_get_primary_monitor: *const fn (d: *anyopaque) callconv(.c) ?*anyopaque,
    gdk_monitor_get_workarea: *const fn (m: *anyopaque, r: *gtk.Rectangle) callconv(.c) void,
};

pub var api: Api = undefined;
var loaded = false;
var tried = false;

pub fn load() bool {
    if (tried) return loaded;
    tried = true;
    if (!gtk.load()) return false;
    const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .GLOBAL = true }) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        const sym = std.c.dlsym(lib, name) orelse return false;
        @field(api, name) = @ptrCast(@alignCast(sym));
    }
    loaded = true;
    return true;
}

/// GdkWindowTypeHint.
pub const hint_dialog = 1;
pub const hint_utility = 5;
pub const hint_popup_menu = 9;

/// GdkEventConfigure's position and size, GdkEventWindowState's states.
pub const Configure = extern struct {
    type: c_int,
    window: ?*anyopaque,
    send_event: i8,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};
pub const WindowState = extern struct {
    type: c_int,
    window: ?*anyopaque,
    send_event: i8,
    changed_mask: c_uint,
    new_window_state: c_uint,
};
pub const state_iconified = 1 << 1;
pub const state_maximized = 1 << 2;
pub const state_fullscreen = 1 << 4;

/// The work area of the monitor at `x`, `y` (or the primary one).
pub fn workArea(x: c_int, y: c_int) ?gtk.Rectangle {
    if (!load()) return null;
    const d = gtk.api.gdk_display_get_default() orelse return null;
    const mon = api.gdk_display_get_monitor_at_point(d, x, y) orelse api.gdk_display_get_primary_monitor(d) orelse return null;
    var r: gtk.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    api.gdk_monitor_get_workarea(mon, &r);
    return r;
}

test "GDK's event layouts" {
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(Configure, "x"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(Configure, "width"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(WindowState, "new_window_state"));
}
