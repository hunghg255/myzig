//! Pages inside native UI on macOS (`ui.webView`): each WKWebView is in a
//! clip view, a flipped NSView with a layer masking to its bounds, a
//! subview of the window's surface (flipped too), framed where the frame
//! shows the web view's part that shows; the web view is at the page's
//! place in it, cut off where it goes past. AppKit lays out in points.
//!
//! What native UI paints over the page shows in its cover: a flipped view
//! above the clip views whose layer shows the cover's pixels; its hit test
//! gives the pointer to the surface where they are opaque, and none
//! elsewhere, where AppKit goes on to the page.
const std = @import("std");
const objc = @import("objc.zig");
const cf = @import("ui/cf.zig");
const CoverProbe = @import("page_embed.zig").CoverProbe;
const Image = @import("page_embed_cover.zig").Image;
const page_mod = @import("page.zig");
const Window = @import("window.zig").Window;
const webview = @import("ui/webview.zig");
const PageOptions = @import("window_types.zig").PageOptions;
const Probe = @import("page_embed.zig").Probe;

pub const Page = page_mod.Page;

/// Where an embedded page goes: its clip view, and its place in it.
pub const Embed = struct {
    clip_view: objc.Object,
    view: *webview.WebView,
    clip: objc.CGRect = .{},
    bounds: objc.CGRect = .{},
    shown: bool = false,
    /// What native UI paints over the page, once something did.
    cover: ?*Cover = null,

    /// The page's web view goes into the clip view.
    pub fn adopt(e: *Embed, wv: objc.Object) void {
        objc.msg(void, wv, "setAutoresizingMask:", .{@as(objc.NSUInteger, 0)});
        objc.msg(void, e.clip_view, "addSubview:", .{wv});
    }
};

fn yes(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

pub fn create(host: *anyopaque, options: PageOptions, view: *webview.WebView) ?*Page {
    const window: *Window = @ptrCast(@alignCast(host));
    const surface = window.surface orelse return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const cls = objc.defineClass(.{
        .name = "MyZigWebClip",
        .superclass = "NSView",
        .methods = &.{.{ .name = "isFlipped", .imp = &yes, .types = "c@:" }},
    });
    const clip = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "initWithFrame:", .{objc.CGRect{}});
    objc.msg(void, clip, "setWantsLayer:", .{objc.YES});
    if (objc.msg(?objc.Object, clip, "layer", .{})) |layer| objc.msg(void, layer, "setMasksToBounds:", .{objc.YES});
    objc.msg(void, clip, "setHidden:", .{objc.YES});
    objc.msg(void, surface.nsview, "addSubview:", .{clip});
    const gpa = window.app.gpa;
    const e = gpa.create(Embed) catch {
        objc.msg(void, clip, "removeFromSuperview", .{});
        objc.release(clip);
        return null;
    };
    e.* = .{ .clip_view = clip, .view = view };
    const page = Page.open(window, options, e) catch {
        objc.msg(void, clip, "removeFromSuperview", .{});
        objc.release(clip);
        gpa.destroy(e);
        return null;
    };
    window.web_views.append(gpa, page) catch {};
    return page;
}

/// The page goes: it leaves its window and its web view, with its clip.
pub fn drop(page: *Page, e: *Embed) void {
    const window = page.window;
    for (window.web_views.items, 0..) |p, i| if (p == page) {
        _ = window.web_views.orderedRemove(i);
        break;
    };
    if (e.view.page == page) {
        e.view.page = null;
        e.view.shown = null;
    }
    if (hasKeyboard(page)) if (window.surface) |s| {
        _ = objc.msg(objc.BOOL, window.nswindow, "makeFirstResponder:", .{s.nsview});
    };
    objc.msg(void, e.clip_view, "removeFromSuperview", .{});
    objc.release(e.clip_view);
    if (e.cover) |cv| cv.destroy(page.gpa);
    page.gpa.destroy(e);
    page.embed = null;
}

pub fn destroy(page: *Page) void {
    page.destroy();
}

fn rect(x: f32, y: f32, w: f32, h: f32) objc.CGRect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

pub fn place(page: *Page, p: webview.Placement) void {
    const e = page.embed orelse return;
    const clip = rect(p.clip.x, p.clip.y, p.clip.w, p.clip.h);
    const bounds = rect(p.frame.x - p.clip.x, p.frame.y - p.clip.y, p.frame.w, p.frame.h);
    if (e.shown and std.meta.eql(clip, e.clip) and std.meta.eql(bounds, e.bounds)) return;
    e.clip = clip;
    e.bounds = bounds;
    objc.msg(void, e.clip_view, "setFrame:", .{clip});
    objc.msg(void, page.webview, "setFrame:", .{bounds});
    if (!e.shown) objc.msg(void, e.clip_view, "setHidden:", .{objc.NO});
    e.shown = true;
}

