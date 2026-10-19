//! Where a key is on the keyboard, whatever it types: the physical key
//! codes views that follow keys (`Context.wants_keys`) get alongside the
//! character (`Input.key_down_code`), named after the US layout as the
//! web's `KeyboardEvent.code` names them. WASD stays where it is on an
//! AZERTY keyboard, where the characters are ZQSD.
//!
//! Each platform's own codes map here: Windows' scan codes (set 1, as in
//! WM_KEYDOWN's lParam), Linux's evdev codes (X11's and GDK's hardware
//! keycodes less 8), macOS's virtual key codes (kVK_*, which are
//! positions), and the web's `code` names.
const std = @import("std");

pub const KeyCode = enum(u8) {
    unknown,
    // zig fmt: off
    a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z,
    digit0, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    escape, tab, caps_lock, space, enter, backspace, delete, insert,
    home, end, page_up, page_down, arrow_up, arrow_down, arrow_left, arrow_right,
    shift_left, shift_right, control_left, control_right, alt_left, alt_right, meta_left, meta_right,
    minus, equal, bracket_left, bracket_right, backslash, semicolon, quote, backquote, comma, period, slash,
    numpad0, numpad1, numpad2, numpad3, numpad4, numpad5, numpad6, numpad7, numpad8, numpad9,
    numpad_add, numpad_subtract, numpad_multiply, numpad_divide, numpad_decimal, numpad_enter,
    // zig fmt: on

    /// The web's name for it (`KeyboardEvent.code`): "KeyW", "ArrowUp".
    pub fn webName(k: KeyCode) []const u8 {
        return web_names[@intFromEnum(k)];
    }
};

/// Set 1 scan codes 0 to 88, which evdev's codes follow too.
const base = blk: {
    var t: [89]KeyCode = @splat(.unknown);
    const K = KeyCode;
    const rows = .{
        .{ 1, .{K.escape} },
        .{ 2, .{ K.digit1, K.digit2, K.digit3, K.digit4, K.digit5, K.digit6, K.digit7, K.digit8, K.digit9, K.digit0, K.minus, K.equal, K.backspace, K.tab } },
        .{ 16, .{ K.q, K.w, K.e, K.r, K.t, K.y, K.u, K.i, K.o, K.p, K.bracket_left, K.bracket_right, K.enter, K.control_left } },
        .{ 30, .{ K.a, K.s, K.d, K.f, K.g, K.h, K.j, K.k, K.l, K.semicolon, K.quote, K.backquote, K.shift_left, K.backslash } },
        .{ 44, .{ K.z, K.x, K.c, K.v, K.b, K.n, K.m, K.comma, K.period, K.slash, K.shift_right, K.numpad_multiply, K.alt_left, K.space, K.caps_lock } },
        .{ 59, .{ K.f1, K.f2, K.f3, K.f4, K.f5, K.f6, K.f7, K.f8, K.f9, K.f10 } },
        .{ 71, .{ K.numpad7, K.numpad8, K.numpad9, K.numpad_subtract, K.numpad4, K.numpad5, K.numpad6, K.numpad_add, K.numpad1, K.numpad2, K.numpad3, K.numpad0, K.numpad_decimal } },
        .{ 87, .{ K.f11, K.f12 } },
    };
    for (rows) |row| for (row[1], 0..) |key, i| {
        t[row[0] + i] = key;
    };
    break :blk t;
};

/// A Windows scan code (bits 16 to 23 of WM_KEYDOWN's lParam), `extended`
/// its bit 24 (the E0 prefix: the arrows, the right modifiers).
pub fn fromScancode(scan: u8, extended: bool) KeyCode {
    if (extended) return switch (scan) {
        0x1c => .numpad_enter,
        0x1d => .control_right,
        0x35 => .numpad_divide,
        0x38 => .alt_right,
        0x47 => .home,
        0x48 => .arrow_up,
        0x49 => .page_up,
        0x4b => .arrow_left,
        0x4d => .arrow_right,
        0x4f => .end,
        0x50 => .arrow_down,
        0x51 => .page_down,
        0x52 => .insert,
        0x53 => .delete,
        0x5b => .meta_left,
        0x5c => .meta_right,
        else => .unknown,
    };
    return if (scan < base.len) base[scan] else .unknown;
}

/// A Windows key message's lParam.
pub fn fromLparam(lp: isize) KeyCode {
    const v: usize = @bitCast(lp);
    return fromScancode(@truncate(v >> 16), (v >> 24) & 1 != 0);
}

/// A Linux evdev code (X11's and GDK's hardware keycode less 8).
pub fn fromEvdev(code: u16) KeyCode {
    if (code < base.len) return base[code];
    return switch (code) {
        96 => .numpad_enter,
        97 => .control_right,
        98 => .numpad_divide,
        100 => .alt_right,
        102 => .home,
        103 => .arrow_up,
        104 => .page_up,
        105 => .arrow_left,
        106 => .arrow_right,
        107 => .end,
        108 => .arrow_down,
        109 => .page_down,
        110 => .insert,
        111 => .delete,
        125 => .meta_left,
        126 => .meta_right,
        else => .unknown,
    };
}

