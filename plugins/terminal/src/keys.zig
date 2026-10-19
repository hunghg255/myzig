//! myzig's keys as Ghostty's: a key combination the window offers
//! (`ui.Shortcut`), a named key (`ui.Context`'s `input.key`), or a typed
//! character, as the key event the encoder turns into what the program
//! reads (`encode.KeyEncoder`).
const std = @import("std");
const ui = @import("myzig").ui;
const encode = @import("encode.zig");
const Key = encode.Key;
const KeyEvent = encode.KeyEvent;

pub const UiKey = @typeInfo(@FieldType(@FieldType(ui.Context, "input"), "key")).optional.child;

/// The key of a named key, and the character it types (0 for none).
pub fn named(k: UiKey) struct { Key, u21 } {
    return switch (k) {
        .backspace => .{ .backspace, 0 },
        .delete => .{ .delete, 0 },
        .left => .{ .arrow_left, 0 },
        .right => .{ .arrow_right, 0 },
        .up => .{ .arrow_up, 0 },
        .down => .{ .arrow_down, 0 },
        .home => .{ .home, 0 },
        .end => .{ .end, 0 },
        .enter => .{ .enter, '\r' },
        .tab => .{ .tab, '\t' },
        .escape => .{ .escape, 0 },
        .page_up => .{ .page_up, 0 },
        .page_down => .{ .page_down, 0 },
        else => .{ Key.function(@intCast(@intFromEnum(k) - @intFromEnum(UiKey.f1) + 1)), 0 },
    };
}

/// The key that types ASCII character `ch` on a US keyboard, the
/// character it types without modifiers, and whether it takes Shift.
pub fn ofChar(ch: u21) ?struct { Key, u21, bool } {
    if (ch >= 0x80) return null;
    const c: u8 = @intCast(ch);
    return switch (c) {
        'a'...'z' => .{ Key.letter(c), c, false },
        'A'...'Z' => .{ Key.letter(c + 32), c + 32, true },
        '0'...'9' => .{ Key.digit(c), c, false },
        ' ' => .{ .space, ' ', false },
        '-' => .{ .minus, '-', false },
        '=' => .{ .equal, '=', false },
        ',' => .{ .comma, ',', false },
        '.' => .{ .period, '.', false },
        '/' => .{ .slash, '/', false },
        ';' => .{ .semicolon, ';', false },
        '\'' => .{ .quote, '\'', false },
        '[' => .{ .bracket_left, '[', false },
        ']' => .{ .bracket_right, ']', false },
        '\\' => .{ .backslash, '\\', false },
        '`' => .{ .backquote, '`', false },
        else => {
            // The symbols Shift types.
            const shifted = "!@#$%^&*()_+<>?:\"{}|~";
            const base = "1234567890-=,./;'[]\\`";
            const i = std.mem.indexOfScalar(u8, shifted, c) orelse return null;
            const k = ofChar(base[i]).?;
            return .{ k[0], k[1], true };
        },
    };
}

/// A key combination as a key event; null for one that is not a key the
/// terminal knows. `text` is a buffer for the event's text.
pub fn fromShortcut(s: ui.Shortcut, text: *[4]u8) ?KeyEvent {
    const S = ui.Shortcut;
    const mods: encode.Mods = .{ .shift = s.shift, .ctrl = s.ctrl, .alt = s.alt, .super = s.cmd };
    const special: ?UiKey = switch (s.key) {
        S.up => .up,
        S.down => .down,
        S.left => .left,
        S.right => .right,
        S.escape => .escape,
        S.tab => .tab,
        S.enter => .enter,
        else => null,
    };
    if (special) |k| {
        const nk = named(k);
        return .{ .key = nk[0], .mods = mods, .unshifted = nk[1] };
    }
    const kc = ofChar(s.key) orelse return null;
    var ev: KeyEvent = .{ .key = kc[0], .mods = mods, .unshifted = kc[1] };
    // Alt types the character itself (the encoder adds ESC); Control's
    // characters are the encoder's to make.
    if (!s.ctrl) {
        var ch: u21 = kc[1];
        if (s.shift and ch >= 'a' and ch <= 'z') ch -= 32;
        const n = std.unicode.utf8Encode(ch, text) catch return ev;
        ev.text = text[0..n];
        if (s.shift) ev.consumed = .{ .shift = true };
    }
    return ev;
}

/// A named key with modifiers as a key event.
pub fn fromKey(k: UiKey, mods: encode.Mods) KeyEvent {
    const nk = named(k);
    return .{ .key = nk[0], .mods = mods, .unshifted = nk[1], .text = switch (k) {
        .enter => if (mods.ctrl or mods.alt) "" else "\r",
        .tab => if (mods.ctrl or mods.alt or mods.shift) "" else "\t",
        else => "",
    } };
}

/// A typed character (UTF-8 in `text`) as a key event, by the key of a US
/// keyboard that types it; unidentified for others, which go as text.
pub fn fromChar(cp: u21, text: []const u8) KeyEvent {
    if (ofChar(cp)) |k| {
        const shift: encode.Mods = .{ .shift = k[2] };
        return .{ .key = k[0], .mods = shift, .consumed = shift, .text = text, .unshifted = k[1] };
    }
    return .{ .key = .unidentified, .text = text, .unshifted = cp };
}

test "keys of characters" {
    try std.testing.expectEqual(Key.letter('q'), ofChar('Q').?[0]);
    try std.testing.expect(ofChar('Q').?[2]);
    try std.testing.expectEqual(Key.digit('1'), ofChar('!').?[0]);
    try std.testing.expectEqual(Key.backquote, ofChar('~').?[0]);
    try std.testing.expect(ofChar(0xe9) == null);
    try std.testing.expectEqual(Key.function(5), named(.f5)[0]);
    var buf: [4]u8 = undefined;
    const alt = fromShortcut(.{ .key = 'x', .alt = true }, &buf).?;
    try std.testing.expectEqualStrings("x", alt.text);
    const ctrl = fromShortcut(.{ .key = 'c', .ctrl = true }, &buf).?;
    try std.testing.expectEqualStrings("", ctrl.text);
    try std.testing.expectEqual(Key.letter('c'), ctrl.key);
}
