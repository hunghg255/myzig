//! The app's light or dark appearance, as the app asks for it
//! (`App.setAppearance`): the system's, or always light or dark. Native
//! UI's theme and the title bars follow it (`isDark` of each platform's
//! desktop applies it); on macOS AppKit applies it (NSApp.appearance).
pub const Appearance = enum { system, light, dark };

/// What the app asked for; `.system` follows the system.
pub var chosen: Appearance = .system;

/// Whether the app shows dark, the system showing dark or not.
pub fn dark(system_dark: bool) bool {
    return switch (chosen) {
        .system => system_dark,
        .light => false,
        .dark => true,
    };
}

test "an app's appearance overrides the system's until it follows it again" {
    const std = @import("std");
    defer chosen = .system;
    try std.testing.expect(dark(true) and !dark(false));
    chosen = .light;
    try std.testing.expect(!dark(true));
    chosen = .dark;
    try std.testing.expect(dark(false));
}
