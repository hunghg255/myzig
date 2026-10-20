//! The caption buttons of a window with a hidden title bar on Windows:
//! minimize, maximize or restore, and close over the content's top right
//! corner, drawn as Windows 11 draws its own (after mygo). They live in a
//! layered child window whose pixels carry their alpha, so the content
//! (native UI or the page) shows around the glyphs. It answers
//! WM_NCHITTEST with the buttons' codes, which brings Windows 11's snap
//! layouts over maximize, and runs the buttons from the non-client mouse
//! messages that follow.
const std = @import("std");
const w = @import("win32.zig");
const gdi = @import("gdi.zig");

/// Windows 11's caption buttons are 46 points wide, as tall as the title
/// bar (32 by default), with glyphs of 10.
pub const button_width = 46;
pub const default_height = 32;
const glyph_size = 10;

pub const HTCLIENT = 1;
pub const HTCAPTION = 2;
pub const HTMINBUTTON = 8;
pub const HTMAXBUTTON = 9;
pub const HTLEFT = 10;
pub const HTTOP = 12;
pub const HTTOPLEFT = 13;
pub const HTTOPRIGHT = 14;
pub const HTCLOSE = 20;

pub const WM_NCHITTEST = 0x0084;
pub const WM_NCMOUSEMOVE = 0x00A0;
pub const WM_NCLBUTTONDOWN = 0x00A1;
pub const WM_NCLBUTTONUP = 0x00A2;
pub const WM_NCLBUTTONDBLCLK = 0x00A3;
pub const WM_NCRBUTTONDOWN = 0x00A4;
pub const WM_NCRBUTTONUP = 0x00A5;
pub const WM_NCMOUSELEAVE = 0x02A2;
pub const WM_SYSCOMMAND = 0x0112;
pub const SC_MINIMIZE = 0xF020;
pub const SC_MAXIMIZE = 0xF030;
pub const SC_RESTORE = 0xF120;
pub const SC_CLOSE = 0xF060;
pub const WS_MINIMIZEBOX = 0x00020000;

pub const Button = enum {
    minimize,
    maximize,
    close,

    /// Its glyph in Segoe Fluent Icons and Segoe MDL2 Assets, which have
    /// them at the same code points.
    pub fn glyph(b: Button, maximized: bool) u16 {
        return switch (b) {
            .minimize => 0xE921,
            .maximize => if (maximized) 0xE923 else 0xE922,
            .close => 0xE8BB,
        };
    }

    pub fn hitTest(b: Button) w.LRESULT {
        return switch (b) {
            .minimize => HTMINBUTTON,
            .maximize => HTMAXBUTTON,
            .close => HTCLOSE,
        };
    }
};

const all = [_]Button{ .minimize, .maximize, .close };
const close_only = [_]Button{.close};

/// The buttons of a window of `style`, left to right: close alone when
/// it can be neither minimized nor maximized, as Windows does.
pub fn buttonsOf(style: u32) []const Button {
    if (style & (WS_MINIMIZEBOX | w.WS_MAXIMIZEBOX) == 0) return &close_only;
    return &all;
}

pub const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

/// Windows 11's close button is red on hover, Windows 10's brighter.
const close_red_11: Rgba = .{ .r = 0xC4, .g = 0x2B, .b = 0x1C, .a = 0xFF };
const close_red_10: Rgba = .{ .r = 0xE8, .g = 0x11, .b = 0x23, .a = 0xFF };

/// The backplate and glyph colors of a button, after Windows' own: the
/// glyph in the text color, fainter while the window is inactive or the
/// button disabled; on hover and press a backplate of the glyph's color
/// at 10% and 20%, or red behind a white glyph for close. At rest the
/// backplate is all but transparent, which keeps the window taking the
/// mouse there.
pub fn colors(b: Button, hot: bool, pressed: bool, enabled: bool, active: bool, dark: bool, fluent: bool) [2]Rgba {
    var fore: Rgba = if (dark) .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0xFF } else .{ .r = 0, .g = 0, .b = 0, .a = 0xE4 };
    var back: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    const red = if (fluent) close_red_11 else close_red_10;
    const white: Rgba = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0xFF };
    if (!enabled) {
        fore.a = 0x5C;
    } else if (hot and pressed and b == .close) {
        back = .{ .r = red.r, .g = red.g, .b = red.b, .a = 0xCC };
        fore = white;
    } else if (hot and b == .close) {
        back = red;
        fore = white;
    } else if (hot and pressed) {
        back = .{ .r = fore.r, .g = fore.g, .b = fore.b, .a = 0x33 };
    } else if (hot) {
        back = .{ .r = fore.r, .g = fore.g, .b = fore.b, .a = 0x1A };
    } else if (!active) fore.a = 0x72;
    return .{ back, fore };
}

