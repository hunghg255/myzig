//! What a window does on macOS beyond showing its content: asking before
//! it closes (windowShouldClose:), telling the app of focus, moves,
//! resizes and state changes (its delegate's notifications), a frameless
//! window (a full-size content view without traffic lights, which keeps
//! its rounded corners and shadow), moving it from the content, and
//! flyouts (NSPanels placed next to a rectangle, a point or a tray icon,
//! or the system's popovers: `popover_mac.zig`).
const std = @import("std");
const objc = @import("objc.zig");
const fly = @import("flyout.zig");
const titlebar = @import("titlebar.zig");
const window_types = @import("window_types.zig");
const Window = @import("window.zig").Window;
const Tray = @import("tray.zig").Tray;
const popover_mac = @import("popover_mac.zig");

/// AppKit's title bar is 28 points tall.
pub const default_height = 28;

/// The delegate's methods for all of this, for `objc.defineClass`.
pub const methods = [_]objc.Method{
    .{ .name = "windowShouldClose:", .imp = &shouldClose, .types = "c@:@" },
    .{ .name = "windowDidBecomeKey:", .imp = &didBecomeKey, .types = "v@:@" },
    .{ .name = "windowDidResignKey:", .imp = &didResignKey, .types = "v@:@" },
    .{ .name = "windowDidMove:", .imp = &didMove, .types = "v@:@" },
    .{ .name = "windowDidResize:", .imp = &didResize, .types = "v@:@" },
    .{ .name = "windowDidMiniaturize:", .imp = &didResize, .types = "v@:@" },
    .{ .name = "windowDidDeminiaturize:", .imp = &didResize, .types = "v@:@" },
};

pub fn emit(self: *Window, e: ?window_types.Event) void {
    const ev = e orelse return;
    if (self.on_event) |cb| cb.func(cb.ctx, self, ev);
}

pub fn mayClose(self: *Window) bool {
    const cb = self.on_close_request orelse return true;
    return cb.func(cb.ctx, self);
}

/// The style mask of a window's options.
pub fn styleMask(options: anytype) objc.NSUInteger {
    if (options.flyout) |f| return if (f.focusable) 0 else 1 << 7; // borderless, non-activating panel
    var style: objc.NSUInteger = 1 | 2 | 4; // titled, closable, miniaturizable
    if (options.resizable) style |= 8;
    if (options.title_bar != .default) style |= 1 << 15; // full size content view
    return style;
}

/// A panel for flyouts: borderless, yet it may take the keyboard.
pub fn flyoutClass() objc.Class {
    return objc.defineClass(.{
        .name = "MyZigFlyoutPanel",
        .superclass = "NSPanel",
        .methods = &.{.{ .name = "canBecomeKeyWindow", .imp = &yes, .types = "c@:" }},
    });
}

