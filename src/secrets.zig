//! Secrets the system keeps encrypted for the user, by service and
//! account, as keytar keeps them: the Keychain on macOS, the Credential
//! Manager on Windows, the keyring through libsecret on Linux.
//!
//!     try myzig.secrets.set(gpa, "com.example.notes", "ada@example.com", token);
//!     const t = try myzig.secrets.get(gpa, "com.example.notes", "ada@example.com");
const std = @import("std");
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .macos => @import("secrets_mac.zig"),
    .windows => @import("windows/secrets.zig"),
    .linux => @import("linux/secrets.zig"),
    .wasi => @import("web/secrets.zig"),
    else => @compileError("myzig runs on macOS, Linux and Windows"),
};

/// Stores `secret` (Linux keeps text: no NUL bytes there).
pub fn set(gpa: std.mem.Allocator, service: []const u8, account: []const u8, secret: []const u8) !void {
    if (builtin.os.tag == .linux) return impl.set(gpa, service, account, secret);
    return impl.set(service, account, secret);
}

/// The secret, or null when there is none. Caller frees it.
pub fn get(gpa: std.mem.Allocator, service: []const u8, account: []const u8) !?[]u8 {
    return impl.get(gpa, service, account);
}

/// Deletes the secret; false when there was none.
pub fn delete(service: []const u8, account: []const u8) !bool {
    return impl.delete(service, account);
}
