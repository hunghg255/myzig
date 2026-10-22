//! The 29 loading.dev indicators, drawn through myzig's portable canvas.
const std = @import("std");
const ui = @import("myzig").ui;
pub const indicators = @import("indicators.zig");
pub const drawing = @import("drawing.zig");
pub const Kind = enum {
    arc,
    atom,
    blocks,
    bouncing_dots,
    cascade,
    circular_dots,
    classic,
    classic_v2,
    clock,
    comet,
    compass,
    dual,
    eclipse,
    flip,
    gather,
    leap,
    linear_dots,
    loading,
    morph,
    orbit,
    pulse,
    radar,
    ring,
    ripple,
    slide,
    snake,
    swirl,
    trace,
    wave,
};
pub const Easing = drawing.Easing;
pub const Cap = drawing.Cap;
pub const Sweep = enum { diagonal, rows, columns };
pub const Direction = enum { out, in };
pub const Origin = enum { center, bottom };
pub const Options = struct {
    size: f32 = 20,
    color: ?ui.Color = null,
    /// Seconds per cycle; null uses the indicator's own duration.
    duration: ?f64 = null,
    paused: bool = false,
    easing: Easing = .linear,
    cap: Cap = .round,
    sweep: Sweep = .diagonal,
    direction: Direction = .out,
    origin: Origin = .center,
    label: ?[]const u8 = null,
};

/// Each instance owns its clock. Keep it in app state, as a TextBuffer.
pub const Indicator = struct {
    frame: ?u64 = null,
    seconds: f64 = 0,
    last: ?f64 = null,
    paused: bool = false,

    pub fn show(s: *Indicator, c: *ui.Context, kind: Kind, o: Options) u32 {
        std.debug.assert(std.math.isFinite(o.size) and o.size > 0);
        const i: usize = @backingInt(kind);
        const duration = o.duration orelse indicators.cycles[i];
        std.debug.assert(std.math.isFinite(duration) and duration > 0);
        const still = ui.preferences.get(c).reduce_motion;
        const id = c.peekId(null);
        const whole: ui.Rect = .{ .w = o.size * indicators.aspect(i), .h = o.size };
        const v = @import("myzig").ui.canvasVisibility(c, id, whole).intersect(whole);
        const visible = v.w > 0 and v.h > 0;
        if (s.last) |last| if (!s.paused and visible and s.frame != null and c.frame <= s.frame.? + 1) {
            s.seconds += @max(0, c.time - last);
        };
        s.last = c.time;
        s.frame = c.frame;
        s.paused = o.paused or still or !visible;
        const f: indicators.Frame = .{ .index = i, .seconds = s.seconds * indicators.cycles[i] / duration, .options = .{
            .color = o.color orelse c.theme.text,
            .easing = o.easing,
            .cap = o.cap,
            .still = still,
            .sweep = o.sweep,
            .direction = o.direction,
            .origin = o.origin,
        } };
        const box = ui.canvas(c, .{ .w = o.size * indicators.aspect(i), .h = o.size }, .{}, &f, indicators.Frame.draw);
        c.describe(c.node(box).id, .{ .role = .progress, .label = o.label orelse indicators.names[i], .range = .{ .now = -1 } });
        if (!o.paused and !still) {
            if (visible) c.animationFrame() else if (c.rects.get(id) == null) c.animationFrame();
        }
        return box;
    }
};

pub const names = indicators.names;

test {
    _ = drawing;
    _ = @import("tests.zig");
    _ = @import("widget_test.zig");
    _ = @import("clock_test.zig");
}
