//! Tray icons on Windows: icons in the notification area
//! (Shell_NotifyIconW), owned by the app's hidden window, which gets their
//! clicks. A right click shows the icon's menu. Notifications are the
//! icons' balloons, which Windows 10 and later show as toasts.
const std = @import("std");
const w = @import("win32.zig");
const appwnd = @import("appwnd.zig");
const menubar = @import("menubar.zig");
const menu_mod = @import("../menu_accel.zig");
const tray_types = @import("../tray_types.zig");

pub const Options = tray_types.Options(menu_mod.MenuItem, Tray);
pub const Click = tray_types.Click(Tray);

pub const HICON = *opaque {};

/// NOTIFYICONDATAW.
pub const NOTIFYICONDATAW = extern struct {
    cbSize: u32 = @sizeOf(NOTIFYICONDATAW),
    hWnd: ?w.HWND = null,
    uID: u32 = 0,
    uFlags: u32 = 0,
    uCallbackMessage: u32 = 0,
    hIcon: ?HICON = null,
    szTip: [128]u16 = @splat(0),
    dwState: u32 = 0,
    dwStateMask: u32 = 0,
    szInfo: [256]u16 = @splat(0),
    uVersion: u32 = 0,
    szInfoTitle: [64]u16 = @splat(0),
    dwInfoFlags: u32 = 0,
    guidItem: [16]u8 = @splat(0),
    hBalloonIcon: ?HICON = null,
};

extern "shell32" fn Shell_NotifyIconW(op: u32, data: *const NOTIFYICONDATAW) callconv(.winapi) w.BOOL;
extern "user32" fn CreateIconFromResourceEx(bits: [*]const u8, size: u32, icon: w.BOOL, ver: u32, cx: i32, cy: i32, flags: u32) callconv(.winapi) ?HICON;
extern "user32" fn DestroyIcon(icon: HICON) callconv(.winapi) w.BOOL;
extern "user32" fn LoadIconW(inst: ?w.HINSTANCE, name: usize) callconv(.winapi) ?HICON;

const NIM_ADD = 0;
const NIM_MODIFY = 1;
const NIM_DELETE = 2;
const NIF_MESSAGE = 0x01;
const NIF_ICON = 0x02;
const NIF_TIP = 0x04;
const NIF_INFO = 0x10;
const NIF_SHOWTIP = 0x80;
const NIIF_USER = 0x04;
const NIIF_NOSOUND = 0x10;

const WM_LBUTTONUP = 0x0202;
const WM_RBUTTONUP = 0x0205;
const WM_CONTEXTMENU = 0x007B;
pub const NIN_BALLOONTIMEOUT = 0x0400 + 4;
pub const NIN_BALLOONUSERCLICK = 0x0400 + 5;

/// Copies `s` as UTF-16 into `dst`, truncated, null-terminated.
pub fn copyWide(dst: []u16, s: []const u8) void {
    _ = w.wide(dst, s);
}

/// An icon of a PNG file's bytes (Windows reads PNG icons itself).
pub fn iconFromPng(png: []const u8) ?HICON {
    if (png.len < 24 or !std.mem.startsWith(u8, png, "\x89PNG")) return null;
    const width: i32 = @intCast(std.mem.readInt(u32, png[16..20], .big));
    const height: i32 = @intCast(std.mem.readInt(u32, png[20..24], .big));
    return CreateIconFromResourceEx(png.ptr, @intCast(png.len), 1, 0x00030000, width, height, 0);
}

/// The app's icon (resource 1), else Windows' default application icon.
pub fn appIcon() ?HICON {
    return LoadIconW(w.GetModuleHandleW(null), 1) orelse LoadIconW(null, 32512);
}

