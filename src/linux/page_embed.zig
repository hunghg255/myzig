//! Pages inside native UI on Linux (`ui.webView`): the window's drawing
//! area goes into a GtkOverlay the first time it shows a web view, and
//! each web view is a GtkLayout over it, the clip, which the overlay
//! places where the frame shows the web view's part that shows (its
//! get-child-position signal); the WebKitWebView is in it at the page's
//! place, cut off where it goes past. GTK lays out in points, as native UI.
//!
//! What native UI paints over the page shows in its cover: a drawing area
//! over the clip in the overlay, painting the cover's pixels with cairo,
//! whose input shape is where they are not transparent; the page gets the
//! pointer elsewhere. What the cover gets goes on to native UI's area.
const std = @import("std");
const gtk = @import("gtk.zig");
const page_mod = @import("page.zig");
const Window = @import("window.zig").Window;
const webview = @import("../ui/webview.zig");
const PageOptions = @import("../window_types.zig").PageOptions;
const Probe = @import("../page_embed.zig").Probe;
const CoverProbe = @import("../page_embed.zig").CoverProbe;
const Image = @import("../page_embed_cover.zig").Image;

pub const Page = page_mod.Page;
const Obj = *anyopaque;

/// What embedding uses of GTK, besides `gtk.api`.
const Api = struct {
    gtk_overlay_new: *const fn () callconv(.c) Obj,
    gtk_overlay_add_overlay: *const fn (o: Obj, child: Obj) callconv(.c) void,
    gtk_layout_new: *const fn (h: ?Obj, v: ?Obj) callconv(.c) Obj,
    gtk_layout_put: *const fn (l: Obj, child: Obj, x: c_int, y: c_int) callconv(.c) void,
    gtk_layout_move: *const fn (l: Obj, child: Obj, x: c_int, y: c_int) callconv(.c) void,
    gtk_container_remove: *const fn (c: Obj, child: Obj) callconv(.c) void,
    gtk_widget_show: *const fn (w: Obj) callconv(.c) void,
    gtk_widget_queue_resize: *const fn (w: Obj) callconv(.c) void,
    gtk_widget_get_allocation: *const fn (w: Obj, a: *gtk.Rectangle) callconv(.c) void,
    gtk_widget_translate_coordinates: *const fn (src: Obj, dst: Obj, x: c_int, y: c_int, out_x: *c_int, out_y: *c_int) callconv(.c) c_int,
    g_object_ref: *const fn (o: Obj) callconv(.c) Obj,
    gtk_widget_get_parent: *const fn (w: Obj) callconv(.c) ?Obj,
};
var api: Api = undefined;
var loaded = false;

fn load() bool {
    if (loaded) return true;
    const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .GLOBAL = true }) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        const sym = std.c.dlsym(lib, name) orelse return false;
        @field(api, name) = @ptrCast(@alignCast(sym));
    }
    loaded = true;
    return true;
}

/// Where an embedded page goes: its clip, and its place in it, in points.
pub const Embed = struct {
    layout: Obj,
    view: *webview.WebView,
    clip: gtk.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    bounds: gtk.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    shown: bool = false,
    /// What native UI paints over the page, once something did.
    cover: ?*Cover = null,

    /// The page's web view goes into the clip.
    pub fn adopt(e: *Embed, wv: Obj) void {
        api.gtk_layout_put(e.layout, wv, 0, 0);
        gtk.connect(wv, "focus-in-event", @ptrCast(&onFocusIn), e);
    }
};

/// The window's overlay, made around its drawing area at the first web view.
fn overlayOf(window: *Window) ?Obj {
    if (window.web_overlay) |o| return o;
    const win = window.gtkwindow orelse return null;
    const s = window.surface orelse return null;
    const g = &gtk.api;
    const area = s.area;
    // Under a hidden title bar the area is in an overlay already: use it.
    if (api.gtk_widget_get_parent(area)) |parent| if (parent != @as(Obj, @ptrCast(win))) {
        gtk.connect(parent, "get-child-position", @ptrCast(&childPosition), window);
        window.web_overlay = parent;
        return parent;
    };
    _ = api.g_object_ref(area);
    api.gtk_container_remove(win, area);
    const overlay = api.gtk_overlay_new();
    g.gtk_container_add(overlay, area);
    g.g_object_unref(area);
    g.gtk_container_add(win, overlay);
    gtk.connect(overlay, "get-child-position", @ptrCast(&childPosition), window);
    g.gtk_widget_show_all(overlay);
    g.gtk_widget_grab_focus(area);
    window.web_overlay = overlay;
    return overlay;
}

