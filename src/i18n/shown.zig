//! The language the app shows, which catalogs say their messages in when
//! a call names none. The app sets it (`setLocale`) from the user's
//! languages and the app's (`match`), on the main thread, which reads it;
//! other threads say a locale themselves (`printIn`, `textIn`).
const std = @import("std");
const tag = @import("tag.zig");

var shown: tag.Tag = tag.Tag.from("en");
var generation: u32 = 0;

/// The language the app shows: "en" until the app sets one.
pub fn locale() []const u8 {
    return shown.slice();
}

/// Shows `tag_text` (a BCP 47 tag, or a POSIX locale), or English when it
/// names no language. Counts a generation, which views that keep text
/// compare to know it changed.
pub fn setLocale(tag_text: []const u8) void {
    shown = tag.Tag.parse(tag_text) orelse tag.Tag.from("en");
    generation +%= 1;
}

/// Counts the changes of the language the app shows.
pub fn localeGeneration() u32 {
    return generation;
}
