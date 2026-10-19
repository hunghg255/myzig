//! The browser's input events, as the host hands them over: pointer,
//! wheel, keys (by `KeyboardEvent.key`), the text area's typed, composed
//! and pasted text. Each runs a frame when it changes something and tells
//! the host whether the view took it (the browser's default is then
//! prevented).
const std = @import("std");
const ui = @import("../ui/ui.zig");
const ctx_mod = @import("../ui/context.zig");
const Surface = @import("surface.zig").Surface;

/// Modifier bits, as the host packs them (Command is Control on a Mac:
/// views' shortcuts take a browser for a system other than macOS).
pub const shift_bit = 1;
pub const ctrl_bit = 2;
pub const alt_bit = 4;

pub const Pointer = enum(u32) { move = 0, down = 1, up = 2, leave = 3 };

fn mods(s: *Surface, m: u32) void {
    s.ctx.input.shift = m & shift_bit != 0;
    s.ctx.input.ctrl = m & ctrl_bit != 0;
    s.ctx.input.cmd = false;
}

/// A pointer event at (`x`, `y`) in CSS pixels of the canvas: `button` 0
/// the primary, 2 the secondary; `clicks` the browser's count (`detail`).
pub fn pointer(s: *Surface, kind: Pointer, x: f32, y: f32, button: u32, clicks: u32, m: u32) bool {
    const c = &s.ctx;
    mods(s, m);
    if (kind == .leave) {
        c.input.mouse = .{ .x = -1e6, .y = -1e6 };
        if (c.hot != 0) {
            c.updateHot();
            s.frame();
        }
        return false;
    }
    c.input.mouse = .{ .x = x, .y = y };
    switch (kind) {
        .move => {
            const before = c.hot;
            c.updateHot();
            if (c.input.down or c.hot != before or c.wants_moves) {
                s.frame();
            } else if (c.pointerOverText() != c.cursor_text) {
                c.cursor_text = !c.cursor_text;
                s.frame();
            }
            return false;
        },
        .down => {
            c.updateHot();
            if (button == 2) {
                c.input.right_pressed = true;
            } else if (button == 0) {
                c.input.click_count = @max(1, clicks);
                c.pointerDown();
            } else return false;
            s.frame();
            return true;
        },
        .up => {
            if (button != 0) return false;
            c.updateHot();
            c.pointerUp();
            s.frame();
            return true;
        },
        .leave => unreachable,
    }
}

/// The wheel, `dy` CSS pixels (down positive, as the browser's deltaY).
pub fn wheel(s: *Surface, x: f32, y: f32, dy: f32, m: u32) bool {
    const c = &s.ctx;
    mods(s, m);
    c.input.mouse = .{ .x = x, .y = y };
    const delta = -dy;
    if (c.applyScroll(delta)) {
        s.frame();
        c.updateHot();
        return true;
    }
    if (c.wants_wheel) {
        c.input.scroll = .{ .y = delta };
        s.frame();
        return true;
    }
    return false;
}

/// `KeyboardEvent.key` for the keys that are not text.
fn keyOf(name: []const u8) ?ctx_mod.Key {
    const table = .{
        .{ "Backspace", .backspace }, .{ "Delete", .delete },    .{ "ArrowLeft", .left },
        .{ "ArrowUp", .up },          .{ "ArrowRight", .right }, .{ "ArrowDown", .down },
        .{ "Home", .home },           .{ "End", .end },          .{ "Enter", .enter },
        .{ "Tab", .tab },             .{ "Escape", .escape },    .{ "PageUp", .page_up },
        .{ "PageDown", .page_down },
    };
    inline for (table) |e| if (std.mem.eql(u8, name, e[0])) return e[1];
    if (name.len >= 2 and name.len <= 3 and name[0] == 'F') {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (n >= 1 and n <= 12) return @enumFromInt(@intFromEnum(ctx_mod.Key.f1) + n - 1);
    }
    return null;
}

/// A key as views see it (`Input.key_down`): characters lowercase, other
/// keys as `Shortcut.up` and the like; 0 for the rest.
fn codeOf(name: []const u8) u21 {
    const S = ui.Shortcut;
    const table = .{
        .{ "ArrowUp", S.up },   .{ "ArrowDown", S.down }, .{ "ArrowLeft", S.left }, .{ "ArrowRight", S.right },
        .{ "Tab", S.tab },      .{ "Escape", S.escape },  .{ "Enter", S.enter },    .{ "Shift", 0xF710 },
        .{ "Control", 0xF711 }, .{ "Alt", 0xF712 },
    };
    inline for (table) |e| if (std.mem.eql(u8, name, e[0])) return e[1];
    const view = std.unicode.Utf8View.init(name) catch return 0;
    var it = view.iterator();
    const cp = it.nextCodepoint() orelse return 0;
    if (it.nextCodepoint() != null) return 0;
    return if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
}

/// The host's `KeyboardEvent.key`, then a NUL and its `code` (where the key
/// is) when it has one.
fn split(key_and_code: []const u8) struct { []const u8, ?@import("../ui/keycode.zig").KeyCode } {
    const nul = std.mem.indexOfScalar(u8, key_and_code, 0) orelse return .{ key_and_code, null };
    return .{ key_and_code[0..nul], @import("../ui/keycode.zig").fromWeb(key_and_code[nul + 1 ..]) };
}

