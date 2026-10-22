//! What a window does on Linux beyond showing its content: asking before
//! it closes, telling the app of focus, moves, resizes and state changes,
//! a frame without decorations (a GTK header bar's title buttons for a
//! hidden title bar, none for a frameless window), moving it from native
//! UI's empty title bar, and flyouts placed and dismissed.
const std = @import("std");
const gtk = @import("gtk.zig");
const more = @import("gtk_more.zig");
const titlebar = @import("../titlebar.zig");
const fly = @import("../flyout.zig");
const window_types = @import("../window_types.zig");
const Window = @import("window.zig").Window;

/// The desktop's header bars are about this tall.
pub const default_height = 28;

pub fn emit(self: *Window, e: ?window_types.Event) void {
    const ev = e orelse return;
    if (self.on_event) |cb| cb.func(cb.ctx, self, ev);
}

pub fn mayClose(self: *Window) bool {
    const cb = self.on_close_request orelse return true;
    return cb.func(cb.ctx, self);
}

/// Connects the window's signals and sets up its frame, as it is made.
pub fn setUp(self: *Window, win: *gtk.Widget, options: anytype) void {
    gtk.connect(win, "focus-in-event", @ptrCast(&onFocusIn), self);
    gtk.connect(win, "focus-out-event", @ptrCast(&onFocusOut), self);
    gtk.connect(win, "configure-event", @ptrCast(&onConfigure), self);
    gtk.connect(win, "window-state-event", @ptrCast(&onState), self);
    if (!more.load()) return;
    const m = &more.api;
    if (options.flyout) |f| {
        m.gtk_window_set_decorated(win, 0);
        m.gtk_window_set_type_hint(win, if (f.focusable) more.hint_dialog else more.hint_popup_menu);
        if (!f.focusable) m.gtk_window_set_accept_focus(win, 0);
        if (f.parent) |p| if (@as(*Window, @ptrCast(@alignCast(p))).gtkwindow) |pw| m.gtk_window_set_transient_for(win, pw);
        if (f.tray != null or f.parent == null) gtk.api.gtk_window_set_keep_above(win, 1);
    } else switch (options.title_bar) {
        .default => {},
        .frameless => m.gtk_window_set_decorated(win, 0),
        // The desktop's own title buttons, in a header bar of the window's.
        .hidden => {
            if (options.hide_window_buttons) {
                if (!@import("titlebar_overlay.zig").hideButtons(win)) m.gtk_window_set_decorated(win, 0);
            } else {
                const bar = m.gtk_header_bar_new();
                m.gtk_header_bar_set_show_close_button(bar, 1);
                m.gtk_window_set_titlebar(win, bar);
                m.gtk_widget_show(bar);
            }
        },
    }
    if (options.skip_taskbar or options.flyout != null) {
        m.gtk_window_set_skip_taskbar_hint(win, 1);
        m.gtk_window_set_skip_pager_hint(win, 1);
    }
}

/// Native UI's press at `x`, `y`: in the empty space of a hidden or
/// frameless window's title bar, it moves the window (twice, maximizes
/// it). True when it did, and the view does not get it.
pub fn press(self: *Window, e: *gtk.Event, x: f32, y: f32, count: c_uint) bool {
    const s = self.surface orelse return false;
    if (self.flyout != null) return false;
    const h = titlebar.strip(self.title_bar, self.title_bar_height, s.ctx.title_bar_height, default_height);
    if (!titlebar.draggable(&s.ctx, x, y, h)) return false;
    if (count >= 2) {
        self.zoom();
        return true;
    }
    return beginDrag(self, e);
}

fn beginDrag(self: *Window, e: *gtk.Event) bool {
    const win = self.gtkwindow orelse return false;
    if (!more.load()) return false;
    var rx: f64 = 0;
    var ry: f64 = 0;
    _ = more.api.gdk_event_get_root_coords(e, &rx, &ry);
    var button: c_uint = 1;
    _ = gtk.api.gdk_event_get_button(e, &button);
    more.api.gtk_window_begin_move_drag(win, @intCast(button), @intFromFloat(rx), @intFromFloat(ry), more.api.gdk_event_get_time(e));
    return true;
}