/// A macOS virtual key code (NSEvent's keyCode, kVK_*).
pub fn fromMac(code: u16) KeyCode {
    const K = KeyCode;
    const low = [_]K{
        .a, .s, .d, .f, .h, .g, .z, .x, .c, .v, .unknown, .b, .q, .w, .e, .r, // 0x00
        .y, .t, .digit1, .digit2, .digit3, .digit4, .digit6, .digit5, .equal, .digit9, .digit7, .minus, .digit8, .digit0, .bracket_right, .o, // 0x10
        .u, .bracket_left, .i, .p, .enter, .l, .j, .quote, .k, .semicolon, .backslash, .comma, .slash, .n, .m, .period, // 0x20
        .tab, .space, .backquote, .backspace, .unknown, .escape, .meta_right, .meta_left, .shift_left, .caps_lock, .alt_left, .control_left, .shift_right, .alt_right, .control_right, .unknown, // 0x30
        .unknown, .numpad_decimal, .unknown, .numpad_multiply, .unknown, .numpad_add, .unknown, .unknown, .unknown, .unknown, .unknown, .numpad_divide, .numpad_enter, .unknown, .numpad_subtract, .unknown, // 0x40
        .unknown, .unknown, .numpad0, .numpad1, .numpad2, .numpad3, .numpad4, .numpad5, .numpad6, .numpad7, .unknown, .numpad8, .numpad9, .unknown, .unknown, .unknown, // 0x50
        .f5, .f6, .f7, .f3, .f8, .f9, .unknown, .f11, .unknown, .unknown, .unknown, .unknown, .unknown, .f10, .unknown, .f12, // 0x60
        .unknown, .unknown, .insert, .home, .page_up, .delete, .f4, .end, .f2, .page_down, .f1, .arrow_left, .arrow_right, .arrow_down, .arrow_up, .unknown, // 0x70
    };
    return if (code < low.len) low[code] else .unknown;
}

const web_names = blk: {
    @setEvalBranchQuota(20_000);
    const fields = @typeInfo(KeyCode).@"enum".field_names;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| names[i] = webNameOf(f);
    break :blk names;
};

fn webNameOf(comptime field: []const u8) []const u8 {
    if (std.mem.eql(u8, field, "unknown")) return "";
    if (field.len == 1) return "Key" ++ [_]u8{std.ascii.toUpper(field[0])};
    if (field[0] == 'f' and std.ascii.isDigit(field[1])) return "F" ++ field[1..];
    // snake_case to PascalCase: arrow_up is ArrowUp, digit1 is Digit1.
    var out: []const u8 = "";
    var up = true;
    for (field) |ch| {
        if (ch == '_') {
            up = true;
            continue;
        }
        out = out ++ [_]u8{if (up) std.ascii.toUpper(ch) else ch};
        up = false;
    }
    return out;
}

/// A web `KeyboardEvent.code`.
pub fn fromWeb(name: []const u8) KeyCode {
    @setEvalBranchQuota(20_000);
    inline for (@typeInfo(KeyCode).@"enum".field_names, 0..) |_, i| {
        if (i > 0 and std.mem.eql(u8, web_names[i], name)) return @enumFromInt(i);
    }
    // Older names for the meta keys.
    if (std.mem.eql(u8, name, "OSLeft")) return .meta_left;
    if (std.mem.eql(u8, name, "OSRight")) return .meta_right;
    return .unknown;
}

test "physical key codes: WASD where they are, on every platform's codes" {
    // Windows' scan codes and Linux's evdev codes.
    try std.testing.expectEqual(KeyCode.w, fromScancode(0x11, false));
    try std.testing.expectEqual(KeyCode.a, fromScancode(0x1e, false));
    try std.testing.expectEqual(KeyCode.s, fromEvdev(31));
    try std.testing.expectEqual(KeyCode.d, fromEvdev(32));
    try std.testing.expectEqual(KeyCode.space, fromEvdev(57));
    try std.testing.expectEqual(KeyCode.f12, fromScancode(0x58, false));
    // The E0 prefix: the arrows, not the numpad's.
    try std.testing.expectEqual(KeyCode.arrow_up, fromScancode(0x48, true));
    try std.testing.expectEqual(KeyCode.numpad8, fromScancode(0x48, false));
    try std.testing.expectEqual(KeyCode.arrow_up, fromEvdev(103));
    try std.testing.expectEqual(KeyCode.control_right, fromEvdev(97));
    // lParam: repeat count 1, scan code 0x11 (W), extended 0.
    try std.testing.expectEqual(KeyCode.w, fromLparam(0x0011_0001));
    try std.testing.expectEqual(KeyCode.arrow_left, fromLparam(0x014b_0001));
    // macOS's virtual key codes.
    try std.testing.expectEqual(KeyCode.w, fromMac(0x0d));
    try std.testing.expectEqual(KeyCode.a, fromMac(0x00));
    try std.testing.expectEqual(KeyCode.digit5, fromMac(0x17));
    try std.testing.expectEqual(KeyCode.arrow_down, fromMac(0x7d));
    try std.testing.expectEqual(KeyCode.f1, fromMac(0x7a));
    // The web's names, both ways.
    try std.testing.expectEqualStrings("KeyW", KeyCode.w.webName());
    try std.testing.expectEqualStrings("ArrowUp", KeyCode.arrow_up.webName());
    try std.testing.expectEqualStrings("Digit7", KeyCode.digit7.webName());
    try std.testing.expectEqualStrings("F11", KeyCode.f11.webName());
    try std.testing.expectEqualStrings("NumpadEnter", KeyCode.numpad_enter.webName());
    @setEvalBranchQuota(20_000);
    inline for (@typeInfo(KeyCode).@"enum".field_names, 0..) |_, i| {
        if (i > 0) try std.testing.expectEqual(@as(KeyCode, @enumFromInt(i)), fromWeb(web_names[i]));
    }
    try std.testing.expectEqual(KeyCode.meta_left, fromWeb("OSLeft"));
    try std.testing.expectEqual(KeyCode.unknown, fromWeb("Lang1"));
    // Every set 1 code that is a key evdev agrees on.
    for (1..base.len) |c| try std.testing.expectEqual(fromScancode(@intCast(c), false), fromEvdev(@intCast(c)));
}
