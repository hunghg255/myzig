//! Tray icons on Linux: StatusNotifierItems through libayatana-appindicator
//! (loaded with dlopen), which panels show with their menu on a click;
//! where it is missing, a GtkStatusIcon (X11 panels with a system tray),
//! which gets clicks and shows the menu on a right click.
const std = @import("std");
const gtk = @import("gtk.zig");
const gtkmenu = @import("gtkmenu.zig");
const menu_mod = @import("../menu_accel.zig");
const tray_types = @import("../tray_types.zig");

pub const Options = tray_types.Options(menu_mod.MenuItem, Tray);
pub const Click = tray_types.Click(Tray);

const Indicator = struct {
    app_indicator_new: *const fn (id: [*:0]const u8, icon: [*:0]const u8, category: c_int) callconv(.c) *anyopaque,
    app_indicator_set_status: *const fn (ind: *anyopaque, status: c_int) callconv(.c) void,
    app_indicator_set_menu: *const fn (ind: *anyopaque, menu: *gtk.Widget) callconv(.c) void,
    app_indicator_set_icon_full: *const fn (ind: *anyopaque, name: [*:0]const u8, desc: [*:0]const u8) callconv(.c) void,
    app_indicator_set_icon_theme_path: *const fn (ind: *anyopaque, path: [*:0]const u8) callconv(.c) void,
    app_indicator_set_label: *const fn (ind: *anyopaque, label: [*:0]const u8, guide: [*:0]const u8) callconv(.c) void,
    app_indicator_set_title: *const fn (ind: *anyopaque, title: [*:0]const u8) callconv(.c) void,
};

var indicator: Indicator = undefined;
var indicator_state: enum { unknown, present, missing } = .unknown;

fn loadIndicator() bool {
    if (indicator_state == .unknown) {
        indicator_state = .missing;
        const lib = std.c.dlopen("libayatana-appindicator3.so.1", .{ .NOW = true }) orelse
            std.c.dlopen("libappindicator3.so.1", .{ .NOW = true }) orelse return false;
        inline for (@typeInfo(Indicator).@"struct".field_names) |name| {
            const sym = std.c.dlsym(lib, name) orelse return false;
            @field(indicator, name) = @ptrCast(@alignCast(sym));
        }
        indicator_state = .present;
    }
    return indicator_state == .present;
}

/// `s` with a NUL, truncated to fit `buf`.
fn z(buf: []u8, s: []const u8) [:0]const u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