/// Whether the window's keyboard is in the page's web view.
fn hasKeyboard(page: *Page) bool {
    var r = objc.msg(?objc.Object, page.window.nswindow, "firstResponder", .{});
    while (r) |v| {
        if (v == page.webview) return true;
        if (!objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSView")})) return false;
        r = objc.msg(?objc.Object, v, "superview", .{});
    }
    return false;
}

pub fn hide(page: *Page) void {
    const e = page.embed orelse return;
    if (!e.shown) return;
    e.shown = false;
    // A hidden page keeps no keyboard: it goes back to native UI.
    if (hasKeyboard(page)) if (page.window.surface) |s| {
        _ = objc.msg(objc.BOOL, page.window.nswindow, "makeFirstResponder:", .{s.nsview});
    };
    objc.msg(void, e.clip_view, "setHidden:", .{objc.YES});
    if (e.cover) |cv| cv.hide();
}

pub fn focus(page: *Page, _: bool) void {
    _ = objc.msg(objc.BOOL, page.window.nswindow, "makeFirstResponder:", .{page.webview});
}

fn box(r: objc.CGRect) [4]i32 {
    return .{ @intFromFloat(@round(r.origin.x)), @intFromFloat(@round(r.origin.y)), @intFromFloat(@round(r.size.width)), @intFromFloat(@round(r.size.height)) };
}

/// Where AppKit has the clip view and the page in it, read back.
pub fn probe(page: *Page) ?Probe {
    const e = page.embed orelse return null;
    const clip = objc.msg(objc.CGRect, e.clip_view, "frame", .{});
    const in = objc.msg(objc.CGRect, page.webview, "frame", .{});
    return .{ .clip = box(clip), .page = box(in), .shown = !objc.msg(objc.BOOL, e.clip_view, "isHidden", .{}) };
}

pub fn expected(p: webview.Placement) Probe {
    return .{ .clip = box(rect(p.clip.x, p.clip.y, p.clip.w, p.clip.h)), .page = box(rect(p.frame.x - p.clip.x, p.frame.y - p.clip.y, p.frame.w, p.frame.h)), .shown = true };
}

// Covers.

const CGImageRef = *opaque {};
extern "c" fn CGBitmapContextCreateImage(ctx: cf.CGContextRef) ?CGImageRef;
extern "c" fn CGImageRelease(img: CGImageRef) void;
/// Premultiplied BGRA, little endian: `kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little`.
const bgra_premultiplied: u32 = 2 | (2 << 12);

/// A page's cover: a flipped view over the clip views, framed at `frame`
/// (points), its layer showing `px` (`scale` pixels a point).
pub const Cover = struct {
    view: objc.Object,
    page: *Page,
    px: std.ArrayList(u32) = .empty,
    pw: usize = 0,
    ph: usize = 0,
    scale: f32 = 1,
    frame: objc.CGRect = .{},
    shown: bool = false,

    fn create(page: *Page) ?*Cover {
        const surface = page.window.surface orelse return null;
        const cls = objc.defineClass(.{
            .name = "MyZigWebCover",
            .superclass = "NSView",
            .methods = &.{
                .{ .name = "isFlipped", .imp = &yes, .types = "c@:" },
                .{ .name = "hitTest:", .imp = &hitTest, .types = "@@:{CGPoint=dd}" },
            },
        });
        const view = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "initWithFrame:", .{objc.CGRect{}});
        objc.msg(void, view, "setWantsLayer:", .{objc.YES});
        objc.msg(void, view, "setHidden:", .{objc.YES});
        objc.msg(void, surface.nsview, "addSubview:", .{view});
        const cv = page.gpa.create(Cover) catch {
            objc.msg(void, view, "removeFromSuperview", .{});
            objc.release(view);
            return null;
        };
        cv.* = .{ .view = view, .page = page };
        objc.setZig(view, cv);
        return cv;
    }

    fn destroy(cv: *Cover, gpa: std.mem.Allocator) void {
        objc.setZig(cv.view, null);
        objc.msg(void, cv.view, "removeFromSuperview", .{});
        objc.release(cv.view);
        cv.px.deinit(gpa);
        gpa.destroy(cv);
    }

    fn hide(cv: *Cover) void {
        if (!cv.shown) return;
        cv.shown = false;
        objc.msg(void, cv.view, "setHidden:", .{objc.YES});
    }

    fn show(cv: *Cover, img: Image) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        cv.px.resize(cv.page.gpa, img.px.len) catch return;
        @memcpy(cv.px.items, img.px);
        cv.pw = img.w;
        cv.ph = img.h;
        cv.scale = img.scale;
        const s: f64 = img.scale;
        cv.frame = .{ .origin = .{ .x = @as(f64, @floatFromInt(img.x)) / s, .y = @as(f64, @floatFromInt(img.y)) / s }, .size = .{ .width = @as(f64, @floatFromInt(img.w)) / s, .height = @as(f64, @floatFromInt(img.h)) / s } };
        objc.msg(void, cv.view, "setFrame:", .{cv.frame});
        if (objc.msg(?objc.Object, cv.view, "layer", .{})) |layer| {
            const space = cf.CGColorSpaceCreateWithName(cf.kCGColorSpaceSRGB) orelse return;
            defer cf.CGColorSpaceRelease(space);
            const ctx = cf.CGBitmapContextCreate(cv.px.items.ptr, img.w, img.h, 8, img.w * 4, space, bgra_premultiplied) orelse return;
            defer cf.CGContextRelease(ctx);
            const picture = CGBitmapContextCreateImage(ctx) orelse return;
            defer CGImageRelease(picture);
            objc.msg(void, layer, "setContentsScale:", .{s});
            objc.msg(void, layer, "setContents:", .{@as(*anyopaque, picture)});
        }
        // Above the clip views of every web view.
        const surface = (cv.page.window.surface orelse return).nsview;
        objc.msg(void, surface, "addSubview:positioned:relativeTo:", .{ cv.view, @as(objc.NSInteger, 1), @as(?objc.Object, null) });
        if (!cv.shown) objc.msg(void, cv.view, "setHidden:", .{objc.NO});
        cv.shown = true;
    }

    /// Whether the pixel under `x`, `y` (points of the cover) shows something.
    fn opaqueAt(cv: *const Cover, x: f64, y: f64) bool {
        const px: i64 = @intFromFloat(@floor(x * cv.scale));
        const py: i64 = @intFromFloat(@floor(y * cv.scale));
        if (px < 0 or py < 0 or px >= cv.pw or py >= cv.ph) return false;
        return cv.px.items[@as(usize, @intCast(py)) * cv.pw + @as(usize, @intCast(px))] >> 24 != 0;
    }
};

