//! Fields around a text field: searching (a magnifying glass and a clear
//! button), tokens (tags typed and taken out, with suggestions), and the
//! avatar of a person or a thing.
const std = @import("std");
const types = @import("types.zig");
const widgets = @import("widgets.zig");
const textfield = @import("textfield.zig");
const state = @import("controls_state.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const TextBuffer = textfield.TextBuffer;

pub const SearchFieldOptions = struct {
    placeholder: []const u8 = "Search",
    width: types.Length = .{ .px = 220 },
    size: f32 = 14,
};

pub const SearchResult = struct {
    changed: bool = false,
    submitted: bool = false,
    /// The clear button or Escape emptied it.
    cleared: bool = false,
    focused: bool = false,
};

/// A field for searching: a magnifying glass, the text, and a button
/// clearing it while it holds any, as Escape does then.
pub fn searchField(c: *Context, query: *TextBuffer, opts: SearchFieldOptions) SearchResult {
    const th = c.theme;
    const i = c.open(.{ .direction = .row, .width = opts.width, .gap = 6, .padding = .xy(8, 5), .radius = 8, .background = th.surface, .border = th.border, .align_items = .center, .clip = true }, null);
    defer c.end();
    const box = c.interact(i, .{});
    widgets.icon(c, "magnifyingglass", .{ .size = opts.size * 0.9, .color = th.muted });
    const field_id = c.peekId(null);
    var res: SearchResult = .{};
    if (c.focus == field_id and c.input.key == .escape and query.len > 0) {
        // Escape empties a field that holds text, and keeps the focus.
        c.input.key = null;
        query.clear();
        res.cleared = true;
    }
    const r = textfield.textField(c, query, .{ .placeholder = opts.placeholder, .width = .fill, .size = opts.size, .bare = true });
    res.changed = r.changed or res.cleared;
    res.submitted = r.submitted;
    res.focused = r.focused;
    if (query.len > 0) {
        const x = c.open(.{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .radius = 8, .align_items = .center, .justify = .center, .control = true }, null);
        const xi = c.interact(x, .{});
        c.node(x).style.background = th.muted.alpha(if (xi.hovered) 0.75 else 0.5);
        widgets.icon(c, "xmark", .{ .size = 9, .weight = .bold, .color = th.surface });
        c.end();
        if (xi.clicked) {
            query.clear();
            c.focus = field_id;
            res.cleared = true;
            res.changed = true;
        }
    }
    // A click on the frame around the text focuses it.
    if (box.clicked) c.focus = field_id;
    const focus_t = c.animate(box.id, 0, if (r.focused) 1 else 0, 20);
    const n = c.node(i);
    n.style.border = th.border.mix(th.accent, focus_t);
    n.style.border_width = 1 + focus_t;
    if (res.changed or res.cleared or box.clicked) c.changed = true;
    return res;
}

/// The tokens of a token field and what is being typed, kept by the app:
/// up to 64 tokens of 2 KB in all.
pub const Tokens = struct {
    buf: [2048]u8 = undefined,
    len: usize = 0,
    ends: [64]u16 = undefined,
    count: usize = 0,
    /// The text typed after the tokens.
    query: TextBuffer = .{},
    /// The suggestion Up and Down are on.
    highlighted: usize = 0,

    pub fn get(t: *const Tokens, i: usize) []const u8 {
        const start: usize = if (i == 0) 0 else t.ends[i - 1];
        return t.buf[start..t.ends[i]];
    }

    pub fn contains(t: *const Tokens, s: []const u8) bool {
        for (0..t.count) |i| if (std.mem.eql(u8, t.get(i), s)) return true;
        return false;
    }

    /// Adds `s`, trimmed, unless it is empty, already there, or too long
    /// for what is left; returns whether it went in.
    pub fn append(t: *Tokens, raw: []const u8) bool {
        const s = std.mem.trim(u8, raw, " \t");
        if (s.len == 0 or t.contains(s) or t.count == t.ends.len or t.len + s.len > t.buf.len) return false;
        @memcpy(t.buf[t.len .. t.len + s.len], s);
        t.len += s.len;
        t.ends[t.count] = @intCast(t.len);
        t.count += 1;
        return true;
    }

    pub fn remove(t: *Tokens, i: usize) void {
        if (i >= t.count) return;
        const start: usize = if (i == 0) 0 else t.ends[i - 1];
        const n = t.ends[i] - start;
        std.mem.copyForwards(u8, t.buf[start .. t.len - n], t.buf[start + n .. t.len]);
        t.len -= n;
        var k = i;
        while (k + 1 < t.count) : (k += 1) t.ends[k] = t.ends[k + 1] - @as(u16, @intCast(n));
        t.count -= 1;
    }
};

pub const TokenFieldOptions = struct {
    placeholder: []const u8 = "",
    width: f32 = 300,
    /// At most this many suggestions show.
    max_suggestions: usize = 8,
};

fn containsFold(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    return false;
}

/// The suggestions containing what was typed (ignoring case), not already
/// tokens, in the frame's memory.
pub fn tokenMatches(c: *Context, t: *const Tokens, suggestions: []const []const u8, max: usize) []const []const u8 {
    const q = std.mem.trim(u8, t.query.text(), " ");
    if (q.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (suggestions) |s| {
        if (out.items.len == max) break;
        if (containsFold(s, q) and !t.contains(s)) out.append(c.alloc(), s) catch break;
    }
    return out.items;
}

/// A field of tokens, as tags or a mail's recipients: chips, each with a
/// button taking it out, wrapping onto more lines, before a text field
/// where Enter or a comma adds what was typed and Backspace while empty
/// takes out the last. The suggestions containing what was typed show
/// below it: Up and Down move among them, Enter or a click adds one.
/// Returns true when the tokens change.
pub fn tokenField(c: *Context, t: *Tokens, suggestions: []const []const u8, opts: TokenFieldOptions) bool {
    const th = c.theme;
    const pad: f32 = 6;
    const gap: f32 = 4;
    const outer = c.open(.{ .width = .{ .px = opts.width }, .gap = gap, .padding = .all(pad), .radius = 8, .background = th.surface, .border = th.border, .clip = true }, null);
    defer c.end();
    const box = c.interact(outer, .{});
    var changed = false;
    var input_id: u64 = 0;
    var focused = false;
    var was_empty = t.query.len == 0;

    // Lines of chips, from their widths; the input ends the last one.
    const room = opts.width - 2 * pad;
    const chip_style: types.TextStyle = .{ .size = 13 };
    var lines: [65]u8 = undefined; // the line of each chip
    var line: u8 = 0;
    var x: f32 = 0;
    for (0..t.count) |k| {
        const w = c.text.width(t.get(k), chip_style) + 8 + 16 + 4;
        if (x > 0 and x + w > room) {
            line += 1;
            x = 0;
        }
        lines[k] = line;
        x += w + gap;
    }
    const input_min: f32 = 80;
    const last_line = if (x > 0 and x + input_min > room) line + 1 else line;

    var removed: ?usize = null;
    var k: usize = 0;
    var l: u8 = 0;
    while (l <= last_line) : (l += 1) {
        _ = c.open(.{ .direction = .row, .width = .fill, .gap = gap, .align_items = .center }, if (l == last_line) "last" else c.print("line{d}", .{l}));
        defer c.end();
        while (k < t.count and lines[k] == l) : (k += 1) {
            widgets.key(c, t.get(k));
            _ = c.open(.{ .direction = .row, .gap = 4, .padding = .{ .left = 8, .right = 2, .top = 2, .bottom = 2 }, .radius = 6, .background = th.track, .align_items = .center }, null);
            widgets.text(c, t.get(k), chip_style);
            const xb = c.open(.{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .radius = 4, .align_items = .center, .justify = .center, .control = true }, null);
            const xi = c.interact(xb, .{});
            if (xi.hovered) c.node(xb).style.background = th.surface_hover;
            widgets.icon(c, "xmark", .{ .size = 8, .weight = .bold, .color = th.muted });
            c.end();
            c.end();
            if (xi.clicked) removed = k;
        }
        if (l == last_line) {
            // The input keeps its id however the chips wrap.
            _ = c.open(.{ .grow = 1, .min_width = input_min }, "input");
            input_id = c.peekId(null);
            if (c.focus == input_id and c.input.key == .backspace and was_empty and t.count > 0) {
                removed = t.count - 1;
                c.input.key = null;
            }
            const r = textfield.textField(c, &t.query, .{ .placeholder = if (t.count == 0) opts.placeholder else "", .width = .fill, .size = 13, .bare = true });
            c.end();
            focused = r.focused;
            const shown = tokenMatches(c, t, suggestions, opts.max_suggestions);
            if (t.highlighted >= shown.len) t.highlighted = 0;
            if (r.changed) t.highlighted = 0;
            if (focused) if (c.input.key) |key| switch (key) {
                .down => if (shown.len > 0) {
                    t.highlighted = (t.highlighted + 1) % shown.len;
                    c.changed = true;
                },
                .up => if (shown.len > 0) {
                    t.highlighted = (t.highlighted + shown.len - 1) % shown.len;
                    c.changed = true;
                },
                else => {},
            };
            if (r.submitted) {
                const what = if (shown.len > 0) shown[t.highlighted] else t.query.text();
                if (t.append(what)) changed = true;
                t.query.clear();
                was_empty = true;
                c.changed = true;
            }
            // A comma ends a token.
            while (std.mem.indexOfScalar(u8, t.query.text(), ',')) |comma| {
                if (t.append(t.query.text()[0..comma])) changed = true;
                t.query.remove(0, comma + 1);
                t.query.want_caret = t.query.len;
                c.changed = true;
            }
            if (focused and shown.len > 0) if (suggestionsOverlay(c, outer, shown, t.highlighted, input_id)) |pick| {
                if (t.append(pick)) changed = true;
                t.query.clear();
            };
        }
    }
    if (removed) |at| {
        t.remove(at);
        changed = true;
    }
    if (box.clicked) {
        c.focus = input_id;
        c.changed = true;
    }
    const n = c.node(outer);
    const focus_t = c.animate(box.id, 0, if (focused) 1 else 0, 20);
    n.style.border = th.border.mix(th.accent, focus_t);
    n.style.border_width = 1 + focus_t;
    if (changed) c.changed = true;
    return changed;
}

/// The suggestions under the field; the one clicked.
fn suggestionsOverlay(c: *Context, field: u32, shown: []const []const u8, highlighted: usize, input_id: u64) ?[]const u8 {
    const th = c.theme;
    const r = c.rects.get(c.node(field).id) orelse return null;
    const o = c.openOverlay(.{ .absolute = true, .offset = .{ .x = r.x, .y = r.y + r.h + 4 }, .width = .{ .px = r.w }, .padding = .all(4), .radius = 8, .background = th.surface, .border = th.border, .shadow = .{ .color = th.shadow, .blur = 12, .y = 4 } }, "suggestions");
    defer c.end();
    _ = c.interact(o, .{});
    var pick: ?[]const u8 = null;
    for (shown, 0..) |s, k| {
        widgets.key(c, s);
        const it = widgets.pressable(c, .{ .width = .fill, .padding = .xy(8, 4), .radius = 5, .control = true }, null);
        // The field keeps the focus a press here would take.
        if (it.pressed) c.focus = input_id;
        const on = k == highlighted;
        if (on or it.hovered) c.node(c.stack.items[c.stack.items.len - 1]).style.background = if (on) th.accent else th.surface_hover;
        widgets.text(c, s, .{ .size = 13, .color = if (on) th.accent_text else th.text });
        c.end();
        if (it.clicked) pick = s;
    }
    return pick;
}

pub const AvatarOptions = struct {
    size: f32 = 32,
    /// A picture (PNG) shown instead of the initials, cropped round.
    image: ?widgets.ImageOptions = null,
};

/// The first letters of the first and the last words of `name`,
/// uppercased, in `out`.
pub fn initials(name: []const u8, out: *[8]u8) []const u8 {
    var first: ?[]const u8 = null;
    var last: ?[]const u8 = null;
    var in_word = false;
    var it = (std.unicode.Utf8View.init(name) catch return "").iterator();
    while (it.nextCodepointSlice()) |cp| {
        const letter = cp.len > 1 or std.ascii.isAlphanumeric(cp[0]);
        if (letter and !in_word) {
            if (first == null) first = cp else last = cp;
        }
        in_word = letter;
    }
    var n: usize = 0;
    for ([_]?[]const u8{ first, last }) |part| if (part) |p| {
        for (p) |b| {
            out[n] = std.ascii.toUpper(b);
            n += 1;
        }
    };
    return out[0..n];
}

/// The color an avatar of `name` gets: a hue of its FNV-1a hash, so that
/// each name keeps its own.
pub fn avatarColor(name: []const u8) types.Color {
    var h: u32 = 2166136261;
    for (name) |b| h = (h ^ b) *% 16777619;
    return hsl(@floatFromInt(h % 360), 0.45, 0.55);
}

fn hsl(h: f32, s: f32, l: f32) types.Color {
    const k = (1 - @abs(2 * l - 1)) * s;
    const x = k * (1 - @abs(@mod(h / 60, 2) - 1));
    const m = l - k / 2;
    const rgb: [3]f32 = if (h < 60) .{ k, x, 0 } else if (h < 120) .{ x, k, 0 } else if (h < 180) .{ 0, k, x } else if (h < 240) .{ 0, x, k } else if (h < 300) .{ x, 0, k } else .{ k, 0, x };
    return .{ .r = rgb[0] + m, .g = rgb[1] + m, .b = rgb[2] + m };
}

/// A picture of a person or a thing: its image cropped round, or the
/// initials of its name on a color picked from the name.
pub fn avatar(c: *Context, name: []const u8, opts: AvatarOptions) void {
    const s = opts.size;
    _ = c.open(.{ .width = .{ .px = s }, .height = .{ .px = s }, .radius = s / 2, .clip = true, .align_items = .center, .justify = .center }, null);
    defer c.end();
    if (opts.image) |img| {
        var o = img;
        o.max_width = s;
        o.max_height = s;
        o.radius = s / 2;
        if (widgets.image(c, o)) return;
    }
    c.node(c.stack.items[c.stack.items.len - 1]).style.background = avatarColor(name);
    const buf = c.alloc().create([8]u8) catch return;
    widgets.text(c, initials(name, buf), .{ .size = s * 0.4, .weight = .semibold, .color = .white });
}
