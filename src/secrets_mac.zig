//! Secrets on macOS: generic passwords of the user's login keychain, as
//! keytar keeps them (the service and the account), through the Security
//! framework, loaded when first used.
const std = @import("std");

const CFTypeRef = *const anyopaque;
extern "c" fn CFRelease(obj: CFTypeRef) void;
extern "c" fn CFStringCreateWithBytes(alloc: ?*anyopaque, bytes: [*]const u8, len: isize, encoding: u32, external: u8) ?CFTypeRef;
extern "c" fn CFDataCreate(alloc: ?*anyopaque, bytes: [*]const u8, len: isize) ?CFTypeRef;
extern "c" fn CFDataGetBytePtr(data: CFTypeRef) [*]const u8;
extern "c" fn CFDataGetLength(data: CFTypeRef) isize;
extern "c" fn CFDictionaryCreate(alloc: ?*anyopaque, keys: [*]const CFTypeRef, values: [*]const CFTypeRef, n: isize, kc: *const anyopaque, vc: *const anyopaque) ?CFTypeRef;
extern "c" const kCFTypeDictionaryKeyCallBacks: opaque {};
extern "c" const kCFTypeDictionaryValueCallBacks: opaque {};
extern "c" const kCFBooleanTrue: CFTypeRef;

const Sec = struct {
    SecItemAdd: *const fn (attrs: CFTypeRef, result: ?*?CFTypeRef) callconv(.c) i32,
    SecItemCopyMatching: *const fn (query: CFTypeRef, result: *?CFTypeRef) callconv(.c) i32,
    SecItemUpdate: *const fn (query: CFTypeRef, attrs: CFTypeRef) callconv(.c) i32,
    SecItemDelete: *const fn (query: CFTypeRef) callconv(.c) i32,
};
const Keys = struct {
    kSecClass: CFTypeRef,
    kSecClassGenericPassword: CFTypeRef,
    kSecAttrService: CFTypeRef,
    kSecAttrAccount: CFTypeRef,
    kSecValueData: CFTypeRef,
    kSecReturnData: CFTypeRef,
};

var sec: Sec = undefined;
var keys: Keys = undefined;
var loaded = false;

const errSecSuccess = 0;
const errSecDuplicateItem = -25299;
const errSecItemNotFound = -25300;

fn load() bool {
    if (loaded) return true;
    const lib = std.c.dlopen("/System/Library/Frameworks/Security.framework/Security", .{ .NOW = true }) orelse return false;
    inline for (@typeInfo(Sec).@"struct".field_names) |name| {
        @field(sec, name) = @ptrCast(@alignCast(std.c.dlsym(lib, name) orelse return false));
    }
    // The keys are variables holding CFStrings.
    inline for (@typeInfo(Keys).@"struct".field_names) |name| {
        const p: *const CFTypeRef = @ptrCast(@alignCast(std.c.dlsym(lib, name) orelse return false));
        @field(keys, name) = p.*;
    }
    loaded = true;
    return true;
}

fn cfString(s: []const u8) !CFTypeRef {
    return CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), 0x08000100, 0) orelse error.OutOfMemory;
}

/// The query of `service` and `account`'s item, with `extra` key/values.
fn query(service: CFTypeRef, account: CFTypeRef, extra_keys: []const CFTypeRef, extra_values: []const CFTypeRef) !CFTypeRef {
    var k: [6]CFTypeRef = undefined;
    var v: [6]CFTypeRef = undefined;
    k[0..3].* = .{ keys.kSecClass, keys.kSecAttrService, keys.kSecAttrAccount };
    v[0..3].* = .{ keys.kSecClassGenericPassword, service, account };
    for (extra_keys, extra_values, 0..) |ek, ev, i| {
        k[3 + i] = ek;
        v[3 + i] = ev;
    }
    const n = 3 + extra_keys.len;
    return CFDictionaryCreate(null, &k, &v, @intCast(n), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse error.OutOfMemory;
}

pub fn set(service: []const u8, account: []const u8, secret: []const u8) !void {
    if (!load()) return error.Unsupported;
    const s = try cfString(service);
    defer CFRelease(s);
    const a = try cfString(account);
    defer CFRelease(a);
    const data = CFDataCreate(null, secret.ptr, @intCast(secret.len)) orelse return error.OutOfMemory;
    defer CFRelease(data);
    const add = try query(s, a, &.{keys.kSecValueData}, &.{data});
    defer CFRelease(add);
    const r = sec.SecItemAdd(add, null);
    if (r == errSecSuccess) return;
    if (r != errSecDuplicateItem) return error.Keychain;
    const q = try query(s, a, &.{}, &.{});
    defer CFRelease(q);
    var uk = [_]CFTypeRef{keys.kSecValueData};
    var uv = [_]CFTypeRef{data};
    const attrs = CFDictionaryCreate(null, &uk, &uv, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return error.OutOfMemory;
    defer CFRelease(attrs);
    if (sec.SecItemUpdate(q, attrs) != errSecSuccess) return error.Keychain;
}

pub fn get(gpa: std.mem.Allocator, service: []const u8, account: []const u8) !?[]u8 {
    if (!load()) return error.Unsupported;
    const s = try cfString(service);
    defer CFRelease(s);
    const a = try cfString(account);
    defer CFRelease(a);
    const q = try query(s, a, &.{keys.kSecReturnData}, &.{kCFBooleanTrue});
    defer CFRelease(q);
    var out: ?CFTypeRef = null;
    const r = sec.SecItemCopyMatching(q, &out);
    if (r == errSecItemNotFound) return null;
    if (r != errSecSuccess) return error.Keychain;
    const data = out orelse return null;
    defer CFRelease(data);
    return try gpa.dupe(u8, CFDataGetBytePtr(data)[0..@intCast(CFDataGetLength(data))]);
}

pub fn delete(service: []const u8, account: []const u8) !bool {
    if (!load()) return error.Unsupported;
    const s = try cfString(service);
    defer CFRelease(s);
    const a = try cfString(account);
    defer CFRelease(a);
    const q = try query(s, a, &.{}, &.{});
    defer CFRelease(q);
    const r = sec.SecItemDelete(q);
    if (r == errSecItemNotFound) return false;
    if (r != errSecSuccess) return error.Keychain;
    return true;
}
