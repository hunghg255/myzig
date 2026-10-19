//! The inspector, after mygo's: a developer's panel docked at the right of
//! a window of native UI, as a browser's developer tools show a page's:
//! the tree of boxes, the rectangle, padding, style and content of the box
//! chosen or under the pointer, outlined over the content, and how long
//! frames take (`Context.stats`). F12, or Alt+Cmd+I on macOS and
//! Ctrl+Shift+I elsewhere, opens and closes it; Shift+Cmd+C (Ctrl+Shift+C)
//! opens it picking a box: the pointer then chooses the box under it, and
//! the click goes to the inspector, not to the box. Escape stops picking.
//!
//!     // In the app's state:
//!     inspector: ui.Inspector = .{},
//!     // Last in the view:
//!     ui.inspector(c, &s.inspector);
//!
//! It is part of debug builds only (`enabled`): elsewhere `Inspector` is
//! empty and `inspector` does nothing, so that it costs a release nothing.
//! The build option `inspector` overrides that either way.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const panel = @import("inspector_panel.zig");
const Context = ctx_mod.Context;
const Shortcut = ctx_mod.Shortcut;
const Rect = types.Rect;

const options = @import("build_options");
/// Whether this build has the inspector: debug builds, unless the build
/// option `inspector` says otherwise.
pub const enabled: bool = if (@hasDecl(options, "inspector")) options.inspector else builtin.mode == @TypeOf(builtin.mode).Debug;

/// Frames the performance graph shows.
pub const history = 60;

pub const Inspector = if (enabled) State else struct {};

pub const State = struct {
    open: bool = false,
    /// The pointer chooses the box under it.
    picking: bool = false,
    /// The box chosen (in the tree or picked), and the one under the
    /// pointer (in the tree, or in the content while picking), by id.
    selected: u64 = 0,
    hovered: u64 = 0,
    /// Lays the window out right to left, to try it before translating.
    rtl: bool = false,
    width: f32 = 340,
    /// The last frames' costs, newest at `stats_at - 1`.
    stats: [history]ctx_mod.FrameStats = @splat(.{}),
    stats_at: usize = 0,
    stats_count: usize = 0,
    noted_frame: u64 = std.math.maxInt(u64),

    pub fn toggle(s: *State) void {
        s.open = !s.open;
        s.picking = false;
    }

    pub fn pick(s: *State) void {
        s.open = true;
        s.picking = true;
    }

    fn note(s: *State, f: ctx_mod.FrameStats) void {
        s.stats[s.stats_at] = f;
        s.stats_at = (s.stats_at + 1) % history;
        s.stats_count = @min(history, s.stats_count + 1);
    }
};

/// Builds the inspector over the view: call it last in the view. It shows
/// the boxes the view built before it.
pub fn inspector(c: *Context, s: *Inspector) void {
    if (comptime enabled) run(c, s);
}

fn run(c: *Context, s: *State) void {
    keys(c, s);
    if (!s.open) return;
    // Once a frame (not every build pass): the last frame's costs.
    if (s.noted_frame != c.frame) {
        s.noted_frame = c.frame;
        if (c.frame > 0) s.note(c.stats);
    }
    const app_nodes: u32 = @intCast(c.nodes.items.len);
    // The content leaves the panel room at the right (at the left right to
    // left, where the content mirrors).
    c.node(0).style.padding.right += s.width;

    if (s.picking) pickBox(c, s, app_nodes) else s.hovered = 0;
    panel.build(c, s, app_nodes);
    highlight(c, s, app_nodes);
}

fn keys(c: *Context, s: *State) void {
    const mac = builtin.os.tag == .macos;
    if (c.input.key == .f12) {
        c.input.key = null;
        s.toggle();
        c.changed = true;
    } else if (c.shortcut(if (mac) .{ .key = 'i', .cmd = true, .alt = true } else .{ .key = 'i', .ctrl = true, .shift = true })) {
        s.toggle();
    } else if (c.shortcut(if (mac) .{ .key = 'c', .cmd = true, .shift = true } else .{ .key = 'c', .ctrl = true, .shift = true })) {
        if (s.picking) s.picking = false else s.pick();
    } else if (s.picking and c.input.key == .escape) {
        c.input.key = null;
        s.picking = false;
        c.changed = true;
    }
}