fn yes(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

/// Sets up the title bar of a hidden or frameless window, and a flyout's panel.
pub fn setUp(nswindow: objc.Object, options: anytype) void {
    if (options.flyout) |f| {
        objc.msg(void, nswindow, "setHidesOnDeactivate:", .{objc.NO});
        objc.msg(void, nswindow, "setHasShadow:", .{objc.YES});
        // Over other apps' windows (NSPopUpMenuWindowLevel), or its parent's.
        objc.msg(void, nswindow, "setLevel:", .{@as(objc.NSInteger, if (f.tray != null or f.parent == null) 101 else 3)});
        return;
    }
    if (options.title_bar == .default) return;
    objc.msg(void, nswindow, "setTitlebarAppearsTransparent:", .{objc.YES});
    objc.msg(void, nswindow, "setTitleVisibility:", .{@as(objc.NSInteger, 1)});
    if (options.title_bar == .frameless) for (0..3) |i| {
        // The close, miniaturize and zoom buttons go: the content draws all.
        const b = objc.msg(?objc.Object, nswindow, "standardWindowButton:", .{@as(objc.NSUInteger, i)}) orelse continue;
        objc.msg(void, b, "setHidden:", .{objc.YES});
    };
}

/// The room the traffic lights take over a hidden title bar's content.
pub fn titleBar(self: *Window) window_types.TitleBarArea {
    if (self.title_bar != .hidden or self.isFullScreen()) return .{};
    const f = objc.msg(objc.CGRect, self.nswindow, "frame", .{});
    const layout = objc.msg(objc.CGRect, self.nswindow, "contentLayoutRect", .{});
    const zoom = objc.msg(?objc.Object, self.nswindow, "standardWindowButton:", .{@as(objc.NSUInteger, 2)});
    const left: f64 = if (zoom) |z| blk: {
        const r = objc.msg(objc.CGRect, z, "frame", .{});
        break :blk r.origin.x + r.size.width + 8;
    } else 78;
    return .{ .height = f.size.height - layout.size.height, .left = left };
}

/// How far down native UI's empty space moves the window.
pub fn dragHeight(self: *Window, view: f32) f32 {
    return titlebar.strip(self.title_bar, self.title_bar_height, view, default_height);
}

/// Moves the window with the pointer, from the press being handled.
pub fn startDrag(self: *Window) void {
    const ev = objc.msg(?objc.Object, self.app.nsapp, "currentEvent", .{}) orelse return;
    objc.msg(void, self.nswindow, "performWindowDragWithEvent:", .{ev});
}

fn primaryHeight() f64 {
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    if (objc.msg(objc.NSUInteger, screens, "count", .{}) == 0) return 0;
    const primary = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    return objc.msg(objc.CGRect, primary, "frame", .{}).size.height;
}

/// A rectangle of AppKit's screen coordinates (bottom left origin) with
/// a top left origin.
fn topLeft(r: objc.CGRect, ph: f64) fly.Rect {
    return .{ .x = r.origin.x, .y = ph - r.origin.y - r.size.height, .width = r.size.width, .height = r.size.height };
}

/// The visible frame of the screen with the point (top left origin).
fn workArea(x: f64, y: f64, ph: f64) fly.Rect {
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const n = objc.msg(objc.NSUInteger, screens, "count", .{});
    var best: ?objc.Object = null;
    for (0..n) |i| {
        const s = objc.msg(objc.Object, screens, "objectAtIndex:", .{i});
        if (topLeft(objc.msg(objc.CGRect, s, "frame", .{}), ph).contains(x, y)) best = s;
    }
    const s = best orelse objc.msg(?objc.Object, objc.class("NSScreen"), "mainScreen", .{}) orelse return .{ .width = 1440, .height = 900 };
    return topLeft(objc.msg(objc.CGRect, s, "visibleFrame", .{}), ph);
}

/// Places a flyout next to its anchor: a rectangle of its parent's
/// content, its tray icon's button, or the screen.
pub fn placeFlyout(self: *Window) void {
    const f = self.flyout orelse return;
    if (self.popover) |p| {
        const a = popoverAnchor(self) orelse return;
        return p.place(if (f.tray == null) a.rect else null, flyoutSize(self));
    }
    const pool = objc.Pool.push();
    defer pool.pop();
    const ph = primaryHeight();
    var anchor = f.anchor;
    if (f.tray) |p| {
        const t: *Tray = @ptrCast(@alignCast(p));
        const button = objc.msg(objc.Object, t.item, "button", .{});
        if (objc.msg(?objc.Object, button, "window", .{})) |bw| anchor = topLeft(objc.msg(objc.CGRect, bw, "frame", .{}), ph);
    } else if (f.parent) |p| {
        const pw: *Window = @ptrCast(@alignCast(p));
        const content = objc.msg(objc.Object, pw.nswindow, "contentView", .{});
        const in_window = objc.msg(objc.CGRect, content, "convertRect:toView:", .{ objc.msg(objc.CGRect, content, "bounds", .{}), @as(?objc.Object, null) });
        const c = topLeft(objc.msg(objc.CGRect, pw.nswindow, "convertRectToScreen:", .{in_window}), ph);
        anchor.x += c.x;
        anchor.y += c.y;
    }
    const work = workArea(anchor.x, anchor.y, ph);
    const r = fly.place(anchor, self.flyout_size[0], self.flyout_size[1], f.placement, f.gap, work);
    const frame: objc.CGRect = .{ .origin = .{ .x = r.x, .y = ph - r.y - r.height }, .size = .{ .width = r.width, .height = r.height } };
    objc.msg(void, self.nswindow, "setFrame:display:", .{ frame, objc.YES });
}

/// The app's Dock tile: a badge, and attention.
pub fn setBadge(nsapp: objc.Object, text: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const tile = objc.msg(objc.Object, nsapp, "dockTile", .{});
    const label: ?objc.Object = if (text.len > 0) objc.nsString(text) else null;
    objc.msg(void, tile, "setBadgeLabel:", .{label});
}

var attention: objc.NSInteger = 0;

/// Bounces the Dock icon while the app is not active, or stops.
pub fn requestAttention(nsapp: objc.Object, on: bool) void {
    if (on) {
        attention = objc.msg(objc.NSInteger, nsapp, "requestUserAttention:", .{@as(objc.NSUInteger, 10)}); // NSInformationalRequest
    } else if (attention != 0) {
        objc.msg(void, nsapp, "cancelUserAttentionRequest:", .{attention});
        attention = 0;
    }
}

fn of(obj: objc.Object) ?*Window {
    return objc.getZig(Window, obj);
}

fn shouldClose(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.BOOL {
    const w = of(obj) orelse return objc.YES;
    if (!mayClose(w)) return objc.NO;
    if (w.flyout) |f| if (f.dismiss == .hide) {
        w.hide();
        return objc.NO;
    };
    return objc.YES;
}

fn didBecomeKey(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = of(obj) orelse return;
    emit(w, w.tracker.focus(true));
}

fn didResignKey(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = of(obj) orelse return;
    emit(w, w.tracker.focus(false));
    // A focusable flyout is dismissed as another window takes the
    // keyboard; a press on its tray icon is left to the icon's click,
    // which toggles it, rather than closing it for the click to open it
    // again.
    if (w.flyout) |f| if (f.focusable and w.isVisible()) {
        if (f.tray) |p| if (@as(*Tray, @ptrCast(@alignCast(p))).pressed()) return;
        w.requestClose();
    };
}

fn didMove(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = of(obj) orelse return;
    const f = w.frame();
    emit(w, w.tracker.moved(.{ .x = f.x, .y = f.y }));
    for (w.app.windows.items) |x| if (x.flyout) |fl| if (fl.parent == @as(*anyopaque, @ptrCast(w))) placeFlyout(x);
}

fn didResize(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = of(obj) orelse return;
    const c = w.contentSize();
    const mini = objc.msg(objc.BOOL, w.nswindow, "isMiniaturized", .{});
    emit(w, w.tracker.sized(mini, !mini and w.isMaximized(), .{ .width = c[0], .height = c[1] }));
}

/// Cuts a flyout's content view (its material, when it has one, which
/// holds the content) to corners of `radius` points; the panel is clear,
/// so its shadow, made from what it draws, follows them.
pub fn roundFlyout(nswindow: objc.Object, radius: f64) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    objc.msg(void, nswindow, "setOpaque:", .{objc.NO});
    objc.msg(void, nswindow, "setBackgroundColor:", .{objc.msg(objc.Object, objc.class("NSColor"), "clearColor", .{})});
    const view = objc.msg(objc.Object, nswindow, "contentView", .{});
    objc.msg(void, view, "setWantsLayer:", .{objc.YES});
    const layer = objc.msg(objc.Object, view, "layer", .{});
    objc.msg(void, layer, "setCornerRadius:", .{radius});
    if (objc.msg(objc.BOOL, layer, "respondsToSelector:", .{objc.sel("setCornerCurve:")}))
        objc.msg(void, layer, "setCornerCurve:", .{objc.nsString("continuous")});
    objc.msg(void, layer, "setMasksToBounds:", .{objc.YES});
    objc.msg(void, nswindow, "invalidateShadow", .{});
}

/// Whether a flyout with these options shows as a popover: one asked
/// for, with a view to show from.
pub fn wantsPopover(f: fly.State) bool {
    return f.popover and (f.parent != null or f.tray != null);
}

fn flyoutSize(self: *Window) objc.CGSize {
    return .{ .width = self.flyout_size[0], .height = self.flyout_size[1] };
}

/// Moves the content the flyout's panel holds (its native UI's view, or
/// the page's) into a popover. The panel stays, hidden: the window's
/// handle while the popover does not show, its window while it does.
pub fn makePopover(self: *Window) !void {
    const f = self.flyout orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const content = objc.retain(objc.msg(objc.Object, self.nswindow, "contentView", .{}));
    defer objc.release(content);
    const empty = objc.msg(objc.Object, objc.alloc("NSView"), "init", .{});
    defer objc.release(empty);
    objc.msg(void, self.nswindow, "setContentView:", .{empty});
    self.host = self.nswindow;
    self.popover = try popover_mac.Popover.create(content, flyoutSize(self), f.focusable, .{ .ctx = self, .should_close = popoverShouldClose, .closed = popoverClosed });
}

const Anchor = struct { view: objc.Object, rect: objc.CGRect, side: fly.Placement.Side };

/// The view the popover shows from, the anchor in it and its side: the
/// tray icon's button, or the parent's content view.
fn popoverAnchor(self: *Window) ?Anchor {
    const f = self.flyout orelse return null;
    const side = f.placement.side();
    if (f.tray) |p| {
        const t: *Tray = @ptrCast(@alignCast(p));
        const b = objc.msg(?objc.Object, t.item, "button", .{}) orelse return null;
        return .{ .view = b, .rect = objc.msg(objc.CGRect, b, "bounds", .{}), .side = side };
    }
    const pw: *Window = @ptrCast(@alignCast(f.parent orelse return null));
    if (pw.closed) return null;
    const view = objc.msg(?objc.Object, pw.nswindow, "contentView", .{}) orelse return null;
    if (!objc.msg(objc.BOOL, view, "isFlipped", .{})) {
        const h = objc.msg(objc.CGRect, view, "bounds", .{}).size.height;
        return .{ .view = view, .rect = popover_mac.anchorIn(h, f.anchor), .side = side };
    }
    // Native UI's view counts y down: its top is AppKit's MinY edge.
    const r: objc.CGRect = .{ .origin = .{ .x = f.anchor.x, .y = f.anchor.y }, .size = .{ .width = @max(f.anchor.width, 1), .height = @max(f.anchor.height, 1) } };
    const flipped: fly.Placement.Side = switch (side) {
        .top => .bottom,
        .bottom => .top,
        else => side,
    };
    return .{ .view = view, .rect = r, .side = flipped };
}

/// Shows the popover from its anchor; its window becomes the window's.
pub fn showPopover(self: *Window) void {
    const p = self.popover orelse return;
    if (p.isShown()) return;
    const a = popoverAnchor(self) orelse return;
    const f = self.flyout.?;
    if (f.tray != null) {
        // A menu bar app's popover takes the keyboard of an app the user
        // did not activate, as AppKit's own status items' do.
        objc.msg(void, self.app.nsapp, "activateIgnoringOtherApps:", .{objc.YES});
    }
    p.show(a.view, a.rect, a.side, flyoutSize(self));
    highlightTray(self, true);
    const win = p.window() orelse return;
    self.nswindow = win;
    if (self.surface) |s| {
        _ = objc.msg(objc.BOOL, win, "makeFirstResponder:", .{s.nsview});
        s.occlusionChanged();
        s.requestFrame();
    }
}

/// Closes the popover, to show again; the panel is the window's again.
pub fn hidePopover(self: *Window) void {
    const p = self.popover orelse return;
    p.hide();
    popoverGone(self);
}

fn popoverGone(self: *Window) void {
    highlightTray(self, false);
    if (self.host) |h| self.nswindow = h;
}

/// Highlights the tray icon the popover shows from while it shows, as
/// AppKit's status items are while their menus show.
fn highlightTray(self: *Window, on: bool) void {
    const f = self.flyout orelse return;
    const t: *Tray = @ptrCast(@alignCast(f.tray orelse return));
    const b = objc.msg(?objc.Object, t.item, "button", .{}) orelse return;
    objc.msg(void, b, "highlight:", .{@as(objc.BOOL, on)});
}

/// The popover goes with the window, before its content.
pub fn destroyPopover(self: *Window) void {
    const p = self.popover orelse return;
    popoverGone(self);
    p.destroy();
    self.popover = null;
}

fn popoverShouldClose(ctx: *anyopaque) bool {
    return mayClose(@ptrCast(@alignCast(ctx)));
}

/// The user closed the popover (a click elsewhere): it stays hidden, or
/// the window closes, once AppKit is done with its notification.
fn popoverClosed(ctx: *anyopaque) void {
    const w: *Window = @ptrCast(@alignCast(ctx));
    popoverGone(w);
    const f = w.flyout orelse return;
    if (f.dismiss != .close) return;
    const job = std.heap.c_allocator.create(CloseJob) catch return w.close();
    job.* = .{ .app = w.app, .window = w };
    objc.dispatchMain(job, CloseJob.run);
}

const CloseJob = struct {
    app: *@import("app.zig").App,
    window: *Window,

    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const job: *CloseJob = @ptrCast(@alignCast(ctx));
        defer std.heap.c_allocator.destroy(job);
        // The window may have closed meanwhile.
        for (job.app.windows.items) |live| if (live == job.window) return live.close();
    }
};
