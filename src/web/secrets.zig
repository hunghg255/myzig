//! Secrets in a browser: no keychain to keep them encrypted, so none are
//! kept (a page's storage is not one).
const std = @import("std");

pub fn set(_: []const u8, _: []const u8, _: []const u8) !void {
    return error.Unsupported;
}

pub fn get(_: std.mem.Allocator, _: []const u8, _: []const u8) !?[]u8 {
    return null;
}

pub fn delete(_: []const u8, _: []const u8) !bool {
    return false;
}
