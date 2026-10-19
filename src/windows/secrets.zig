//! Secrets on Windows: generic credentials of the Credential Manager, as
//! keytar keeps them (the target is "service/account", the user name the
//! account), which the system encrypts for the user (DPAPI).
const std = @import("std");
const w = @import("win32.zig");

const CREDENTIALW = extern struct {
    Flags: u32 = 0,
    Type: u32 = 1, // CRED_TYPE_GENERIC
    TargetName: [*:0]const u16,
    Comment: ?[*:0]const u16 = null,
    LastWritten: u64 = 0,
    CredentialBlobSize: u32 = 0,
    CredentialBlob: ?[*]const u8 = null,
    Persist: u32 = 3, // CRED_PERSIST_ENTERPRISE, as keytar
    AttributeCount: u32 = 0,
    Attributes: ?*anyopaque = null,
    TargetAlias: ?[*:0]const u16 = null,
    UserName: ?[*:0]const u16 = null,
};

extern "advapi32" fn CredWriteW(cred: *const CREDENTIALW, flags: u32) callconv(.winapi) w.BOOL;
extern "advapi32" fn CredReadW(target: [*:0]const u16, kind: u32, flags: u32, out: **CREDENTIALW) callconv(.winapi) w.BOOL;
extern "advapi32" fn CredDeleteW(target: [*:0]const u16, kind: u32, flags: u32) callconv(.winapi) w.BOOL;
extern "advapi32" fn CredFree(p: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

const ERROR_NOT_FOUND = 1168;

fn target(buf: []u16, service: []const u8, account: []const u8) [*:0]const u16 {
    var b: [1024]u8 = undefined;
    const t = std.fmt.bufPrint(&b, "{s}/{s}", .{ service, account }) catch "";
    return w.wide(buf, t);
}

pub fn set(service: []const u8, account: []const u8, secret: []const u8) !void {
    var tb: [1024]u16 = undefined;
    var ub: [512]u16 = undefined;
    const c: CREDENTIALW = .{
        .TargetName = target(&tb, service, account),
        .UserName = w.wide(&ub, account),
        .CredentialBlobSize = @intCast(secret.len),
        .CredentialBlob = if (secret.len > 0) secret.ptr else null,
    };
    if (CredWriteW(&c, 0) == 0) return error.SecretWrite;
}

/// The secret, or null when there is none. Caller frees it.
pub fn get(gpa: std.mem.Allocator, service: []const u8, account: []const u8) !?[]u8 {
    var tb: [1024]u16 = undefined;
    var p: *CREDENTIALW = undefined;
    if (CredReadW(target(&tb, service, account), 1, 0, &p) == 0) {
        if (GetLastError() == ERROR_NOT_FOUND) return null;
        return error.SecretRead;
    }
    defer CredFree(p);
    const blob = if (p.CredentialBlob) |b| b[0..p.CredentialBlobSize] else "";
    return try gpa.dupe(u8, blob);
}

/// Deletes the secret; false when there was none.
pub fn delete(service: []const u8, account: []const u8) !bool {
    var tb: [1024]u16 = undefined;
    if (CredDeleteW(target(&tb, service, account), 1, 0) == 0) {
        if (GetLastError() == ERROR_NOT_FOUND) return false;
        return error.SecretDelete;
    }
    return true;
}

test "a secret stored under a test service, read back and deleted" {
    const gpa = std.testing.allocator;
    var rnd: [4]u8 = undefined;
    std.Io.random(std.testing.io, &rnd);
    var sb: [48]u8 = undefined;
    const service = try std.fmt.bufPrint(&sb, "myzig-test-{x}", .{std.mem.readInt(u32, &rnd, .little)});
    try std.testing.expect((try get(gpa, service, "ada")) == null);
    try set(service, "ada", "s3cret\x00bytes");
    defer _ = delete(service, "ada") catch {};
    const got = (try get(gpa, service, "ada")).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("s3cret\x00bytes", got);
    try set(service, "ada", "new");
    const again = (try get(gpa, service, "ada")).?;
    defer gpa.free(again);
    try std.testing.expectEqualStrings("new", again);
    try std.testing.expect(try delete(service, "ada"));
    try std.testing.expect(!try delete(service, "ada"));
    try std.testing.expect((try get(gpa, service, "ada")) == null);
}
