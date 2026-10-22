//! GTK 3's gesture recognizer reports touchpad pinches on Wayland.
const std = @import("std");
const gtk = @import("gtk.zig");
const Surface = @import("surface.zig").Surface;
const Gesture = anyopaque;

const Api = struct {
    gtk_gesture_zoom_new: *const fn (*gtk.Widget) callconv(.c) *Gesture,
    gtk_gesture_get_bounding_box_center: *const fn (*Gesture, *f64, *f64) callconv(.c) c_int,
};
var api: Api = undefined;
var loaded = false;

pub const State = struct {
    gesture: ?*Gesture = null,
    scale: f64 = 1,
};

pub fn install(s: *Surface) void {
    if (!loaded) {
        const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .GLOBAL = true }) orelse return;
        inline for (@typeInfo(Api).@"struct".field_names) |name| {
            @field(api, name) = @ptrCast(@alignCast(std.c.dlsym(lib, name) orelse return));
        }
        loaded = true;
    }
    const g = api.gtk_gesture_zoom_new(s.area);
    s.zoom.gesture = g;
    gtk.connect(g, "begin", @ptrCast(&begin), s);
    gtk.connect(g, "scale-changed", @ptrCast(&changed), s);
}

pub fn destroy(s: *Surface) void {
    if (s.zoom.gesture) |g| gtk.api.g_object_unref(g);
}

fn begin(_: *Gesture, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const s: *Surface = @ptrCast(@alignCast(data));
    s.zoom.scale = 1;
}

fn changed(g: *Gesture, scale: f64, data: ?*anyopaque) callconv(.c) void {
    const s: *Surface = @ptrCast(@alignCast(data));
    if (!std.math.isFinite(scale) or scale <= 0) return;
    const relative = scale / s.zoom.scale;
    s.zoom.scale = scale;
    var x: f64 = 0;
    var y: f64 = 0;
    if (api.gtk_gesture_get_bounding_box_center(g, &x, &y) == 0) return;
    if (@import("../ui/gesture.zig").pinch(&s.ctx, @floatCast(x), @floatCast(y), @floatCast(relative))) s.frame();
}
