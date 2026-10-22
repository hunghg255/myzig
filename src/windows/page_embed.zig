//! Pages inside native UI on Windows (`ui.webView`): a WebView2 controller
//! whose parent is a child window of the window's, the clip window, placed
//! where the frame shows the web view's part that shows; the page's
//! bounds in it put the rest of the page outside, cut off. A web view not
//! shown hides both. The clip window also takes the page's flushes (the
//! window's own WM_APP+1 is native UI's frame). Tab past the page's ends
//! gives native UI the keyboard back (MoveFocusRequested), and a page that
//! takes the keyboard (clicked) takes native UI's focus.
//!
//! What native UI paints over the page shows in its cover: a layered child
//! window over the clip window, of premultiplied pixels (UpdateLayeredWindow),
//! made when something first covers the page. Windows lets the pointer
//! through its transparent pixels to the page; the cover sends what it
//! gets on to the window's, as native UI's own.
const std = @import("std");
const w = @import("win32.zig");
const gdi = @import("gdi.zig");
const com = @import("com.zig");
const page_mod = @import("page.zig");
const Window = @import("window.zig").Window;
const webview = @import("../ui/webview.zig");
const PageOptions = @import("../window_types.zig").PageOptions;
const Probe = @import("../page_embed.zig").Probe;
const CoverProbe = @import("../page_embed.zig").CoverProbe;
const Image = @import("../page_embed_cover.zig").Image;

pub const Page = page_mod.Page;

const ctl_get_visible = 3;
const ctl_put_visible = 4;
const ctl_get_bounds = 5;
const ctl_put_bounds = 6;
const ctl_move_focus = 12;
const ctl_add_move_focus_requested = 13;
const ctl_add_got_focus = 15;
const ctl_add_lost_focus = 17;
const move_focus_get_reason = 3;
const move_focus_put_handled = 5;
const set9_put_non_client_region = 38;
const iid_settings9 = com.GUID.parse("0528a73b-e92d-49f4-927a-e547dddaa37d");

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("MyZigWebClip");
var registered = false;

/// Where an embedded page goes: its clip window, and its place in it.
pub const Embed = struct {
    /// The clip window, a child of the window's.
    hwnd: w.HWND,
    view: *webview.WebView,
    /// The clip window's rectangle in the window, and the page's in it, in pixels.
    clip: w.RECT = .{},
    bounds: w.RECT = .{},
    shown: bool = false,
    /// The page has the keyboard.
    focused: bool = false,
    /// What native UI paints over the page, once something did.
    cover: ?*Cover = null,

    /// The controller is there: it goes where the last frame placed it,
    /// and hears of the keyboard.
    pub fn setUp(e: *Embed, page: *Page) void {
        const c = page.controller.?;
        var token: i64 = 0;
        _ = com.withHandler(page, moveFocusRequested, Page.addEvent, .{ c, @as(usize, ctl_add_move_focus_requested), &token });
        _ = com.withHandler(page, gotFocus, Page.addEvent, .{ c, @as(usize, ctl_add_got_focus), &token });
        _ = com.withHandler(page, lostFocus, Page.addEvent, .{ c, @as(usize, ctl_add_lost_focus), &token });
        nonClientRegions(page);
        apply(page, e);
    }
};

/// CSS's `app-region: drag` moves the window, where WebView2 supports it
/// (ICoreWebView2Settings9); the bridge's `--app-region` works everywhere.
fn nonClientRegions(page: *Page) void {
    const wv = page.webview orelse return;
    var settings: ?com.Object = null;
    if (com.failed(com.call(wv, page_mod.wv_get_settings, .{&settings}))) return;
    defer com.release(settings);
    const s9 = com.query(settings orelse return, &iid_settings9) orelse return;
    defer com.release(s9);
    _ = com.call(s9, set9_put_non_client_region, .{@as(i32, 1)});
}