/// The deepest box of the app's under `p`, as the last frame placed it.
pub fn boxAt(c: *Context, app_nodes: u32, p: types.Point) ?u32 {
    var found: ?u32 = null;
    var i: u32 = 1;
    while (i < app_nodes) : (i += 1) {
        const r = c.rects.get(c.nodes.items[i].id) orelse continue;
        // Later boxes are inside or over earlier ones.
        if (r.contains(p)) found = i;
    }
    return found;
}

/// While picking: a cover over the content takes the pointer, and the box
/// under it is hovered, chosen by a press.
fn pickBox(c: *Context, s: *State, app_nodes: u32) void {
    const x: f32 = if (panelAtLeft(c)) s.width else 0;
    const cover = c.openOverlay(.{ .absolute = true, .offset = .{ .x = x }, .width = .{ .px = @max(0, c.size.w - s.width) }, .height = .fill }, "myzig.inspector.cover");
    const it = c.interact(cover, .{});
    c.end();
    s.hovered = 0;
    if (!it.hovered) return;
    const at = boxAt(c, app_nodes, c.input.mouse) orelse return;
    s.hovered = c.nodes.items[at].id;
    c.wants_moves = true;
    if (c.input.pressed) {
        s.selected = s.hovered;
        s.picking = false;
        c.changed = true;
    }
}

/// The index of the app's box `id` in this frame.
pub fn find(c: *Context, app_nodes: u32, id: u64) ?u32 {
    if (id == 0) return null;
    for (c.nodes.items[0..app_nodes], 0..) |n, i| if (n.id == id) return @intCast(i);
    return null;
}

/// Outlines the box hovered (else the one chosen): its rectangle in blue,
/// its content box inside its padding in green, as browsers do.
fn highlight(c: *Context, s: *State, app_nodes: u32) void {
    const id = if (s.hovered != 0) s.hovered else s.selected;
    const at = find(c, app_nodes, id) orelse return;
    const r = c.rects.get(id) orelse return;
    const pad = c.nodes.items[at].style.padding;
    const blue: types.Color = .{ .r = 0.24, .g = 0.55, .b = 0.95, .a = 0.28 };
    const green: types.Color = .{ .r = 0.35, .g = 0.75, .b = 0.35, .a = 0.3 };
    _ = c.openOverlay(.{ .absolute = true, .offset = .{ .x = r.x, .y = r.y }, .width = .{ .px = r.w }, .height = .{ .px = r.h }, .background = green, .border = blue.alpha(3), .border_width = 1 }, "myzig.inspector.box");
    const inner = r.inset(pad);
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = inner.x - r.x, .y = inner.y - r.y }, .width = .{ .px = inner.w }, .height = .{ .px = inner.h }, .background = blue }, .none, null);
    c.end();
    // Its size beside it.
    const tip_y = if (r.y > 22) r.y - 20 else r.y + r.h + 2;
    _ = c.openOverlay(.{ .absolute = true, .offset = .{ .x = @max(0, r.x), .y = tip_y }, .padding = .xy(6, 2), .radius = 4, .background = c.theme.text }, "myzig.inspector.size");
    _ = c.leaf(.{}, .{ .text = .{ .str = c.print("{d:.0} × {d:.0}", .{ r.w, r.h }), .style = .{ .size = 11, .mono = true }, .color = c.theme.background } }, null);
    c.end();
}

/// Whether the panel is docked at the left: right to left, where the
/// content mirrors away from the room it leaves at the right.
pub fn panelAtLeft(c: *Context) bool {
    return @import("direction.zig").window(c) == .rtl;
}