pub fn create(host: *anyopaque, options: PageOptions, view: *webview.WebView) ?*Page {
    const window: *Window = @ptrCast(@alignCast(host));
    if (!load()) return null;
    const overlay = overlayOf(window) orelse return null;
    const gpa = window.app.gpa;
    const e = gpa.create(Embed) catch return null;
    e.* = .{ .layout = api.gtk_layout_new(null, null), .view = view };
    api.gtk_overlay_add_overlay(overlay, e.layout);
    const page = Page.open(window, options, e) catch {
        gtk.api.gtk_widget_destroy(e.layout);
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
    if (!window.closed) gtk.api.gtk_widget_destroy(e.layout);
    if (e.cover) |cv| cv.destroy(page.gpa, !window.closed);
    page.gpa.destroy(e);
    page.embed = null;
}

pub fn destroy(page: *Page) void {
    page.destroy();
}

fn rect(r: @import("../ui/types.zig").Rect) gtk.Rectangle {
    const x0: c_int = @intFromFloat(@round(r.x));
    const y0: c_int = @intFromFloat(@round(r.y));
    return .{ .x = x0, .y = y0, .width = @as(c_int, @intFromFloat(@round(r.x + r.w))) - x0, .height = @as(c_int, @intFromFloat(@round(r.y + r.h))) - y0 };
}

pub fn place(page: *Page, p: webview.Placement) void {
    const e = page.embed orelse return;
    const clip = rect(p.clip);
    var bounds = rect(p.frame);
    bounds.x -= clip.x;
    bounds.y -= clip.y;
    if (e.shown and std.meta.eql(clip, e.clip) and std.meta.eql(bounds, e.bounds)) return;
    e.clip = clip;
    e.bounds = bounds;
    api.gtk_layout_move(e.layout, page.webview, bounds.x, bounds.y);
    gtk.api.gtk_widget_set_size_request(page.webview, bounds.width, bounds.height);
    if (!e.shown) gtk.api.gtk_widget_show_all(e.layout);
    e.shown = true;
    api.gtk_widget_queue_resize(e.layout);
}

pub fn hide(page: *Page) void {
    const e = page.embed orelse return;
    if (!e.shown) return;
    e.shown = false;
    gtk.api.gtk_widget_hide(e.layout);
    if (e.cover) |cv| cv.hide();
    // A hidden page keeps no keyboard: it goes back to native UI.
    if (page.window.surface) |s| gtk.api.gtk_widget_grab_focus(s.area);
}

pub fn focus(page: *Page, _: bool) void {
    gtk.api.gtk_widget_grab_focus(page.webview);
}

fn box(r: gtk.Rectangle) [4]i32 {
    return .{ r.x, r.y, r.width, r.height };
}

/// Where GTK put the clip in the window and the page in it, read back.
pub fn probe(page: *Page) ?Probe {
    const e = page.embed orelse return null;
    var clip: gtk.Rectangle = undefined;
    var in: gtk.Rectangle = undefined;
    api.gtk_widget_get_allocation(e.layout, &clip);
    api.gtk_widget_get_allocation(page.webview, &in);
    // The overlay moves its child's own window: where it is in native UI.
    const area = (page.window.surface orelse return null).area;
    _ = api.gtk_widget_translate_coordinates(e.layout, area, 0, 0, &clip.x, &clip.y);
    return .{ .clip = box(clip), .page = box(in), .shown = gtk.api.gtk_widget_is_visible(e.layout) != 0 };
}

pub fn expected(p: webview.Placement) Probe {
    const clip = rect(p.clip);
    var in = rect(p.frame);
    in.x -= clip.x;
    in.y -= clip.y;
    return .{ .clip = box(clip), .page = box(in), .shown = true };
}

fn childPosition(_: Obj, widget: Obj, out: *gtk.Rectangle, data: ?*anyopaque) callconv(.c) c_int {
    const window: *Window = @ptrCast(@alignCast(data));
    for (window.web_views.items) |p| if (p.embed) |e| {
        if (e.layout == widget) {
            out.* = e.clip;
            return 1;
        }
        if (e.cover) |cv| if (cv.area == widget) {
            out.* = cv.rect;
            return 1;
        };
    };
    return 0;
}

fn onFocusIn(_: Obj, _: Obj, data: ?*anyopaque) callconv(.c) c_int {
    const e: *Embed = @ptrCast(@alignCast(data));
    if (!e.view.focused) {
        e.view.tookFocus();
        if (e.view.page) |p| p.window.redraw();
    }
    return 0;
}

// Covers.

/// What covers use of GTK, GDK and cairo, besides `gtk.api`; loaded with
/// the first.
const CoverApi = struct {
    gtk_overlay_reorder_overlay: *const fn (o: Obj, child: Obj, at: c_int) callconv(.c) void,
    gtk_widget_event: *const fn (w: Obj, e: Obj) callconv(.c) c_int,
    gtk_widget_input_shape_combine_region: *const fn (w: Obj, region: ?Obj) callconv(.c) void,
    gtk_widget_get_parent_window: *const fn (w: Obj) callconv(.c) ?Obj,
    gdk_window_input_shape_combine_region: *const fn (w: Obj, region: ?Obj, x: c_int, y: c_int) callconv(.c) void,
    gdk_event_copy: *const fn (e: Obj) callconv(.c) ?Obj,
    gdk_event_new: *const fn (kind: c_int) callconv(.c) ?Obj,
    gdk_event_free: *const fn (e: Obj) callconv(.c) void,
    cairo_image_surface_create_for_data: *const fn (data: [*]u8, format: c_int, w: c_int, h: c_int, stride: c_int) callconv(.c) ?Obj,
    cairo_surface_set_device_scale: *const fn (s: Obj, x: f64, y: f64) callconv(.c) void,
    cairo_surface_destroy: *const fn (s: Obj) callconv(.c) void,
    cairo_set_source_surface: *const fn (cr: Obj, s: Obj, x: f64, y: f64) callconv(.c) void,
    cairo_paint: *const fn (cr: Obj) callconv(.c) void,
    cairo_region_create: *const fn () callconv(.c) ?Obj,
    cairo_region_union_rectangle: *const fn (r: Obj, rect: *const gtk.Rectangle) callconv(.c) c_int,
    cairo_region_destroy: *const fn (r: Obj) callconv(.c) void,
};
var capi: CoverApi = undefined;
var cover_loaded = false;

fn loadCover() bool {
    if (cover_loaded) return true;
    const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .GLOBAL = true }) orelse return false;
    inline for (@typeInfo(CoverApi).@"struct".field_names) |name| {
        const sym = std.c.dlsym(lib, name) orelse return false;
        @field(capi, name) = @ptrCast(@alignCast(sym));
    }
    cover_loaded = true;
    return true;
}

