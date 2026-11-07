//! Drawers, after vaul (github.com/emilkowalski/vaul): a panel from an edge
//! of the window, over its dimmed content, that the pointer drags: let go
//! far or fast enough toward the edge, it closes; else it settles back, or
//! at the nearest of its snap points.
//!
//!     if (ui.button(c, "Open", .{}).clicked) s.drawer.show();
//!     if (ui.drawer(c, &s.drawer, .{})) |d| {
//!         defer d.end();
//!         ui.text(c, "Move goal", .{ .weight = .semibold });
//!     }
//!
//! Wrapped in `drawerBackground`, the window's content shrinks back behind
//! an open drawer, as a sheet on iOS; a drawer opened from another
//! (`parent`) pushes that one back. Like a dialog, an open drawer keeps the
//! keyboard: Tab stays in it, and Escape and a press beside it close it
//! (`dismissible`); one that is not `modal` leaves the window as it is,
//! to use beside it. Dragging is `drawer_drag.zig`.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const base = @import("overlay_base.zig");
const dialog_mod = @import("dialog.zig");
const motion = @import("motion.zig");
const direction = @import("direction.zig");
const drag = @import("drawer_drag.zig");
const Context = ctx_mod.Context;

pub const Side = enum { bottom, top, left, right };

/// Where a drawer may rest open: a part of the room it has (`0.5`), or
/// so many points of it.
pub const Snap = union(enum) {
    fraction: f32,
    px: f32,

    pub fn size(s: Snap, extent: f32) f32 {
        return std.math.clamp(switch (s) {
            .fraction => |f| f * extent,
            .px => |p| p,
        }, 0, extent);
    }
};

pub const Options = struct {
    side: Side = .bottom,
    /// Where it rests, from the least open to the most; none: all open,
    /// as tall (or wide) as its content asks.
    snap_points: []const Snap = &.{},
    /// The snap point from which the window is dimmed (below it, what is
    /// behind stays as it is): the last when null.
    fade_from: ?usize = null,
    /// A press beside it, Escape and a drag close it; else it rests at its
    /// first snap point at least.
    dismissible: bool = true,
    /// The part of its size it must be dragged toward the edge to close.
    close_threshold: f32 = 0.25,
    /// The bar to grab it by, at its inner edge (bottom and top drawers).
    handle: bool = true,
    /// Only the handle drags it, not the rest of it.
    handle_only: bool = false,
    /// A throw goes one snap point at a time, never straight to the last
    /// (or closed), as vaul's `snapToSequentialPoint`.
    snap_to_sequential: bool = false,
    /// Its height (bottom, top) or width (left, right); null: its
    /// content's, for bottom and top, and 384 for left and right.
    size: ?f32 = null,
    /// The part of the window's height (or width) it takes at most.
    max: f32 = 0.8,
    padding: types.Edges = .all(16),
    gap: f32 = 12,
    label: []const u8 = "Drawer",
    /// The window behind is dimmed and takes no pointer, and Tab stays in
    /// the drawer; else what is behind is used as it is, a press there
    /// leaving the drawer open.
    modal: bool = true,
    /// The drawer this one opens from: it shrinks back and moves away from
    /// its edge as this one opens, following its drag. Build this one in
    /// that one's content.
    parent: ?*DrawerState = null,
};

/// Whether a drawer shows, kept by the app: `show` opens it.
pub const DrawerState = struct {
    open: bool = false,
    /// The snap point it rests at, from 0; kept by the drawer.
    snap: usize = 0,

    // Kept by the drawer.
    overlay: base.OverlayState = .{},
    /// From 0 (closed) to 1 (open), as the dimming and the background go.
    presence: f32 = 0,
    /// The presence `drawerBackground` drew with.
    presence_drawn: f32 = 0,
    /// The side it was built at, for the background.
    side: Side = .bottom,
    drag: drag.Drag = .{},
    /// The context's clock as it opened: a drag waits a moment after it.
    opened_at: f64 = 0,
    /// Its size along its axis, from the last layout; 0 unknown.
    extent: f32 = 0,
    /// How open a drawer nested in it is (`Options.parent`), as that one
    /// built it, and as this one drew with it.
    child: f32 = 0,
    child_drawn: f32 = 0,

    pub fn show(s: *DrawerState) void {
        s.open = true;
    }

    pub fn close(s: *DrawerState) void {
        s.open = false;
    }

    pub fn toggle(s: *DrawerState) void {
        s.open = !s.open;
    }

    /// Whether it shows, closing ones included.
    pub fn visible(s: *const DrawerState) bool {
        return s.open or s.overlay.open;
    }
};

