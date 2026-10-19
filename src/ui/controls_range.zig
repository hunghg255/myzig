//! Values between bounds: a range slider of two knobs, a stepper, a number
//! input, a meter, and the spinner of work of unknown length.
const std = @import("std");
const types = @import("types.zig");
const widgets = @import("widgets.zig");
const textfield = @import("textfield.zig");
const state = @import("controls_state.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

pub const RangeSliderOptions = struct {
    min: f64 = 0,
    max: f64 = 1,
    /// Above 0, values snap to `min` plus multiples of it, with tick marks.
    step: f64 = 0,
    width: f32 = 200,
};

const knob_w: f32 = 18;

/// A slider of two knobs setting `low` and `high`, as a price range: each
/// knob takes the keyboard focus, and the arrows, Home and End move it; a
/// press on the track moves the knob nearest to it. The knobs do not
/// cross. Returns true when a value changes.
pub fn rangeSlider(c: *Context, low: *f64, high: *f64, opts: RangeSliderOptions) bool {
    const th = c.theme;
    const lo = opts.min;
    const hi = opts.max;
    const ticks: usize = if (opts.step > 0 and (hi - lo) / opts.step <= 40) @intFromFloat(@round((hi - lo) / opts.step) + 1) else 0;
    const i = c.open(.{ .width = .{ .px = opts.width }, .height = .{ .px = if (ticks > 0) 30 else 22 }, .control = true }, null);
    defer c.end();
    const track = c.interact(i, .{});
    // Kept in order, whatever the app set.
    if (low.* > high.*) std.mem.swap(f64, low, high);
    low.* = std.math.clamp(low.*, lo, hi);
    high.* = std.math.clamp(high.*, lo, hi);

    const bar_y: f32 = 9;
    _ = c.leaf(.{ .absolute = true, .width = .fill, .height = .{ .px = 4 }, .radius = 2, .background = th.track, .offset = .{ .y = bar_y } }, .none, null);
    const fill = c.leaf(.{ .absolute = true, .height = .{ .px = 4 }, .radius = 2, .background = th.accent, .offset = .{ .y = bar_y } }, .none, null);
    if (ticks > 1) for (0..ticks) |k| {
        const f: f32 = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(ticks - 1));
        _ = c.leaf(.{ .absolute = true, .width = .{ .px = 1 }, .height = .{ .px = 4 }, .background = th.muted.alpha(0.6), .offset = .{ .x = knob_w / 2 + f * (opts.width - knob_w) - 0.5, .y = 24 } }, .none, null);
    };
    var knobs: [2]u32 = undefined;
    var its: [2]ctx_mod.Interaction = undefined;
    for (0..2) |k| {
        knobs[k] = c.leaf(.{ .absolute = true, .width = .{ .px = knob_w }, .height = .{ .px = knob_w }, .radius = knob_w / 2, .background = th.knob, .offset = .{ .y = 2 } }, .none, null);
        its[k] = c.interact(knobs[k], .{ .focusable = true });
        c.describe(its[k].id, .{ .role = .slider, .label = if (k == 0) "Minimum" else "Maximum", .range = .{ .min = lo, .max = hi, .now = if (k == 0) low.* else high.*, .step = opts.step } });
    }

    var changed = false;
    const setValue = struct {
        fn f(v: *f64, to: f64, from: f64, until: f64, o: RangeSliderOptions) bool {
            const x = state.snap(std.math.clamp(to, from, until), o.min, o.max, o.step);
            const y = std.math.clamp(x, from, until);
            if (y == v.*) return false;
            v.* = y;
            return true;
        }
    }.f;
    // The knob the pointer drags: pressed on, or nearest to the press.
    var which: ?usize = if (its[0].pressed) 0 else if (its[1].pressed) 1 else null;
    if (which == null and track.pressed) if (track.rect) |r| {
        const x = lo + @as(f64, std.math.clamp((c.input.mouse.x - r.x - knob_w / 2) / @max(1, r.w - knob_w), 0, 1)) * (hi - lo);
        which = if (@abs(x - high.*) < @abs(x - low.*) or x > high.*) 1 else 0;
        // The knob holds the press from now on, and takes the focus.
        c.active = its[which.?].id;
        c.focus = its[which.?].id;
    };
    if (which) |k| if (track.rect) |r| {
        const x = lo + @as(f64, std.math.clamp((c.input.mouse.x - r.x - knob_w / 2) / @max(1, r.w - knob_w), 0, 1)) * (hi - lo);
        changed = if (k == 0) setValue(low, x, lo, high.*, opts) else setValue(high, x, low.*, hi, opts);
    };
    const key_step = if (opts.step > 0) opts.step else (hi - lo) / 100;
    for (0..2) |k| {
        if (!(its[k].focused and c.focus == its[k].id)) continue;
        const v = if (k == 0) low else high;
        const from = if (k == 0) lo else low.*;
        const until = if (k == 0) high.* else hi;
        const key = c.input.key orelse continue;
        const to: ?f64 = switch (key) {
            .left, .down => v.* - key_step,
            .right, .up => v.* + key_step,
            .home => from,
            .end => until,
            else => null,
        };
        if (to) |t| {
            c.input.key = null;
            if (setValue(v, t, from, until, opts)) changed = true;
        }
    }

    const span = opts.width - knob_w;
    const x0 = state.fraction(low.*, lo, hi) * span;
    const x1 = state.fraction(high.*, lo, hi) * span;
    c.node(fill).style.offset.x = x0 + knob_w / 2;
    c.node(fill).style.width = .{ .px = x1 - x0 };
    for (0..2) |k| {
        const n = c.node(knobs[k]);
        n.style.offset.x = if (k == 0) x0 else x1;
        const held = c.animate(its[k].id, 0, if (its[k].pressed or its[k].hovered) 1 else 0, 20);
        n.style.border = th.border.mix(th.accent, held);
        n.style.shadow = .{ .color = .{ .a = 0.2 + 0.1 * held }, .blur = 3 + 2 * held, .y = 1 };
        state.focusRing(c, knobs[k], its[k].focused and c.focus == its[k].id);
    }
    if (changed) c.changed = true;
    return changed;
}