pub fn create(host: *anyopaque, options: PageOptions, view: *webview.WebView) ?*Page {
    const window: *Window = @ptrCast(@alignCast(host));
    const parent = window.hwnd orelse return null;
    const inst = w.GetModuleHandleW(null);
    if (!registered) {
        const wc: w.WNDCLASSEXW = .{ .lpfnWndProc = clipProc, .hInstance = inst, .hCursor = w.LoadCursorW(null, 32512), .lpszClassName = class_name };
        if (w.RegisterClassExW(&wc) == 0) return null;
        registered = true;
    }
    const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
    const hwnd = w.CreateWindowExW(0, class_name, empty, gdi.WS_CHILD | gdi.WS_CLIPCHILDREN | gdi.WS_CLIPSIBLINGS, 0, 0, 0, 0, parent, null, inst, null) orelse return null;
    // The window's frames paint around its children, not over them.
    const style = w.GetWindowLongPtrW(parent, gdi.GWL_STYLE);
    if (style & gdi.WS_CLIPCHILDREN == 0) _ = w.SetWindowLongPtrW(parent, gdi.GWL_STYLE, style | gdi.WS_CLIPCHILDREN);
    const gpa = window.app.gpa;
    const e = gpa.create(Embed) catch {
        _ = w.DestroyWindow(hwnd);
        return null;
    };
    e.* = .{ .hwnd = hwnd, .view = view };
    const page = Page.open(window, options, e) catch {
        gpa.destroy(e);
        _ = w.DestroyWindow(hwnd);
        return null;
    };
    _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(page)));
    window.web_views.append(gpa, page) catch {};
    return page;
}

/// The page goes: it leaves its window and its web view, and its clip
/// window is destroyed once its controller closed (returned).
pub fn drop(page: *Page, e: *Embed) ?w.HWND {
    const window = page.window;
    for (window.web_views.items, 0..) |p, i| if (p == page) {
        _ = window.web_views.orderedRemove(i);
        break;
    };
    if (e.view.page == page) {
        e.view.page = null;
        e.view.shown = null;
    }
    if (e.focused) if (window.hwnd) |h| {
        _ = w.SetFocus(h);
    };
    _ = w.SetWindowLongPtrW(e.hwnd, w.GWLP_USERDATA, 0);
    _ = w.ShowWindow(e.hwnd, 0);
    if (e.cover) |cv| cv.destroy(page.gpa);
    const hwnd = e.hwnd;
    page.gpa.destroy(e);
    page.embed = null;
    return hwnd;
}

pub fn destroy(page: *Page) void {
    page.destroy();
}

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// The clip window's rectangle in the window, and the page's in it, in pixels.
fn pixels(p: webview.Placement) [2]w.RECT {
    const s = p.scale;
    const clip: w.RECT = .{ .left = px(p.clip.x, s), .top = px(p.clip.y, s), .right = px(p.clip.x + p.clip.w, s), .bottom = px(p.clip.y + p.clip.h, s) };
    const fx = px(p.frame.x, s) - clip.left;
    const fy = px(p.frame.y, s) - clip.top;
    return .{ clip, .{ .left = fx, .top = fy, .right = fx + px(p.frame.x + p.frame.w, s) - px(p.frame.x, s), .bottom = fy + px(p.frame.y + p.frame.h, s) - px(p.frame.y, s) } };
}

pub fn place(page: *Page, p: webview.Placement) void {
    const e = page.embed orelse return;
    const clip, const bounds = pixels(p);
    if (e.shown and std.meta.eql(clip, e.clip) and std.meta.eql(bounds, e.bounds)) return;
    e.clip = clip;
    e.bounds = bounds;
    e.shown = true;
    apply(page, e);
}

/// Puts the clip window and the page where `e` says.
fn apply(page: *Page, e: *Embed) void {
    if (e.shown) {
        _ = w.SetWindowPos(e.hwnd, null, e.clip.left, e.clip.top, e.clip.right - e.clip.left, e.clip.bottom - e.clip.top, gdi.SWP_NOZORDER | gdi.SWP_NOACTIVATE | gdi.SWP_SHOWWINDOW);
    } else {
        _ = w.ShowWindow(e.hwnd, 0);
        if (e.cover) |cv| cv.hide();
    }
    const c = page.controller orelse return;
    if (e.shown) _ = com.call(c, ctl_put_bounds, .{e.bounds});
    _ = com.call(c, ctl_put_visible, .{@as(i32, @intFromBool(e.shown))});
    @import("page_memory.zig").refresh(page);
}

pub fn hide(page: *Page) void {
    const e = page.embed orelse return;
    if (!e.shown) return;
    e.shown = false;
    // A hidden page keeps no keyboard: it goes back to native UI.
    if (e.focused) if (page.window.hwnd) |h| {
        _ = w.SetFocus(h);
    };
    apply(page, e);
}

