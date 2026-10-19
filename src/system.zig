//! What the system does for the app, the same calls on every platform:
//! the user's locale, recent documents, opening at login, URL schemes and
//! file types, keeping the system awake. Calls taking the app use its
//! name and id (`AppOptions.id`).
//!
//!     try myzig.system.registerUrlScheme(app, "notes");
//!     const awake = try myzig.system.preventSleep(app, "Exporting", .system);
//!     defer awake.release();
const std = @import("std");
const builtin = @import("builtin");
const recent = @import("recent.zig");
const launch = @import("launch.zig");

const os = builtin.os.tag;
const impl = switch (os) {
    .macos => @import("system_mac.zig"),
    .windows => @import("windows/system.zig"),
    .linux => @import("linux/system.zig"),
    .wasi => @import("web/system.zig"),
    else => @compileError("myzig runs on macOS, Linux and Windows"),
};
const desktop = switch (os) {
    .macos => @import("desktop.zig"),
    .windows => @import("windows/desktop.zig"),
    .linux => @import("linux/desktop.zig"),
    .wasi => @import("web/desktop.zig"),
    else => unreachable,
};
const win = if (os == .windows) struct {
    const protocols = @import("windows/protocols.zig");
    const jumplist = @import("windows/jumplist.zig");
} else struct {};

/// A task of the app's jump list (Windows).
pub const JumpTask = if (os == .windows) @import("windows/jumplist.zig").Task else struct {
    title: []const u8,
    description: []const u8 = "",
    path: []const u8 = "",
    args: []const u8 = "",
    icon_path: []const u8 = "",
    icon_index: i32 = 0,
};

/// Sets the Tasks of the app's jump list on Windows (a right click on its
/// taskbar button), with the Recent category of its documents; no tasks
/// removes them. Windows keeps the list after the app quits: set it once
/// at startup. A task best runs a URL of the app's own scheme, which
/// reaches `on_open_url`. Elsewhere it does nothing.
pub fn setJumpList(app: anytype, tasks: []const JumpTask) !void {
    if (os != .windows) return;
    const path = try exe(app);
    defer app.gpa.free(path);
    try win.jumplist.set(app.gpa, path, tasks, true, .commit);
}
const lin = if (os == .linux) struct {
    const xdg = @import("linux/xdg.zig");
    const services = @import("linux/services.zig");
    const Bus = @import("linux/dbus_conn.zig").Bus;
} else struct {};

/// The user's locale as a BCP 47 tag ("en-US"). Caller frees it.
pub const locale = impl.locale;
/// The user's region, two letters ("US"). Caller frees it.
pub const region = impl.region;
/// The user's languages, most preferred first. Free with `freeList`.
pub const languages = impl.languages;
pub const freeList = impl.freeList;

fn dataDir(app: anytype) ![]u8 {
    return desktop.path(app.gpa, .data, app.options.name);
}

/// Records a document the user opened: in the app's list
/// (`recentDocuments`) and the system's (macOS's Open Recent and Dock
/// menu, Windows' Recent and jump list, Linux's recently used files).
pub fn addRecentDocument(app: anytype, path: []const u8) !void {
    impl.addRecentDocument(path);
    const dir = try dataDir(app);
    defer app.gpa.free(dir);
    try recent.add(app.gpa, app.io, dir, path);
}

/// The app's recent documents that still exist, newest first, ten at
/// most. Free with `freeList`.
pub fn recentDocuments(app: anytype) ![][]u8 {
    const dir = try dataDir(app);
    defer app.gpa.free(dir);
    return recent.list(app.gpa, app.io, dir);
}

/// Forgets the app's recent documents (on Linux the user's other recent
/// files stay).
pub fn clearRecentDocuments(app: anytype) void {
    if (os == .linux) {
        const list = recentDocuments(app) catch return;
        defer recent.freeList(app.gpa, list);
        for (list) |p| impl.removeRecentDocument(p);
    } else impl.clearRecentDocuments();
    const dir = dataDir(app) catch return;
    defer app.gpa.free(dir);
    recent.clear(app.gpa, app.io, dir);
}

fn exe(app: anytype) ![]u8 {
    return switch (os) {
        .windows => win.protocols.executable(app.gpa),
        .linux => lin.xdg.executable(app.gpa, app.io),
        else => error.Unsupported,
    };
}

/// Opens the app when the user logs in (a Run entry on Windows, an XDG
/// autostart entry on Linux, a login item on macOS 13 and later for
/// bundled apps). `wasOpenedAtLogin` tells such a launch apart.
pub fn setOpenAtLogin(app: anytype, on: bool) !void {
    switch (os) {
        .macos => return impl.setOpenAtLogin(on),
        .windows => {
            const path = try exe(app);
            defer app.gpa.free(path);
            return impl.setOpenAtLogin(app.gpa, impl.run_key, app.options.name, path, on);
        },
        .linux => {
            const path = try exe(app);
            defer app.gpa.free(path);
            const dirs = try lin.xdg.Dirs.user(app.gpa);
            defer dirs.deinit(app.gpa);
            return lin.xdg.setAutostart(app.gpa, app.io, dirs, app.options.appId(), app.options.name, path, on);
        },
        else => unreachable,
    }
}

