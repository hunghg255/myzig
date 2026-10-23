//! A two-click inclusive date range, committed only when both ends exist.
const ctx = @import("context.zig");
const dates = @import("controls_date.zig");
const widgets = @import("widgets.zig");
const base = @import("overlay_base.zig");
const popup = @import("popover.zig");
const Date = dates.Date;
const Range = dates.DateRange;

pub const State = struct {
    overlay: base.OverlayState = .{},
    cursor: Date = .{ .year = 2026, .month = 1, .day = 1 },
    pending: ?Date = null,
};

pub const Options = struct {
    label: []const u8 = "Choose date range",
    format: dates.DateFormat = .day_month_year,
    calendar: dates.CalendarOptions = .{},
    disabled: bool = false,
};

/// All days, including the endpoints, must be enabled.
pub fn allowed(range: Range, opts: dates.CalendarOptions) bool {
    if (range.start.toDays() > range.end.toDays()) return false;
    if (!opts.allows(range.start) or !opts.allows(range.end)) return false;
    if (opts.disabled == null) return true;
    var day = range.start;
    while (!day.eql(range.end)) {
        if (!opts.allows(day)) return false;
        day = day.addDays(1);
    }
    return true;
}

pub fn dateRangeInput(c: *ctx.Context, value: *?Range, s: *State, opts: Options) bool {
    const title = if (value.*) |v| c.print("{s} – {s}", .{ dates.formatDate(c, v.start, opts.format), dates.formatDate(c, v.end, opts.format) }) else opts.label;
    const anchor = widgets.button(c, title, .{ .disabled = opts.disabled, .icon = "calendar" });
    c.describe(anchor.id, .{ .role = .popup_button, .label = opts.label, .value = title, .expanded = s.overlay.open, .has_popup = true, .disabled = opts.disabled });
    if (opts.disabled) s.overlay.close();
    if (anchor.clicked) {
        s.overlay.toggle();
        s.pending = null;
        s.cursor = if (value.*) |v| v.start else opts.calendar.today orelse opts.calendar.min orelse s.cursor;
    }
    const p = popup.popover(c, &s.overlay, anchor, .{}) orelse return false;
    defer p.end();
    widgets.text(c, if (s.pending == null) "Choose start date" else "Choose end date", .{ .size = 12, .color = c.theme.muted });
    var cal = opts.calendar;
    cal.range = if (s.pending) |start| Range.ordered(start, s.cursor) else value.*;
    const selected = s.pending orelse if (value.*) |v| v.start else s.cursor;
    const grid = c.open(.{ .gap = 4 }, "calendar");
    const it = c.interact(grid, .{ .focusable = true });
    if (s.overlay.justOpened(c)) c.focus = it.id;
    const r = dates.grid(c, selected, s.cursor, c.focus == it.id, cal);
    widgets.focusRing(c, grid, it);
    c.end();
    if (r.moved) |day| {
        s.cursor = day;
        c.focus = it.id;
        c.changed = true;
    }
    var changed = false;
    if (r.chosen) |day| {
        c.focus = it.id;
        s.cursor = day;
        if (s.pending) |start| {
            const next = Range.ordered(start, day);
            if (allowed(next, cal)) {
                changed = if (value.*) |before| !before.eql(next) else true;
                value.* = next;
                s.pending = null;
                s.overlay.close();
            }
        } else s.pending = day;
        c.changed = true;
    }
    if (s.pending) |start| if (!allowed(Range.ordered(start, s.cursor), cal)) widgets.text(c, "Range includes an unavailable date", .{ .size = 12, .color = c.theme.danger });
    if (widgets.button(c, "Cancel", .{ .variant = .ghost, .size = 12 }).clicked) {
        s.pending = null;
        s.overlay.close();
    }
    return changed;
}