const button_press = 4; // GDK_BUTTON_PRESS
const button_release = 7;
const cairo_argb32 = 0;

/// A page's cover: a drawing area over its clip in the window's overlay,
/// at `rect` (points), painting `px` (`scale` pixels a point).
pub const Cover = struct {
    area: Obj,
    page: *Page,
    rect: gtk.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    px: std.ArrayList(u32) = .empty,
    pw: usize = 0,
    ph: usize = 0,
    scale: f32 = 1,
    surface: ?Obj = null,
    shown: bool = false,

    fn create(page: *Page) ?*Cover {
        if (!loadCover()) return null;
        const overlay = page.window.web_overlay orelse return null;
        const g = &gtk.api;
        const cv = page.gpa.create(Cover) catch return null;
        cv.* = .{ .area = g.gtk_drawing_area_new(), .page = page };
        g.gtk_widget_add_events(cv.area, gtk.pointer_motion_mask | gtk.button_press_mask | gtk.button_release_mask | gtk.leave_notify_mask | gtk.scroll_mask | gtk.smooth_scroll_mask);
        gtk.connect(cv.area, "draw", @ptrCast(&onCoverDraw), cv);
        gtk.connect(cv.area, "realize", @ptrCast(&onCoverRealize), cv);
        inline for (.{ "button-press-event", "button-release-event", "motion-notify-event", "scroll-event", "leave-notify-event" }) |signal|
            gtk.connect(cv.area, signal, @ptrCast(&onCoverEvent), cv);
        api.gtk_overlay_add_overlay(overlay, cv.area);
        return cv;
    }

    fn destroy(cv: *Cover, gpa: std.mem.Allocator, widget: bool) void {
        if (widget) gtk.api.gtk_widget_destroy(cv.area);
        if (cv.surface) |s| capi.cairo_surface_destroy(s);
        cv.px.deinit(gpa);
        gpa.destroy(cv);
    }

    fn hide(cv: *Cover) void {
        if (!cv.shown) return;
        cv.shown = false;
        gtk.api.gtk_widget_hide(cv.area);
    }

    fn show(cv: *Cover, img: Image) void {
        const gpa = cv.page.gpa;
        cv.px.resize(gpa, img.px.len) catch return;
        @memcpy(cv.px.items, img.px);
        if (cv.surface) |s| capi.cairo_surface_destroy(s);
        cv.surface = null;
        cv.pw = img.w;
        cv.ph = img.h;
        cv.scale = img.scale;
        const bytes: [*]u8 = @ptrCast(cv.px.items.ptr);
        cv.surface = capi.cairo_image_surface_create_for_data(bytes, cairo_argb32, @intCast(img.w), @intCast(img.h), @intCast(img.w * 4));
        if (cv.surface) |s| capi.cairo_surface_set_device_scale(s, img.scale, img.scale);
        // Pixels on whole points (`unit`).
        cv.rect = .{
            .x = @intFromFloat(@round(@as(f32, @floatFromInt(img.x)) / img.scale)),
            .y = @intFromFloat(@round(@as(f32, @floatFromInt(img.y)) / img.scale)),
            .width = @intFromFloat(@round(@as(f32, @floatFromInt(img.w)) / img.scale)),
            .height = @intFromFloat(@round(@as(f32, @floatFromInt(img.h)) / img.scale)),
        };
        gtk.api.gtk_widget_set_size_request(cv.area, cv.rect.width, cv.rect.height);
        if (!cv.shown) api.gtk_widget_show(cv.area);
        cv.shown = true;
        // Over the clips of every web view.
        if (cv.page.window.web_overlay) |o| capi.gtk_overlay_reorder_overlay(o, cv.area, -1);
        cv.shape();
        api.gtk_widget_queue_resize(cv.area);
        gtk.api.gtk_widget_queue_draw(cv.area);
    }

    /// Whether the pixel under point `x`, `y` of the cover shows something.
    fn opaqueAt(cv: *const Cover, x: c_int, y: c_int) bool {
        const px: i64 = @intFromFloat(@floor((@as(f32, @floatFromInt(x)) + 0.5) * cv.scale));
        const py: i64 = @intFromFloat(@floor((@as(f32, @floatFromInt(y)) + 0.5) * cv.scale));
        if (px < 0 or py < 0 or px >= cv.pw or py >= cv.ph) return false;
        return cv.px.items[@as(usize, @intCast(py)) * cv.pw + @as(usize, @intCast(px))] >> 24 != 0;
    }

    /// The pointer is the cover's where it shows something, the page's
    /// elsewhere: its input shape, on its window and the overlay's for it.
    fn shape(cv: *Cover) void {
        const region = capi.cairo_region_create() orelse return;
        defer capi.cairo_region_destroy(region);
        var y: c_int = 0;
        while (y < cv.rect.height) : (y += 1) {
            var x: c_int = 0;
            while (x < cv.rect.width) {
                if (!cv.opaqueAt(x, y)) {
                    x += 1;
                    continue;
                }
                const x0 = x;
                while (x < cv.rect.width and cv.opaqueAt(x, y)) x += 1;
                _ = capi.cairo_region_union_rectangle(region, &.{ .x = x0, .y = y, .width = x - x0, .height = 1 });
            }
        }
        capi.gtk_widget_input_shape_combine_region(cv.area, region);
        if (capi.gtk_widget_get_parent_window(cv.area)) |win| capi.gdk_window_input_shape_combine_region(win, region, 0, 0);
    }
};

