//! The toasts' view (`toast.zig`), after sonner: a stack in a corner, the
//! newest in front and the others peeking out behind it, smaller and
//! blank, spread out under the pointer; each comes in from the edge, goes
//! back to it as it leaves, and follows a swipe toward the edge away.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const widgets = @import("widgets.zig");
const base = @import("overlay_base.zig");
const motion = @import("motion.zig");
const direction = @import("direction.zig");
const spinner = @import("controls_range.zig").spinner;
const toast = @import("toast.zig");
const Context = ctx_mod.Context;
const Color = types.Color;
const Toasts = toast.Toasts;
const Item = toast.Item;

/// A toast's width, and the window's below which toasts take its width.
pub const width: f32 = 356;
const narrow: f32 = 600;
/// A swipe this far, or this fast (points a second), closes a toast.
pub const swipe_distance: f32 = 45;
const swipe_speed: f32 = 110;
/// A toast leaving is gone after this.
const leave_seconds: f64 = 0.2;
/// The height a toast is taken to be until laid out.
const guess_title: f32 = 52;
const guess_description: f32 = 70;
/// CSS's `ease`, which sonner's transitions use.
const ease = motion.Easing.cubicBezier(0.25, 0.1, 0.25, 1);

fn over(s: f32) motion.Animation {
    return .curve(s, ease);
}

const Look = struct { background: Color, border: Color, text: Color, muted: Color };

/// sonner's rich colors: background, border and text, light then dark.
fn richColors(kind: toast.Kind, dark: bool) ?[3]Color {
    const v: [3]u24 = switch (kind) {
        .success => if (dark) .{ 0x001f0f, 0x003d1c, 0x59f3a6 } else .{ 0xecfdf3, 0xbffcd9, 0x008a2e },
        .info => if (dark) .{ 0x000d1f, 0x19233e, 0x5896f3 } else .{ 0xf0f8ff, 0xdde7fd, 0x0973dc },
        .warning => if (dark) .{ 0x1d1f00, 0x2e2e00, 0xf3cf58 } else .{ 0xfffcf0, 0xfbeeb1, 0xdc7609 },
        .@"error" => if (dark) .{ 0x2d0607, 0x4d0408, 0xff9ea1 } else .{ 0xfff0f0, 0xffe0e1, 0xe60000 },
        else => return null,
    };
    return .{ .hex(v[0]), .hex(v[1]), .hex(v[2]) };
}

fn lookOf(s: *const Toasts, it: *const Item, th: anytype) Look {
    if (it.rich_colors orelse s.rich_colors) if (richColors(it.kind, th.dark)) |r|
        return .{ .background = r[0], .border = r[1], .text = r[2], .muted = r[2] };
    if (s.invert) return .{ .background = th.text, .border = th.text.mix(th.background, 0.2), .text = th.background, .muted = th.background.alpha(0.75) };
    return .{ .background = th.surface, .border = th.border, .text = th.text, .muted = th.muted };
}

fn heightOf(it: *const Item) f32 {
    if (it.height > 0) return it.height;
    return if (it.description.len > 0) guess_description else guess_title;
}

fn contains(r: types.Rect, p: types.Point) bool {
    return p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h;
}

/// How far a swipe moves a toast along an axis: all the way toward a way
/// it may leave, held back the other way, not at all on an axis it can't.
fn follow(delta: f32, forth: bool, back: bool) f32 {
    if ((delta > 0 and forth) or (delta < 0 and back)) return delta;
    if (forth or back) return delta / (1.5 + @abs(delta) / 20);
    return 0;
}

/// Whether a toast may leave along `axis` (1 x, 2 y) the way of `sign`.
fn leaves(s: *const Toasts, axis: u2, sign: f32) bool {
    if (s.swipe_directions) |d| return if (axis == 2) (if (sign > 0) d.bottom else d.top) else (if (sign > 0) d.right else d.left);
    if (axis == 2) return if (s.position.bottom()) sign > 0 else sign < 0;
    const side = s.position.side();
    return (side > 0 and sign > 0) or (side < 0 and sign < 0);
}

