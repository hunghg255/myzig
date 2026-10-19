//! Secrets on Linux: the user's keyring (GNOME Keyring, KWallet,
//! KeePassXC...) through libsecret, loaded with dlopen, with keytar's
//! schema: org.freedesktop.Secret.Generic with the string attributes
//! "service" and "account". Without libsecret: `error.Unsupported`.
const std = @import("std");

const Api = struct {
    secret_schema_new: *const fn (name: [*:0]const u8, flags: c_int, ...) callconv(.c) ?*anyopaque,
    secret_password_store_sync: *const fn (schema: *anyopaque, collection: ?[*:0]const u8, label: [*:0]const u8, password: [*:0]const u8, cancellable: ?*anyopaque, err: *?*GError, ...) callconv(.c) c_int,
    secret_password_lookup_sync: *const fn (schema: *anyopaque, cancellable: ?*anyopaque, err: *?*GError, ...) callconv(.c) ?[*:0]u8,
    secret_password_clear_sync: *const fn (schema: *anyopaque, cancellable: ?*anyopaque, err: *?*GError, ...) callconv(.c) c_int,
    secret_password_free: *const fn (p: ?[*:0]u8) callconv(.c) void,
    g_error_free: *const fn (e: *GError) callconv(.c) void,
};

const GError = extern struct { domain: u32, code: c_int, message: ?[*:0]u8 };

var api: Api = undefined;
var schema: ?*anyopaque = null;
var state: enum { unknown, present, missing } = .unknown;

fn load() bool {
    if (state == .unknown) {
        state = .missing;
        const lib = std.c.dlopen("libsecret-1.so.0", .{ .NOW = true }) orelse return false;
        inline for (@typeInfo(Api).@"struct".field_names) |name| {
            const sym = std.c.dlsym(lib, name) orelse return false;
            @field(api, name) = @ptrCast(@alignCast(sym));
        }
        // SECRET_SCHEMA_NONE; SECRET_SCHEMA_ATTRIBUTE_STRING is 0.
        schema = api.secret_schema_new("org.freedesktop.Secret.Generic", @as(c_int, 0), "service", @as(c_int, 0), "account", @as(c_int, 0), @as(?*anyopaque, null));
        if (schema == null) return false;
        state = .present;
    }
    return state == .present;
}

fn z(buf: []u8, s: []const u8) ![*:0]const u8 {
    if (s.len >= buf.len or std.mem.indexOfScalar(u8, s, 0) != null) return error.BadName;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

fn check(err: ?*GError) !void {
    if (err) |e| {
        api.g_error_free(e);
        return error.Keyring;
    }
}

/// Stores `secret` (text: libsecret keeps strings) for `service` and `account`.
pub fn set(gpa: std.mem.Allocator, service: []const u8, account: []const u8, secret: []const u8) !void {
    if (!load()) return error.Unsupported;
    var sb: [512]u8 = undefined;
    var ab: [512]u8 = undefined;
    var lb: [1100]u8 = undefined;
    const label = try std.fmt.bufPrint(&lb, "{s}/{s}\x00", .{ service, account });
    const value = try gpa.alloc(u8, secret.len + 1);
    defer {
        @memset(value, 0);
        gpa.free(value);
    }
    if (std.mem.indexOfScalar(u8, secret, 0) != null) return error.BinarySecret;
    @memcpy(value[0..secret.len], secret);
    value[secret.len] = 0;
    var err: ?*GError = null;
    _ = api.secret_password_store_sync(schema.?, null, @ptrCast(label.ptr), @ptrCast(value.ptr), null, &err, "service", try z(&sb, service), "account", try z(&ab, account), @as(?*anyopaque, null));
    try check(err);
}

/// The secret, or null when there is none. Caller frees it.
pub fn get(gpa: std.mem.Allocator, service: []const u8, account: []const u8) !?[]u8 {
    if (!load()) return error.Unsupported;
    var sb: [512]u8 = undefined;
    var ab: [512]u8 = undefined;
    var err: ?*GError = null;
    const p = api.secret_password_lookup_sync(schema.?, null, &err, "service", try z(&sb, service), "account", try z(&ab, account), @as(?*anyopaque, null));
    try check(err);
    const s = p orelse return null;
    defer api.secret_password_free(s);
    return try gpa.dupe(u8, std.mem.span(s));
}

/// Deletes the secret; false when there was none.
pub fn delete(service: []const u8, account: []const u8) !bool {
    if (!load()) return error.Unsupported;
    var sb: [512]u8 = undefined;
    var ab: [512]u8 = undefined;
    var err: ?*GError = null;
    const ok = api.secret_password_clear_sync(schema.?, null, &err, "service", try z(&sb, service), "account", try z(&ab, account), @as(?*anyopaque, null));
    try check(err);
    return ok != 0;
}

test "a secret stored under a test service, read back and deleted (with a keyring)" {
    const gpa = std.testing.allocator;
    if (!load()) return error.SkipZigTest;
    var rnd: [4]u8 = undefined;
    std.Io.random(std.testing.io, &rnd);
    var sb: [48]u8 = undefined;
    const service = try std.fmt.bufPrint(&sb, "myzig-test-{x}", .{std.mem.readInt(u32, &rnd, .little)});
    set(gpa, service, "ada", "s3cret") catch return error.SkipZigTest; // no keyring daemon
    defer _ = delete(service, "ada") catch {};
    const got = (try get(gpa, service, "ada")).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("s3cret", got);
    try std.testing.expect(try delete(service, "ada"));
    try std.testing.expect((try get(gpa, service, "ada")) == null);
}
