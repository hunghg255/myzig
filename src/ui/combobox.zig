//! Text fields with a list below them: the combobox, whose value is one of
//! its options, and the autocomplete, which keeps what the user typed and
//! suggests options for it.
//!
//!     _ = ui.combobox(c, &s.font, fonts, &s.font_box, .{});
//!     _ = ui.autocomplete(c, &s.city, cities, &s.city_box, .{});
//!
//! Typing filters the options (those starting with the text first, then
//! those containing it, ignoring case); Up and Down move among them and
//! Enter chooses, as does a click; Escape closes the list. The field keeps
//! the focus while the user types and picks.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const base = @import("overlay_base.zig");
const listbox = @import("listbox.zig");
const textfield = @import("textfield.zig");
const Context = ctx_mod.Context;
const TextBuffer = textfield.TextBuffer;

/// A combobox's state, kept by the app: its list and the text typed.
pub const ComboboxState = struct {
    list: listbox.ListState = .{},
    buffer: TextBuffer = .{},
    /// Typed since the list opened: the text filters it.
    typed: bool = false,
    was_focused: bool = false,

    pub fn isOpen(s: *const ComboboxState) bool {
        return s.list.state.open;
    }
};

/// An autocomplete's state, kept by the app (the text is the app's).
pub const AutocompleteState = struct {
    list: listbox.ListState = .{},
    was_focused: bool = false,

    pub fn isOpen(s: *const AutocompleteState) bool {
        return s.list.state.open;
    }
};

pub const FieldOptions = struct {
    placeholder: []const u8 = "",
    width: types.Length = .{ .px = 240 },
    size: f32 = 14,
};

pub const ComboboxResult = struct {
    /// A new option was chosen in this frame.
    changed: bool = false,
    open: bool = false,
    focused: bool = false,
};

pub const AutocompleteResult = struct {
    /// The text changed, typed or a suggestion taken.
    changed: bool = false,
    /// Enter with no suggestion highlighted.
    submitted: bool = false,
    open: bool = false,
    focused: bool = false,
};

/// Keys the open list takes before the field sees them: the arrows,
/// Escape (which closes the list, not the field's focus), and Enter on a
/// highlighted option, returned.
fn listKeys(c: *Context, l: *listbox.ListState, n: usize) ?usize {
    if (!l.state.open) return null;
    return listbox.navigate(c, l, n, false);
}

/// Keeps the focus in the field `field` when the press was in its list.
fn keepFocus(c: *Context, l: *const listbox.ListState, field: u64, was: bool) void {
    if (!was or !c.input.pressed) return;
    const at = base.hotIndex(c) orelse return;
    if (at >= l.state.lo and at < l.state.hi) c.focus = field;
}

/// A field choosing `selected` among `options`: it shows the choice, and a
/// click or Down shows them all (the click selecting the text, for typing
/// to replace); its text goes back to the choice as it loses the focus.
pub fn combobox(c: *Context, selected: *?usize, options: []const []const u8, s: *ComboboxState, opts: FieldOptions) ComboboxResult {
    const l = &s.list;
    const field_id = c.peekId(null);
    const focused = c.focus == field_id;
    const choice: []const u8 = if (selected.*) |i| (if (i < options.len) options[i] else "") else "";
    if (!focused and !std.mem.eql(u8, s.buffer.text(), choice)) s.buffer.set(choice);

    const shown = if (s.typed) listbox.filter(c, options, s.buffer.text()) else listbox.filter(c, options, "");
    var chosen: ?usize = null;
    if (focused) {
        if (!l.state.open and base.takeKey(c, .down)) {
            s.typed = false;
            l.openWith(posOf(listbox.filter(c, options, ""), selected.*));
            c.changed = true;
        } else if (listKeys(c, l, shown.len)) |pos| chosen = shown[pos];
    }
    const r = textfield.textField(c, &s.buffer, .{ .placeholder = opts.placeholder, .width = opts.width, .size = opts.size });
    var result: ComboboxResult = .{ .focused = r.focused };
    const rect = c.rects.get(field_id);
    if (r.focused and !s.was_focused) {
        // Focused by a click: every option shows, the text selected.
        s.typed = false;
        l.openWith(posOf(listbox.filter(c, options, ""), selected.*));
        if (c.edits.getPtr(field_id)) |e| {
            e.anchor = 0;
            e.caret = s.buffer.len;
            e.selecting = false;
        }
        c.changed = true;
    }
    if (r.changed) {
        s.typed = true;
        if (!l.state.open) l.openWith(0);
        l.highlight = if (listbox.filter(c, options, s.buffer.text()).len > 0) 0 else -1;
    }
    const list_items = if (s.typed) listbox.filter(c, options, s.buffer.text()) else listbox.filter(c, options, "");
    if (!r.focused and s.was_focused) {
        // The focus went: the list closes and the text is the choice's.
        l.state.open = false;
        _ = l.state.sync(c);
        s.buffer.set(choice);
        c.changed = true;
    } else if (rect) |fr| {
        if (listbox.popup(c, l, fr, listbox.labelsOf(c, options, list_items), .{ .selected = posOfOpt(list_items, selected.*), .except = field_id })) |pos| chosen = list_items[pos];
        keepFocus(c, l, field_id, r.focused);
    }
    if (chosen) |i| {
        if (l.state.open) {
            l.state.open = false;
            _ = l.state.sync(c);
        }
        s.buffer.set(options[i]);
        s.typed = false;
        c.changed = true;
        if (selected.* != i) {
            selected.* = i;
            result.changed = true;
        }
    }
    s.was_focused = c.focus == field_id;
    result.open = l.state.open;
    // The field keeps the focus for the option the arrows are on.
    c.describe(field_id, .{ .role = .combo_box, .expanded = l.state.open, .active_descendant = if (l.state.open) l.highlight_id else 0 });
    return result;
}

