//! Dates: a civil date, a month's calendar choosing a day, and a date
//! input opening that calendar below it.
const std = @import("std");
const types = @import("types.zig");
const widgets = @import("widgets.zig");
const state = @import("controls_state.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

/// A day of the proleptic Gregorian calendar.
pub const Date = struct {
    year: i32,
    /// 1 to 12.
    month: u8,
    /// 1 to the month's last.
    day: u8,

    /// Days since 1970-01-01 (Howard Hinnant's algorithm).
    pub fn toDays(d: Date) i32 {
        const y = if (d.month <= 2) d.year - 1 else d.year;
        const era = @divFloor(y, 400);
        const yoe = y - era * 400;
        const m: i32 = d.month;
        const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + @as(i32, d.day) - 1;
        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        return era * 146097 + doe - 719468;
    }

    pub fn fromDays(days: i32) Date {
        const z = days + 719468;
        const era = @divFloor(z, 146097);
        const doe = z - era * 146097;
        const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp = @divFloor(5 * doy + 2, 153);
        const d = doy - @divFloor(153 * mp + 2, 5) + 1;
        const m = if (mp < 10) mp + 3 else mp - 9;
        return .{ .year = yoe + era * 400 + @as(i32, if (m <= 2) 1 else 0), .month = @intCast(m), .day = @intCast(d) };
    }

    pub fn addDays(d: Date, n: i32) Date {
        return fromDays(d.toDays() + n);
    }

    /// `n` months later (earlier if negative), on the same day or the
    /// month's last: January 31 and a month is February's last day.
    pub fn addMonths(d: Date, n: i32) Date {
        const total = d.year * 12 + @as(i32, d.month) - 1 + n;
        const y = @divFloor(total, 12);
        const m: u8 = @intCast(total - y * 12 + 1);
        return .{ .year = y, .month = m, .day = @min(d.day, daysInMonth(y, m)) };
    }

    /// 0 for Sunday to 6 for Saturday.
    pub fn weekday(d: Date) u8 {
        return @intCast(@mod(d.toDays() + 4, 7));
    }

    pub fn eql(a: Date, b: Date) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }

    /// A valid date: the month and the day within their bounds.
    pub fn valid(d: Date) bool {
        return d.month >= 1 and d.month <= 12 and d.day >= 1 and d.day <= daysInMonth(d.year, d.month);
    }
};

pub fn isLeap(y: i32) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

