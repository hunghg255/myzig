//! The Windows Runtime without headers: HSTRINGs, activation factories
//! and instances of runtime classes (combase.dll, loaded when first
//! needed, so apps that never use WinRT import nothing of it), and the
//! interfaces WinRT objects share (IInspectable, IPropertyValue, IMap).
const std = @import("std");
const com = @import("com.zig");

pub const HSTRING = ?*opaque {};

extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

const Api = struct {
    WindowsCreateString: *const fn (s: [*]const u16, len: u32, out: *HSTRING) callconv(.winapi) com.HRESULT,
    WindowsDeleteString: *const fn (s: HSTRING) callconv(.winapi) com.HRESULT,
    WindowsGetStringRawBuffer: *const fn (s: HSTRING, len: ?*u32) callconv(.winapi) ?[*]const u16,
    RoGetActivationFactory: *const fn (class: HSTRING, iid: *const com.GUID, out: *?com.Object) callconv(.winapi) com.HRESULT,
    RoActivateInstance: *const fn (class: HSTRING, out: *?com.Object) callconv(.winapi) com.HRESULT,
};

var api: Api = undefined;
var state: enum { untried, ok, missing } = .untried;

/// Loads combase.dll's functions; false before Windows 8.
pub fn load() bool {
    if (state != .untried) return state == .ok;
    state = .missing;
    const lib = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("combase.dll")) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        @field(api, name) = @ptrCast(@alignCast(GetProcAddress(lib, name) orelse return false));
    }
    state = .ok;
    return true;
}

/// An HSTRING of `s`, which `free` deletes. Null is WinRT's empty string.
pub fn string(s: []const u8) !HSTRING {
    if (!load()) return error.Unsupported;
    if (s.len == 0) return null;
    var stack: [512]u16 = undefined;
    var heap: ?[]u16 = null;
    defer if (heap) |h| std.heap.c_allocator.free(h);
    const units: []u16 = if (s.len <= stack.len) stack[0..s.len] else blk: {
        heap = try std.heap.c_allocator.alloc(u16, s.len);
        break :blk heap.?;
    };
    const n = std.unicode.utf8ToUtf16Le(units, s) catch return error.InvalidUtf8;
    var out: HSTRING = null;
    if (com.failed(api.WindowsCreateString(units.ptr, @intCast(n), &out))) return error.OutOfMemory;
    return out;
}

pub fn free(s: HSTRING) void {
    if (s != null and state == .ok) _ = api.WindowsDeleteString(s);
}

/// The text of `s`, as UTF-8 in `gpa`.
pub fn utf8(gpa: std.mem.Allocator, s: HSTRING) ![]u8 {
    if (s == null or state != .ok) return gpa.dupe(u8, "");
    var len: u32 = 0;
    const p = api.WindowsGetStringRawBuffer(s, &len) orelse return gpa.dupe(u8, "");
    return std.unicode.utf16LeToUtf8Alloc(gpa, p[0..len]);
}

/// The activation factory (or statics) of runtime class `class` as `iid`.
pub fn factory(class: []const u8, iid: *const com.GUID) !com.Object {
    const name = try string(class);
    defer free(name);
    var out: ?com.Object = null;
    if (com.failed(api.RoGetActivationFactory(name, iid, &out))) return error.ClassNotRegistered;
    return out orelse error.ClassNotRegistered;
}

/// A new instance of runtime class `class` (its default constructor), as
/// `iid`.
pub fn activate(class: []const u8, iid: *const com.GUID) !com.Object {
    const name = try string(class);
    defer free(name);
    var out: ?com.Object = null;
    if (com.failed(api.RoActivateInstance(name, &out))) return error.ClassNotRegistered;
    const obj = out orelse return error.ClassNotRegistered;
    defer com.release(obj);
    return com.query(obj, iid) orelse error.NoInterface;
}

/// IInspectable's methods come after IUnknown's: an interface's own
/// methods start at this index.
pub const first_method = 6;

pub const iid_property_value = com.GUID.parse("4bd682dd-7554-40e9-9a9b-82654ede7e62");
/// IMap<HSTRING, IInspectable>, which a ValueSet implements.
pub const iid_map_string_object = com.GUID.parse("1b0d3570-0877-5ec2-8a2c-3b9539506aca");

// IPropertyValue.GetString; IMap.Lookup and HasKey.
const property_get_string = first_method + 13;
const map_lookup = first_method;
const map_has_key = first_method + 2;

/// The string `map` (an IMap<HSTRING, IInspectable>) holds under `key`,
/// or null when it holds none (or no string).
pub fn mapString(gpa: std.mem.Allocator, map: com.Object, key: []const u8) !?[]u8 {
    const k = try string(key);
    defer free(k);
    var has: u8 = 0;
    if (com.failed(com.call(map, map_has_key, .{ k, &has })) or has == 0) return null;
    var value: ?com.Object = null;
    if (com.failed(com.call(map, map_lookup, .{ k, &value }))) return null;
    const v = value orelse return null;
    defer com.release(v);
    const pv = com.query(v, &iid_property_value) orelse return null;
    defer com.release(pv);
    var s: HSTRING = null;
    if (com.failed(com.call(pv, property_get_string, .{&s}))) return null;
    defer free(s);
    return try utf8(gpa, s);
}

test "HSTRINGs carry UTF-8 there and back" {
    if (!load()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const s = try string("héllo, wörld");
    defer free(s);
    const back = try utf8(gpa, s);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("héllo, wörld", back);
    try std.testing.expect((try string("")) == null);
    const empty = try utf8(gpa, null);
    defer gpa.free(empty);
    try std.testing.expectEqualStrings("", empty);
}