/// Builds the window's toasts over everything else, in `s.position`: call
/// it once in the view, last, to be over the other overlays. The pointer
/// goes through the room around them.
pub fn toasts(c: *Context, s: *Toasts) toast.Result {
    var result: toast.Result = .{ .timed_out = s.tick(c) };
    // Gone once left.
    var r: usize = s.len;
    while (r > 0) {
        r -= 1;
        const it = &s.items[r];
        if (it.closing and it.closed_at >= 0 and c.time - it.closed_at >= leave_seconds) s.removeAt(r);
    }
    if (s.len == 0) {
        s.hovered = false;
        s.by_keys = false;
        s.paused = false;
        return result;
    }
    const th = c.theme;
    const small = c.size.w < narrow;
    const edge: f32 = if (small) 16 else s.offset;
    const w: f32 = if (small) @max(0, c.size.w - 32) else width;
    const bottom = s.position.bottom();
    const content_direction = direction.current(c);

    // Places, newest first among those not leaving: where each is spread
    // out (the heights of those newer and the gaps), and the front's height.
    var index_of: [toast.capacity]usize = undefined;
    var offset_of: [toast.capacity]f32 = undefined;
    var newer: f32 = 0;
    var front_h: f32 = 0;
    var live: usize = 0;
    var i: usize = s.len;
    while (i > 0) {
        i -= 1;
        const it = &s.items[i];
        if (it.closing) continue;
        index_of[i] = live;
        offset_of[i] = newer + s.gap * @as(f32, @floatFromInt(live));
        if (live == 0) front_h = heightOf(it);
        if (live < s.visible) newer += heightOf(it);
        live += 1;
    }
    var to_front = false;
    if (s.hotkey and live > 0 and c.shortcut(.{ .key = 't', .alt = true })) {
        if (!s.by_keys) s.return_focus = c.focus;
        s.by_keys = true;
        to_front = true;
    }
    const expanded = live > 0 and (s.expand or s.hovered or s.by_keys);
    const shown: f32 = @floatFromInt(@min(live, s.visible));
    const gaps = s.gap * @max(0, shown - 1);
    const area: f32 = if (live == 0) 0 else if (expanded) newer + gaps else front_h + gaps;

    const lo: u32 = @intCast(c.nodes.items.len);
    const root = base.overlay(c, .{
        .absolute = true,
        .width = .fill,
        .height = .fill,
        .padding = .all(edge),
        .justify = if (bottom) .end else .start,
        .align_items = switch (s.position.side()) {
            -1 => .start,
            0 => .center,
            else => .end,
        },
    }, base.seedOf(s));
    // Corners are the window's; what is in a toast follows the text's way.
    direction.scope(c, root, .ltr);
    const list = c.open(.{ .width = .{ .px = w }, .height = .{ .px = area } }, null);
    const list_id = c.node(list).id;
    var pointer_over = if (c.rects.get(list_id)) |rect| contains(rect, c.input.mouse) else false;
    var swiping = false;
    var front_id: u64 = 0;

    i = 0;
    while (i < s.len) : (i += 1) {
        const it = &s.items[i];
        if (it.closing and it.closed_at < 0) it.closed_at = c.time;
        const k = if (it.closing) it.last_index else index_of[i];
        const hidden = !it.closing and k >= s.visible;
        const spread = expanded or k == 0;
        var h: f32 = undefined;
        var y: f32 = undefined;
        var scale: f32 = undefined;
        var move = over(0.4);
        var fade = over(0.4);
        if (!it.closing) {
            h = if (spread) heightOf(it) else front_h;
            const off = if (expanded) offset_of[i] else s.gap * @as(f32, @floatFromInt(k));
            y = if (bottom) -h - off else off;
            scale = if (spread) 1 else 1 - 0.05 * @as(f32, @floatFromInt(k));
            it.last_y = y;
            it.last_h = h;
            it.last_index = k;
            it.last_expanded = expanded;
        } else {
            h = it.last_h;
            y = it.last_y;
            scale = if (it.last_expanded or k == 0) 1 else 1 - 0.05 * @as(f32, @floatFromInt(k));
            if (it.swipe.out) {
                move = .curve(0.2, .ease_out);
                fade = .curve(0.2, .ease_out);
            } else if (k == 0 or it.last_expanded) {
                y += if (bottom) h else -h;
            } else {
                y += 0.4 * h;
                move = over(0.5);
                fade = over(0.2);
            }
        }

        c.next_key_int = it.id;
        const box = c.open(.{ .absolute = true, .width = .fill }, null);
        const bid = c.node(box).id;
        if (it.fresh) {
            // In from the edge.
            _ = motion.jump(c, bid, "y", if (bottom) y + h else y - h);
            // Not quite transparent: screen readers see it from its first frame.
            _ = motion.jump(c, bid, "o", 0.02);
            _ = motion.jump(c, bid, "h", h);
            _ = motion.jump(c, bid, "scale", scale);
            _ = motion.jump(c, bid, "x", 0);
            _ = motion.jump(c, bid, "sy", 0);
            it.fresh = false;
            c.announce(it.title.get());
        } else if (it.changed) c.announce(it.title.get());
        it.changed = false;
        c.describe(bid, .{ .role = .status, .label = it.title.get(), .description = it.description.get() });
        const yv = motion.animateTo(c, bid, "y", y, move);
        const hv = motion.animateTo(c, bid, "h", h, over(0.4));
        const sv = motion.animateTo(c, bid, "scale", scale, over(0.4));
        const ov = motion.animateTo(c, bid, "o", if (it.closing or hidden) 0 else 1, fade);
        const sx = if (it.swipe.on) motion.jump(c, bid, "x", it.swipe.x) else motion.animateTo(c, bid, "x", it.swipe.x, if (it.swipe.out) move else over(0.4));
        const sy = if (it.swipe.on) motion.jump(c, bid, "sy", it.swipe.y) else motion.animateTo(c, bid, "sy", it.swipe.y, if (it.swipe.out) move else over(0.4));
        const look = lookOf(s, it, th);
        const st = &c.node(box).style;
        st.height = .{ .px = @max(0, hv) };
        st.offset = .{ .y = (if (bottom) area else 0) + yv };
        st.transform = types.Affine.scaling(sv, sv).then(.translation(sx, sy));
        st.opacity = ov;
        st.background = look.background;
        st.border = look.border;
        st.radius = 8;
        st.shadow = .{ .color = Color.black.alpha(0.1), .blur = 12, .y = 4 };

        if (!it.closing and !hidden) {
            const hit = c.interact(box, .{ .focusable = true });
            if (k == 0) front_id = bid;
            if (hit.hovered) pointer_over = true;
            swipe(c, s, it, bid, w, h, &result);
            if (it.swipe.on) swiping = true;
        }
        content(c, s, it, look, spread, bid, w, content_direction, &result);
        c.end();
    }
    c.end();
    c.end();
    s.hovered = pointer_over or swiping;
    // Escape takes the keyboard back; so does the focus leaving them.
    const inside = base.focusIn(c, lo, @intCast(c.nodes.items.len));
    if (to_front and front_id != 0) {
        c.focus = front_id;
        c.focus_visible = true;
        c.changed = true;
    } else if (s.by_keys) {
        if (!inside) {
            s.by_keys = false;
        } else if (base.takeKey(c, .escape)) {
            s.by_keys = false;
            c.focus = s.return_focus;
            c.changed = true;
        }
    }
    s.paused = s.hovered or s.by_keys;
    if (!s.paused) {
        var soonest: ?f32 = null;
        for (s.items[0..s.len]) |it| if (!it.closing and it.left >= 0) {
            soonest = if (soonest) |v| @min(v, it.left) else it.left;
        };
        if (soonest) |v| c.frameIn(v);
    }
    for (s.items[0..s.len]) |it| if (it.closing) c.frameIn(@floatCast(@max(0.001, leave_seconds - (c.time - it.closed_at))));
    return result;
}