/// A key went down: true when it was taken. Text the key types is not
/// taken here: it arrives through the text area (`typed`), as an input
/// method or a dead key makes it.
pub fn keyDown(s: *Surface, key_and_code: []const u8, m: u32, repeat: bool) bool {
    const c = &s.ctx;
    const in = &c.input;
    mods(s, m);
    const ctrl = m & ctrl_bit != 0;
    const alt = m & alt_bit != 0;
    const name, const physical = split(key_and_code);
    const code = codeOf(name);
    if (c.wants_keys and !repeat and code != 0) {
        in.key_down = code;
        in.key_down_code = physical;
    }
    const taken = offer(s, name, code, ctrl, alt);
    if (in.key_down != null) s.frame();
    return taken;
}

fn offer(s: *Surface, name: []const u8, code: u21, ctrl: bool, alt: bool) bool {
    const S = ui.Shortcut;
    const in = &s.ctx.input;
    const key = keyOf(name);
    const special = key != null and (code == S.up or code == S.down or code == S.tab or code == S.escape);
    if (code != 0 and (ctrl or alt or special)) {
        const sc: S = .{ .key = code, .ctrl = ctrl, .alt = alt, .shift = in.shift };
        if (s.window.app.accelerator(sc)) return true;
        if (ctrl and s.ctx.focused_text != null) switch (code) {
            // The browser pastes into the text area (`pasted`).
            'v' => return false,
            'c', 'x', 'a' => {
                const cmd: ctx_mod.Command = switch (code) {
                    'c' => .copy,
                    'x' => .cut,
                    else => .select_all,
                };
                runOps(s, &.{.{ .command = cmd }});
                return true;
            },
            else => {},
        };
        s.ctx.shortcut_taken = false;
        in.shortcut = sc;
        s.frame();
        in.shortcut = null;
        if (s.ctx.shortcut_taken) return true;
    }
    if (key) |k| {
        in.key = k;
        s.frame();
        return true;
    }
    // Ctrl with a character the view did not take: the browser's.
    return false;
}

pub fn keyUp(s: *Surface, key_and_code: []const u8, m: u32) bool {
    if (!s.ctx.wants_keys) return false;
    mods(s, m);
    const name, const physical = split(key_and_code);
    const code = codeOf(name);
    if (code == 0) return false;
    s.ctx.input.key_up = code;
    s.ctx.input.key_up_code = physical;
    s.frame();
    return true;
}

fn runOps(s: *Surface, ops: []const ctx_mod.TextOp) void {
    s.ctx.input.ops = ops;
    s.frame();
    s.ctx.input.ops = &.{};
}

/// Text typed into the text area (a key, a dead key's result, an input
/// method's commit outside composition).
pub fn typed(s: *Surface, t: []const u8) void {
    if (t.len == 0) return;
    if (s.ctx.focused_text == null) {
        // Characters for views that read them (a terminal).
        s.ctx.input.chars = t;
        s.frame();
        return;
    }
    // Newlines are Enter's: a field takes them as keys.
    for (t) |ch| if (ch < 0x20 or ch == 0x7f) return;
    s.ctx.input.chars = t;
    s.frame();
}

/// An input method's composition so far (empty: none).
pub fn composing(s: *Surface, t: []const u8) void {
    if (t.len == 0) return runOps(s, &.{.unmark});
    runOps(s, &.{.{ .set_marked = .{ .text = t, .sel_start = t.len, .sel_len = 0 } }});
}

/// The composition ended with `t`, which replaces it.
pub fn committed(s: *Surface, t: []const u8) void {
    if (t.len == 0) return runOps(s, &.{.unmark});
    runOps(s, &.{.{ .insert = t }});
}

/// The browser's paste, its text (newlines become spaces in a field).
pub fn pasted(s: *Surface, t: []u8) void {
    if (s.ctx.focused_text == null) {
        s.ctx.input.chars = t;
        s.frame();
        return;
    }
    for (t) |*ch| if (ch.* == '\n' or ch.* == '\r') {
        ch.* = ' ';
    };
    runOps(s, &.{.{ .insert = t }});
}

test "the browser's key names" {
    const S = ui.Shortcut;
    try std.testing.expectEqual(ctx_mod.Key.up, keyOf("ArrowUp").?);
    try std.testing.expectEqual(ctx_mod.Key.f12, keyOf("F12").?);
    try std.testing.expectEqual(ctx_mod.Key.backspace, keyOf("Backspace").?);
    try std.testing.expect(keyOf("a") == null and keyOf("F13") == null and keyOf("Fn") == null);
    try std.testing.expectEqual(@as(u21, 'a'), codeOf("A"));
    try std.testing.expectEqual(S.enter, codeOf("Enter"));
    try std.testing.expectEqual(@as(u21, 0xe9), codeOf("é"));
    try std.testing.expectEqual(@as(u21, 0), codeOf("Dead"));
}
