//! What the system does for apps on macOS: the user's locale, region and
//! languages (NSLocale), recent documents (NSDocumentController: the Dock
//! menu and Open Recent), opening at login (SMAppService, macOS 13 and
//! later, for bundled apps), keeping the system awake (IOKit power
//! assertions) and the default handler of URL schemes (Launch Services).
//! Frameworks myzig doesn't link are loaded when first used.
const std = @import("std");
const objc = @import("objc.zig");

extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;
extern "c" fn CFRelease(obj: *const anyopaque) void;
extern "c" fn CFStringCreateWithBytes(alloc: ?*anyopaque, bytes: [*]const u8, len: isize, encoding: u32, external: u8) ?*anyopaque;

fn cfString(s: []const u8) ?*anyopaque {
    return CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), 0x08000100, 0); // UTF-8
}

/// "en_US" as a BCP 47 tag: "en-US". Caller frees it.
fn tag(gpa: std.mem.Allocator, id: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, id);
    for (out) |*c| if (c.* == '_') {
        c.* = '-';
    };
    if (std.mem.indexOfScalar(u8, out, '@')) |i| return gpa.realloc(out, i);
    return out;
}

/// The user's locale as a BCP 47 tag ("en-US"). Caller frees it.
pub fn locale(gpa: std.mem.Allocator) ![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const loc = objc.msg(objc.Object, objc.class("NSLocale"), "currentLocale", .{});
    return tag(gpa, objc.fromNSString(objc.msg(?objc.Object, loc, "localeIdentifier", .{})));
}

/// The user's region, two letters ("US").
pub fn region(gpa: std.mem.Allocator) ![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const loc = objc.msg(objc.Object, objc.class("NSLocale"), "currentLocale", .{});
    return gpa.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, loc, "countryCode", .{})));
}

/// The user's languages, most preferred first. Free with `freeList`.
pub fn languages(gpa: std.mem.Allocator) ![][]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const list = objc.msg(objc.Object, objc.class("NSLocale"), "preferredLanguages", .{});
    const n = objc.msg(objc.NSUInteger, list, "count", .{});
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeList(gpa, out.items);
    for (0..n) |i| try out.append(gpa, try tag(gpa, objc.fromNSString(objc.msg(objc.Object, list, "objectAtIndex:", .{i}))));
    return out.toOwnedSlice(gpa);
}

pub fn freeList(gpa: std.mem.Allocator, list: []const []u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

fn documents() objc.Object {
    return objc.msg(objc.Object, objc.class("NSDocumentController"), "sharedDocumentController", .{});
}

/// Adds `path` to the app's recent documents (Open Recent, the Dock menu).
pub fn addRecentDocument(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
    objc.msg(void, documents(), "noteNewRecentDocumentURL:", .{url});
}

pub fn clearRecentDocuments() void {
    objc.msg(void, documents(), "clearRecentDocuments:", .{@as(?objc.Object, null)});
}

/// SMAppService's main app service, or null before macOS 13.
fn appService() ?objc.Object {
    _ = std.c.dlopen("/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement", .{ .NOW = true });
    const cls = objc_getClass("SMAppService") orelse return null;
    return objc.msg(objc.Object, cls, "mainAppService", .{});
}

/// Opens the app at login (a login item of the user; the app must be a
/// bundle). `--myzig-login` is not passed here: macOS has no arguments
/// for login items.
pub fn setOpenAtLogin(on: bool) !void {
    const svc = appService() orelse return error.Unsupported;
    const ok = objc.msg(objc.BOOL, svc, if (on) "registerAndReturnError:" else "unregisterAndReturnError:", .{@as(?*anyopaque, null)});
    if (!ok) return error.LoginItem;
}

pub fn openAtLogin() bool {
    const svc = appService() orelse return false;
    return objc.msg(objc.NSInteger, svc, "status", .{}) == 1; // SMAppServiceStatusEnabled
}

const IOPMAssertionCreateWithName = *const fn (kind: *anyopaque, level: u32, name: *anyopaque, id: *u32) callconv(.c) i32;
const IOPMAssertionRelease = *const fn (id: u32) callconv(.c) i32;

pub const Awake = enum { system, display };

pub const Blocker = struct {
    id: u32,

    pub fn release(b: Blocker) void {
        const lib = std.c.dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", .{ .NOW = true }) orelse return;
        const f: IOPMAssertionRelease = @ptrCast(@alignCast(std.c.dlsym(lib, "IOPMAssertionRelease") orelse return));
        _ = f(b.id);
    }
};

/// Keeps the system (and the display) awake until released.
pub fn preventSleep(reason: []const u8, what: Awake) !Blocker {
    const lib = std.c.dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", .{ .NOW = true }) orelse return error.Unsupported;
    const create: IOPMAssertionCreateWithName = @ptrCast(@alignCast(std.c.dlsym(lib, "IOPMAssertionCreateWithName") orelse return error.Unsupported));
    const kind = cfString(if (what == .display) "PreventUserIdleDisplaySleep" else "PreventUserIdleSystemSleep") orelse return error.OutOfMemory;
    defer CFRelease(kind);
    const name = cfString(reason) orelse return error.OutOfMemory;
    defer CFRelease(name);
    var id: u32 = 0;
    if (create(kind, 255, name, &id) != 0) return error.PowerAssertion; // kIOPMAssertionLevelOn
    return .{ .id = id };
}

/// Makes the app (its bundle identifier) the default handler of `scheme`,
/// which its Info.plist must declare.
pub fn setDefaultSchemeHandler(scheme: []const u8) !void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const bundle = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    const id = objc.msg(?objc.Object, bundle, "bundleIdentifier", .{}) orelse return error.NeedsBundle;
    const f: *const fn (*anyopaque, objc.Object) callconv(.c) i32 = @ptrCast(@alignCast(lsSym("LSSetDefaultHandlerForURLScheme") orelse return error.Unsupported));
    const s = cfString(scheme) orelse return error.OutOfMemory;
    defer CFRelease(s);
    if (f(s, id) != 0) return error.LaunchServices;
}

/// Whether the app is the default handler of `scheme`.
pub fn isDefaultSchemeHandler(scheme: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const bundle = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    const id = objc.msg(?objc.Object, bundle, "bundleIdentifier", .{}) orelse return false;
    const f: *const fn (*anyopaque) callconv(.c) ?objc.Object = @ptrCast(@alignCast(lsSym("LSCopyDefaultHandlerForURLScheme") orelse return false));
    const s = cfString(scheme) orelse return false;
    defer CFRelease(s);
    const handler = f(s) orelse return false;
    defer objc.release(handler);
    return objc.msg(objc.NSInteger, handler, "caseInsensitiveCompare:", .{id}) == 0;
}

/// A Launch Services function (CoreServices, which AppKit loads).
fn lsSym(name: [*:0]const u8) ?*anyopaque {
    const lib = std.c.dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", .{ .NOW = true }) orelse return null;
    return std.c.dlsym(lib, name);
}