/// Follows a swipe of the toast and closes it when it goes far or fast
/// enough toward a way it may leave.
fn swipe(c: *Context, s: *Toasts, it: *Item, bid: u64, w: f32, h: f32, result: *toast.Result) void {
    const sw = &it.swipe;
    if (c.input.pressed and c.hot == bid and it.dismissible and it.kind != .loading) {
        sw.* = .{ .on = true, .start = c.input.mouse, .start_time = c.time };
        return;
    }
    if (!sw.on) return;
    const dx = c.input.mouse.x - sw.start.x;
    const dy = c.input.mouse.y - sw.start.y;
    if (sw.axis == 0 and @max(@abs(dx), @abs(dy)) > 1) sw.axis = if (@abs(dx) > @abs(dy)) 1 else 2;
    if (c.input.down) {
        sw.x = if (sw.axis == 1) follow(dx, leaves(s, 1, 1), leaves(s, 1, -1)) else 0;
        sw.y = if (sw.axis == 2) follow(dy, leaves(s, 2, 1), leaves(s, 2, -1)) else 0;
        c.changed = c.changed or sw.x != 0 or sw.y != 0;
        return;
    }
    // Let go.
    sw.on = false;
    const amount = if (sw.axis == 1) sw.x else sw.y;
    const seconds: f32 = @floatCast(@max(0.001, c.time - sw.start_time));
    const fast = @abs(amount) / seconds > swipe_speed;
    if (sw.axis != 0 and amount != 0 and leaves(s, sw.axis, std.math.sign(amount)) and (@abs(amount) >= swipe_distance or fast)) {
        sw.out = true;
        // On out of sight the way it went.
        if (sw.axis == 1) sw.x += std.math.sign(amount) * w else sw.y += std.math.sign(amount) * h;
        it.closing = true;
        result.closed = it.id;
    } else {
        sw.x = 0;
        sw.y = 0;
    }
    c.changed = true;
}

