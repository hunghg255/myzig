//! What the program reads for input, as its modes ask: keys (legacy
//! sequences, xterm's modifyOtherKeys or the Kitty keyboard protocol),
//! pointer reports, focus reports and pastes, encoded by libghostty-vt.
const std = @import("std");
const g = @import("ghostty.zig");
const vt = @import("vt.zig");

/// Modifier keys (GhosttyMods).
pub const Mods = packed struct(u16) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    _: u12 = 0,
};

/// A GhosttyKey: a key by its place on the keyboard, as the W3C's
/// KeyboardEvent.code names them.
pub const Key = enum(c_int) {
    unidentified = 0,
    backquote = 1,
    backslash = 2,
    bracket_left = 3,
    bracket_right = 4,
    comma = 5,
    digit_0 = 6,
    equal = 16,
    a = 20,
    minus = 46,
    period = 47,
    quote = 48,
    semicolon = 49,
    slash = 50,
    backspace = 53,
    enter = 58,
    space = 63,
    tab = 64,
    delete = 68,
    end = 69,
    home = 71,
    insert = 72,
    page_down = 73,
    page_up = 74,
    arrow_down = 75,
    arrow_left = 76,
    arrow_right = 77,
    arrow_up = 78,
    escape = 120,
    f1 = 121,
    _,

    /// The key of letter `l` ('a' to 'z').
    pub fn letter(l: u8) Key {
        return @enumFromInt(@intFromEnum(Key.a) + @as(c_int, l - 'a'));
    }

    /// The key of digit `d` ('0' to '9').
    pub fn digit(d: u8) Key {
        return @enumFromInt(@intFromEnum(Key.digit_0) + @as(c_int, d - '0'));
    }

    /// The function key F`n` (1 to 12).
    pub fn function(n: u8) Key {
        return @enumFromInt(@intFromEnum(Key.f1) + @as(c_int, n - 1));
    }
};

pub const Action = enum(c_int) { release = 0, press = 1, repeat = 2 };

/// A key to encode.
pub const KeyEvent = struct {
    action: Action = .press,
    key: Key,
    mods: Mods = .{},
    /// The modifiers that made `text`, as Shift an "A".
    consumed: Mods = .{},
    /// What the key types, without what Ctrl or Alt change; empty for keys
    /// that type nothing.
    text: []const u8 = "",
    /// The character the key types without modifiers.
    unshifted: u21 = 0,
};

pub const KeyEncoder = struct {
    h: *g.KeyEncoder,
    ev: *g.KeyEvent,
    buf: [128]u8 = undefined,

    pub fn init() vt.Error!KeyEncoder {
        if (!g.loaded()) return error.GhosttyNotLoaded;
        var h: ?*g.KeyEncoder = null;
        if (g.api.ghostty_key_encoder_new(null, &h) != g.success) return error.GhosttyFailed;
        var ev: ?*g.KeyEvent = null;
        if (g.api.ghostty_key_event_new(null, &ev) != g.success) {
            g.api.ghostty_key_encoder_free(h.?);
            return error.GhosttyFailed;
        }
        return .{ .h = h.?, .ev = ev.? };
    }

    pub fn deinit(e: *KeyEncoder) void {
        g.api.ghostty_key_event_free(e.ev);
        g.api.ghostty_key_encoder_free(e.h);
    }

    /// Takes the terminal's modes (cursor keys, Kitty flags…), and whether
    /// Option is Alt on macOS.
    pub fn sync(e: *KeyEncoder, t: vt.Vt, option_as_alt: bool) void {
        g.api.ghostty_key_encoder_setopt_from_terminal(e.h, t.h);
        const v: i32 = @intFromBool(option_as_alt);
        g.api.ghostty_key_encoder_setopt(e.h, 6, &v);
    }

    /// The bytes the program reads for `k`, valid until the next call;
    /// empty for keys that send nothing.
    pub fn encode(e: *KeyEncoder, k: KeyEvent) []const u8 {
        g.api.ghostty_key_event_set_action(e.ev, @intFromEnum(k.action));
        g.api.ghostty_key_event_set_key(e.ev, @intFromEnum(k.key));
        g.api.ghostty_key_event_set_mods(e.ev, @bitCast(k.mods));
        g.api.ghostty_key_event_set_consumed_mods(e.ev, @bitCast(k.consumed));
        g.api.ghostty_key_event_set_composing(e.ev, false);
        g.api.ghostty_key_event_set_unshifted_codepoint(e.ev, k.unshifted);
        g.api.ghostty_key_event_set_utf8(e.ev, if (k.text.len > 0) k.text.ptr else null, k.text.len);
        defer g.api.ghostty_key_event_set_utf8(e.ev, null, 0);
        var n: usize = 0;
        if (g.api.ghostty_key_encoder_encode(e.h, e.ev, &e.buf, e.buf.len, &n) != g.success) return "";
        return e.buf[0..@min(n, e.buf.len)];
    }
};

