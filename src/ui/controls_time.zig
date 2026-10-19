//! A time of day, and its input: hours, minutes and the half of the day,
//! each taking the keyboard focus, as the segments of AppKit's date picker.
const std = @import("std");
const types = @import("types.zig");
const widgets = @import("widgets.zig");
const state = @import("controls_state.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

pub const Time = struct {
    /// 0 to 23.
    hour: u8 = 0,
    /// 0 to 59.
    minute: u8 = 0,
};

pub const TimeInputOptions = struct {
    /// 3:04 PM rather than 15:04.
    twelve_hour: bool = false,
    am: []const u8 = "AM",
    pm: []const u8 = "PM",
};

const Seg = enum(u8) { hours, minutes, period };

// The digits typed into a segment so far, and how many.
const salt_typed = 0;
const salt_count = 1;

/// The time of day of `time`: Up and Down step the segment with the focus
/// round the clock, digits typed set it (going on to the minutes once the
/// hours are typed), A or P choose the half of the day, and Left and Right
/// move between the segments; a click focuses one. Returns true when the
/// time changes.
pub fn timeInput(c: *Context, time: *Time, opts: TimeInputOptions) bool {
    const th = c.theme;
    const i = c.open(.{ .direction = .row, .padding = .xy(8, 6), .radius = 8, .background = th.surface, .border = th.border, .align_items = .center }, null);
    defer c.end();
    const count: usize = if (opts.twelve_hour) 3 else 2;
    var ids: [3]u64 = undefined;
    var focused: ?usize = null;
    var pressed_one = false;
    for (0..count) |k| {
        const seg: Seg = @enumFromInt(k);
        if (seg == .minutes) widgets.text(c, ":", .{ .color = th.muted }) //
        else if (seg == .period) _ = c.leaf(.{ .width = .{ .px = 4 } }, .none, null);
        const b = c.open(.{ .padding = .xy(2, 0), .radius = 4, .control = true }, null);
        const it = c.interact(b, .{ .focusable = true });
        ids[k] = it.id;
        if (it.pressed and c.input.pressed) pressed_one = true;
        const on = c.focus == it.id;
        if (on) {
            focused = k;
            c.node(b).style.background = th.accent;
        }
        const h12 = (time.hour + 11) % 12 + 1;
        const str = switch (seg) {
            .hours => if (opts.twelve_hour) c.print("{d}", .{h12}) else c.print("{d:0>2}", .{time.hour}),
            .minutes => c.print("{d:0>2}", .{time.minute}),
            .period => if (time.hour >= 12) opts.pm else opts.am,
        };
        widgets.text(c, str, .{ .color = if (on) th.accent_text else th.text });
        c.end();
    }
    if (focused != null) {
        c.node(i).style.border = th.accent;
        c.node(i).style.border_width = 2;
    }
    const k = focused orelse return false;
    var seg: Seg = @enumFromInt(k);
    var id = ids[k];
    // A click starts the typing afresh.
    if (pressed_one) {
        state.put(c, id, salt_typed, 0);
        state.put(c, id, salt_count, 0);
    }
    var h: i32 = time.hour;
    var m: i32 = time.minute;
    if (c.input.key) |key| switch (key) {
        .up, .down => {
            const step: i32 = if (key == .up) 1 else -1;
            switch (seg) {
                .hours => h = if (opts.twelve_hour) @divFloor(h, 12) * 12 + @mod(@mod(h, 12) + step, 12) else @mod(h + step, 24),
                .minutes => m = @mod(m + step, 60),
                .period => h = @mod(h + 12, 24),
            }
            state.put(c, id, salt_count, 0);
            c.input.key = null;
        },
        .left, .right => {
            const to = if (key == .left) (if (k == 0) null else k - 1) else (if (k + 1 < count) k + 1 else null);
            if (to) |t| {
                c.focus = ids[t];
                state.put(c, ids[t], salt_count, 0);
                c.changed = true;
            }
            c.input.key = null;
        },
        else => {},
    };
    for (c.input.chars) |ch| {
        if (seg == .period) {
            const lower = std.ascii.toLower(ch);
            if (lower == std.ascii.toLower(opts.pm[0]) or lower == 'p') {
                if (h < 12) h += 12;
            } else if (lower == std.ascii.toLower(opts.am[0]) or lower == 'a') {
                if (h >= 12) h -= 12;
            }
            continue;
        }
        if (!std.ascii.isDigit(ch)) continue;
        const d: i32 = ch - '0';
        const top: i32 = if (seg == .minutes) 60 else if (opts.twelve_hour) 13 else 24;
        const prev: i32 = @intFromFloat(state.get(c, id, salt_typed, 0));
        const n_prev: i32 = @intFromFloat(state.get(c, id, salt_count, 0));
        // A second digit joins the first while the number stays in range.
        var n = d;
        var digits: i32 = 1;
        if (n_prev == 1 and prev * 10 + d < top) {
            n = prev * 10 + d;
            digits = 2;
        }
        state.put(c, id, salt_typed, @floatFromInt(n));
        state.put(c, id, salt_count, @floatFromInt(digits));
        switch (seg) {
            .hours => if (opts.twelve_hour) {
                if (n != 0) h = @divFloor(h, 12) * 12 + @mod(n, 12);
            } else {
                h = n;
            },
            .minutes => m = n,
            .period => unreachable,
        }
        // Typed in full: on to the minutes.
        if (seg == .hours and (digits == 2 or n * 10 >= top)) {
            c.focus = ids[1];
            state.put(c, ids[1], salt_count, 0);
            c.changed = true;
            seg = .minutes;
            id = ids[1];
        }
    }
    const next: Time = .{ .hour = @intCast(h), .minute = @intCast(m) };
    if (std.meta.eql(next, time.*)) return false;
    time.* = next;
    c.changed = true;
    return true;
}