/// vaul's transitions: half a second of a curve that starts fast.
pub const ease = motion.Easing.cubicBezier(0.32, 0.72, 0, 1);
pub const seconds: f32 = 0.5;
/// The room kept beyond the window's edge, so a drag past open shows no gap.
const beyond: f32 = 48;
/// How far a drawer moves back with one open from it (vaul's 16 points).
const nested_push: f32 = 16;

pub const Drawer = struct {
    c: *Context,
    state: *DrawerState,
    /// A modal drawer's dialog; else its boxes from `lo` on.
    dialog: ?dialog_mod.Dialog,
    lo: u32,
    opts: Options,

    pub fn end(d: Drawer) void {
        const c = d.c;
        if (d.opts.side == .top and d.opts.handle) handle(c, d.state, d.opts);
        // Escape closes it, unless something in it took Escape first.
        if (d.opts.dismissible and d.state.open and base.takeKey(c, .escape)) {
            d.state.open = false;
            d.state.overlay.dismissed = true;
            d.state.overlay.dismissed_frame = c.frame;
            c.changed = true;
        }
        if (d.dialog) |dl| return dl.end();
        c.end();
        c.end();
        d.state.overlay.record(c, d.lo);
    }
};

/// The boxes a drawer is built in: over the window and its panel.
const Frame = struct { backdrop: u32, panel: u32, lo: u32, dialog: ?dialog_mod.Dialog };

/// A modal drawer is a dialog; another is a panel over the window that
/// leaves the pointer and the focus to what is behind.
fn frame(c: *Context, state: *DrawerState, modal: bool) ?Frame {
    if (modal) {
        const d = dialog_mod.dialog(c, &state.overlay, .{ .bare = true, .dismissible = false, .escape = false, .animated = false }) orelse return null;
        return .{ .backdrop = d.backdrop, .panel = d.panel, .lo = d.lo, .dialog = d };
    }
    if (!state.overlay.sync(c)) return null;
    const lo: u32 = @intCast(c.nodes.items.len);
    const backdrop = base.overlay(c, .{ .absolute = true, .width = .fill, .height = .fill }, base.seedOf(&state.overlay));
    const panel = c.open(.{}, null);
    _ = c.interact(panel, .{});
    c.describe(c.node(panel).id, .{ .role = .dialog });
    return .{ .backdrop = backdrop, .panel = panel, .lo = lo, .dialog = null };
}

/// Tells the drawer a nested one opens from how open that one is.
fn tellParent(c: *Context, opts: Options, open: f32) void {
    const p = opts.parent orelse return;
    p.child = open;
    if (@abs(p.child_drawn - open) > 0.001) c.changed = true;
}

pub fn horizontal(side: Side) bool {
    return side == .left or side == .right;
}

/// The window's room along the drawer's axis.
pub fn room(c: *Context, side: Side) f32 {
    return if (horizontal(side)) c.size.w else c.size.h;
}

/// Its size along its axis: as given, else as laid out, else a guess.
pub fn extentOf(c: *Context, s: *const DrawerState, opts: Options) f32 {
    const most = room(c, opts.side) * opts.max;
    if (opts.size) |v| return @min(v, most);
    if (opts.snap_points.len > 0) return most;
    if (horizontal(opts.side)) return @min(384, most);
    return if (s.extent > 0) @min(s.extent, most) else most;
}