/// A glyph's color of coverage `cov` over a backplate, as the
/// premultiplied BGRA pixel UpdateLayeredWindow takes.
pub fn over(fore: Rgba, cov: u32, back: Rgba) u32 {
    const fa = @as(u32, fore.a) * cov / 255;
    const ba = @as(u32, back.a) * (255 - fa) / 255;
    const ch = struct {
        fn f(fc: u8, bc: u8, a: u32, b: u32) u32 {
            return (@as(u32, fc) * a + @as(u32, bc) * b) / 255;
        }
    }.f;
    return (fa + ba) << 24 | ch(fore.r, back.r, fa, ba) << 16 | ch(fore.g, back.g, fa, ba) << 8 | ch(fore.b, back.b, fa, ba);
}

/// What the caption asks of its window.
pub const Host = struct {
    ctx: *anyopaque,
    hwnd: w.HWND,
    /// The title bar's height in points.
    height: f64,
    dark: *const fn (ctx: *anyopaque) bool,
    full_screen: *const fn (ctx: *anyopaque) bool,
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("MyZigCaption");
var registered = false;

pub const Caption = struct {
    host: Host,
    hwnd: w.HWND,
    /// The index of the button under the pointer, and of the one pressed.
    hot: ?usize = null,
    pressed: ?usize = null,
    tracking: bool = false,
    active: bool = true,
    /// Whether the glyphs were last drawn for a dark title bar.
    drawn_dark: ?bool = null,
    /// An owned popup rather than a child (no manifest).
    popup: bool = false,
    /// Buttons clicked, for tests: what was sent to the window.
    last_command: usize = 0,

    pub fn create(gpa: std.mem.Allocator, host: Host) !*Caption {
        const inst = w.GetModuleHandleW(null);
        if (!registered) {
            const wc: w.WNDCLASSEXW = .{ .lpfnWndProc = wndProc, .hInstance = inst, .hCursor = w.LoadCursorW(null, 32512), .lpszClassName = class_name };
            if (w.RegisterClassExW(&wc) == 0) return error.RegisterClass;
            registered = true;
        }
        const self = try gpa.create(Caption);
        errdefer gpa.destroy(self);
        const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
        // A layered child needs the app's manifest to name Windows 8 or
        // later (`myzig.manifest`); without one, a layered popup owned by
        // the window, kept over its corner, does instead.
        var popup = false;
        const hwnd = w.CreateWindowExW(gdi.WS_EX_LAYERED, class_name, empty, gdi.WS_CHILD | gdi.WS_CLIPSIBLINGS, 0, 0, 0, 0, host.hwnd, null, inst, null) orelse blk: {
            popup = true;
            break :blk w.CreateWindowExW(gdi.WS_EX_LAYERED | gdi.WS_EX_TOOLWINDOW | gdi.WS_EX_NOACTIVATE, class_name, empty, gdi.WS_POPUP, 0, 0, 0, 0, host.hwnd, null, inst, null) orelse return error.CreateWindow;
        };
        self.* = .{ .host = host, .hwnd = hwnd, .popup = popup };
        _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        return self;
    }

    /// Frees it; Windows destroys its window with the parent's.
    pub fn destroy(self: *Caption, gpa: std.mem.Allocator) void {
        _ = w.SetWindowLongPtrW(self.hwnd, w.GWLP_USERDATA, 0);
        gpa.destroy(self);
    }

    fn style(self: *Caption) u32 {
        return @truncate(@as(usize, @bitCast(w.GetWindowLongPtrW(self.host.hwnd, gdi.GWL_STYLE))));
    }

    pub fn buttons(self: *Caption) []const Button {
        return buttonsOf(self.style());
    }

    fn enabled(self: *Caption, b: Button) bool {
        return switch (b) {
            .minimize => self.style() & WS_MINIMIZEBOX != 0,
            .maximize => self.style() & w.WS_MAXIMIZEBOX != 0,
            .close => true,
        };
    }

    fn dpi(self: *Caption) u32 {
        const d = w.GetDpiForWindow(self.host.hwnd);
        return if (d == 0) 96 else d;
    }

    fn px(self: *Caption, points: f64) i32 {
        return @intFromFloat(@round(points * @as(f64, @floatFromInt(self.dpi())) / 96));
    }

    /// Its width in points: what the content keeps clear of.
    pub fn width(self: *Caption) f64 {
        return @floatFromInt(button_width * self.buttons().len);
    }

    /// Puts the buttons at the top right corner, above the content, and
    /// paints them: when the window changes size, state or DPI, and once
    /// a page's view is there.
    pub fn layout(self: *Caption) void {
        const h = self.host.hwnd;
        if (gdi.IsIconic(h) != 0) return;
        var r: w.RECT = .{};
        _ = w.GetClientRect(h, &r);
        const bw = self.px(button_width) * @as(i32, @intCast(self.buttons().len));
        const bh = self.px(self.host.height);
        var at: w.POINT = .{ .x = r.right - bw };
        var shown = !self.host.full_screen(self.host.ctx);
        // A popup is on the screen: over the corner, and shown with its window only.
        if (self.popup) {
            _ = gdi.ClientToScreen(h, &at);
            shown = shown and w.IsWindowVisible(h) != 0;
        }
        const show: u32 = if (shown) gdi.SWP_SHOWWINDOW else gdi.SWP_HIDEWINDOW;
        // HWND_TOP: above a page's view, made after it.
        _ = w.SetWindowPos(self.hwnd, null, at.x, at.y, bw, bh, gdi.SWP_NOACTIVATE | show);
        self.paint();
    }

    /// Draws the buttons again if the title bar went light or dark (the
    /// view's theme changed), after each frame.
    pub fn followTheme(self: *Caption) void {
        const dark = self.host.dark(self.host.ctx);
        if (self.drawn_dark != dark) self.paint();
    }

    pub fn activate(self: *Caption, on: bool) void {
        if (self.active == on) return;
        self.active = on;
        self.paint();
    }

    fn setHot(self: *Caption, i: ?usize) void {
        const v = if (i) |n| (if (self.enabled(self.buttons()[n])) i else null) else null;
        if (v == self.hot) return;
        self.hot = v;
        self.paint();
    }

    /// The button at a non-client message's screen position.
    pub fn indexAt(self: *Caption, lp: w.LPARAM) ?usize {
        var pt: w.POINT = .{ .x = @as(i16, @truncate(lp)), .y = @as(i16, @truncate(lp >> 16)) };
        _ = w.ScreenToClient(self.hwnd, &pt);
        const bw = self.px(button_width);
        if (pt.x < 0 or pt.y < 0 or pt.y >= self.px(self.host.height) or bw <= 0) return null;
        const i: usize = @intCast(@divTrunc(pt.x, bw));
        return if (i < self.buttons().len) i else null;
    }

    fn click(self: *Caption, b: Button) void {
        if (!self.enabled(b)) return;
        const cmd: usize = switch (b) {
            .minimize => SC_MINIMIZE,
            .maximize => if (w.IsZoomed(self.host.hwnd) != 0) SC_RESTORE else SC_MAXIMIZE,
            .close => SC_CLOSE,
        };
        self.last_command = cmd;
        // Sent, as the system's buttons do. A close request may keep the
        // window open, or it closes during the call.
        _ = w.SendMessageW(self.host.hwnd, WM_SYSCOMMAND, cmd, 0);
    }

    fn message(self: *Caption, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
        _ = wp;
        switch (msg) {
            WM_NCHITTEST => {
                if (self.indexAt(lp)) |i| if (self.enabled(self.buttons()[i])) return self.buttons()[i].hitTest();
                return HTCLIENT;
            },
            WM_NCMOUSEMOVE => {
                self.setHot(self.indexAt(lp));
                if (!self.tracking) {
                    var t: w.TRACKMOUSEEVENT = .{ .dwFlags = 2 | 0x10, .hwndTrack = self.hwnd }; // TME_LEAVE | TME_NONCLIENT
                    _ = w.TrackMouseEvent(&t);
                    self.tracking = true;
                }
                // DefWindowProc brings the snap layouts over HTMAXBUTTON.
                return null;
            },
            WM_NCMOUSELEAVE, w.WM_MOUSELEAVE => {
                self.tracking = false;
                self.pressed = null;
                self.hot = null;
                self.paint();
                return 0;
            },
            WM_NCLBUTTONDOWN, WM_NCLBUTTONDBLCLK => {
                // Not DefWindowProc: it would run the system's buttons on this child.
                if (self.indexAt(lp)) |i| if (self.enabled(self.buttons()[i])) {
                    self.pressed = i;
                    self.paint();
                };
                return 0;
            },
            WM_NCLBUTTONUP => {
                const i = self.indexAt(lp);
                const was = self.pressed;
                self.pressed = null;
                self.paint();
                if (i != null and i == was) self.click(self.buttons()[i.?]);
                return 0;
            },
            WM_NCRBUTTONDOWN, WM_NCRBUTTONUP => return 0,
            else => return null,
        }
    }

    /// Draws the buttons for the window's state and appearance into the
    /// layered window.
    pub fn paint(self: *Caption) void {
        const shown = self.buttons();
        const bw = self.px(button_width);
        const height = self.px(self.host.height);
        const total = bw * @as(i32, @intCast(shown.len));
        if (total <= 0 or height <= 0) return;
        const screen = gdi.GetDC(null) orelse return;
        defer _ = gdi.ReleaseDC(null, screen);
        var img = gdi.Bitmap.init(screen, total, height) orelse return;
        defer img.deinit();
        var mask = gdi.Bitmap.init(screen, total, height) orelse return;
        defer mask.deinit();
        // The glyphs white on black: their coverage.
        const face = gdi.captionFont(self.px(glyph_size));
        const old = gdi.SelectObject(mask.dc, face.font);
        _ = gdi.SetBkMode(mask.dc, 1);
        _ = gdi.SetTextColor(mask.dc, 0xFFFFFF);
        const maximized = w.IsZoomed(self.host.hwnd) != 0;
        for (shown, 0..) |b, i| {
            var g = b.glyph(maximized);
            const x0 = @as(i32, @intCast(i)) * bw;
            var r: w.RECT = .{ .left = x0, .top = 0, .right = x0 + bw, .bottom = height };
            _ = gdi.DrawTextW(mask.dc, @ptrCast(&g), 1, &r, 0x1 | 0x4 | 0x20 | 0x800);
        }
        _ = gdi.SelectObject(mask.dc, old);
        _ = gdi.GdiFlush();
        const dark = self.host.dark(self.host.ctx);
        self.drawn_dark = dark;
        const tw: usize = @intCast(total);
        for (shown, 0..) |b, i| {
            const c = colors(b, self.hot == i, self.pressed == i, self.enabled(b), self.active, dark, face.fluent);
            for (0..@intCast(height)) |y| {
                const x0: usize = i * @as(usize, @intCast(bw));
                for (x0..x0 + @as(usize, @intCast(bw))) |x| img.px[y * tw + x] = over(c[1], mask.px[y * tw + x] & 0xFF, c[0]);
            }
        }
        var size: [2]i32 = .{ total, height };
        var origin: w.POINT = .{};
        const blend: u32 = 255 << 16 | 1 << 24; // AC_SRC_OVER, constant alpha 255, AC_SRC_ALPHA
        _ = gdi.UpdateLayeredWindow(self.hwnd, screen, null, &size, img.dc, &origin, 0, &blend, 2);
    }
};

fn wndProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    const p = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
    if (p != 0) {
        const self: *Caption = @ptrFromInt(@as(usize, @bitCast(p)));
        if (self.message(msg, wp, lp)) |r| return r;
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

test "caption buttons: the system's colors, close alone, glyphs" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 3), buttonsOf(w.WS_OVERLAPPEDWINDOW).len);
    try t.expectEqual(@as(usize, 1), buttonsOf(w.WS_OVERLAPPEDWINDOW & ~@as(u32, WS_MINIMIZEBOX | w.WS_MAXIMIZEBOX)).len);
    try t.expectEqual(@as(u16, 0xE923), Button.maximize.glyph(true));
    const hot_close = colors(.close, true, false, true, true, false, true);
    try t.expectEqual(close_red_11, hot_close[0]);
    try t.expectEqual(@as(u8, 0xFF), hot_close[1].r);
    try t.expectEqual(@as(u8, 0x72), colors(.minimize, false, false, true, false, true, true)[1].a);
    // An opaque white glyph's full coverage is opaque white; none is the backplate.
    try t.expectEqual(@as(u32, 0xFFFFFFFF), over(.{ .r = 255, .g = 255, .b = 255, .a = 255 }, 255, .{ .r = 0, .g = 0, .b = 0, .a = 1 }));
    try t.expectEqual(@as(u32, 0x01000000), over(.{ .r = 255, .g = 255, .b = 255, .a = 255 }, 0, .{ .r = 0, .g = 0, .b = 0, .a = 1 }));
}