pub fn focus(page: *Page, back: bool) void {
    const c = page.controller orelse return;
    _ = com.call(c, ctl_move_focus, .{@as(i32, if (back) 2 else 1)}); // previous, next
}

fn box(r: w.RECT) [4]i32 {
    return .{ r.left, r.top, r.right - r.left, r.bottom - r.top };
}

/// Where the clip window is and the controller puts the page, read back.
pub fn probe(page: *Page) ?Probe {
    const e = page.embed orelse return null;
    const c = page.controller orelse return null;
    const parent = page.window.hwnd orelse return null;
    var r: w.RECT = .{};
    _ = w.GetWindowRect(e.hwnd, &r);
    var at: w.POINT = .{ .x = r.left, .y = r.top };
    _ = w.ScreenToClient(parent, &at);
    var b: w.RECT = .{};
    var visible: i32 = 0;
    _ = com.call(c, ctl_get_bounds, .{&b});
    _ = com.call(c, ctl_get_visible, .{&visible});
    // Its own flag: a hidden window's children are not visible either.
    const own_style = w.GetWindowLongPtrW(e.hwnd, gdi.GWL_STYLE);
    return .{ .clip = .{ at.x, at.y, r.right - r.left, r.bottom - r.top }, .page = box(b), .shown = own_style & gdi.WS_VISIBLE != 0 and visible != 0 };
}

pub fn expected(p: webview.Placement) Probe {
    const r = pixels(p);
    return .{ .clip = box(r[0]), .page = box(r[1]), .shown = true };
}

fn moveFocusRequested(ctx: ?*anyopaque, _: usize, args: usize) void {
    const page = Page.alive(ctx) orelse return;
    const e = page.embed orelse return;
    var reason: i32 = 0;
    _ = com.call(@ptrFromInt(args), move_focus_get_reason, .{&reason});
    // Tab past the page's ends: the keyboard goes to native UI, not to
    // the window WebView2 would find next.
    _ = com.call(@ptrFromInt(args), move_focus_put_handled, .{@as(i32, 1)});
    if (page.window.hwnd) |h| _ = w.SetFocus(h);
    e.focused = false;
    e.view.tabOut(reason == 2);
    page.window.redraw();
}

fn gotFocus(ctx: ?*anyopaque, _: usize, _: usize) void {
    const page = Page.alive(ctx) orelse return;
    const e = page.embed orelse return;
    e.focused = true;
    if (e.view.focused) return;
    e.view.tookFocus();
    page.window.redraw();
}

fn lostFocus(ctx: ?*anyopaque, _: usize, _: usize) void {
    const page = Page.alive(ctx) orelse return;
    if (page.embed) |e| e.focused = false;
}

fn clipProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    const p = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
    if (msg == page_mod.WM_FLUSH) {
        if (p != 0) @as(*Page, @ptrFromInt(@as(usize, @bitCast(p)))).flush();
        return 0;
    }
    if (msg == w.WM_ERASEBKGND) return 1;
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

// Covers.

const cover_class = std.unicode.utf8ToUtf16LeStringLiteral("MyZigWebCover");
var cover_registered = false;

extern "user32" fn WindowFromPoint(p: w.POINT) callconv(.winapi) ?w.HWND;

const ht_transparent: w.LRESULT = -1;
const ht_client: w.LRESULT = 1;
const wm_nchittest = 0x0084;

