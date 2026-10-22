//! What one event brings, and what text editing keeps: keys, key
//! combinations offered to the view, text operations (typing, the input
//! method, selection, clipboard), the focused field as the input method
//! asks about it, where copied text goes, a field's editing state, and the
//! pointer and keys of this event.
pub const KeyCode = @import("keycode.zig").KeyCode;
const std = @import("std");
const types = @import("types.zig");

pub const Key = enum { backspace, delete, left, right, up, down, home, end, enter, tab, escape, page_up, page_down, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12 };

/// A key with modifiers, offered to the view before text editing sees it:
/// characters lowercase, other keys as `Shortcut.up` and the like.
pub const Shortcut = struct {
    key: u21,
    cmd: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    pub const up: u21 = 0xF700;
    pub const down: u21 = 0xF701;
    pub const left: u21 = 0xF702;
    pub const right: u21 = 0xF703;
    pub const escape: u21 = 0x1b;
    pub const tab: u21 = '\t';
    pub const enter: u21 = '\r';
    pub const backspace: u21 = 0x08;
    pub const delete: u21 = 0x7f;
    /// AppKit's function key codes, as accelerators name them.
    pub const home: u21 = 0xF729;
    pub const end: u21 = 0xF72B;
    pub const page_up: u21 = 0xF72C;
    pub const page_down: u21 = 0xF72D;
    pub const f1: u21 = 0xF704;

    /// As this platform has it: Command is Control off macOS.
    pub fn native(s: Shortcut) Shortcut {
        if (@import("builtin").os.tag == .macos or !s.cmd) return s;
        var n = s;
        n.cmd = false;
        n.ctrl = true;
        return n;
    }

    /// The key `s` names when no backend offers it as a shortcut: Delete,
    /// Backspace, Home, End, Page Up and Down, Left and Right without a
    /// modifier come as keys (`Input.key`), which `Context.shortcut` matches.
    pub fn plainKey(s: Shortcut) ?Key {
        if (s.cmd or s.ctrl or s.alt or s.shift) return null;
        return switch (s.key) {
            delete => .delete,
            backspace => .backspace,
            home => .home,
            end => .end,
            page_up => .page_up,
            page_down => .page_down,
            left => .left,
            right => .right,
            else => null,
        };
    }
};

/// What text input does to the focused text, in AppKit's terms: typed or
/// pasted text, an input method's composition, and editing commands.
pub const TextOp = union(enum) {
    insert: []const u8,
    /// Text being composed (underlined), with the selection inside it.
    set_marked: struct { text: []const u8, sel_start: usize, sel_len: usize },
    unmark,
    command: Command,
};

pub const Command = enum {
    delete_backward,
    delete_forward,
    delete_word_backward,
    delete_to_line_start,
    move_left,
    move_right,
    move_word_left,
    move_word_right,
    move_line_start,
    move_line_end,
    select_left,
    select_right,
    select_word_left,
    select_word_right,
    select_line_start,
    select_line_end,
    select_all,
    // By lines, pages and the whole text: one-line fields go to an end.
    move_up,
    move_down,
    select_up,
    select_down,
    move_page_up,
    move_page_down,
    select_page_up,
    select_page_down,
    move_doc_start,
    move_doc_end,
    select_doc_start,
    select_doc_end,
    delete_word_forward,
    insert_newline,
    insert_tab,
    insert_backtab,
    cancel,
    copy,
    cut,
};

/// The focused text field as the last frame left it, for the input
/// method's questions between frames. Offsets are bytes.
pub const FocusedText = struct {
    id: u64,
    text: []const u8,
    caret: usize,
    anchor: usize,
    marked: ?[2]usize,
    /// Where the caret is drawn, in view points.
    caret_rect: types.Rect,
    /// It takes several lines: pasted newlines stay.
    multiline: bool = false,
};

/// Pasted text as a field takes it, in place: newlines (any of `\r\n`,
/// `\r`, `\n`) as `\n` for one of several lines, as spaces for one line.
pub fn pasteText(text: []u8, multiline: bool) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        var ch = text[i];
        if (ch == '\r') {
            if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
            ch = '\n';
        }
        text[n] = if (ch == '\n' and !multiline) ' ' else ch;
        n += 1;
    }
    return text[0..n];
}

test "pasted newlines stay in a field of several lines, become spaces in one" {
    var a = "one\r\ntwo\rthree\nfour".*;
    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour", pasteText(&a, true));
    var b = "one\r\ntwo\rthree".*;
    try std.testing.expectEqualStrings("one two three", pasteText(&b, false));
}

/// Where copied text goes: the system's clipboard, or the Tester's own.
pub const Clipboard = struct {
    ctx: ?*anyopaque = null,
    write: *const fn (ctx: ?*anyopaque, text: []const u8) void = systemWrite,

    fn systemWrite(_: ?*anyopaque, s: []const u8) void {
        @import("../platform.zig").clipboardWrite(s);
    }
};

/// A text field's editing state, kept across frames.
pub const EditState = struct {
    caret: usize = 0,
    anchor: usize = 0,
    marked: ?[2]usize = null,
    scroll_x: f32 = 0,
    /// Pressed in the field: dragging extends the selection.
    selecting: bool = false,
};

pub const Input = struct {
    mouse: types.Point = .{ .x = -1e6, .y = -1e6 },
    down: bool = false,
    /// The button went down / up in this event.
    pressed: bool = false,
    /// The secondary button went down in this event (a context menu).
    right_pressed: bool = false,
    /// The middle button (the wheel) went down in this event: a tab
    /// closes, as in browsers.
    middle_pressed: bool = false,
    released: bool = false,
    click_count: u32 = 0,
    scroll: types.Point = .{},
    key: ?Key = null,
    /// A key went down (not a repeat) or up in this event, when the view
    /// asked (`Context.wants_keys`): characters lowercase, other keys as
    /// `Shortcut.up` and the like.
    key_down: ?u21 = null,
    key_up: ?u21 = null,
    /// Where the key that went down or up is on the keyboard, whatever
    /// the layout types there (`keycode.zig`): a game's WASD. Set with
    /// `key_down` and `key_up` (and for keys typing nothing, as Shift).
    key_down_code: ?KeyCode = null,
    key_up_code: ?KeyCode = null,
    /// Text typed or pasted in this event.
    chars: []const u8 = "",
    /// Text input operations of this event, for the focused text field.
    ops: []const TextOp = &.{},
    /// A key combination offered in this event (`Context.shortcut`).
    shortcut: ?Shortcut = null,
    shift: bool = false,
    cmd: bool = false,
    ctrl: bool = false,

    /// The key that adds to a selection with a click: Command on the
    /// Mac, Control elsewhere.
    pub fn adding(i: Input) bool {
        return if (comptime @import("builtin").os.tag == .macos) i.cmd else i.ctrl;
    }

    pub fn clearEdges(i: *Input) void {
        i.pressed = false;
        i.right_pressed = false;
        i.middle_pressed = false;
        i.released = false;
        i.scroll = .{};
        i.key = null;
        i.key_down = null;
        i.key_up = null;
        i.key_down_code = null;
        i.key_up_code = null;
        i.chars = "";
        i.ops = &.{};
        i.shortcut = null;
    }
};