/// How far from open each snap point is, toward the edge: `out[i]`.
pub fn snapOffset(opts: Options, extent: f32, i: usize) f32 {
    if (opts.snap_points.len == 0) return 0;
    return @max(0, extent - opts.snap_points[@min(i, opts.snap_points.len - 1)].size(extent));
}

/// How dimmed the window is with the drawer `moved` points toward its
/// edge from open: 1 at the fading snap point and beyond, 0 at the one
/// below it (or closed).
pub fn presenceAt(opts: Options, extent: f32, moved: f32) f32 {
    const n = opts.snap_points.len;
    if (n == 0) return std.math.clamp(1 - moved / @max(1, extent), 0, 1);
    const from = @min(opts.fade_from orelse n - 1, n - 1);
    const full = snapOffset(opts, extent, from);
    const none = if (from == 0) extent else snapOffset(opts, extent, from - 1);
    if (none <= full) return if (moved <= full) 1 else 0;
    return std.math.clamp(1 - (moved - full) / (none - full), 0, 1);
}

/// Where it rests now: open, or at its snap point.
pub fn restAt(opts: Options, s: *const DrawerState, extent: f32) f32 {
    return snapOffset(opts, extent, s.snap);
}

/// A drawer at its side while `state.open`, and while it slides away;
/// null once gone.
pub fn drawer(c: *Context, state: *DrawerState, opts: Options) ?Drawer {
    // The overlay outlives `open` by its way out.
    if (state.open and !state.overlay.open) {
        state.overlay.open = true;
        state.opened_at = c.time;
        state.drag = .{};
    }
    // Closed from outside: by a dialog's means (an assistive press).
    if (state.overlay.dismissed and state.overlay.dismissed_frame == c.frame) state.open = false;
    const content_direction = direction.current(c);
    const d = frame(c, state, opts.modal) orelse {
        state.presence = 0;
        tellParent(c, opts, 0);
        return null;
    };
    state.side = opts.side;
    const id = base.seedOf(state);
    const extent = extentOf(c, state, opts);
    const all = room(c, opts.side);
    const opened = state.overlay.justOpened(c);
    if (opened) {
        state.snap = 0;
        _ = motion.jump(c, id, "moved", all);
    }
    const bid = c.node(d.backdrop).id;
    const pid = c.node(d.panel).id;
    // A press beside it.
    if (opts.modal and opts.dismissible and state.open and !opened and c.input.pressed and c.hot == bid) {
        state.open = false;
        c.changed = true;
    }
    const target = if (state.open) restAt(opts, state, extent) else all;
    const moved = drag.follow(c, state, opts, id, pid, extent, target);
    const presence = presenceAt(opts, extent, moved);
    state.presence = presence;
    if (@abs(state.presence_drawn - presence) > 0.001) c.changed = true;
    tellParent(c, opts, presence);
    // Gone once out of sight.
    if (!state.open and !state.drag.on and moved >= all - 0.5) {
        state.overlay.open = false;
        state.presence = 0;
        c.changed = true;
    }

    // Edges are physical; what is in it follows the text's way.
    direction.scope(c, d.backdrop, .ltr);
    direction.scope(c, d.panel, content_direction);
    const th = c.theme;
    const bs = &c.node(d.backdrop).style;
    if (opts.modal) bs.background = types.Color.black.alpha((if (th.dark) @as(f32, 0.5) else 0.3) * presence);
    bs.direction = if (horizontal(opts.side)) .row else .column;
    bs.align_items = .stretch;
    bs.justify = if (opts.side == .top or opts.side == .left) .start else .end;
    const ps = &c.node(d.panel).style;
    ps.* = .{
        .background = th.background,
        .border = th.border,
        .radius = 10,
        .gap = opts.gap,
        .padding = opts.padding,
        .clip = true,
        .shadow = .{ .color = th.shadow.alpha(2), .blur = 32 },
    };
    // It reaches past its edge, its corners there out of sight.
    switch (opts.side) {
        .bottom => {
            ps.padding.bottom += beyond;
            ps.offset.y = moved + beyond;
        },
        .top => {
            ps.padding.top += beyond;
            ps.offset.y = -moved - beyond;
        },
        .right => {
            ps.padding.right += beyond;
            ps.offset.x = moved + beyond;
        },
        .left => {
            ps.padding.left += beyond;
            ps.offset.x = -moved - beyond;
        },
    }
    // Pushed back by a drawer open from it, as vaul's nested drawers.
    const k = state.child;
    state.child_drawn = k;
    if (k > 0) {
        const s = 1 - nested_push / @max(1, c.size.w) * k;
        const away = nested_push * k;
        ps.transform = types.Affine.scaling(s, s).then(switch (opts.side) {
            .bottom => .translation(0, -away),
            .top => .translation(0, away),
            .right => .translation(-away, 0),
            .left => .translation(away, 0),
        });
    }
    const fixed = opts.size != null or opts.snap_points.len > 0 or horizontal(opts.side);
    if (horizontal(opts.side)) {
        ps.width = .{ .px = extent + beyond };
        ps.height = .fill;
    } else {
        ps.width = .fill;
        if (fixed) ps.height = .{ .px = extent + beyond } else ps.max_height = extent + beyond;
    }
    c.describe(pid, .{ .label = opts.label });
    // Its size as laid out, for the next frame's places.
    if (c.rects.get(pid)) |r| {
        const e = (if (horizontal(opts.side)) r.w else r.h) - beyond;
        if (e > 0 and @abs(e - state.extent) > 0.5) {
            state.extent = e;
            c.animationFrame();
        }
    }
    if (opts.side == .bottom and opts.handle) handle(c, state, opts);
    return .{ .c = c, .state = state, .dialog = d.dialog, .lo = d.lo, .opts = opts };
}