/// A page's cover: a layered child window of the window's, over the clip
/// window, showing `bitmap` at `x`, `y` (pixels of the window).
pub const Cover = struct {
    hwnd: w.HWND,
    /// The window that hosts native UI, which gets the pointer.
    parent: w.HWND,
    page: *Page,
    bitmap: ?gdi.Bitmap = null,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    shown: bool = false,
    /// It asked to hear that the pointer left.
    tracking: bool = false,

    fn create(page: *Page, parent: w.HWND) ?*Cover {
        const inst = w.GetModuleHandleW(null);
        if (!cover_registered) {
            const wc: w.WNDCLASSEXW = .{ .lpfnWndProc = coverProc, .hInstance = inst, .hCursor = w.LoadCursorW(null, 32512), .lpszClassName = cover_class };
            if (w.RegisterClassExW(&wc) == 0) return null;
            cover_registered = true;
        }
        const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
        // A layered child: the manifest names Windows 8 or later (`myzig.manifest`).
        const hwnd = w.CreateWindowExW(gdi.WS_EX_LAYERED, cover_class, empty, gdi.WS_CHILD | gdi.WS_CLIPSIBLINGS, 0, 0, 0, 0, parent, null, inst, null) orelse return null;
        const cv = page.gpa.create(Cover) catch {
            _ = w.DestroyWindow(hwnd);
            return null;
        };
        cv.* = .{ .hwnd = hwnd, .parent = parent, .page = page };
        _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(cv)));
        return cv;
    }

    fn destroy(cv: *Cover, gpa: std.mem.Allocator) void {
        _ = w.SetWindowLongPtrW(cv.hwnd, w.GWLP_USERDATA, 0);
        _ = w.DestroyWindow(cv.hwnd);
        if (cv.bitmap) |*b| b.deinit();
        gpa.destroy(cv);
    }

    fn hide(cv: *Cover) void {
        if (!cv.shown) return;
        cv.shown = false;
        _ = w.ShowWindow(cv.hwnd, 0);
    }

    /// Shows `img`, over the page.
    fn show(cv: *Cover, img: Image) void {
        const iw: i32 = @intCast(img.w);
        const ih: i32 = @intCast(img.h);
        if (cv.bitmap == null or cv.width != iw or cv.height != ih) {
            if (cv.bitmap) |*b| b.deinit();
            cv.bitmap = null;
            const screen = gdi.GetDC(null) orelse return;
            defer _ = gdi.ReleaseDC(null, screen);
            cv.bitmap = gdi.Bitmap.init(screen, iw, ih) orelse return;
            cv.width = iw;
            cv.height = ih;
        }
        const b = &cv.bitmap.?;
        @memcpy(b.px, img.px[0..b.px.len]);
        _ = gdi.GdiFlush();
        cv.x = img.x;
        cv.y = img.y;
        var size: [2]i32 = .{ iw, ih };
        var origin: w.POINT = .{};
        const blend: u32 = 255 << 16 | 1 << 24; // AC_SRC_OVER, constant alpha 255, AC_SRC_ALPHA
        _ = gdi.UpdateLayeredWindow(cv.hwnd, null, null, &size, b.dc, &origin, 0, &blend, 2); // ULW_ALPHA
        // On top: over the page, and over clip windows made since.
        _ = w.SetWindowPos(cv.hwnd, null, cv.x, cv.y, iw, ih, gdi.SWP_NOACTIVATE | gdi.SWP_SHOWWINDOW);
        cv.shown = true;
    }

    /// The pixel at `x`, `y` of the cover (0 outside).
    fn pixel(cv: *const Cover, x: i32, y: i32) u32 {
        const b = cv.bitmap orelse return 0;
        if (x < 0 or y < 0 or x >= cv.width or y >= cv.height) return 0;
        return b.px[@as(usize, @intCast(y)) * @as(usize, @intCast(cv.width)) + @as(usize, @intCast(x))];
    }

    /// Native UI's window gets what the cover got, at its place there.
    fn forward(cv: *Cover, msg: u32, wp: w.WPARAM, lp: w.LPARAM) void {
        const x: i32 = @as(i16, @truncate(lp));
        const y: i32 = @as(i16, @truncate(lp >> 16));
        _ = w.SendMessageW(cv.parent, msg, wp, param(x + cv.x, y + cv.y));
    }

    fn message(cv: *Cover, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
        switch (msg) {
            wm_nchittest => {
                // Through where it shows nothing (as Windows lets the
                // pointer through a layered window's transparent pixels).
                var p: w.POINT = .{ .x = @as(i16, @truncate(lp)), .y = @as(i16, @truncate(lp >> 16)) };
                _ = w.ScreenToClient(cv.hwnd, &p);
                return if (cv.pixel(p.x, p.y) >> 24 == 0) ht_transparent else ht_client;
            },
            w.WM_ERASEBKGND => return 1,
            w.WM_MOUSEMOVE => {
                if (!cv.tracking) {
                    var t: w.TRACKMOUSEEVENT = .{ .dwFlags = 2, .hwndTrack = cv.hwnd };
                    _ = w.TrackMouseEvent(&t);
                    cv.tracking = true;
                }
                // The window heard the pointer leave it for the cover: it
                // is still over native UI, whose leaving the cover tells.
                var m: w.MSG = undefined;
                while (w.PeekMessageW(&m, cv.parent, w.WM_MOUSELEAVE, w.WM_MOUSELEAVE, 1) != 0) {}
                if (cv.page.window.surface) |s| s.tracking = true;
                cv.forward(msg, wp, lp);
                return 0;
            },
            w.WM_MOUSELEAVE => {
                cv.tracking = false;
                if (cv.page.window.surface) |s| s.tracking = false;
                // Onto native UI's window, it hears the pointer there itself.
                var p: w.POINT = .{};
                _ = gdi.GetCursorPos(&p);
                if (WindowFromPoint(p) != cv.parent) _ = w.SendMessageW(cv.parent, w.WM_MOUSELEAVE, 0, 0);
                return 0;
            },
            0x0201...0x0209 => { // the left, right and middle buttons
                cv.forward(msg, wp, lp);
                return 0;
            },
            else => return null,
        }
    }
};