/// Moves the window with the pointer, from the press being handled.
pub fn startDrag(self: *Window) void {
    if (!more.load()) return;
    const e = more.api.gtk_get_current_event() orelse return;
    defer more.api.gdk_event_free(e);
    _ = beginDrag(self, e);
}

/// Places a flyout next to its anchor, in the work area of its monitor.
pub fn placeFlyout(self: *Window) void {
    const f = self.flyout orelse return;
    const win = self.gtkwindow orelse return;
    var anchor = f.anchor;
    // GTK's tray icons tell nobody where they are.
    const centered = f.tray != null;
    if (f.parent) |p| {
        const pw: *Window = @ptrCast(@alignCast(p));
        const gw = if (pw.gtkwindow) |g| gtk.api.gtk_widget_get_window(g) else null;
        if (gw) |g| if (more.load()) {
            var ox: c_int = 0;
            var oy: c_int = 0;
            _ = more.api.gdk_window_get_origin(g, &ox, &oy);
            anchor.x += @floatFromInt(ox);
            anchor.y += @floatFromInt(oy);
        };
    }
    const wa = more.workArea(@intFromFloat(anchor.x), @intFromFloat(anchor.y)) orelse return;
    const work: fly.Rect = .{ .x = @floatFromInt(wa.x), .y = @floatFromInt(wa.y), .width = @floatFromInt(wa.width), .height = @floatFromInt(wa.height) };
    const r = if (centered) fly.centered(self.width, self.height, work) else fly.place(anchor, self.width, self.height, f.placement, f.gap, work);
    gtk.api.gtk_window_resize(win, @intFromFloat(r.width), @intFromFloat(r.height));
    gtk.api.gtk_window_move(win, @intFromFloat(r.x), @intFromFloat(r.y));
}

fn of(data: ?*anyopaque) *Window {
    return @ptrCast(@alignCast(data));
}

fn onFocusIn(_: *gtk.Widget, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    const self = of(data);
    emit(self, self.tracker.focus(true));
    return 0;
}

fn onFocusOut(_: *gtk.Widget, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    const self = of(data);
    emit(self, self.tracker.focus(false));
    // A focusable flyout is dismissed as another window takes the keyboard.
    if (self.flyout) |f| if (f.focusable and self.isVisible()) {
        _ = gtk.api.g_idle_add(dismiss, self);
    };
    return 0;
}

fn dismiss(data: ?*anyopaque) callconv(.c) c_int {
    const self = of(data);
    // It may have closed meanwhile.
    for (self.app.windows.items) |live| if (live == self) {
        if (!self.isFocused()) self.requestClose();
        break;
    };
    return 0;
}

fn onConfigure(_: *gtk.Widget, e: *more.Configure, data: ?*anyopaque) callconv(.c) c_int {
    const self = of(data);
    emit(self, self.tracker.moved(.{ .x = @floatFromInt(e.x), .y = @floatFromInt(e.y) }));
    const st = self.tracker.shown;
    emit(self, self.tracker.sized(st == .minimized, st == .maximized, .{ .width = @floatFromInt(e.width), .height = @floatFromInt(e.height) }));
    // Its flyouts follow it.
    for (self.app.windows.items) |x| if (x.flyout) |f| if (f.parent == @as(*anyopaque, @ptrCast(self))) placeFlyout(x);
    return 0;
}

fn onState(_: *gtk.Widget, e: *more.WindowState, data: ?*anyopaque) callconv(.c) c_int {
    const self = of(data);
    const s = e.new_window_state;
    self.full_screen = s & more.state_fullscreen != 0;
    const size = self.tracker.size;
    emit(self, self.tracker.sized(s & more.state_iconified != 0, s & more.state_maximized != 0, size));
    return 0;
}

/// The delete-event's answer: 1 keeps the window.
pub fn onDelete(self: *Window) c_int {
    if (!mayClose(self)) return 1;
    if (self.flyout) |f| if (f.dismiss == .hide) {
        self.hide();
        return 1;
    };
    return 0;
}
