//! The bar of a scrolling box: where it sits, and dragging its thumb. Paint
//! records each bar (`paint.zig`), and the next frame's press on a thumb or
//! its track takes the pointer until the button goes up, before any view sees
//! it. A press on the track brings the thumb's middle there.
const std = @import("std");
const types = @import("types.zig");
const Context = @import("context.zig").Context;

/// How thick the bar is drawn, and how far from the edge a press finds it.
pub const thickness: f32 = 6;
const reach: f32 = 14;
/// How far from the edge a press finds the track: less than the thumb's, as
/// what scrolls can have controls near the edge.
const track_reach: f32 = 8;
const min_thumb: f32 = 24;

/// A bar as it was painted.
pub const Bar = struct {
    id: u64,
    horizontal: bool,
    /// Where the thumb can be found: as long as it is, `reach` thick.
    grip: types.Rect,
    /// Where the track can be found.
    track: types.Rect,
    /// The thumb's start along the bar, and where its track starts.
    thumb_start: f32,
    track_start: f32,
    /// How far the thumb can travel, and the offset that takes it there.
    span: f32,
    max: f32,
    /// How long the thumb is.
    thumb_len: f32,
    /// The hits recorded before this bar: those after it are over it.
    hits_below: usize,
};

pub const Drag = struct {
    id: u64,
    horizontal: bool,
    /// The pointer's place along the bar, from the thumb's start.
    grab: f32,
    track_start: f32,
    span: f32,
    max: f32,
};

/// The bar of a box of `view` along its axis at `start`, with `content` to
/// show and scrolled to `offset`; null when everything fits. `edge` is the
/// far side of the box, across the axis, as far as it can be seen.
pub const Geometry = struct { thumb: types.Rect, thumb_start: f32, track_start: f32, span: f32, max: f32, grip: types.Rect, track: types.Rect };

pub fn geometry(horizontal: bool, start: f32, view: f32, content: f32, offset: f32, edge: f32) ?Geometry {
    if (content <= view + 0.5 or view <= 0) return null;
    const length = @max(min_thumb, view * view / content);
    const span = @max(0, view - length);
    const max = content - view;
    const at = start + span * std.math.clamp(offset / max, 0, 1);
    return .{
        .thumb_start = at,
        .track_start = start,
        .span = span,
        .max = max,
        .thumb = if (horizontal)
            .{ .x = at + 2, .y = edge - thickness - 1, .w = length - 4, .h = thickness }
        else
            .{ .x = edge - thickness - 1, .y = at + 2, .w = thickness, .h = length - 4 },
        .grip = if (horizontal)
            .{ .x = at, .y = edge - reach, .w = length, .h = reach }
        else
            .{ .x = edge - reach, .y = at, .w = reach, .h = length },
        .track = if (horizontal)
            .{ .x = start, .y = edge - track_reach, .w = view, .h = track_reach }
        else
            .{ .x = edge - track_reach, .y = start, .w = track_reach, .h = view },
    };
}

fn along(c: *const Context, horizontal: bool) f32 {
    return if (horizontal) c.input.mouse.x else c.input.mouse.y;
}

/// Before a frame's views: a thumb's drag moves its box, and a press on a
/// thumb starts one. Views see neither.
pub fn input(c: *Context) void {
    if (c.bar_drag) |d| {
        c.input.pressed = false;
        c.input.released = false;
        if (!c.input.down) {
            c.bar_drag = null;
            return;
        }
        const t = if (d.span > 0) std.math.clamp((along(c, d.horizontal) - d.grab - d.track_start) / d.span, 0, 1) else 0;
        c.scroll.put(c.gpa, d.id, t * d.max) catch {};
        return;
    }
    if (!c.input.pressed) return;
    var i = c.bars.items.len;
    while (i > 0) {
        i -= 1;
        const b = c.bars.items[i];
        const on_thumb = b.grip.contains(c.input.mouse);
        if (!on_thumb and !b.track.contains(c.input.mouse)) continue;
        if (covered(c, b)) continue;
        const length = b.thumb_len;
        const at = along(c, b.horizontal);
        const grab = if (on_thumb) at - b.thumb_start else length / 2;
        if (!on_thumb) {
            const t = if (b.span > 0) std.math.clamp((at - grab - b.track_start) / b.span, 0, 1) else 0;
            c.scroll.put(c.gpa, b.id, t * b.max) catch {};
        }
        c.bar_drag = .{
            .id = b.id,
            .horizontal = b.horizontal,
            .grab = grab,
            .track_start = b.track_start,
            .span = b.span,
            .max = b.max,
        };
        c.input.pressed = false;
        return;
    }
}

/// Something painted after the bar is under the pointer: a dialog over it.
fn covered(c: *const Context, b: Bar) bool {
    if (b.hits_below >= c.hits.items.len) return false;
    for (c.hits.items[b.hits_below..]) |h| if (!h.scroll and h.contains(c.input.mouse)) return true;
    return false;
}