/// A toast's icon: the app's, its kind's, or a spinner while loading. Done
/// loading, the new icon grows in from 0.8 as sonner's does.
fn icon(c: *Context, it: *Item, look: Look, bid: u64) void {
    const name: []const u8 = if (it.icon.len > 0) it.icon.get() else switch (it.kind) {
        .normal, .loading => "",
        .success => "checkmark.circle.fill",
        .info => "info.circle.fill",
        .warning => "exclamationmark.triangle.fill",
        .@"error" => "exclamationmark.circle.fill",
    };
    if (it.kind != .loading and name.len == 0) return;
    const box = c.open(.{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .align_items = .center, .justify = .center }, null);
    if (it.settled) {
        _ = motion.jump(c, bid, "icon", 0);
        it.settled = false;
    }
    const v = motion.animateTo(c, bid, "icon", 1, over(0.3));
    const st = &c.node(box).style;
    st.opacity = v;
    st.transform = types.Affine.scaling(0.8 + 0.2 * v, 0.8 + 0.2 * v);
    if (it.kind == .loading and it.icon.len == 0) {
        spinner(c, .{ .size = 16, .color = look.muted });
    } else widgets.icon(c, name, .{ .size = 16, .color = look.text });
    c.end();
    _ = c.leaf(.{ .width = .{ .px = 4 } }, .none, null);
}

/// What a toast shows: its icon, title and description, Cancel and the
/// action, and its close button at the corner.
fn content(c: *Context, s: *const Toasts, it: *Item, look: Look, spread: bool, bid: u64, w: f32, dir: direction.Direction, result: *toast.Result) void {
    const th = c.theme;
    const row = c.open(.{ .direction = .row, .width = .fill, .padding = .all(16), .gap = 6, .align_items = .center }, null);
    direction.scope(c, row, dir);
    c.node(row).style.opacity = motion.animateTo(c, bid, "content", if (spread) 1 else 0, over(0.4));
    if (it.content) |v| {
        // The app's own content, its icon and words.
        widgets.column(c, .{ .grow = 1 });
        v.build(v.ptr, c);
        widgets.end(c);
    } else {
        icon(c, it, look, bid);
        widgets.column(c, .{ .gap = 2, .grow = 1 });
        widgets.text(c, it.title.get(), .{ .size = 13, .weight = .medium, .color = look.text, .wrap = true });
        if (it.description.len > 0) widgets.text(c, it.description.get(), .{ .size = 13, .color = look.muted, .wrap = true });
        widgets.end(c);
    }
    if (it.cancel.len > 0) {
        const b = widgets.pressable(c, .{ .padding = .xy(8, 0), .height = .{ .px = 24 }, .align_items = .center, .justify = .center, .radius = 4, .control = true, .background = th.surface_hover }, th.border);
        widgets.text(c, it.cancel.get(), .{ .size = 12, .weight = .medium, .color = th.text });
        widgets.end(c);
        if (b.clicked and !it.closing) {
            result.cancel = it.id;
            if (it.dismissible) it.closing = true;
            c.changed = true;
        }
    }
    if (it.action.len > 0) {
        const b = widgets.pressable(c, .{ .padding = .xy(8, 0), .height = .{ .px = 24 }, .align_items = .center, .justify = .center, .radius = 4, .control = true, .background = th.accent }, th.accent_hover);
        widgets.text(c, it.action.get(), .{ .size = 12, .weight = .medium, .color = th.accent_text });
        widgets.end(c);
        if (b.clicked and !it.closing) {
            result.action = it.id;
            it.closing = true;
            c.changed = true;
        }
    }
    c.end();
    // Its height as its content asks, for the stack's places.
    if (c.rects.get(c.node(row).id)) |rect| if (@abs(rect.h - it.height) > 0.5) {
        it.height = rect.h;
        c.animationFrame();
    };
    if ((it.close_button orelse s.close_button) and it.kind != .loading) {
        const at_end = dir == .rtl;
        const x = widgets.pressable(c, .{
            .absolute = true,
            .width = .{ .px = 20 },
            .height = .{ .px = 20 },
            .radius = 10,
            .align_items = .center,
            .justify = .center,
            .background = look.background,
            .border = look.border,
            .control = true,
            .offset = .{ .x = if (at_end) w - 13 else -7, .y = -7 },
        }, th.surface_hover);
        c.describe(x.id, .{ .label = "Close toast" });
        widgets.icon(c, "xmark", .{ .size = 12, .color = look.text });
        widgets.end(c);
        if (x.clicked and !it.closing) {
            result.closed = it.id;
            it.closing = true;
            c.changed = true;
        }
    }
}
