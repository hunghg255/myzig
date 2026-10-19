//! The desktop's settings that `preferences.zig` follows, asked of each
//! platform: higher contrast (macOS's Increase contrast, Windows' contrast
//! themes, a GTK high-contrast theme), the size of text (Windows' and
//! GNOME's text size), and the accent color the user chose.
const std = @import("std");
const builtin = @import("builtin");

pub const System = struct {
    high_contrast: bool = false,
    text_scale: f32 = 1,
    /// sRGB, null where the desktop has none.
    accent: ?[3]f32 = null,
};

pub fn ask() System {
    return switch (builtin.os.tag) {
        .windows => windows(),
        .macos => macos(),
        .linux => linux(),
        else => .{},
    };
}

extern "user32" fn SystemParametersInfoW(action: u32, param: u32, out: ?*anyopaque, flags: u32) callconv(.winapi) i32;

const HighContrastW = extern struct {
    size: u32,
    flags: u32,
    scheme: ?[*:0]u16,
};

fn windows() System {
    var s: System = .{};
    const spi_get_high_contrast = 0x0042;
    const hcf_high_contrast_on = 1;
    var hc: HighContrastW = .{ .size = @sizeOf(HighContrastW), .flags = 0, .scheme = null };
    if (SystemParametersInfoW(spi_get_high_contrast, @sizeOf(HighContrastW), &hc, 0) != 0)
        s.high_contrast = hc.flags & hcf_high_contrast_on != 0;
    const reg = @import("../windows/registry.zig");
    if (reg.getNumber("Software\\Microsoft\\Accessibility", "TextScaleFactor")) |pct| {
        if (pct >= 100 and pct <= 225) s.text_scale = @as(f32, @floatFromInt(pct)) / 100;
    }
    s.accent = @import("../windows/desktop.zig").accentColor();
    return s;
}

fn macos() System {
    const objc = @import("../objc.zig");
    var s: System = .{};
    if (objc.msg(?objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{})) |ws|
        s.high_contrast = objc.msg(bool, ws, "accessibilityDisplayShouldIncreaseContrast", .{});
    s.accent = @import("../desktop.zig").accentColor();
    return s;
}

fn linux() System {
    var s: System = .{};
    if (builtin.link_libc == false) return s;
    // GTK, if the app loaded it: its theme and its text's resolution.
    const self = std.c.dlopen(null, .{ .LAZY = true }) orelse return s;
    const get_default: *const fn () callconv(.c) ?*anyopaque = @ptrCast(@alignCast(std.c.dlsym(self, "gtk_settings_get_default") orelse return s));
    const object_get: *const fn (obj: *anyopaque, name: [*:0]const u8, ...) callconv(.c) void = @ptrCast(@alignCast(std.c.dlsym(self, "g_object_get") orelse return s));
    const g_free: *const fn (?*anyopaque) callconv(.c) void = @ptrCast(@alignCast(std.c.dlsym(self, "g_free") orelse return s));
    const settings = get_default() orelse return s;
    var theme: ?[*:0]u8 = null;
    object_get(settings, "gtk-theme-name", &theme, @as(?*anyopaque, null));
    if (theme) |t| {
        s.high_contrast = std.mem.indexOf(u8, std.mem.span(t), "HighContrast") != null;
        g_free(t);
    }
    var dpi: c_int = -1;
    object_get(settings, "gtk-xft-dpi", &dpi, @as(?*anyopaque, null));
    // In 1024ths of a dot per inch; 96 is usual.
    if (dpi > 0) s.text_scale = std.math.clamp(@as(f32, @floatFromInt(dpi)) / 1024 / 96, 0.5, 3);
    s.accent = @import("../linux/desktop.zig").accentColor();
    return s;
}