fn param(x: i32, y: i32) w.LPARAM {
    const ux: u16 = @bitCast(@as(i16, @truncate(x)));
    const uy: u16 = @bitCast(@as(i16, @truncate(y)));
    return @bitCast(@as(usize, ux) | @as(usize, uy) << 16);
}

fn coverProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    const p = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
    if (p != 0) {
        const cv: *Cover = @ptrFromInt(@as(usize, @bitCast(p)));
        if (cv.message(msg, wp, lp)) |r| return r;
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

/// Covers fall on whole pixels.
pub fn unit(_: f32) f32 {
    return 1;
}

pub fn cover(page: *Page, img: ?Image) void {
    const e = page.embed orelse return;
    const pic = img orelse {
        if (e.cover) |cv| cv.hide();
        return;
    };
    if (!e.shown) return;
    if (e.cover == null) e.cover = Cover.create(page, page.window.hwnd orelse return);
    const cv = e.cover orelse return;
    cv.show(pic);
}

/// Where the cover window is in the window, read back, and whether it shows.
pub fn probeCover(page: *Page) ?CoverProbe {
    const e = page.embed orelse return null;
    const cv = e.cover orelse return .{};
    const parent = page.window.hwnd orelse return null;
    var r: w.RECT = .{};
    _ = w.GetWindowRect(cv.hwnd, &r);
    var at: w.POINT = .{ .x = r.left, .y = r.top };
    _ = w.ScreenToClient(parent, &at);
    const own_style = w.GetWindowLongPtrW(cv.hwnd, gdi.GWL_STYLE);
    // Shown over the page: the clip window is under it.
    var under = GetWindow(cv.hwnd, 2); // GW_HWNDNEXT
    while (under) |u| : (under = GetWindow(u, 2)) if (u == e.hwnd) break;
    return .{ .rect = .{ at.x, at.y, r.right - r.left, r.bottom - r.top }, .shown = own_style & gdi.WS_VISIBLE != 0 and under != null };
}

extern "user32" fn GetWindow(hwnd: w.HWND, cmd: u32) callconv(.winapi) ?w.HWND;

pub fn expectedCover(img: Image) CoverProbe {
    return .{ .rect = .{ img.x, img.y, @intCast(img.w), @intCast(img.h) }, .shown = true };
}

/// A click on the cover, as Windows delivers one: hit-tested, then the
/// button's messages, at the cover's pixels.
pub fn clickCover(page: *Page, x: f32, y: f32) bool {
    const e = page.embed orelse return false;
    const cv = e.cover orelse return false;
    if (!cv.shown) return false;
    const s = page.window.surface orelse return false;
    const cx: i32 = @as(i32, @intFromFloat(@round(x * s.scale))) - cv.x;
    const cy: i32 = @as(i32, @intFromFloat(@round(y * s.scale))) - cv.y;
    var at: w.POINT = .{ .x = cx, .y = cy };
    _ = gdi.ClientToScreen(cv.hwnd, &at);
    if (w.SendMessageW(cv.hwnd, wm_nchittest, 0, param(at.x, at.y)) != ht_client) return false;
    _ = w.SendMessageW(cv.hwnd, w.WM_MOUSEMOVE, 0, param(cx, cy));
    _ = w.SendMessageW(cv.hwnd, w.WM_LBUTTONDOWN, 1, param(cx, cy)); // MK_LBUTTON
    _ = w.SendMessageW(cv.hwnd, w.WM_LBUTTONUP, 0, param(cx, cy));
    return true;
}