pub const StepperOptions = struct {
    min: f64 = 0,
    max: f64 = 100,
    step: f64 = 1,
};

/// A pair of arrows changing `value` by a step, as AppKit's stepper beside
/// a field: a click steps, holding an arrow keeps stepping (faster after a
/// while), and Up, Down, Home and End step with the keyboard focus.
/// Returns true when the value changes.
pub fn stepper(c: *Context, value: *f64, opts: StepperOptions) bool {
    const th = c.theme;
    const i = c.open(.{ .width = .{ .px = 20 }, .radius = 6, .background = th.surface, .border = th.border, .clip = true, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{ .focusable = true });
    c.describe(it.id, .{ .role = .stepper, .range = .{ .min = opts.min, .max = opts.max, .now = value.*, .step = opts.step } });
    var next = value.*;
    for ([_]bool{ true, false }) |up| {
        const a = c.open(.{ .width = .fill, .height = .{ .px = 13 }, .align_items = .center, .justify = .center }, null);
        const ai = c.interact(a, .{});
        const can = if (up) value.* < opts.max else value.* > opts.min;
        const hover = c.animate(ai.id, 0, if (ai.hovered and can) 1 else 0, 20);
        c.node(a).style.background = th.surface.mix(th.surface_hover, hover).mix(th.border, if (ai.pressed and can) 0.6 else 0);
        widgets.icon(c, if (up) "chevron.up" else "chevron.down", .{ .size = 9, .weight = .bold, .color = if (can) th.text else th.muted.alpha(0.5) });
        c.end();
        // A press steps at once, and again while held: every 80 ms after
        // 400 ms, as AppKit's.
        if (ai.pressed) {
            if (c.input.pressed) {
                state.put(c, ai.id, 0, @floatCast(c.time));
                state.put(c, ai.id, 1, 0);
            }
            const start = state.get(c, ai.id, 0, @floatCast(c.time));
            var done = state.get(c, ai.id, 1, 0);
            const held: f32 = @as(f32, @floatCast(c.time)) - start;
            const due: f32 = 1 + if (held > 0.4) @floor((held - 0.4) / 0.08) else 0;
            while (done < due) : (done += 1) next += if (up) opts.step else -opts.step;
            state.put(c, ai.id, 1, done);
            c.focus = it.id;
            c.frameIn(0.08);
        }
    }
    if (it.focused or c.focus == it.id) if (c.input.key) |key| {
        const to: ?f64 = switch (key) {
            .up, .right => next + opts.step,
            .down, .left => next - opts.step,
            .home => opts.min,
            .end => opts.max,
            else => null,
        };
        if (to) |t| {
            c.input.key = null;
            next = t;
        }
    };
    state.focusRing(c, i, c.focus == it.id);
    next = state.snap(next, opts.min, opts.max, opts.step);
    if (next == value.*) return false;
    value.* = next;
    c.changed = true;
    return true;
}

pub const NumberInputOptions = struct {
    min: f64 = 0,
    max: f64 = 100,
    step: f64 = 1,
    width: types.Length = .{ .px = 80 },
};

/// A text field editing `value` as a number between bounds, which Up and
/// Down, and the − and + buttons beside it, change by the step. What is
/// typed applies as soon as it is a number in range, and shows rounded to
/// the step's decimals once the field loses the focus. `text` is the
/// field's text, kept by the app. Returns true when the value changes.
pub fn numberInput(c: *Context, value: *f64, text: *textfield.TextBuffer, opts: NumberInputOptions) bool {
    _ = c.open(.{ .direction = .row, .gap = 4, .align_items = .center }, null);
    defer c.end();
    const decimals = state.decimalsOf(opts.step);
    var next = value.*;
    // The field's id, to read its keys before it does (Up and Down step).
    const field_id = c.peekId(null);
    const focused = c.focus == field_id;
    var stepped = false;
    if (focused) if (c.input.key) |key| switch (key) {
        .up, .down => {
            next = state.snap(next + if (key == .up) opts.step else -opts.step, opts.min, opts.max, opts.step);
            c.input.key = null;
            stepped = true;
        },
        else => {},
    };
    if (!focused and !std.mem.eql(u8, text.text(), state.formatNumber(c, value.*, decimals))) text.set(state.formatNumber(c, value.*, decimals));
    const r = textfield.textField(c, text, .{ .width = opts.width });
    if (r.changed) if (std.fmt.parseFloat(f64, std.mem.trim(u8, text.text(), " "))) |v| {
        if (v >= opts.min and v <= opts.max) next = v;
    } else |_| {};
    if (widgets.button(c, "−", .{ .size = 13, .disabled = next <= opts.min }).clicked) {
        next = state.snap(next - opts.step, opts.min, opts.max, opts.step);
        stepped = true;
    }
    if (widgets.button(c, "+", .{ .size = 13, .disabled = next >= opts.max }).clicked) {
        next = state.snap(next + opts.step, opts.min, opts.max, opts.step);
        stepped = true;
    }
    if (stepped) text.set(state.formatNumber(c, next, decimals));
    if (next == value.*) return false;
    value.* = next;
    c.changed = true;
    return true;
}

pub const MeterOptions = struct {
    min: f64 = 0,
    max: f64 = 1,
    /// The levels from which the value shows it is worse: the warning
    /// color from `warning`, the danger color from `critical`. A critical
    /// below the warning makes low values the bad ones, as a battery's.
    warning: ?f64 = null,
    critical: ?f64 = null,
    width: types.Length = .{ .px = 160 },
};

/// The color a meter shows `value` in.
pub fn meterColor(c: *Context, value: f64, opts: MeterOptions) types.Color {
    const w = opts.warning orelse opts.critical orelse return c.theme.success;
    const cr = opts.critical orelse std.math.inf(f64);
    const low = cr < w;
    if (if (low) value <= cr else value >= cr) return c.theme.danger;
    if (opts.warning != null and (if (low) value <= w else value >= w)) return state.warning(c);
    return c.theme.success;
}

/// A bar showing a value between bounds, as AppKit's level indicator and
/// the web's meter: green, or orange and red from the levels given.
pub fn meter(c: *Context, value: f64, opts: MeterOptions) void {
    const th = c.theme;
    const t = state.fraction(value, opts.min, opts.max);
    _ = c.open(.{ .direction = .row, .width = opts.width, .height = .{ .px = 8 }, .radius = 4, .background = th.track, .clip = true }, null);
    defer c.end();
    c.describeOpen(.{ .role = .meter, .range = .{ .min = opts.min, .max = opts.max, .now = value } });
    _ = c.leaf(.{ .grow = t, .height = .fill, .radius = 4, .background = meterColor(c, value, opts) }, .none, null);
    _ = c.leaf(.{ .grow = 1 - t }, .none, null);
}

pub const SpinnerOptions = struct {
    size: f32 = 18,
    color: ?types.Color = null,
};

const spokes = 12;
const turn: f64 = 0.9;

/// The spoke leading at `time`: a twelfth of a turn every twelfth of 0.9 s.
pub fn spinnerStep(time: f64) u8 {
    const in_turn = @mod(time, turn);
    return @intCast(@min(spokes - 1, @as(u32, @intFromFloat(in_turn * spokes / turn))));
}

/// An indicator of work of unknown length, as AppKit's spinning one: dots
/// round a circle, fading behind the one leading, a step every twelfth of
/// 0.9 s on the context's clock. It asks for a frame only at each step.
pub fn spinner(c: *Context, opts: SpinnerOptions) void {
    const color = opts.color orelse c.theme.muted;
    const s = opts.size;
    _ = c.open(.{ .width = .{ .px = s }, .height = .{ .px = s } }, null);
    defer c.end();
    // Progress of unknown length: no range.
    c.describeOpen(.{ .role = .progress, .label = "Loading" });
    const lead = spinnerStep(c.time);
    const next_at = (@floor(c.time / (turn / spokes)) + 1) * (turn / spokes);
    c.frameIn(@floatCast(@max(0.001, next_at - c.time)));
    const dot = s * 0.16;
    const radius = s / 2 - dot / 2;
    for (0..spokes) |k| {
        const a = @as(f32, @floatFromInt(k)) * 2 * std.math.pi / spokes - std.math.pi / 2.0;
        const age: f32 = @floatFromInt((lead + spokes - k) % spokes);
        _ = c.leaf(.{
            .absolute = true,
            .width = .{ .px = dot },
            .height = .{ .px = dot },
            .radius = dot / 2,
            .background = color.alpha(1 - age / spokes * 0.85),
            .offset = .{ .x = s / 2 - dot / 2 + radius * @cos(a), .y = s / 2 - dot / 2 + radius * @sin(a) },
        }, .none, null);
    }
}
