//! What a window's procedure does on Windows beyond showing its content:
//! asking before it closes, telling the app of focus, moves, resizes and
//! state changes, the frame of a window without a caption (its hit tests,
//! the caption buttons, moving it from the content), and flyouts being
//! dismissed.
const std = @import("std");
const w = @import("win32.zig");
const gdi = @import("gdi.zig");
const frame = @import("frame.zig");
const caption = @import("caption.zig");
const flyout = @import("flyout.zig");
const titlebar = @import("../titlebar.zig");
const window_types = @import("../window_types.zig");
const Window = @import("window.zig").Window;

/// Tells the app what happened to the window.
pub fn emit(self: *Window, e: ?window_types.Event) void {
    const ev = e orelse return;
    if (self.on_event) |cb| cb.func(cb.ctx, self, ev);
}

/// Whether the window closes as the user closes it.
pub fn mayClose(self: *Window) bool {
    const cb = self.on_close_request orelse return true;
    return cb.func(cb.ctx, self);
}

fn captionless(self: *Window) bool {
    return self.title_bar != .default or self.flyout != null;
}

/// Whether a press at a client pixel moves the window: the empty space
/// of its title bar in native UI.
fn dragAt(ctx: *anyopaque, x: i32, y: i32) bool {
    const self: *Window = @ptrCast(@alignCast(ctx));
    const s = self.surface orelse return false;
    const scale: f32 = if (s.scale > 0) s.scale else 1;
    const h = titlebar.strip(self.title_bar, self.title_bar_height, s.ctx.title_bar_height, caption.default_height);
    return titlebar.draggable(&s.ctx, @as(f32, @floatFromInt(x)) / scale, @as(f32, @floatFromInt(y)) / scale, h);
}

/// The app's maximize button in client pixels, if it drew one.
fn snapRect(self: *Window) ?w.RECT {
    const r = self.snap orelse return null;
    const s = self.dpiScale();
    return .{ .left = @intFromFloat(r.x * s), .top = @intFromFloat(r.y * s), .right = @intFromFloat((r.x + r.width) * s), .bottom = @intFromFloat((r.y + r.height) * s) };
}

/// Passes a non-client mouse message over the app's maximize button to
/// native UI as the client one, so its button hovers and clicks.
fn forward(self: *Window, hwnd: w.HWND, msg: u32, lp: w.LPARAM) void {
    const s = self.surface orelse return;
    _ = s.handle(hwnd, msg, 0, frame.clientParam(hwnd, lp));
}

/// The window procedure's part for all of this; null for what it leaves
/// to the rest.
pub fn handle(self: *Window, hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
    switch (msg) {
        w.WM_CLOSE => {
            if (!mayClose(self)) return 0;
            if (self.flyout) |f| if (f.dismiss == .hide) {
                self.hide();
                return 0;
            };
            return null;
        },
        frame.WM_ACTIVATE => {
            const active = wp & 0xFFFF != 0;
            if (self.caption) |c| c.activate(active);
            emit(self, self.tracker.focus(active));
            if (!active) if (self.flyout) |f| if (f.focusable) {
                // Not for a flyout of its own, nor a press on its own tray icon.
                const other: ?w.HWND = if (lp != 0) @ptrFromInt(@as(usize, @bitCast(lp))) else null;
                const owned = if (other) |o| GetWindow(o, 4) == hwnd else false; // GW_OWNER
                if (!owned and !flyout.onOwnIcon(f)) _ = w.PostMessageW(hwnd, frame.WM_DISMISS, 0, 0);
            };
            return null;
        },
        frame.WM_DISMISS => {
            if (self.isVisible()) self.requestClose();
            return 0;
        },
        frame.WM_MOUSEACTIVATE => if (self.flyout) |f| if (!f.focusable) return flyout.MA_NOACTIVATE,
        frame.WM_MOVE => {
            const fr = self.frame();
            if (gdi.IsIconic(hwnd) == 0) emit(self, self.tracker.moved(.{ .x = fr.x, .y = fr.y }));
            // Its flyouts follow it.
            for (self.app.windows.items) |x| if (x.flyout) |f| if (f.parent == @as(*anyopaque, @ptrCast(self))) x.placeFlyout();
            return null;
        },
        w.WM_SIZE => {
            if (self.caption) |c| if (wp != 1) c.layout();
            var r: w.RECT = .{};
            _ = w.GetClientRect(hwnd, &r);
            const s = self.dpiScale();
            const size: window_types.Size = .{ .width = @as(f64, @floatFromInt(r.right - r.left)) / s, .height = @as(f64, @floatFromInt(r.bottom - r.top)) / s };
            emit(self, self.tracker.sized(wp == 1, wp == 2, size)); // SIZE_MINIMIZED, SIZE_MAXIMIZED
            return null;
        },
        w.WM_DPICHANGED => if (self.caption) |c| c.layout(),
        // Shown, hidden or moved: a caption that is a popup follows.
        WM_WINDOWPOSCHANGED => if (self.caption) |c| if (c.popup) c.layout(),
        frame.WM_NCCALCSIZE => if (captionless(self) and wp != 0 and !self.full_screen)
            return frame.calcSize(hwnd, wp, lp, self.title_bar == .hidden, self.flyout != null),
        caption.WM_NCHITTEST => if (captionless(self) and !self.full_screen) {
            if (self.flyout != null) return caption.HTCLIENT;
            return frame.hitTest(hwnd, wp, lp, .{
                .resizes = frame.style(hwnd) & w.WS_THICKFRAME != 0,
                .snap = snapRect(self),
                .drag = if (self.surface != null) .{ .ctx = self, .func = dragAt } else null,
            });
        },
        caption.WM_NCMOUSEMOVE => if (wp == caption.HTMAXBUTTON and self.snap != null) {
            forward(self, hwnd, w.WM_MOUSEMOVE, lp);
            return null; // DefWindowProc opens the snap layouts
        },
        caption.WM_NCLBUTTONDOWN, caption.WM_NCLBUTTONDBLCLK => if (wp == caption.HTMAXBUTTON and self.snap != null) {
            forward(self, hwnd, w.WM_LBUTTONDOWN, lp);
            _ = w.ReleaseCapture();
            return 0;
        },
        caption.WM_NCLBUTTONUP => if (wp == caption.HTMAXBUTTON and self.snap != null) {
            forward(self, hwnd, w.WM_LBUTTONUP, lp);
            return 0;
        },
        caption.WM_NCMOUSELEAVE => if (self.snap != null) if (self.surface) |s| {
            _ = s.handle(hwnd, w.WM_MOUSELEAVE, 0, 0);
        },
        frame.WM_START_DRAG => {
            frame.runDrag(hwnd);
            // The move loop took the button's release: native UI gets it.
            if (self.surface) |s| {
                var pt: w.POINT = .{};
                _ = gdi.GetCursorPos(&pt);
                _ = w.ScreenToClient(hwnd, &pt);
                const x: u16 = @bitCast(@as(i16, @truncate(pt.x)));
                const y: u16 = @bitCast(@as(i16, @truncate(pt.y)));
                _ = s.handle(hwnd, w.WM_LBUTTONUP, 0, @bitCast(@as(usize, x) | @as(usize, y) << 16));
            }
            return 0;
        },
        else => {},
    }
    return null;
}

const WM_WINDOWPOSCHANGED = 0x0047;
extern "user32" fn GetWindow(hwnd: w.HWND, cmd: u32) callconv(.winapi) ?w.HWND;