pub const Tray = struct {
    gpa: std.mem.Allocator,
    hwnd: w.HWND,
    id: u32,
    icon: ?HICON = null,
    owns_icon: bool = false,
    tip: [128]u16 = @splat(0),
    menu: ?*menu_mod.Menu = null,
    on_click: ?Click = null,
    on_appearance: ?Click = null,
    added: bool = false,
    /// The notification its balloon shows, if any (owned).
    notification: ?[]u8 = null,
    /// Added only to show a notification, removed after.
    temporary: bool = false,
    /// The PNG the icon shows (owned) and whether it is black and
    /// transparent, which shows white on a dark taskbar, as macOS tints
    /// a template image.
    image: ?[]u8 = null,
    template: bool = false,
    /// The taskbar's appearance, as last told.
    was_dark: bool = false,

    /// Adds an icon owned by `hwnd` (the app's window) with id `id`
    /// (`number` gives the id of an icon with an ID).
    pub fn create(gpa: std.mem.Allocator, hwnd: w.HWND, id: u32, opts: Options) !*Tray {
        const self = try gpa.create(Tray);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .hwnd = hwnd, .id = id, .on_click = opts.on_click, .on_appearance = opts.on_appearance, .template = opts.template, .was_dark = taskbarDark() };
        // Added once it has its number, image and tooltip: the
        // notification area keeps the user's choices for an icon by its
        // number, and names it by its first tooltip.
        self.applyIcon(opts.icon) catch {};
        errdefer {
            self.dropIcon();
            if (self.image) |i| gpa.free(i);
        }
        if (self.icon == null) self.icon = appIcon();
        copyWide(&self.tip, if (opts.tooltip.len > 0) opts.tooltip else opts.title);
        if (opts.menu.len > 0) try self.setMenu("", opts.menu);
        self.add();
        return self;
    }

    pub fn destroy(self: *Tray) void {
        self.remove();
        self.dropIcon();
        if (self.image) |i| self.gpa.free(i);
        if (self.menu) |m| m.destroy();
        if (self.notification) |n| self.gpa.free(n);
        self.gpa.destroy(self);
    }

    fn dropIcon(self: *Tray) void {
        if (self.owns_icon) if (self.icon) |i| {
            _ = DestroyIcon(i);
        };
        self.icon = null;
        self.owns_icon = false;
    }

    fn data(self: *Tray, extra: u32) NOTIFYICONDATAW {
        var d: NOTIFYICONDATAW = .{ .hWnd = self.hwnd, .uID = self.id, .uFlags = NIF_MESSAGE | extra, .uCallbackMessage = appwnd.WM_TRAY, .hIcon = self.icon, .szTip = self.tip };
        if (self.icon != null) d.uFlags |= NIF_ICON;
        if (self.tip[0] != 0) d.uFlags |= NIF_TIP | NIF_SHOWTIP;
        return d;
    }

    /// Adds the icon to the notification area (again, after Explorer restarted).
    pub fn add(self: *Tray) void {
        const d = self.data(0);
        self.added = Shell_NotifyIconW(NIM_ADD, &d) != 0;
    }

    fn remove(self: *Tray) void {
        if (!self.added) return;
        const d = self.data(0);
        _ = Shell_NotifyIconW(NIM_DELETE, &d);
        self.added = false;
    }

    fn update(self: *Tray) void {
        const d = self.data(0);
        _ = Shell_NotifyIconW(NIM_MODIFY, &d);
    }

    /// Windows shows no text in the notification area: the title becomes
    /// the tooltip when there is none.
    pub fn setTitle(self: *Tray, title: []const u8) void {
        if (self.tip[0] == 0) self.setTooltip(title);
    }

    /// SF Symbols are macOS's.
    pub fn setSymbol(_: *Tray, _: []const u8) void {}

    pub fn setTooltip(self: *Tray, tip: []const u8) void {
        copyWide(&self.tip, tip);
        self.update();
    }

    /// Replaces the icon with a PNG image's (white on a dark taskbar for
    /// a template icon).
    pub fn setIcon(self: *Tray, png: []const u8) !void {
        try self.applyIcon(png);
        self.update();
    }

    fn applyIcon(self: *Tray, png: []const u8) !void {
        if (png.len == 0) return;
        const white = if (self.template and taskbarDark()) whiten(self.gpa, png) catch null else null;
        defer if (white) |x| self.gpa.free(x);
        const icon = iconFromPng(white orelse png) orelse return error.BadIcon;
        const copy = try self.gpa.dupe(u8, png);
        // `png` may be the old image: copied first, freed after.
        if (self.image) |old| self.gpa.free(old);
        self.image = copy;
        self.dropIcon();
        self.icon = icon;
        self.owns_icon = true;
    }

    /// Whether the taskbar the icon shows on is dark: Windows draws it in
    /// the system's mode, which may differ from the apps'.
    pub fn dark(_: *Tray) bool {
        return taskbarDark();
    }

    /// The system's mode may have changed: a template icon is drawn for
    /// the taskbar again, and `on_appearance` hears of a change.
    pub fn appearanceChanged(self: *Tray) void {
        const now = taskbarDark();
        if (now == self.was_dark) return;
        self.was_dark = now;
        if (self.template) if (self.image) |img| self.setIcon(img) catch {};
        if (self.on_appearance) |c| c.func(c.ctx, self);
    }

    pub fn setMenu(self: *Tray, _: []const u8, template: []const menu_mod.MenuItem) !void {
        const m = try menu_mod.Menu.create(self.gpa, template);
        if (self.menu) |old| old.destroy();
        self.menu = m;
    }

    /// Shows the icon's menu at the mouse; runs the item chosen.
    pub fn popUpMenu(self: *Tray) void {
        const m = self.menu orelse return;
        if (menubar.popup(m, self.hwnd)) |it| menu_mod.Menu.activate(it);
    }

    /// A mouse or balloon event of the icon; returns the notification
    /// clicked, if one was (owned by the caller).
    pub fn event(self: *Tray, ev: u32) ?[]u8 {
        switch (ev) {
            WM_LBUTTONUP => if (self.on_click) |c| c.func(c.ctx, self),
            WM_RBUTTONUP, WM_CONTEXTMENU => self.popUpMenu(),
            NIN_BALLOONUSERCLICK => {
                const n = self.notification;
                self.notification = null;
                return n;
            },
            NIN_BALLOONTIMEOUT => self.endNotification(),
            else => {},
        }
        return null;
    }

    /// Shows a notification as the icon's balloon.
    pub fn notify(self: *Tray, id: []const u8, title: []const u8, body: []const u8, silent: bool) !void {
        var d = self.data(NIF_INFO);
        balloon(&d, title, body, silent);
        if (Shell_NotifyIconW(NIM_MODIFY, &d) == 0) return error.NotificationFailed;
        if (self.notification) |n| self.gpa.free(n);
        self.notification = try self.gpa.dupe(u8, id);
    }

    /// Hides the balloon (an empty one replaces it).
    pub fn endNotification(self: *Tray) void {
        if (self.notification) |n| self.gpa.free(n);
        self.notification = null;
        const d = self.data(NIF_INFO);
        _ = Shell_NotifyIconW(NIM_MODIFY, &d);
    }
};