fn onCoverRealize(_: Obj, data: ?*anyopaque) callconv(.c) void {
    const cv: *Cover = @ptrCast(@alignCast(data));
    cv.shape();
}

fn onCoverDraw(_: Obj, cr: Obj, data: ?*anyopaque) callconv(.c) c_int {
    const cv: *Cover = @ptrCast(@alignCast(data));
    const s = cv.surface orelse return 0;
    capi.cairo_set_source_surface(cr, s, 0, 0);
    capi.cairo_paint(cr);
    return 1;
}

/// Native UI's area gets what the cover got, at its place there: the
/// event's x and y (as GdkEventButton, GdkEventMotion and GdkEventScroll
/// lay them out) moved by the cover's place.
fn onCoverEvent(_: Obj, e: Obj, data: ?*anyopaque) callconv(.c) c_int {
    const cv: *Cover = @ptrCast(@alignCast(data));
    const s = cv.page.window.surface orelse return 0;
    const copy = capi.gdk_event_copy(e) orelse return 0;
    defer capi.gdk_event_free(copy);
    const kind = @as(*const c_int, @ptrCast(@alignCast(copy))).*;
    if (kind != 11) { // GDK_LEAVE_NOTIFY lays its coordinates out otherwise
        const xy: *[2]f64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(copy)) + 24));
        xy[0] += @floatFromInt(cv.rect.x);
        xy[1] += @floatFromInt(cv.rect.y);
    }
    return capi.gtk_widget_event(s.area, copy);
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

