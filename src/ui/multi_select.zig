//! Searchable multiple choice. The app owns one selection flag per option.
const std = @import("std");
const ctx = @import("context.zig");
const widgets = @import("widgets.zig");
const field = @import("textfield.zig");
const listbox = @import("listbox.zig");
const base = @import("overlay_base.zig");
const popup = @import("popover.zig");
const types = @import("types.zig");

pub const State = struct {
    overlay: base.OverlayState = .{},
    query: field.TextBuffer = .{},
    active: usize = 0,
};

pub const Options = struct {
    label: []const u8 = "Choose options",
    placeholder: []const u8 = "Search options",
    empty_label: []const u8 = "No matching options",
    width: types.Length = .{ .px = 280 },
    max_height: f32 = 240,
    disabled: bool = false,
    /// Optional flags parallel to options; disabled choices stay selected.
    disabled_items: ?[]const bool = null,
};

pub fn multiSelect(c: *ctx.Context, s: *State, options: []const []const u8, selected: []bool, opts: Options) bool {
    std.debug.assert(options.len == selected.len);
    if (opts.disabled_items) |disabled| std.debug.assert(disabled.len == options.len);
    var count: usize = 0;
    for (selected) |on| if (on) {
        count += 1;
    };
    const anchor = widgets.button(c, c.print("{s} ({d})", .{ opts.label, count }), .{ .width = opts.width, .disabled = opts.disabled, .icon = "chevron.down" });
    c.describe(anchor.id, .{ .role = .popup_button, .label = opts.label, .expanded = s.overlay.open, .has_popup = true, .disabled = opts.disabled });
    if (opts.disabled) s.overlay.close();
    if (anchor.clicked) {
        s.overlay.toggle();
        s.query.set("");
        s.active = 0;
    }
    const p = popup.popover(c, &s.overlay, anchor, .{ .width = opts.width }) orelse return false;
    defer p.end();
    if (base.takeKey(c, .escape)) {
        s.overlay.dismiss(c);
        return false;
    }
    c.next_key = "search";
    const field_id = c.peekId(null);
    if (s.overlay.justOpened(c)) c.focus = field_id;
    var shown = listbox.filter(c, options, s.query.text());
    var activate = false;
    var moved = false;
    if (c.focus == field_id) {
        const down = base.takeKey(c, .down);
        const up = base.takeKey(c, .up);
        const home = base.takeKey(c, .home);
        const end = base.takeKey(c, .end);
        activate = base.takeKey(c, .enter);
        if (shown.len > 0 and (down or up or home or end)) {
            s.active = @min(s.active, shown.len - 1);
            if (home) s.active = 0 else if (end) s.active = shown.len - 1 else {
                var attempts: usize = 0;
                while (attempts < shown.len) : (attempts += 1) {
                    s.active = if (up) (s.active + shown.len - 1) % shown.len else (s.active + 1) % shown.len;
                    if (!isDisabled(opts, shown[s.active])) break;
                }
            }
            moved = true;
            c.changed = true;
        }
    }
    const edit = field.textField(c, &s.query, .{ .label = opts.label, .placeholder = opts.placeholder, .width = .fill });
    if (edit.changed) {
        shown = listbox.filter(c, options, s.query.text());
        s.active = 0;
    }
    if (shown.len > 0) s.active = @min(s.active, shown.len - 1);
    var changed = false;
    var active_id: u64 = 0;
    const list = c.open(.{ .width = .fill, .max_height = @max(0, opts.max_height), .scroll = true, .clip = true, .gap = 2 }, "choices");
    const list_id = c.node(list).id;
    c.describe(list_id, .{ .role = .list, .label = opts.label });
    if (edit.changed) c.scroll.put(c.gpa, list_id, 0) catch {};
    for (shown, 0..) |original, pos| {
        c.next_key_int = original;
        const disabled = isDisabled(opts, original);
        const row = c.open(.{ .direction = .row, .width = .fill, .padding = .xy(8, 7), .gap = 8, .radius = 5, .opacity = if (disabled) 0.45 else 1 }, null);
        const it = c.interact(row, .{});
        if (it.hovered and c.input.pressed) c.focus = field_id;
        if (pos == s.active) {
            active_id = it.id;
            c.node(row).style.background = c.theme.surface_hover;
            if (moved) if (it.rect) |rect| reveal(c, list_id, rect);
        }
        if (!disabled and (it.clicked or (activate and pos == s.active))) {
            selected[original] = !selected[original];
            changed = true;
            c.changed = true;
            s.active = pos;
        }
        c.describe(it.id, .{ .role = .checkbox, .label = options[original], .checked = if (selected[original]) .on else .off, .disabled = disabled });
        widgets.text(c, if (selected[original]) "✓" else "○", .{ .color = c.theme.accent });
        widgets.text(c, options[original], .{ .wrap = true });
        c.end();
    }
    if (shown.len == 0) widgets.text(c, opts.empty_label, .{ .color = c.theme.muted, .wrap = true });
    c.end();
    c.describe(field_id, .{ .role = .combo_box, .expanded = true, .active_descendant = active_id });
    if (widgets.button(c, "Done", .{ .size = 12 }).clicked) {
        s.overlay.close();
        c.changed = true;
    }
    return changed;
}

fn isDisabled(opts: Options, index: usize) bool {
    return if (opts.disabled_items) |flags| flags[index] else false;
}

fn reveal(c: *ctx.Context, id: u64, rect: types.Rect) void {
    const view = c.rects.get(id) orelse return;
    var offset = c.scroll.get(id) orelse 0;
    if (rect.y < view.y) offset -= view.y - rect.y;
    if (rect.y + rect.h > view.y + view.h) offset += rect.y + rect.h - view.y - view.h;
    c.scroll.put(c.gpa, id, @max(0, offset)) catch {};
}