fn posOf(items: []const usize, want: ?usize) i32 {
    const w = want orelse return 0;
    for (items, 0..) |v, k| if (v == w) return @intCast(k);
    return 0;
}

fn posOfOpt(items: []const usize, want: ?usize) ?usize {
    const w = want orelse return null;
    for (items, 0..) |v, k| if (v == w) return k;
    return null;
}

/// A text field editing `buffer` that suggests, below it, those of
/// `suggestions` containing what was typed: Up and Down move among them
/// and Enter takes one, as does a click, while Enter on none submits.
pub fn autocomplete(c: *Context, buffer: *TextBuffer, suggestions: []const []const u8, s: *AutocompleteState, opts: FieldOptions) AutocompleteResult {
    const l = &s.list;
    const field_id = c.peekId(null);
    const focused = c.focus == field_id;
    const before = matches(c, suggestions, buffer.text());
    var taken: ?usize = null;
    if (focused) {
        if (!l.state.open and buffer.len > 0 and before.len > 0 and base.takeKey(c, .down)) {
            l.openWith(0);
            c.changed = true;
        } else if (listKeys(c, l, before.len)) |pos| taken = before[pos];
    }
    const r = textfield.textField(c, buffer, .{ .placeholder = opts.placeholder, .width = opts.width, .size = opts.size });
    var result: AutocompleteResult = .{ .focused = r.focused, .changed = r.changed, .submitted = r.submitted };
    const items = matches(c, suggestions, buffer.text());
    if (r.changed) {
        if (buffer.len > 0 and items.len > 0) {
            if (!l.state.open) l.openWith(-1);
            l.highlight = -1;
        } else if (l.state.open) {
            l.state.open = false;
            _ = l.state.sync(c);
        }
    }
    if (!r.focused) {
        if (l.state.open) {
            l.state.open = false;
            c.changed = true;
        }
        _ = l.state.sync(c);
    } else if (c.rects.get(field_id)) |fr| {
        if (listbox.popup(c, l, fr, listbox.labelsOf(c, suggestions, items), .{ .except = field_id })) |pos| taken = items[pos];
        keepFocus(c, l, field_id, r.focused);
    }
    if (taken) |i| {
        if (l.state.open) {
            l.state.open = false;
            _ = l.state.sync(c);
        }
        buffer.set(suggestions[i]);
        result.changed = true;
        result.submitted = false;
        c.changed = true;
    }
    s.was_focused = c.focus == field_id;
    result.open = l.state.open;
    // The field keeps the focus for the option the arrows are on.
    c.describe(field_id, .{ .role = .combo_box, .expanded = l.state.open, .active_descendant = if (l.state.open) l.highlight_id else 0 });
    return result;
}

/// Suggestions for `text`: none for no text, and none that is the text.
fn matches(c: *Context, suggestions: []const []const u8, text: []const u8) []const usize {
    if (text.len == 0) return &.{};
    const all = listbox.filter(c, suggestions, text);
    if (all.len == 1 and std.mem.eql(u8, suggestions[all[0]], text)) return &.{};
    return all;
}