/// The surface takes the pointer where the cover shows something; none
/// does elsewhere, and AppKit goes on to the page under it.
fn hitTest(self: objc.Object, _: objc.SEL, p: objc.CGPoint) callconv(.c) ?objc.Object {
    const cv = objc.getZig(Cover, self) orelse return null;
    if (!cv.shown) return null;
    if (!cv.opaqueAt(p.x - cv.frame.origin.x, p.y - cv.frame.origin.y)) return null;
    return if (cv.page.window.surface) |s| s.nsview else null;
}

/// Covers fall on whole points.
pub fn unit(scale: f32) f32 {
    return scale;
}

pub fn cover(page: *Page, img: ?Image) void {
    const e = page.embed orelse return;
    const pic = img orelse {
        if (e.cover) |cv| cv.hide();
        return;
    };
    if (!e.shown) return;
    if (e.cover == null) e.cover = Cover.create(page);
    const cv = e.cover orelse return;
    cv.show(pic);
}

/// Where AppKit has the cover view, read back, and whether it shows.
pub fn probeCover(page: *Page) ?CoverProbe {
    const e = page.embed orelse return null;
    const cv = e.cover orelse return .{};
    const r = objc.msg(objc.CGRect, cv.view, "frame", .{});
    return .{ .rect = box(r), .shown = !objc.msg(objc.BOOL, cv.view, "isHidden", .{}) };
}

pub fn expectedCover(img: Image) CoverProbe {
    const s = img.scale;
    const f = struct {
        fn pt(v: anytype, scale: f32) i32 {
            return @intFromFloat(@round(@as(f32, @floatFromInt(v)) / scale));
        }
    }.pt;
    return .{ .rect = .{ f(img.x, s), f(img.y, s), f(img.w, s), f(img.h, s) }, .shown = true };
}

/// A click on the cover, as AppKit delivers one: hit-tested, then a press
/// and a release to the view that takes it.
pub fn clickCover(page: *Page, x: f32, y: f32) bool {
    const e = page.embed orelse return false;
    const cv = e.cover orelse return false;
    const surface = page.window.surface orelse return false;
    const target = hitTest(cv.view, undefined, .{ .x = x, .y = y }) orelse return false;
    const pool = objc.Pool.push();
    defer pool.pop();
    const at = objc.msg(objc.CGPoint, surface.nsview, "convertPoint:toView:", .{ objc.CGPoint{ .x = x, .y = y }, @as(?objc.Object, null) });
    const number = objc.msg(objc.NSInteger, page.window.nswindow, "windowNumber", .{});
    inline for (.{ .{ @as(objc.NSUInteger, 1), "mouseDown:" }, .{ @as(objc.NSUInteger, 2), "mouseUp:" } }) |step| {
        const ev = objc.msg(?objc.Object, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
            step[0], at, @as(objc.NSUInteger, 0), @as(f64, 0), number, @as(?objc.Object, null), @as(objc.NSInteger, 0), @as(objc.NSInteger, 1), @as(f32, 1),
        }) orelse return false;
        objc.msg(void, target, step[1], .{ev});
    }
    return true;
}
