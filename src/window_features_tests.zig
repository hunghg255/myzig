//! The tests of windows' events and frames, flyouts, global shortcuts,
//! the network's status, signals and the app's directories, per platform.
const std = @import("std");
const builtin = @import("builtin");

test {
    _ = @import("flyout.zig");
    _ = @import("paths.zig");
    _ = @import("hotkeys.zig");
    _ = @import("network.zig");
    _ = @import("titlebar.zig");
    _ = @import("window_types.zig");
    switch (builtin.os.tag) {
        .windows => {
            _ = @import("windows/gdi.zig");
            _ = @import("windows/caption.zig");
            _ = @import("windows/frame.zig");
            _ = @import("windows/taskbar.zig");
            _ = @import("windows/network.zig");
            _ = @import("windows/hotkey.zig");
            _ = @import("windows/signal.zig");
            _ = @import("windows/flyout.zig");
            _ = @import("windows/app_extras.zig");
            _ = @import("windows/window_tests.zig");
        },
        .linux => {
            _ = @import("signal_unix.zig");
            _ = @import("linux/gtk_more.zig");
            _ = @import("linux/hotkey.zig");
            _ = @import("linux/network.zig");
            _ = @import("linux/launcher_entry.zig");
            std.testing.refAllDecls(@import("linux/app_extras.zig"));
            std.testing.refAllDecls(@import("linux/window_events.zig"));
            _ = @import("linux/window_tests.zig");
        },
        .macos => {
            _ = @import("signal_unix.zig");
            std.testing.refAllDecls(@import("window_mac_events.zig"));
            std.testing.refAllDecls(@import("hotkey_mac.zig"));
            std.testing.refAllDecls(@import("network_mac.zig"));
            std.testing.refAllDecls(@import("app_extras_mac.zig"));
        },
        else => {},
    }
}