/// Where GTK put the cover in the window, read back, and whether it shows.
pub fn probeCover(page: *Page) ?CoverProbe {
    const e = page.embed orelse return null;
    const cv = e.cover orelse return .{};
    var r: gtk.Rectangle = undefined;
    api.gtk_widget_get_allocation(cv.area, &r);
    const area = (page.window.surface orelse return null).area;
    _ = api.gtk_widget_translate_coordinates(cv.area, area, 0, 0, &r.x, &r.y);
    return .{ .rect = box(r), .shown = gtk.api.gtk_widget_is_visible(cv.area) != 0 };
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

/// A click on the cover, as GTK delivers one where its input shape takes
/// the pointer: a press and a release of the first button.
pub fn clickCover(page: *Page, x: f32, y: f32) bool {
    const e = page.embed orelse return false;
    const cv = e.cover orelse return false;
    if (!cv.shown) return false;
    const win = gtk.api.gtk_widget_get_window(cv.area) orelse return false;
    const lx = x - @as(f32, @floatFromInt(cv.rect.x));
    const ly = y - @as(f32, @floatFromInt(cv.rect.y));
    if (!cv.opaqueAt(@intFromFloat(@floor(lx)), @intFromFloat(@floor(ly)))) return false;
    inline for (.{ button_press, button_release }) |kind| {
        const ev = capi.gdk_event_new(kind) orelse return false;
        defer capi.gdk_event_free(ev);
        const b: [*]u8 = @ptrCast(ev);
        // GdkEventButton: its window (a reference, freed with it), x, y, button.
        @as(*?Obj, @ptrCast(@alignCast(b + 8))).* = api.g_object_ref(win);
        @as(*[2]f64, @ptrCast(@alignCast(b + 24))).* = .{ lx, ly };
        @as(*c_uint, @ptrCast(@alignCast(b + 52))).* = 1;
        _ = capi.gtk_widget_event(cv.area, ev);
    }
    return true;
}
