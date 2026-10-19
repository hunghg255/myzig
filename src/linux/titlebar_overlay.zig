//! A hidden title bar over native UI on Linux: the window keeps GTK's
//! client-side frame without a title bar (an empty one, never shown), and
//! its content goes into a GtkOverlay with a header bar of the desktop's
//! title buttons over its top right corner, transparent, as wide as the
//! buttons. `Window.titleBar` reports its height and width, which the
//! content keeps clear of; the rest of the top strip moves the window
//! (`titlebar.zig`), as on macOS and Windows.
const std = @import("std");
const gtk = @import("gtk.zig");

const Requisition = extern struct { width: c_int = 0, height: c_int = 0 };

const Api = struct {
    gtk_overlay_new: *const fn () callconv(.c) *gtk.Widget,
    gtk_overlay_add_overlay: *const fn (o: *gtk.Widget, w: *gtk.Widget) callconv(.c) void,
    gtk_container_remove: *const fn (c: *gtk.Widget, w: *gtk.Widget) callconv(.c) void,
    gtk_widget_get_parent: *const fn (w: *gtk.Widget) callconv(.c) ?*gtk.Widget,
    gtk_widget_set_halign: *const fn (w: *gtk.Widget, a: c_int) callconv(.c) void,
    gtk_widget_set_valign: *const fn (w: *gtk.Widget, a: c_int) callconv(.c) void,
    gtk_widget_show: *const fn (w: *gtk.Widget) callconv(.c) void,
    gtk_widget_get_preferred_size: *const fn (w: *gtk.Widget, min: ?*Requisition, nat: ?*Requisition) callconv(.c) void,
    gtk_widget_get_style_context: *const fn (w: *gtk.Widget) callconv(.c) *anyopaque,
    gtk_style_context_add_provider: *const fn (ctx: *anyopaque, p: *anyopaque, priority: c_uint) callconv(.c) void,
    gtk_css_provider_new: *const fn () callconv(.c) *anyopaque,
    gtk_css_provider_load_from_data: *const fn (p: *anyopaque, data: [*]const u8, len: isize, err: ?*anyopaque) callconv(.c) c_int,
    gtk_box_new: *const fn (orientation: c_int, spacing: c_int) callconv(.c) *gtk.Widget,
    gtk_header_bar_new: *const fn () callconv(.c) *gtk.Widget,
    gtk_header_bar_set_show_close_button: *const fn (bar: *gtk.Widget, on: c_int) callconv(.c) void,
    gtk_window_set_titlebar: *const fn (w: *gtk.Widget, bar: ?*gtk.Widget) callconv(.c) void,
    g_object_ref: *const fn (o: *anyopaque) callconv(.c) *anyopaque,
};

var api: Api = undefined;
var state: enum { untried, ok, missing } = .untried;
var css: ?*anyopaque = null;

fn load() bool {
    if (state != .untried) return state == .ok;
    state = .missing;
    if (!gtk.load()) return false;
    const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .GLOBAL = true }) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        @field(api, name) = @ptrCast(@alignCast(std.c.dlsym(lib, name) orelse return false));
    }
    state = .ok;
    return true;
}

/// The header bar's look: no background, border or shadow of its own,
/// the buttons only.
const style = "headerbar { background: none; border: none; box-shadow: none; min-height: 0; padding: 4px 6px; }";

const GTK_ALIGN_END = 2;
const GTK_ALIGN_START = 1;
const GTK_STYLE_PROVIDER_PRIORITY_APPLICATION = 600;

pub const Installed = struct { bar: *gtk.Widget, overlay: *gtk.Widget };

/// Puts `content` (the window's child) under a header bar of title
/// buttons over its top right corner, in an overlay (which pages
/// embedded in native UI later share); null where GTK lacks what it
/// takes (the window keeps its header bar then).
pub fn install(win: *gtk.Widget, content: *gtk.Widget) ?Installed {
    if (!load()) return null;
    // A title bar never shown: the frame stays client-side, without one.
    const empty = api.gtk_box_new(0, 0);
    api.gtk_window_set_titlebar(win, empty);
    const overlay = api.gtk_overlay_new();
    if (api.gtk_widget_get_parent(content) != null) {
        _ = api.g_object_ref(content);
        api.gtk_container_remove(win, content);
        gtk.api.gtk_container_add(overlay, content);
        gtk.api.g_object_unref(content);
    } else gtk.api.gtk_container_add(overlay, content);
    const bar = api.gtk_header_bar_new();
    api.gtk_header_bar_set_show_close_button(bar, 1);
    api.gtk_widget_set_halign(bar, GTK_ALIGN_END);
    api.gtk_widget_set_valign(bar, GTK_ALIGN_START);
    if (css == null) {
        const p = api.gtk_css_provider_new();
        _ = api.gtk_css_provider_load_from_data(p, style, style.len, null);
        css = p;
    }
    api.gtk_style_context_add_provider(api.gtk_widget_get_style_context(bar), css.?, GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    api.gtk_overlay_add_overlay(overlay, bar);
    api.gtk_widget_show(bar);
    api.gtk_widget_show(content);
    api.gtk_widget_show(overlay);
    gtk.api.gtk_container_add(win, overlay);
    return .{ .bar = bar, .overlay = overlay };
}

/// The room the header bar takes: its height, and its width from the right.
pub fn area(bar: *gtk.Widget) struct { height: f64, right: f64 } {
    var nat: Requisition = .{};
    api.gtk_widget_get_preferred_size(bar, null, &nat);
    return .{ .height = @floatFromInt(nat.height), .right = @floatFromInt(nat.width) };
}
