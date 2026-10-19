//! What window chrome myzig draws itself needs of GDI and user32 beyond
//! `win32.zig`: bitmaps to draw into, fonts and their glyphs, layered
//! windows, and window styles.
const std = @import("std");
const w = @import("win32.zig");

pub const HGDIOBJ = *opaque {};

pub const WS_POPUP = 0x80000000;
pub const WS_CHILD = 0x40000000;
pub const WS_VISIBLE = 0x10000000;
pub const WS_CLIPSIBLINGS = 0x04000000;
pub const WS_CLIPCHILDREN = 0x02000000;
pub const WS_CAPTION = 0x00C00000;
pub const WS_SYSMENU = 0x00080000;
pub const WS_EX_TOPMOST = 0x00000008;
pub const WS_EX_TOOLWINDOW = 0x00000080;
pub const WS_EX_LAYERED = 0x00080000;
pub const WS_EX_NOACTIVATE = 0x08000000;
pub const GWL_STYLE = -16;
pub const GWL_EXSTYLE = -20;
pub const SWP_NOSIZE = 0x0001;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOACTIVATE = 0x0010;
pub const SWP_FRAMECHANGED = 0x0020;
pub const SWP_SHOWWINDOW = 0x0040;
pub const SWP_HIDEWINDOW = 0x0080;

pub extern "user32" fn GetDC(hwnd: ?w.HWND) callconv(.winapi) ?w.HDC;
pub extern "user32" fn ReleaseDC(hwnd: ?w.HWND, dc: w.HDC) callconv(.winapi) i32;
pub extern "user32" fn IsIconic(hwnd: w.HWND) callconv(.winapi) w.BOOL;
pub extern "user32" fn DrawTextW(dc: w.HDC, text: [*]const u16, n: i32, r: *w.RECT, format: u32) callconv(.winapi) i32;
pub extern "user32" fn UpdateLayeredWindow(hwnd: w.HWND, dst: ?w.HDC, pt_dst: ?*const w.POINT, size: ?*const [2]i32, src: ?w.HDC, pt_src: ?*const w.POINT, key: u32, blend: ?*const u32, flags: u32) callconv(.winapi) w.BOOL;
pub extern "user32" fn GetCursorPos(p: *w.POINT) callconv(.winapi) w.BOOL;
pub extern "user32" fn ClientToScreen(hwnd: w.HWND, p: *w.POINT) callconv(.winapi) w.BOOL;
pub extern "user32" fn GetSystemMetricsForDpi(index: i32, dpi: u32) callconv(.winapi) i32;
pub extern "user32" fn MonitorFromRect(r: *const w.RECT, flags: u32) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn MonitorFromWindow(hwnd: w.HWND, flags: u32) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn GetMonitorInfoW(mon: *anyopaque, info: *MONITORINFO) callconv(.winapi) w.BOOL;
pub extern "user32" fn FlashWindowEx(info: *const FLASHWINFO) callconv(.winapi) w.BOOL;
pub extern "gdi32" fn CreateCompatibleDC(dc: ?w.HDC) callconv(.winapi) ?w.HDC;
pub extern "gdi32" fn DeleteDC(dc: w.HDC) callconv(.winapi) w.BOOL;
pub extern "gdi32" fn CreateDIBSection(dc: ?w.HDC, info: *const w.BITMAPINFOHEADER, usage: u32, bits: *?*anyopaque, section: ?*anyopaque, offset: u32) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn SelectObject(dc: w.HDC, obj: HGDIOBJ) callconv(.winapi) HGDIOBJ;
pub extern "gdi32" fn DeleteObject(obj: HGDIOBJ) callconv(.winapi) w.BOOL;
pub extern "gdi32" fn CreateFontW(height: i32, width: i32, esc: i32, orient: i32, weight: i32, italic: u32, underline: u32, strike: u32, charset: u32, out: u32, clip: u32, quality: u32, pitch: u32, face: [*:0]const u16) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn SetBkMode(dc: w.HDC, mode: i32) callconv(.winapi) i32;
pub extern "gdi32" fn SetTextColor(dc: w.HDC, color: u32) callconv(.winapi) u32;
pub extern "gdi32" fn GdiFlush() callconv(.winapi) w.BOOL;
pub extern "gdi32" fn GetTextFaceW(dc: w.HDC, n: i32, face: [*]u16) callconv(.winapi) i32;

pub const MONITORINFO = extern struct {
    cbSize: u32 = @sizeOf(MONITORINFO),
    rcMonitor: w.RECT = .{},
    rcWork: w.RECT = .{},
    dwFlags: u32 = 0,
};

pub const FLASHWINFO = extern struct {
    cbSize: u32 = @sizeOf(FLASHWINFO),
    hwnd: w.HWND,
    dwFlags: u32,
    uCount: u32 = 0,
    dwTimeout: u32 = 0,
};