pub fn openAtLogin(app: anytype) bool {
    switch (os) {
        .macos => return impl.openAtLogin(),
        .windows => {
            const path = exe(app) catch return false;
            defer app.gpa.free(path);
            return impl.openAtLogin(app.gpa, impl.run_key, app.options.name, path);
        },
        .linux => {
            const dirs = lin.xdg.Dirs.user(app.gpa) catch return false;
            defer dirs.deinit(app.gpa);
            return lin.xdg.autostart(app.gpa, app.io, dirs, app.options.appId());
        },
        else => unreachable,
    }
}

/// Whether the system started this launch at login (Windows, Linux).
pub fn wasOpenedAtLogin(app: anytype) bool {
    return app.opened_at_login;
}

/// Makes the app the user's handler of `scheme`'s URLs ("notes" for
/// notes://...), which reach `on_open_url`; cheap to call at every launch.
/// On macOS the scheme must be in the bundle's Info.plist; this makes the
/// app its default handler.
pub fn registerUrlScheme(app: anytype, scheme: []const u8) !void {
    if (!launch.isUrlScheme(scheme)) return error.BadScheme;
    switch (os) {
        .macos => return impl.setDefaultSchemeHandler(scheme),
        .windows => {
            const path = try exe(app);
            defer app.gpa.free(path);
            return win.protocols.registerScheme(app.gpa, win.protocols.default_root, scheme, app.options.name, path);
        },
        .linux => {
            const path = try exe(app);
            defer app.gpa.free(path);
            const dirs = try lin.xdg.Dirs.user(app.gpa);
            defer dirs.deinit(app.gpa);
            return lin.xdg.registerScheme(app.gpa, app.io, dirs, app.options.appId(), app.options.name, path, scheme);
        },
        else => unreachable,
    }
}

/// Undoes `registerUrlScheme` (Windows, Linux) if the app is the handler.
pub fn unregisterUrlScheme(app: anytype, scheme: []const u8) !void {
    switch (os) {
        .macos => return,
        .windows => {
            const path = try exe(app);
            defer app.gpa.free(path);
            return win.protocols.unregisterScheme(app.gpa, win.protocols.default_root, scheme, path);
        },
        .linux => {
            const path = try exe(app);
            defer app.gpa.free(path);
            const dirs = try lin.xdg.Dirs.user(app.gpa);
            defer dirs.deinit(app.gpa);
            return lin.xdg.unregisterScheme(app.gpa, app.io, dirs, app.options.appId(), app.options.name, path, scheme);
        },
        else => unreachable,
    }
}

pub fn isUrlSchemeRegistered(app: anytype, scheme: []const u8) bool {
    switch (os) {
        .macos => return impl.isDefaultSchemeHandler(scheme),
        .windows => {
            const path = exe(app) catch return false;
            defer app.gpa.free(path);
            return win.protocols.isSchemeRegistered(app.gpa, win.protocols.default_root, scheme, path);
        },
        .linux => {
            const dirs = lin.xdg.Dirs.user(app.gpa) catch return false;
            defer dirs.deinit(app.gpa);
            return lin.xdg.isSchemeRegistered(app.gpa, app.io, dirs, app.options.appId(), scheme);
        },
        else => unreachable,
    }
}

/// Lets the app open files of `ext` ("md") from Explorer (Windows: the
/// extension's Open with list; the files reach `on_open_file`). macOS
/// declares file types in the bundle, Linux in the app's desktop entry.
pub fn registerFileType(app: anytype, ext: []const u8, description: []const u8) !void {
    if (os != .windows) return error.Unsupported;
    const path = try exe(app);
    defer app.gpa.free(path);
    var pb: [256]u8 = undefined;
    const prog_id = try std.fmt.bufPrint(&pb, "{s}.{s}", .{ app.options.appId(), ext });
    return win.protocols.registerFileType(app.gpa, win.protocols.default_root, ext, prog_id, description, path);
}

pub fn unregisterFileType(app: anytype, ext: []const u8) !void {
    if (os != .windows) return error.Unsupported;
    var pb: [256]u8 = undefined;
    const prog_id = try std.fmt.bufPrint(&pb, "{s}.{s}", .{ app.options.appId(), ext });
    return win.protocols.unregisterFileType(win.protocols.default_root, ext, prog_id);
}

pub const Awake = enum {
    /// The system does not sleep while idle; the display may turn off.
    system,
    /// Nor does the display.
    display,
};

/// Keeps the system awake until `release`d.
pub const Blocker = struct {
    inner: switch (os) {
        .linux => struct { bus: *lin.Bus, cookie: u32 },
        .windows => impl.Blocker,
        .macos => impl.Blocker,
        else => void,
    },

    pub fn release(b: Blocker) void {
        switch (os) {
            .linux => lin.services.uninhibit(b.inner.bus, b.inner.cookie),
            .windows, .macos => b.inner.release(),
            else => {},
        }
    }
};

/// Keeps the system (and the display) awake while the app works:
/// Windows' power requests, macOS's power assertions; on Linux the screen
/// saver's inhibition over the session bus, which keeps both awake.
pub fn preventSleep(app: anytype, reason: []const u8, what: Awake) !Blocker {
    switch (os) {
        .linux => {
            const bus = app.sessionBus() orelse return error.NoSessionBus;
            return .{ .inner = .{ .bus = bus, .cookie = try lin.services.inhibit(bus, app.options.name, reason) } };
        },
        .windows => return .{ .inner = try impl.preventSleep(reason, if (what == .display) .display else .system) },
        .macos => return .{ .inner = try impl.preventSleep(reason, if (what == .display) .display else .system) },
        else => unreachable,
    }
}
