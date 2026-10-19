//! The app's badge on Windows: a count or short text drawn as a red disc
//! (Windows' taskbar draws no text of its own), set as the overlay icon
//! of each window's taskbar button (`taskbar.setOverlay`). The text is
//! GDI's, antialiased, as coverage; the disc and the colors are drawn
//! here, premultiplied, so the drawing is tested without a screen.
const std = @import("std");
const w = @import("win32.zig");
const gdi = @import("gdi.zig");
const HICON = @import("tray.zig").HICON;

const ICONINFO = extern struct { fIcon: w.BOOL = 1, xHotspot: u32 = 0, yHotspot: u32 = 0, hbmMask: ?gdi.HGDIOBJ, hbmColor: ?gdi.HGDIOBJ };
extern "user32" fn CreateIconIndirect(info: *const ICONINFO) callconv(.winapi) ?HICON;
extern "user32" fn DestroyIcon(icon: HICON) callconv(.winapi) w.BOOL;
extern "gdi32" fn CreateBitmap(w: i32, h: i32, planes: u32, bits: u32, data: ?*const anyopaque) callconv(.winapi) ?gdi.HGDIOBJ;

/// The disc's color (BGR) and the text's: white on Windows' red.
const red = [3]u8{ 0x23, 0x11, 0xE8 };

/// The badge's pixels: premultiplied BGRA rows of `size`², from the
/// text's coverage (0-255 per pixel, the same size).
pub fn paint(out: []u8, size: usize, text: []const u8) void {
    const r: f32 = @as(f32, @floatFromInt(size)) / 2;
    for (0..size) |y| for (0..size) |x| {
        const dx = @as(f32, @floatFromInt(x)) + 0.5 - r;
        const dy = @as(f32, @floatFromInt(y)) + 0.5 - r;
        // Coverage of the disc: one pixel of antialiasing at its edge.
        const disc = std.math.clamp(r - @sqrt(dx * dx + dy * dy), 0, 1);
        const t: f32 = @as(f32, @floatFromInt(text[y * size + x])) / 255 * disc;
        const px = out[(y * size + x) * 4 ..][0..4];
        for (0..3) |c| {
            const below = @as(f32, @floatFromInt(red[c])) * disc;
            px[c] = @intFromFloat(@round(255 * t + below * (1 - t)));
        }
        px[3] = @intFromFloat(@round(255 * disc));
    };
}

/// The font's height for `len` characters in a badge of `size`.
pub fn fontHeight(size: usize, len: usize) i32 {
    const s: f32 = @floatFromInt(size);
    const k: f32 = switch (len) {
        0, 1 => 0.78,
        2 => 0.62,
        else => 0.46,
    };
    return @intFromFloat(@round(s * k));
}

/// GDI's coverage of `text` centered in `size`² (owned by `gpa`).
fn coverage(gpa: std.mem.Allocator, size: usize, text: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, size * size);
    errdefer gpa.free(out);
    @memset(out, 0);
    const dc = gdi.CreateCompatibleDC(null) orelse return error.Gdi;
    defer _ = gdi.DeleteDC(dc);
    const s: i32 = @intCast(size);
    const info: w.BITMAPINFOHEADER = .{ .biWidth = s, .biHeight = -s };
    var bits: ?*anyopaque = null;
    const bmp = gdi.CreateDIBSection(dc, &info, 0, &bits, null, 0) orelse return error.Gdi;
    defer _ = gdi.DeleteObject(bmp);
    const old = gdi.SelectObject(dc, bmp);
    defer _ = gdi.SelectObject(dc, old);
    var len: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
    while (it.nextCodepoint()) |_| len += 1;
    // Bold Segoe UI, antialiased without ClearType's colored fringes.
    const font = gdi.CreateFontW(-fontHeight(size, len), 0, 0, 0, 700, 0, 0, 0, 1, 0, 0, 4, 0, std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI")) orelse return error.Gdi;
    defer _ = gdi.DeleteObject(font);
    const old_font = gdi.SelectObject(dc, font);
    defer _ = gdi.SelectObject(dc, old_font);
    _ = gdi.SetBkMode(dc, 1); // TRANSPARENT
    _ = gdi.SetTextColor(dc, 0xFFFFFF);
    var wide: [32]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, text[0..@min(text.len, wide.len)]) catch return error.InvalidUtf8;
    var rect: w.RECT = .{ .right = s, .bottom = s };
    _ = gdi.DrawTextW(dc, &wide, @intCast(n), &rect, 0x1 | 0x4 | 0x20 | 0x100); // center, vcenter, single line, no clip
    _ = gdi.GdiFlush();
    const px: [*]const u8 = @ptrCast(bits orelse return error.Gdi);
    for (out, 0..) |*c, i| c.* = px[i * 4 + 1];
    return out;
}

/// The badge of `text` as an icon of `size`² pixels; DestroyIcon frees it.
pub fn icon(gpa: std.mem.Allocator, size: usize, text: []const u8) !HICON {
    const cov = try coverage(gpa, size, text);
    defer gpa.free(cov);
    const s: i32 = @intCast(size);
    const info: w.BITMAPINFOHEADER = .{ .biWidth = s, .biHeight = -s };
    var bits: ?*anyopaque = null;
    const color = gdi.CreateDIBSection(null, &info, 0, &bits, null, 0) orelse return error.Gdi;
    defer _ = gdi.DeleteObject(color);
    const px: [*]u8 = @ptrCast(bits orelse return error.Gdi);
    paint(px[0 .. size * size * 4], size, cov);
    const mask = CreateBitmap(s, s, 1, 1, null) orelse return error.Gdi;
    defer _ = gdi.DeleteObject(mask);
    return CreateIconIndirect(&.{ .hbmMask = mask, .hbmColor = color }) orelse error.Gdi;
}

pub fn destroy(i: HICON) void {
    _ = DestroyIcon(i);
}

/// The size of overlay icons: the small icons' (16 pixels at 100%).
pub fn iconSize() usize {
    return @intCast(@max(16, w.GetSystemMetrics(49))); // SM_CXSMICON
}

test "a badge: a red disc, transparent corners, white text inside" {
    const gpa = std.testing.allocator;
    const n = 16;
    var text: [n * n]u8 = @splat(0);
    text[8 * n + 8] = 255;
    var px: [n * n * 4]u8 = undefined;
    paint(&px, n, &text);
    // A corner is outside the disc: transparent.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, px[0..4]);
    // Inside: opaque red, and white where the text covers it.
    try std.testing.expectEqualSlices(u8, &.{ red[0], red[1], red[2], 255 }, px[(4 * n + 8) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, px[(8 * n + 8) * 4 ..][0..4]);
    try std.testing.expect(fontHeight(16, 1) > fontHeight(16, 3));

    // GDI draws "7" in the middle, and the icon is made.
    const cov = try coverage(gpa, 32, "7");
    defer gpa.free(cov);
    var sum: usize = 0;
    for (cov) |c| sum += c;
    try std.testing.expect(sum > 0);
    try std.testing.expectEqual(@as(u8, 0), cov[0]);
    const i = try icon(gpa, 32, "12");
    destroy(i);
}