/// The work area of the monitor with most of `r` (pixels), or the nearest.
pub fn workAreaOf(r: w.RECT) w.RECT {
    var info: MONITORINFO = .{};
    const mon = MonitorFromRect(&r, 2) orelse return .{ .right = w.GetSystemMetrics(0), .bottom = w.GetSystemMetrics(1) }; // MONITOR_DEFAULTTONEAREST
    if (GetMonitorInfoW(mon, &info) == 0) return .{ .right = w.GetSystemMetrics(0), .bottom = w.GetSystemMetrics(1) };
    return info.rcWork;
}

/// A 32-bit top-down DIB section selected into a memory DC.
pub const Bitmap = struct {
    dc: w.HDC,
    bmp: HGDIOBJ,
    old: HGDIOBJ,
    px: []u32,

    pub fn init(screen: w.HDC, width: i32, height: i32) ?Bitmap {
        const hdr: w.BITMAPINFOHEADER = .{ .biWidth = width, .biHeight = -height };
        var bits: ?*anyopaque = null;
        const bmp = CreateDIBSection(screen, &hdr, 0, &bits, null, 0) orelse return null;
        const p = bits orelse {
            _ = DeleteObject(bmp);
            return null;
        };
        const dc = CreateCompatibleDC(screen) orelse {
            _ = DeleteObject(bmp);
            return null;
        };
        const old = SelectObject(dc, bmp);
        const n: usize = @intCast(width * height);
        const px = @as([*]u32, @ptrCast(@alignCast(p)))[0..n];
        @memset(px, 0);
        return .{ .dc = dc, .bmp = bmp, .old = old, .px = px };
    }

    pub fn deinit(b: *Bitmap) void {
        _ = SelectObject(b.dc, b.old);
        _ = DeleteDC(b.dc);
        _ = DeleteObject(b.bmp);
    }
};

pub const Font = struct {
    font: HGDIOBJ,
    /// Segoe Fluent Icons, Windows 11's; Windows 10 has Segoe MDL2 Assets.
    fluent: bool,
};

var fonts: [8]?struct { px: i32, f: Font } = @splat(null);

/// The caption glyphs' font at `px` pixels, made once per size.
pub fn captionFont(px: i32) Font {
    for (fonts) |e| if (e) |f| if (f.px == px) return f.f;
    const fluent_name = std.unicode.utf8ToUtf16LeStringLiteral("Segoe Fluent Icons");
    var f: Font = .{ .font = createFont(-px, fluent_name), .fluent = true };
    if (!isFace(f.font, fluent_name)) {
        _ = DeleteObject(f.font);
        f = .{ .font = createFont(-px, std.unicode.utf8ToUtf16LeStringLiteral("Segoe MDL2 Assets")), .fluent = false };
    }
    for (&fonts) |*slot| if (slot.* == null) {
        slot.* = .{ .px = px, .f = f };
        break;
    };
    return f;
}

fn createFont(height: i32, face: [*:0]const u16) HGDIOBJ {
    // FW_NORMAL, DEFAULT_CHARSET, ANTIALIASED_QUALITY. A font always comes back.
    return CreateFontW(height, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 4, 0, face).?;
}

/// Whether `font` is the face named, not one Windows put in for a missing one.
fn isFace(font: HGDIOBJ, name: [*:0]const u16) bool {
    const dc = CreateCompatibleDC(null) orelse return false;
    defer _ = DeleteDC(dc);
    const old = SelectObject(dc, font);
    defer _ = SelectObject(dc, old);
    var buf: [64]u16 = undefined;
    const n = GetTextFaceW(dc, buf.len, &buf);
    if (n <= 0) return false;
    const got = std.mem.sliceTo(buf[0..@intCast(n)], 0);
    const want = std.mem.span(name);
    if (got.len != want.len) return false;
    for (got, want) |a, b| if (std.ascii.toLower(@truncate(a)) != std.ascii.toLower(@truncate(b))) return false;
    return true;
}

const OSVERSIONINFOW = extern struct {
    size: u32 = @sizeOf(OSVERSIONINFOW),
    major: u32 = 0,
    minor: u32 = 0,
    build: u32 = 0,
    platform: u32 = 0,
    csd: [128]u16 = @splat(0),
};
extern "ntdll" fn RtlGetVersion(info: *OSVERSIONINFOW) callconv(.winapi) i32;

/// Windows 11 (build 22000 and later): snap layouts, Mica, round corners.
pub fn windows11() bool {
    var v: OSVERSIONINFOW = .{};
    if (RtlGetVersion(&v) != 0) return false;
    return v.major >= 10 and v.build >= 22000;
}

test "bitmaps to draw into, and the caption's font" {
    const screen = GetDC(null) orelse return error.NoScreen;
    defer _ = ReleaseDC(null, screen);
    var b = Bitmap.init(screen, 4, 3) orelse return error.NoBitmap;
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 12), b.px.len);
    const f = captionFont(10);
    try std.testing.expectEqual(f.font, captionFont(10).font);
}