pub fn daysInMonth(y: i32, m: u8) u8 {
    return switch (m) {
        2 => if (isLeap(y)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

pub const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const weekday_names = [_][]const u8{ "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" };

pub const CalendarOptions = struct {
    /// The first day of the week: 0 for Sunday (the United States), 1 for
    /// Monday (most of Europe).
    first_weekday: u8 = 0,
    /// Today, marked with a ring; none when null.
    today: ?Date = null,
};

const GridResult = struct {
    /// A day chosen: clicked, or Enter or Space on the cursor.
    chosen: ?Date = null,
    /// Where the keys or the buttons moved the cursor.
    moved: ?Date = null,
};

/// The month around `cursor`, the day the keys move, with `selected`
/// chosen; it reads the keys when `keyboard` is set.
fn grid(c: *Context, selected: Date, cursor: Date, keyboard: bool, opts: CalendarOptions) GridResult {
    const th = c.theme;
    var res: GridResult = .{};
    if (keyboard) if (c.input.key) |key| {
        res.moved = switch (key) {
            .left => cursor.addDays(-1),
            .right => cursor.addDays(1),
            .up => cursor.addDays(-7),
            .down => cursor.addDays(7),
            .page_up => cursor.addMonths(-1),
            .page_down => cursor.addMonths(1),
            .home => .{ .year = cursor.year, .month = cursor.month, .day = 1 },
            .end => .{ .year = cursor.year, .month = cursor.month, .day = daysInMonth(cursor.year, cursor.month) },
            .enter => blk: {
                res.chosen = cursor;
                break :blk null;
            },
            else => null,
        };
        if (res.moved != null or res.chosen != null) c.input.key = null;
    };
    if (keyboard and state.takeSpace(c)) res.chosen = cursor;

    // The header: the month's buttons round its title.
    _ = c.open(.{ .direction = .row, .width = .fill, .align_items = .center, .gap = 4 }, null);
    if (monthButton(c, "‹")) res.moved = cursor.addMonths(-1);
    _ = c.open(.{ .grow = 1, .align_items = .center }, null);
    widgets.text(c, c.print("{s} {d}", .{ month_names[cursor.month - 1], cursor.year }), .{ .weight = .semibold });
    c.end();
    if (monthButton(c, "›")) res.moved = cursor.addMonths(1);
    c.end();

    const cell_w: f32 = 32;
    const cell_h: f32 = 28;
    _ = c.open(.{ .direction = .row }, null);
    for (0..7) |k| {
        _ = c.open(.{ .width = .{ .px = cell_w }, .align_items = .center }, null);
        widgets.text(c, weekday_names[(opts.first_weekday + k) % 7], .{ .size = 11, .color = th.muted });
        c.end();
    }
    c.end();
    // Six weeks from the first day of the week on or before the first.
    const first: Date = .{ .year = cursor.year, .month = cursor.month, .day = 1 };
    const back: i32 = @mod(@as(i32, first.weekday()) - @as(i32, opts.first_weekday), 7);
    const start = first.toDays() - back;
    for (0..6) |w| {
        _ = c.open(.{ .direction = .row }, null);
        defer c.end();
        for (0..7) |d| {
            const day = Date.fromDays(start + @as(i32, @intCast(w * 7 + d)));
            const chosen = day.eql(selected);
            const at_cursor = day.eql(cursor);
            const i = c.open(.{ .width = .{ .px = cell_w }, .height = .{ .px = cell_h }, .radius = 6, .align_items = .center, .justify = .center, .control = true }, null);
            const it = c.interact(i, .{});
            const n = c.node(i);
            if (chosen) n.style.background = th.accent //
            else if (at_cursor or it.hovered) n.style.background = th.surface_hover;
            if (opts.today) |today| if (day.eql(today) and !chosen) {
                n.style.border = th.accent;
            };
            const fg = if (chosen) th.accent_text else if (day.month != cursor.month) th.muted else th.text;
            widgets.text(c, c.print("{d}", .{day.day}), .{ .size = 13, .color = fg, .weight = if (chosen) .semibold else .regular });
            c.end();
            if (it.clicked) res.chosen = day;
        }
    }
    return res;
}

fn monthButton(c: *Context, glyph: []const u8) bool {
    const th = c.theme;
    const i = c.open(.{ .width = .{ .px = 28 }, .height = .{ .px = 24 }, .radius = 6, .align_items = .center, .justify = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    if (it.hovered) c.node(i).style.background = th.surface_hover;
    widgets.text(c, glyph, .{ .size = 18, .weight = .medium, .color = th.text });
    return it.clicked;
}

/// A month's calendar choosing the day of `date`, as SwiftUI's graphical
/// date picker: a click chooses a day, as the arrows do while it has the
/// keyboard focus; Page Up and Page Down, or its buttons, move by months,
/// and Home and End go to the first and the last day of the month.
/// Returns true when the date changes.
pub fn calendar(c: *Context, date: *Date, opts: CalendarOptions) bool {
    const i = c.open(.{ .gap = 4, .padding = .all(4), .radius = 8 }, null);
    defer c.end();
    const it = c.interact(i, .{ .focusable = true });
    const focused = it.focused and c.focus == it.id;
    const r = grid(c, date.*, date.*, focused, opts);
    if (r.moved != null or r.chosen != null) c.focus = it.id;
    state.focusRing(c, i, c.focus == it.id);
    const next = r.chosen orelse r.moved orelse return false;
    if (next.eql(date.*)) return false;
    date.* = next;
    c.changed = true;
    return true;
}

pub const DateFormat = enum {
    /// 1/5/2026, as in the United States.
    month_day_year,
    /// 05/01/2026, as in the United Kingdom.
    day_month_year,
    /// 2026/1/5, as in China.
    year_month_day,
};

pub fn formatDate(c: *Context, d: Date, f: DateFormat) []const u8 {
    return switch (f) {
        .month_day_year => c.print("{d}/{d}/{d}", .{ d.month, d.day, d.year }),
        .day_month_year => c.print("{d:0>2}/{d:0>2}/{d}", .{ d.day, d.month, d.year }),
        .year_month_day => c.print("{d}/{d}/{d}", .{ d.year, d.month, d.day }),
    };
}

pub const DateInputOptions = struct {
    format: DateFormat = .month_day_year,
    calendar: CalendarOptions = .{},
};

const salt_open = 0;
const salt_cursor = 1;

/// A field showing `date` in numbers, which a calendar below it changes:
/// a click, Enter or Space opens the calendar, where a click chooses a
/// day, as the arrows and Enter do; Page Up and Page Down, or its buttons,
/// move by months, and Escape or a click outside closes it. Returns true
/// when the date changes.
pub fn dateInput(c: *Context, date: *Date, opts: DateInputOptions) bool {
    const th = c.theme;
    const i = c.open(.{ .direction = .row, .gap = 8, .padding = .xy(10, 6), .radius = 8, .background = th.surface, .border = th.border, .align_items = .center, .control = true }, null);
    const it = c.interact(i, .{ .focusable = true });
    widgets.text(c, formatDate(c, date.*, opts.format), .{});
    widgets.icon(c, "chevron.down", .{ .size = 11, .weight = .semibold, .color = th.muted });
    c.end();
    const focused = c.focus == it.id;
    var open = state.getBool(c, it.id, salt_open);
    var cursor = Date.fromDays(@intFromFloat(state.get(c, it.id, salt_cursor, @floatFromInt(date.toDays()))));
    var changed = false;
    const toggle = it.clicked or (focused and !open and (c.input.key == .enter or state.takeSpace(c)));
    if (toggle) {
        if (!it.clicked) c.input.key = null;
        open = !open;
        cursor = date.*;
        c.focus = it.id;
        c.changed = true;
    } else if (open and focused and c.input.key == .escape) {
        c.input.key = null;
        open = false;
        c.changed = true;
    }
    if (open) {
        const r = c.rects.get(it.id) orelse types.Rect{};
        const o = c.openOverlay(.{ .absolute = true, .offset = .{ .x = r.x, .y = r.y + r.h + 4 }, .gap = 4, .padding = .all(8), .radius = 10, .background = th.surface, .border = th.border, .shadow = .{ .color = th.shadow, .blur = 16, .y = 6 } }, "calendar");
        const oi = c.interact(o, .{});
        const g = grid(c, date.*, cursor, focused and !toggle, opts.calendar);
        c.end();
        if (g.moved) |m| {
            cursor = m;
            c.focus = it.id;
            c.changed = true;
        }
        if (g.chosen) |d| {
            if (!d.eql(date.*)) {
                date.* = d;
                changed = true;
            }
            open = false;
            c.focus = it.id;
            c.changed = true;
        }
        // A press outside closes it; one on the field toggles it instead.
        if (c.pressedOutside(oi.id) and c.hot != it.id) {
            open = false;
            c.changed = true;
        }
    }
    state.putBool(c, it.id, salt_open, open);
    state.put(c, it.id, salt_cursor, @floatFromInt(cursor.toDays()));
    const n = c.node(i);
    if (focused or open) {
        n.style.border = th.accent;
        n.style.border_width = 2;
    }
    return changed;
}
