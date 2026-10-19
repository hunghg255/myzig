//! Global shortcuts: keys that reach the app while another app is in
//! front, as launchers open (Spotlight, Raycast, PowerToys Run). Each
//! platform registers them its way (RegisterHotKey, Carbon's
//! RegisterEventHotKey, an X11 key grab); this is what they share: the
//! handlers by id, and each system's names of the keys.
//!
//!     const id = try app.registerHotkey("Alt+Shift+Space", .of(&launcher, Launcher.toggle));
//!     defer app.unregisterHotkey(id);
const std = @import("std");
const menu_types = @import("menu_types.zig");
const Handler = @import("app_types.zig").Handler;

pub const Accelerator = menu_types.Accelerator;

pub const Error = error{
    /// A key a global shortcut cannot use, or no key at all.
    UnsupportedKey,
    /// Another app has it, or the system refused it.
    Unavailable,
    /// The system has no global shortcuts (Wayland without the portal, headless).
    Unsupported,
} || std.mem.Allocator.Error;

pub const Entry = struct {
    id: u32,
    accelerator: Accelerator,
    handler: Handler(void),
    /// The platform's handle of the registration.
    native: usize = 0,
};

/// The app's registered shortcuts.
pub const Registry = struct {
    list: std.ArrayList(Entry) = .empty,
    next: u32 = 1,

    pub fn deinit(r: *Registry, gpa: std.mem.Allocator) void {
        r.list.deinit(gpa);
    }

    pub fn add(r: *Registry, gpa: std.mem.Allocator, a: Accelerator, h: Handler(void)) !*Entry {
        if (a.key == 0) return error.UnsupportedKey;
        try r.list.append(gpa, .{ .id = r.next, .accelerator = a, .handler = h });
        r.next += 1;
        return &r.list.items[r.list.items.len - 1];
    }

    pub fn find(r: *Registry, id: u32) ?*Entry {
        for (r.list.items) |*e| if (e.id == id) return e;
        return null;
    }

    /// Forgets `id`; its entry, for the platform to unregister.
    pub fn remove(r: *Registry, id: u32) ?Entry {
        for (r.list.items, 0..) |e, i| if (e.id == id) return r.list.orderedRemove(i);
        return null;
    }

    /// The shortcut `id` was pressed.
    pub fn fire(r: *Registry, id: u32) void {
        const e = r.find(id) orelse return;
        e.handler.call({});
    }
};

pub fn has(a: Accelerator, m: usize) bool {
    return a.mods & m != 0;
}

/// A key as a Windows virtual key code.
pub fn windowsKey(key: u21) ?u32 {
    return switch (key) {
        'a'...'z' => key - 'a' + 'A',
        '0'...'9' => key,
        ' ' => 0x20,
        '\r' => 0x0D,
        '\t' => 0x09,
        0x1b => 0x1B,
        0x08 => 0x08,
        0x7f => 0x2E,
        0xF700 => 0x26,
        0xF701 => 0x28,
        0xF702 => 0x25,
        0xF703 => 0x27,
        0xF729 => 0x24,
        0xF72B => 0x23,
        0xF72C => 0x21,
        0xF72D => 0x22,
        0xF704...0xF704 + 23 => 0x70 + (key - 0xF704),
        ',' => 0xBC,
        '.' => 0xBE,
        '/' => 0xBF,
        ';' => 0xBA,
        '\'' => 0xDE,
        '[' => 0xDB,
        ']' => 0xDD,
        '\\' => 0xDC,
        '-' => 0xBD,
        '=', '+' => 0xBB,
        '`' => 0xC0,
        else => null,
    };
}

/// RegisterHotKey's modifiers: Command or Control is Control off macOS.
pub fn windowsMods(a: Accelerator) u32 {
    var m: u32 = 0x4000; // MOD_NOREPEAT: one press, not the key's repeats
    if (has(a, menu_types.mod_alt)) m |= 0x1;
    if (has(a, menu_types.mod_ctrl) or has(a, menu_types.mod_cmd)) m |= 0x2;
    if (has(a, menu_types.mod_shift)) m |= 0x4;
    return m;
}

/// A key as an X11 keysym's name (XStringToKeysym), NUL-terminated.
pub fn x11Key(key: u21, buf: *[16]u8) ?[*:0]const u8 {
    const named: ?[]const u8 = switch (key) {
        ' ' => "space",
        '\r' => "Return",
        '\t' => "Tab",
        0x1b => "Escape",
        0x08 => "BackSpace",
        0x7f => "Delete",
        0xF700 => "Up",
        0xF701 => "Down",
        0xF702 => "Left",
        0xF703 => "Right",
        0xF729 => "Home",
        0xF72B => "End",
        0xF72C => "Prior",
        0xF72D => "Next",
        ',' => "comma",
        '.' => "period",
        '/' => "slash",
        ';' => "semicolon",
        '\'' => "apostrophe",
        '[' => "bracketleft",
        ']' => "bracketright",
        '\\' => "backslash",
        '-' => "minus",
        '=' => "equal",
        '+' => "plus",
        '`' => "grave",
        else => null,
    };
    const s: []const u8 = named orelse switch (key) {
        'a'...'z', '0'...'9' => buf[0..1],
        0xF704...0xF704 + 23 => std.fmt.bufPrint(buf[0..15], "F{d}", .{key - 0xF704 + 1}) catch return null,
        else => return null,
    };
    if (@intFromPtr(s.ptr) == @intFromPtr(buf)) {
        if (s.len == 1) buf[0] = @intCast(key);
    } else @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf);
}