pub const MouseAction = enum(c_int) { press = 0, release = 1, motion = 2 };

/// Buttons: 1 left, 2 right, 3 middle, 4 and 5 the wheel up and down.
pub const Button = enum(c_int) { none = 0, left = 1, right = 2, middle = 3, wheel_up = 4, wheel_down = 5, wheel_left = 6, wheel_right = 7 };

/// Encodes pointer events in the format and for the events the program
/// asked for.
pub const MouseEncoder = struct {
    h: *g.MouseEncoder,
    ev: *g.MouseEvent,
    buf: [64]u8 = undefined,

    pub fn init() vt.Error!MouseEncoder {
        if (!g.loaded()) return error.GhosttyNotLoaded;
        var h: ?*g.MouseEncoder = null;
        if (g.api.ghostty_mouse_encoder_new(null, &h) != g.success) return error.GhosttyFailed;
        var ev: ?*g.MouseEvent = null;
        if (g.api.ghostty_mouse_event_new(null, &ev) != g.success) {
            g.api.ghostty_mouse_encoder_free(h.?);
            return error.GhosttyFailed;
        }
        // Motion is reported once per cell, as xterm does.
        const v = true;
        g.api.ghostty_mouse_encoder_setopt(h.?, 4, &v);
        return .{ .h = h.?, .ev = ev.? };
    }

    pub fn deinit(m: *MouseEncoder) void {
        g.api.ghostty_mouse_event_free(m.ev);
        g.api.ghostty_mouse_encoder_free(m.h);
    }

    /// Takes the terminal's mouse modes, the screen's geometry in pixels,
    /// and whether a button is held.
    pub fn sync(m: *MouseEncoder, t: vt.Vt, size: g.MouseEncoderSize, pressed: bool) void {
        g.api.ghostty_mouse_encoder_setopt_from_terminal(m.h, t.h);
        var s = size;
        s.size = @sizeOf(g.MouseEncoderSize);
        g.api.ghostty_mouse_encoder_setopt(m.h, 2, &s);
        g.api.ghostty_mouse_encoder_setopt(m.h, 3, &pressed);
    }

    /// The bytes for a pointer event at `x`, `y` pixels, valid until the
    /// next call; empty when the program asked for no such event.
    pub fn encode(m: *MouseEncoder, action: MouseAction, button: Button, mods: Mods, x: f32, y: f32) []const u8 {
        g.api.ghostty_mouse_event_set_action(m.ev, @intFromEnum(action));
        if (button == .none) g.api.ghostty_mouse_event_clear_button(m.ev) else g.api.ghostty_mouse_event_set_button(m.ev, @intFromEnum(button));
        g.api.ghostty_mouse_event_set_mods(m.ev, @bitCast(mods));
        g.api.ghostty_mouse_event_set_position(m.ev, .{ .x = x, .y = y });
        var n: usize = 0;
        if (g.api.ghostty_mouse_encoder_encode(m.h, m.ev, &m.buf, m.buf.len, &n) != g.success) return "";
        return m.buf[0..@min(n, m.buf.len)];
    }
};

pub const MouseSize = g.MouseEncoderSize;

/// The report of the terminal gaining or losing the focus (mode 1004).
pub fn focus(gained: bool, buf: *[8]u8) []const u8 {
    var n: usize = 0;
    if (g.api.ghostty_focus_encode(@intFromBool(!gained), buf, buf.len, &n) != g.success) return "";
    return buf[0..@min(n, buf.len)];
}

/// `text` as the program reads a paste: bracketed (mode 2004), or with
/// newlines as carriage returns, without the control characters that
/// could run commands. Allocated with `gpa`.
pub fn paste(gpa: std.mem.Allocator, text: []const u8, bracketed: bool) ![]u8 {
    if (text.len == 0) return gpa.alloc(u8, 0);
    // The library may change its input in place: give it a copy.
    const data = try gpa.dupe(u8, text);
    defer gpa.free(data);
    var out = try gpa.alloc(u8, text.len + 16);
    errdefer gpa.free(out);
    var n: usize = 0;
    var r = g.api.ghostty_paste_encode(data.ptr, data.len, bracketed, out.ptr, out.len, &n);
    if (r == g.out_of_space and n > out.len) {
        @memcpy(data, text);
        out = try gpa.realloc(out, n);
        r = g.api.ghostty_paste_encode(data.ptr, data.len, bracketed, out.ptr, out.len, &n);
    }
    if (r != g.success) return error.GhosttyFailed;
    return gpa.realloc(out, n);
}

/// Whether pasting `text` cannot run a command by itself.
pub fn pasteIsSafe(text: []const u8) bool {
    return text.len == 0 or g.api.ghostty_paste_is_safe(text.ptr, text.len);
}
