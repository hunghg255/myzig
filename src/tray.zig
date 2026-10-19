//! Tray icons: items in the menu bar's status area, with a menu, a title,
//! an SF Symbol or a PNG image as their icon.
const std = @import("std");
const objc = @import("objc.zig");
const menu_mod = @import("menu.zig");
const tray_types = @import("tray_types.zig");

pub const Options = tray_types.Options(menu_mod.MenuItem, Tray);
pub const Click = tray_types.Click(Tray);

pub const Tray = struct {
    gpa: std.mem.Allocator,
    item: objc.Object,
    menu: ?*menu_mod.Menu = null,
    on_click: ?Click = null,
    on_appearance: ?Click = null,
    /// A PNG icon is a template image, tinted to match the menu bar.
    template: bool = false,
    /// The menu bar's appearance, as last told.
    was_dark: bool = false,
    /// The button's target, calling `on_click`, and the observer of its
    /// appearance.
    target: objc.Object,

    pub fn create(gpa: std.mem.Allocator, app_name: []const u8, opts: Options) !*Tray {
        const pool = objc.Pool.push();
        defer pool.pop();
        const self = try gpa.create(Tray);
        errdefer gpa.destroy(self);
        const bar = objc.msg(objc.Object, objc.class("NSStatusBar"), "systemStatusBar", .{});
        // NSVariableStatusItemLength is -1.
        const item = objc.retain(objc.msg(objc.Object, bar, "statusItemWithLength:", .{@as(f64, -1)}));
        // macOS keeps where the user dragged the item with ⌘ under its
        // autosave name, and puts it back there as it is made again.
        if (opts.id.len > 0) objc.msg(void, item, "setAutosaveName:", .{objc.nsString(opts.id)});
        const cls = objc.defineClass(.{
            .name = "MyZigTrayTarget",
            .methods = &.{
                .{ .name = "clicked:", .imp = &clicked, .types = "v@:@" },
                .{ .name = "observeValueForKeyPath:ofObject:change:context:", .imp = &observed, .types = "v@:@@@^v" },
            },
        });
        const target = objc.msg(objc.Object, cls, "new", .{});
        objc.setZig(target, self);
        self.* = .{ .gpa = gpa, .item = item, .on_click = opts.on_click, .on_appearance = opts.on_appearance, .template = opts.template, .target = target };
        self.setTitle(opts.title);
        if (opts.symbol.len > 0) self.setSymbol(opts.symbol);
        if (opts.icon.len > 0) self.setIcon(opts.icon) catch {};
        if (opts.tooltip.len > 0) self.setTooltip(opts.tooltip);
        if (opts.menu.len > 0) try self.setMenu(app_name, opts.menu);
        const button = objc.msg(objc.Object, item, "button", .{});
        if (opts.on_click != null) {
            objc.msg(void, button, "setTarget:", .{target});
            objc.msg(void, button, "setAction:", .{objc.sel("clicked:")});
        }
        // The menu bar under the button turns dark or light with the
        // system's appearance, or the wallpaper under a translucent bar.
        self.was_dark = self.dark();
        objc.msg(void, button, "addObserver:forKeyPath:options:context:", .{ target, objc.nsString("effectiveAppearance"), @as(objc.NSUInteger, 0), @as(?*anyopaque, null) });
        return self;
    }

    pub fn destroy(self: *Tray) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const button = objc.msg(objc.Object, self.item, "button", .{});
        objc.msg(void, button, "removeObserver:forKeyPath:", .{ self.target, objc.nsString("effectiveAppearance") });
        const bar = objc.msg(objc.Object, objc.class("NSStatusBar"), "systemStatusBar", .{});
        objc.msg(void, bar, "removeStatusItem:", .{self.item});
        objc.release(self.item);
        objc.setZig(self.target, null);
        objc.release(self.target);
        if (self.menu) |m| m.destroy();
        self.gpa.destroy(self);
    }

    fn clicked(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
        const t = objc.getZig(Tray, self_obj) orelse return;
        if (t.on_click) |c| c.func(c.ctx, t);
    }

    fn observed(self_obj: objc.Object, _: objc.SEL, _: ?objc.Object, _: ?objc.Object, _: ?objc.Object, _: ?*anyopaque) callconv(.c) void {
        const t = objc.getZig(Tray, self_obj) orelse return;
        const now = t.dark();
        if (now == t.was_dark) return;
        t.was_dark = now;
        if (t.on_appearance) |c| c.func(c.ctx, t);
    }

    /// Whether the menu bar under the icon is dark, as AppKit draws its
    /// own status items: by the button's appearance, which follows the
    /// bar's (the system's appearance, or the wallpaper under a
    /// translucent bar). With several displays, the bar of the display
    /// with the menu bar.
    pub fn dark(self: *Tray) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const button = objc.msg(objc.Object, self.item, "button", .{});
        const list = [_]objc.Object{ objc.nsString("NSAppearanceNameAqua"), objc.nsString("NSAppearanceNameDarkAqua") };
        const names = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObjects:count:", .{ &list, @as(objc.NSUInteger, 2) });
        const appearance = objc.msg(objc.Object, button, "effectiveAppearance", .{});
        const match = objc.msg(?objc.Object, appearance, "bestMatchFromAppearancesWithNames:", .{names});
        return std.mem.eql(u8, objc.fromNSString(match), "NSAppearanceNameDarkAqua");
    }

    /// Whether the user is pressing the icon's button: the event being
    /// handled is a press on it, or a mouse button is down with the
    /// pointer over it (the app may hear of a press on the menu bar only
    /// after it made the app's flyout resign).
    pub fn pressed(self: *Tray) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const button = objc.msg(objc.Object, self.item, "button", .{});
        const win = objc.msg(?objc.Object, button, "window", .{}) orelse return false;
        const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        if (objc.msg(?objc.Object, nsapp, "currentEvent", .{})) |ev| if (objc.msg(?objc.Object, ev, "window", .{})) |ew| if (ew == win) {
            const kind = objc.msg(objc.NSUInteger, ev, "type", .{});
            if (kind == 1 or kind == 3) { // NSEventTypeLeftMouseDown, RightMouseDown
                const p = objc.msg(objc.CGPoint, button, "convertPoint:fromView:", .{ objc.msg(objc.CGPoint, ev, "locationInWindow", .{}), @as(?objc.Object, null) });
                return inRect(p, objc.msg(objc.CGRect, button, "bounds", .{}));
            }
        };
        if (objc.msg(objc.NSUInteger, objc.class("NSEvent"), "pressedMouseButtons", .{}) == 0) return false;
        return inRect(objc.msg(objc.CGPoint, objc.class("NSEvent"), "mouseLocation", .{}), objc.msg(objc.CGRect, win, "frame", .{}));
    }

    pub fn setTitle(self: *Tray, title: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const button = objc.msg(objc.Object, self.item, "button", .{});
        objc.msg(void, button, "setTitle:", .{objc.nsString(title)});
    }

    pub fn setTooltip(self: *Tray, tip: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const button = objc.msg(objc.Object, self.item, "button", .{});
        objc.msg(void, button, "setToolTip:", .{objc.nsString(tip)});
    }

    pub fn setSymbol(self: *Tray, name: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const button = objc.msg(objc.Object, self.item, "button", .{});
        const img = objc.msg(?objc.Object, objc.class("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", .{
            objc.nsString(name), @as(?objc.Object, null),
        }) orelse return;
        objc.msg(void, img, "setTemplate:", .{objc.YES});
        objc.msg(void, button, "setImage:", .{img});
    }

    /// Replaces the icon with a PNG image's, drawn 18 points high (a
    /// template image with `Options.template`).
    pub fn setIcon(self: *Tray, png: []const u8) !void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ png.ptr, png.len });
        const img = objc.msg(?objc.Object, objc.alloc("NSImage"), "initWithData:", .{data}) orelse return error.BadIcon;
        defer objc.release(img);
        const size = objc.msg(objc.CGSize, img, "size", .{});
        if (size.height > 0) objc.msg(void, img, "setSize:", .{objc.CGSize{ .width = size.width * 18 / size.height, .height = 18 }});
        if (self.template) objc.msg(void, img, "setTemplate:", .{objc.YES});
        const button = objc.msg(objc.Object, self.item, "button", .{});
        objc.msg(void, button, "setImage:", .{img});
    }

    pub fn setMenu(self: *Tray, app_name: []const u8, template: []const menu_mod.MenuItem) !void {
        const m = try menu_mod.Menu.create(self.gpa, app_name, template);
        if (self.menu) |old| old.destroy();
        self.menu = m;
        objc.msg(void, self.item, "setMenu:", .{m.ns});
    }
};

/// Whether `p` is in `r`, its far edges excluded.
fn inRect(p: objc.CGPoint, r: objc.CGRect) bool {
    return p.x >= r.origin.x and p.y >= r.origin.y and p.x < r.origin.x + r.size.width and p.y < r.origin.y + r.size.height;
}

test "a point is in a rectangle without its far edges" {
    const r: objc.CGRect = .{ .origin = .{ .x = 10, .y = 20 }, .size = .{ .width = 30, .height = 22 } };
    try std.testing.expect(inRect(.{ .x = 10, .y = 20 }, r));
    try std.testing.expect(!inRect(.{ .x = 40, .y = 30 }, r));
    try std.testing.expect(!inRect(.{ .x = 9, .y = 30 }, r));
}