/// Whether the taskbar is dark (Settings > Personalization > Colors, the
/// Windows mode), which may differ from the apps' mode.
pub fn taskbarDark() bool {
    const v = @import("registry.zig").getNumber("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", "SystemUsesLightTheme") orelse return false;
    return v == 0;
}

/// The number of an icon with an ID: its FNV-1a hash with the high bit
/// set, which the numbers `App.newTray` counts never reach. The
/// notification area keeps whether the user shows an icon on the taskbar
/// by the executable's path and the icon's number: counted as icons
/// come, an icon made again, or after others in another order, would
/// lose the user's choice or take another icon's.
pub fn number(id: []const u8) u32 {
    return std.hash.Fnv1a_32.hash(id) | 1 << 31;
}

/// A template image drawn white, its alpha kept. Caller frees it.
pub fn whiten(gpa: std.mem.Allocator, png: []const u8) ![]u8 {
    const img = try @import("../ui/png_decode.zig").decode(gpa, png);
    defer img.deinit(gpa);
    // Premultiplied BGRA: white at alpha a is (a, a, a, a).
    var i: usize = 0;
    while (i + 4 <= img.bgra.len) : (i += 4) @memset(img.bgra[i .. i + 3], img.bgra[i + 3]);
    return @import("../ui/png.zig").encode(gpa, .{ .bytes = img.bgra, .width = img.width, .height = img.height });
}

/// Fills a balloon's title, text and flags.
pub fn balloon(d: *NOTIFYICONDATAW, title: []const u8, body: []const u8, silent: bool) void {
    copyWide(&d.szInfoTitle, title);
    // The balloon must have text to show.
    copyWide(&d.szInfo, if (body.len > 0) body else " ");
    d.dwInfoFlags = NIIF_USER | (if (silent) @as(u32, NIIF_NOSOUND) else 0);
}

test "NOTIFYICONDATAW is Windows' layout, balloons are truncated to fit" {
    if (@sizeOf(usize) == 8) try std.testing.expectEqual(@as(usize, 976), @sizeOf(NOTIFYICONDATAW));
    var d: NOTIFYICONDATAW = .{};
    const long: [100]u8 = @splat('x');
    balloon(&d, &long, "", true);
    try std.testing.expectEqual(@as(u16, 0), d.szInfoTitle[63]);
    try std.testing.expectEqual(@as(u16, 'x'), d.szInfoTitle[62]);
    try std.testing.expectEqual(@as(u16, ' '), d.szInfo[0]);
    try std.testing.expect(d.dwInfoFlags & NIIF_NOSOUND != 0);
    try std.testing.expect(iconFromPng("not a png") == null);
    try std.testing.expect(appIcon() != null);
}

test "icons with an ID are numbered by it, whatever their order, apart from the counted ones" {
    const t = std.testing;
    try t.expectEqual(number("app.cpu"), number("app.cpu"));
    try t.expect(number("app.cpu") != number("app.memory"));
    try t.expect(number("app.cpu") & (1 << 31) != 0);
    // FNV-1a, as mygo numbers them: the same icon keeps the user's choice.
    try t.expectEqual(@as(u32, 0x811c9dc5 | 1 << 31), number(""));
}

test "a template icon is drawn white on a dark taskbar, keeping its shape" {
    const gpa = std.testing.allocator;
    // Black, opaque then at 56/255.
    var px = [_]u8{ 0, 0, 0, 255, 0, 0, 0, 56 };
    const png = try @import("../ui/png.zig").encode(gpa, .{ .bytes = &px, .width = 2, .height = 1 });
    defer gpa.free(png);
    const out = try whiten(gpa, png);
    defer gpa.free(out);
    const img = try @import("../ui/png_decode.zig").decode(gpa, out);
    defer img.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255, 56, 56, 56, 56 }, img.bgra);
    try std.testing.expectError(error.NotPng, whiten(gpa, "not a png"));
}