/// X11's modifier masks: Shift, Control, Mod1 (Alt), Mod4 (Super).
pub fn x11Mods(a: Accelerator) u32 {
    var m: u32 = 0;
    if (has(a, menu_types.mod_shift)) m |= 1 << 0;
    if (has(a, menu_types.mod_ctrl) or has(a, menu_types.mod_cmd)) m |= 1 << 2;
    if (has(a, menu_types.mod_alt)) m |= 1 << 3;
    return m;
}

/// A key as a macOS virtual key code (ANSI layout).
pub fn macKey(key: u21) ?u32 {
    const letters = "asdfhgzxcv?bqweryt123465=97-80]ou[ip?lj'k;\\,/nm.";
    if (key < 128) if (std.mem.indexOfScalar(u8, letters, @intCast(key))) |i| if (key != '?') return @intCast(i);
    return switch (key) {
        '`' => 0x32,
        '\r' => 0x24,
        '\t' => 0x30,
        ' ' => 0x31,
        0x08 => 0x33,
        0x1b => 0x35,
        0x7f => 0x75,
        0xF729 => 0x73,
        0xF72B => 0x77,
        0xF72C => 0x74,
        0xF72D => 0x79,
        0xF702 => 0x7B,
        0xF703 => 0x7C,
        0xF701 => 0x7D,
        0xF700 => 0x7E,
        0xF704...0xF704 + 11 => ([_]u32{ 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F })[key - 0xF704],
        else => null,
    };
}

/// Carbon's modifiers: cmdKey, shiftKey, optionKey, controlKey.
pub fn macMods(a: Accelerator) u32 {
    var m: u32 = 0;
    if (has(a, menu_types.mod_cmd)) m |= 1 << 8;
    if (has(a, menu_types.mod_shift)) m |= 1 << 9;
    if (has(a, menu_types.mod_alt)) m |= 1 << 11;
    if (has(a, menu_types.mod_ctrl)) m |= 1 << 12;
    return m;
}

test "global shortcuts in each system's terms" {
    const t = std.testing;
    const a = menu_types.parseAccelerator("Alt+Shift+Space");
    try t.expectEqual(@as(?u32, 0x20), windowsKey(a.key));
    try t.expectEqual(@as(u32, 0x4005), windowsMods(a));
    try t.expectEqual(@as(?u32, 'K'), windowsKey(menu_types.parseAccelerator("CmdOrCtrl+K").key));
    try t.expectEqual(@as(u32, 0x4002), windowsMods(menu_types.parseAccelerator("CmdOrCtrl+K")));
    try t.expectEqual(@as(?u32, 0x74), windowsKey(menu_types.parseAccelerator("F5").key));
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("space", std.mem.span(x11Key(' ', &buf).?));
    try t.expectEqualStrings("k", std.mem.span(x11Key('k', &buf).?));
    try t.expectEqualStrings("F12", std.mem.span(x11Key(0xF704 + 11, &buf).?));
    try t.expectEqual(@as(u32, 1 | 8), x11Mods(a));
    try t.expectEqual(@as(?u32, 0x31), macKey(' '));
    try t.expectEqual(@as(?u32, 0x28), macKey('k'));
    try t.expectEqual(@as(?u32, 0x00), macKey('a'));
    try t.expectEqual(@as(?u32, 0x2E), macKey('m'));
    try t.expectEqual(@as(?u32, 0x60), macKey(0xF704 + 4));
    try t.expectEqual(@as(u32, (1 << 9) | (1 << 11)), macMods(a));
    try t.expect(windowsKey(0x1F600) == null);
}

test "the registry calls a shortcut's handler by its id" {
    const gpa = std.testing.allocator;
    const S = struct {
        n: usize = 0,
        fn hit(s: *@This(), _: void) void {
            s.n += 1;
        }
    };
    var s: S = .{};
    var r: Registry = .{};
    defer r.deinit(gpa);
    const e = try r.add(gpa, menu_types.parseAccelerator("Alt+Space"), Handler(void).of(&s, S.hit));
    const id = e.id;
    r.fire(id);
    r.fire(id + 7);
    try std.testing.expectEqual(@as(usize, 1), s.n);
    try std.testing.expect(r.remove(id) != null);
    r.fire(id);
    try std.testing.expectEqual(@as(usize, 1), s.n);
    try std.testing.expectError(error.UnsupportedKey, r.add(gpa, menu_types.parseAccelerator("Alt"), Handler(void).of(&s, S.hit)));
}