pub const Tray = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The AppIndicator, or the GtkStatusIcon.
    handle: *anyopaque,
    is_indicator: bool,
    menu: ?*menu_mod.Menu = null,
    gtk_menu: ?*gtk.Widget = null,
    /// The app's, to run the roles of the menu's items (`setPerform`).
    perform: ?menu_mod.Perform = null,
    on_click: ?Click = null,
    /// Where the icon's PNG is written (indicators and status icons take files).
    icon_dir: ?[]u8 = null,
    icon_serial: u32 = 0,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, app_id: []const u8, opts: Options) !*Tray {
        if (!gtkmenu.load()) return error.GtkMissing;
        const self = try gpa.create(Tray);
        errdefer gpa.destroy(self);
        var idb: [256]u8 = undefined;
        if (loadIndicator()) {
            // APP_INDICATOR_CATEGORY_APPLICATION_STATUS, then ACTIVE.
            const ind = indicator.app_indicator_new(z(&idb, app_id), "application-x-executable", 0);
            indicator.app_indicator_set_status(ind, 1);
            self.* = .{ .gpa = gpa, .io = io, .handle = ind, .is_indicator = true, .on_click = opts.on_click };
        } else {
            const icon = gtkmenu.api.gtk_status_icon_new_from_icon_name("application-x-executable");
            gtk.connect(icon, "activate", @ptrCast(&onActivate), self);
            gtk.connect(icon, "popup-menu", @ptrCast(&onPopup), self);
            self.* = .{ .gpa = gpa, .io = io, .handle = icon, .is_indicator = false, .on_click = opts.on_click };
        }
        errdefer self.destroy();
        if (opts.icon.len > 0) try self.setIcon(opts.icon);
        if (opts.title.len > 0) self.setTitle(opts.title);
        if (opts.tooltip.len > 0) self.setTooltip(opts.tooltip);
        // An indicator only shows once it has a menu.
        const placeholder = [_]menu_mod.MenuItem{.{ .label = if (opts.tooltip.len > 0) opts.tooltip else if (opts.title.len > 0) opts.title else app_id, .disabled = true }};
        try self.setMenu("", if (opts.menu.len > 0) opts.menu else &placeholder);
        return self;
    }

    pub fn destroy(self: *Tray) void {
        if (self.is_indicator) indicator.app_indicator_set_status(self.handle, 0) // PASSIVE
        else gtkmenu.api.gtk_status_icon_set_visible(self.handle, 0);
        gtkmenu.api.g_object_unref(self.handle);
        if (self.gtk_menu) |g| gtkmenu.destroy(self.menu.?, g);
        if (self.menu) |m| m.destroy();
        if (self.icon_dir) |d| {
            std.Io.Dir.cwd().deleteTree(self.io, d) catch {};
            self.gpa.free(d);
        }
        self.gpa.destroy(self);
    }

    fn onActivate(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(data));
        if (self.on_click) |c| c.func(c.ctx, self) else self.popUpMenu();
    }

    fn onPopup(_: *anyopaque, _: c_uint, _: c_uint, data: ?*anyopaque) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(data));
        self.popUpMenu();
    }

    /// False: panels tell nothing of their color, and draw their icon
    /// themes their own way (`on_appearance` is never called). An
    /// indicator's ID is the app's, and panels place icons themselves:
    /// `Options.id` and `template` change nothing.
    pub fn dark(_: *Tray) bool {
        return false;
    }

    /// Shows the menu at the mouse (status icons; panels show indicators' own).
    pub fn popUpMenu(self: *Tray) void {
        if (self.is_indicator) return;
        if (self.gtk_menu) |g| gtkmenu.api.gtk_menu_popup_at_pointer(g, null);
    }

    /// The label panels show next to the icon (indicators).
    pub fn setTitle(self: *Tray, title: []const u8) void {
        var buf: [256]u8 = undefined;
        const t = z(&buf, title);
        if (self.is_indicator) indicator.app_indicator_set_label(self.handle, t, t) else gtkmenu.api.gtk_status_icon_set_title(self.handle, t);
    }

    pub fn setTooltip(self: *Tray, tip: []const u8) void {
        var buf: [256]u8 = undefined;
        const t = z(&buf, tip);
        if (self.is_indicator) indicator.app_indicator_set_title(self.handle, t) else gtkmenu.api.gtk_status_icon_set_tooltip_text(self.handle, t);
    }

    /// SF Symbols are macOS's; on Linux it names an icon of the theme.
    pub fn setSymbol(self: *Tray, name: []const u8) void {
        if (!self.is_indicator) return;
        var buf: [256]u8 = undefined;
        indicator.app_indicator_set_icon_full(self.handle, z(&buf, name), "");
    }

    /// Replaces the icon with a PNG image's (written to a temporary file:
    /// panels load icons from files).
    pub fn setIcon(self: *Tray, png: []const u8) !void {
        if (!std.mem.startsWith(u8, png, "\x89PNG")) return error.BadIcon;
        const io = self.io;
        if (self.icon_dir == null) {
            const tmp: []const u8 = if (std.c.getenv("XDG_RUNTIME_DIR")) |d| std.mem.span(d) else "/tmp";
            var rnd: [4]u8 = undefined;
            std.Io.random(io, &rnd);
            self.icon_dir = try std.fmt.allocPrint(self.gpa, "{s}/myzig-tray-{x}", .{ tmp, std.mem.readInt(u32, &rnd, .little) });
            try std.Io.Dir.cwd().createDirPath(io, self.icon_dir.?);
        }
        // A new name each time: panels cache icons by name.
        self.icon_serial += 1;
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "icon{d}", .{self.icon_serial});
        var path_buf: [600]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.png", .{ self.icon_dir.?, name });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = png });
        var zb: [600]u8 = undefined;
        var nb: [32]u8 = undefined;
        var db: [600]u8 = undefined;
        if (self.is_indicator) {
            indicator.app_indicator_set_icon_theme_path(self.handle, z(&db, self.icon_dir.?));
            indicator.app_indicator_set_icon_full(self.handle, z(&nb, name), "");
        } else gtkmenu.api.gtk_status_icon_set_from_file(self.handle, z(&zb, path));
    }

    pub fn setMenu(self: *Tray, _: []const u8, template: []const menu_mod.MenuItem) !void {
        const m = try menu_mod.Menu.create(self.gpa, template);
        errdefer m.destroy();
        m.perform = self.perform;
        const g = gtkmenu.build(m) orelse return error.GtkMissing;
        if (self.gtk_menu) |old| gtkmenu.destroy(self.menu.?, old);
        if (self.menu) |old| old.destroy();
        self.menu = m;
        self.gtk_menu = g;
        if (self.is_indicator) indicator.app_indicator_set_menu(self.handle, g);
    }

    /// How the items chosen run, roles included: set by the app.
    pub fn setPerform(self: *Tray, p: menu_mod.Perform) void {
        self.perform = p;
        if (self.menu) |m| m.perform = p;
    }
};
