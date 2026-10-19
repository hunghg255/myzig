//! A surface's part of UI Automation (`uia.zig`): made when a client
//! first asks the window, updated after each frame, gone with the window.
//! Generic over the surface, which has `access: ?*uia.Access`, `ctx`,
//! `gpa`, `scale`, `frame()` and `requestFrame()`.
const std = @import("std");
const w = @import("win32.zig");
const uia = @import("uia.zig");
const access = @import("../ui/access.zig");

pub const WM_GETOBJECT = @import("uia_api.zig").WM_GETOBJECT;

/// Answers WM_GETOBJECT; null leaves it to the default.
pub fn getObject(s: anytype, h: w.HWND, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
    const S = @TypeOf(s.*);
    if (s.access == null) {
        const id: i32 = @truncate(lp);
        if (id < 0 and id != -25 and id != -4) return null;
        const Glue = struct {
            fn perform(p: *anyopaque, id_: u64, role: access.Role, action: access.Action) void {
                const self: *S = @ptrCast(@alignCast(p));
                access.perform(&self.ctx, id_, role, action);
                self.requestFrame();
            }
            fn frameNow(p: *anyopaque) void {
                const self: *S = @ptrCast(@alignCast(p));
                self.frame();
            }
            fn scale(p: *anyopaque) f32 {
                const self: *S = @ptrCast(@alignCast(p));
                return self.scale;
            }
        };
        s.access = uia.Access.create(s.gpa, h, .{ .ptr = s, .ctx = &s.ctx, .perform = Glue.perform, .frame_now = Glue.frameNow, .scale = Glue.scale }) catch return null;
    }
    return s.access.?.getObject(wp, lp);
}

/// After a frame: clients see it.
pub fn afterFrame(s: anytype) void {
    if (s.access) |a| a.update();
}

pub fn destroy(s: anytype) void {
    if (s.access) |a| a.destroy();
    s.access = null;
}
