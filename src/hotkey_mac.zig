//! Global shortcuts on macOS: Carbon's RegisterEventHotKey, which needs no
//! accessibility permission, loaded with dlopen. Presses arrive as Carbon
//! events on the application's target, on the main thread.
const std = @import("std");
const hotkeys = @import("hotkeys.zig");

const EventTypeSpec = extern struct { class: u32, kind: u32 };
const EventHotKeyID = extern struct { signature: u32, id: u32 };
const HandlerFn = *const fn (next: ?*anyopaque, event: ?*anyopaque, data: ?*anyopaque) callconv(.c) i32;

const Api = struct {
    GetApplicationEventTarget: *const fn () callconv(.c) ?*anyopaque,
    InstallEventHandler: *const fn (target: ?*anyopaque, handler: HandlerFn, n: usize, specs: *const EventTypeSpec, data: ?*anyopaque, out: ?*?*anyopaque) callconv(.c) i32,
    RegisterEventHotKey: *const fn (code: u32, mods: u32, id: EventHotKeyID, target: ?*anyopaque, options: u32, out: *?*anyopaque) callconv(.c) i32,
    UnregisterEventHotKey: *const fn (ref: *anyopaque) callconv(.c) i32,
    GetEventParameter: *const fn (event: ?*anyopaque, name: u32, kind: u32, out_kind: ?*u32, size: usize, out_size: ?*usize, out: *anyopaque) callconv(.c) i32,
};

var api: Api = undefined;
var state: enum { untried, ok, missing } = .untried;
var installed = false;

const signature: u32 = 0x4D795A67; // 'MyZg'
const class_keyboard: u32 = 0x6B657962; // 'keyb'
const hot_key_pressed: u32 = 5;
const param_direct_object: u32 = 0x2D2D2D2D; // '----'
const type_hot_key_id: u32 = 0x686B6964; // 'hkid'

pub const Pressed = *const fn (ctx: *anyopaque, id: u32) void;
var pressed: ?struct { ctx: *anyopaque, func: Pressed } = null;

fn load() bool {
    if (state == .untried) {
        state = .missing;
        const lib = std.c.dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", .{ .NOW = true }) orelse return false;
        inline for (@typeInfo(Api).@"struct".field_names) |name| @field(api, name) = @ptrCast(@alignCast(std.c.dlsym(lib, name) orelse return false));
        state = .ok;
    }
    return state == .ok;
}

fn handler(_: ?*anyopaque, event: ?*anyopaque, _: ?*anyopaque) callconv(.c) i32 {
    var hk: EventHotKeyID = .{ .signature = 0, .id = 0 };
    if (api.GetEventParameter(event, param_direct_object, type_hot_key_id, null, @sizeOf(EventHotKeyID), null, &hk) != 0) return 0;
    if (hk.signature != signature) return 0;
    if (pressed) |p| p.func(p.ctx, hk.id);
    return 0;
}

pub fn listen(ctx: *anyopaque, func: Pressed) void {
    pressed = .{ .ctx = ctx, .func = func };
}

/// Registers `a` as the shortcut `id`; its handle unregisters it.
pub fn register(id: u32, a: hotkeys.Accelerator) hotkeys.Error!*anyopaque {
    var acc = a;
    var mods = hotkeys.macMods(a);
    // "+" is Shift and "=" on the ANSI layout.
    if (acc.key == '+') {
        acc.key = '=';
        mods |= 1 << 9;
    }
    const code = hotkeys.macKey(acc.key) orelse return error.UnsupportedKey;
    if (!load()) return error.Unsupported;
    const target = api.GetApplicationEventTarget();
    if (!installed) {
        const spec: EventTypeSpec = .{ .class = class_keyboard, .kind = hot_key_pressed };
        if (api.InstallEventHandler(target, handler, 1, &spec, null, null) != 0) return error.Unsupported;
        installed = true;
    }
    var ref: ?*anyopaque = null;
    if (api.RegisterEventHotKey(code, mods, .{ .signature = signature, .id = id }, target, 0, &ref) != 0) return error.Unavailable;
    return ref orelse error.Unavailable;
}

pub fn unregister(ref: *anyopaque) void {
    if (state == .ok) _ = api.UnregisterEventHotKey(ref);
}