/// The bar to grab it by: a click on it goes to the next snap point, or
/// closes it from the last.
fn handle(c: *Context, s: *DrawerState, opts: Options) void {
    _ = c.open(.{ .width = .fill, .align_items = .center, .padding = .{ .top = if (opts.side == .bottom) 0 else 4, .bottom = if (opts.side == .bottom) 4 else 0 } }, null);
    const bar = c.open(.{ .width = .{ .px = 100 }, .height = .{ .px = 8 }, .radius = 4, .background = c.theme.surface_hover }, "handle");
    const hit = c.interact(bar, .{});
    c.describe(hit.id, .{ .role = .button, .label = "Drag to resize" });
    s.drag.handle = hit.id;
    c.end();
    c.end();
    // A long press is not a click (vaul's quarter of a second).
    if (hit.clicked and !s.drag.moved and c.time - s.drag.start_time < 0.25) drag.cycle(c, s, opts);
}

/// The window's content behind a drawer, shrinking back as it opens:
/// open it first in the view, around the rest, then `end`.
pub const Background = struct {
    c: *Context,

    pub fn end(b: Background) void {
        b.c.end();
        b.c.end();
    }
};

/// How far the content behind shrinks: 26 points narrower, as vaul.
fn backScale(w: f32) f32 {
    return if (w <= 26) 1 else (w - 26) / w;
}

pub fn drawerBackground(c: *Context, s: *DrawerState) Background {
    const p = s.presence;
    s.presence_drawn = p;
    const th = c.theme;
    _ = c.open(.{ .width = .fill, .height = .fill, .background = if (p > 0) types.Color.black else null }, "drawer-background");
    const k = backScale(c.size.w);
    const scale = 1 - (1 - k) * p;
    const across = 14 * p;
    const h = horizontal(s.side);
    _ = c.open(.{
        .width = .fill,
        .height = .fill,
        .background = if (p > 0) th.background else null,
        .radius = 8 * p,
        .clip = p > 0,
        .transform = if (p > 0) types.Affine.scaling(scale, scale).then(if (h) .translation(across, 0) else .translation(0, across)) else null,
        .transform_origin = if (h) .{ .x = 0, .y = 0.5 } else .{ .x = 0.5, .y = 0 },
    }, "drawer-content");
    return .{ .c = c };
}
