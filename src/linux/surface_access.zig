//! A surface's part of AT-SPI (`atspi.zig`): linked after its first frame
//! when assistive technology is on, updated after each frame, gone with
//! the window. Generic over the surface, which has `access: ?*atspi.Link`,
//! `access_tried`, `ctx`, `gpa`, `area` and `requestFrame()`.
const std = @import("std");
const atspi = @import("atspi.zig");
const types = @import("../ui/types.zig");
const gtk = @import("gtk.zig");

const OriginFn = *const fn (window: *anyopaque, x: *c_int, y: *c_int) callconv(.c) c_int;
var origin_fn: ?OriginFn = null;
var origin_looked = false;

fn originOf(area: *gtk.Widget) types.Point {
    if (!origin_looked) {
        origin_looked = true;
        if (std.c.dlopen("libgtk-3.so.0", .{ .NOW = true })) |lib| origin_fn = @ptrCast(@alignCast(std.c.dlsym(lib, "gdk_window_get_origin")));
    }
    const f = origin_fn orelse return .{};
    const win = gtk.api.gtk_widget_get_window(area) orelse return .{};
    var x: c_int = 0;
    var y: c_int = 0;
    _ = f(win, &x, &y);
    return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
}

/// After a frame: links the surface the first time (when assistive
/// technology is on), then shows listeners the frame.
pub fn afterFrame(s: anytype) void {
    const S = @TypeOf(s.*);
    if (s.access) |l| return l.update();
    if (s.access_tried) return;
    s.access_tried = true;
    const Glue = struct {
        fn request(p: *anyopaque) void {
            const self: *S = @ptrCast(@alignCast(p));
            self.requestFrame();
        }
        /// Assistive technology started after the app: try again.
        fn wake(p: *anyopaque) void {
            const self: *S = @ptrCast(@alignCast(p));
            self.access_tried = false;
            self.requestFrame();
        }
        fn origin(p: *anyopaque) types.Point {
            const self: *S = @ptrCast(@alignCast(p));
            return originOf(self.area);
        }
    };
    const server = atspi.get(s.gpa) orelse {
        atspi.wait(s.gpa, s, Glue.wake);
        return;
    };
    s.access = server.attach(.{ .ptr = s, .ctx = &s.ctx, .request_frame = Glue.request, .origin = Glue.origin }) catch null;
}

pub fn destroy(s: anytype) void {
    atspi.unwait(s);
    if (s.access) |l| l.detach();
    s.access = null;
}
