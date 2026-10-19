//! Popovers and tooltips: panels beside an element, over everything else.
//!
//!     const more = ui.button(c, "More", .{});
//!     if (more.clicked) s.menu.toggle();
//!     if (ui.popover(c, &s.menu, more, .{})) |p| {
//!         defer p.end();
//!         if (ui.button(c, "Rename", .{}).clicked) s.menu.close();
//!     }
//!     ui.tooltip(c, more, "More actions");
//!
//! A press outside a popover or Escape closes it, and the press goes on to
//! what is under the pointer, as with the web's popovers: one on another
//! button closes the popover and presses the button, one on the anchor
//! closes it as the anchor toggles it.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const base = @import("overlay_base.zig");
const widgets = @import("widgets.zig");
const Context = ctx_mod.Context;
const Interaction = ctx_mod.Interaction;
const OverlayState = base.OverlayState;

pub const PopoverOptions = struct {
    side: base.Side = .below,
    @"align": base.Align = .start,
    /// Room between the anchor and the panel.
    gap: f32 = 6,
    padding: types.Edges = .all(8),
    gap_children: f32 = 4,
    width: types.Length = .auto,
    max_width: f32 = 360,
    /// No look of its own (`PopoverBase`): style it with `Panel.style`.
    bare: bool = false,
};

/// An open popover's panel: its children follow, then `end`.
pub const Panel = struct {
    c: *Context,
    state: *OverlayState,
    index: u32,
    lo: u32,
    anchor: types.Rect,
    opts: PopoverOptions,

    /// The panel's style, for one without a look of its own.
    pub fn style(p: Panel) *types.Style {
        return &p.c.node(p.index).style;
    }

    pub fn id(p: Panel) u64 {
        return p.c.node(p.index).id;
    }

    /// Closes the panel: Escape (unless what is in it took it) closes the
    /// popover; it is measured and placed beside its anchor.
    pub fn end(p: Panel) void {
        const c = p.c;
        if (base.takeKey(c, .escape)) p.state.dismiss(c);
        std.debug.assert(c.stack.items[c.stack.items.len - 1] == p.index);
        _ = base.place(c, p.index, p.anchor, p.opts.side, p.opts.@"align", p.opts.gap);
        c.end();
        p.state.record(c, p.lo);
    }
};

/// A panel beside `anchor` while `state.open`; null while it is closed.
pub fn popover(c: *Context, state: *OverlayState, anchor: Interaction, opts: PopoverOptions) ?Panel {
    if (state.open and state.shown and state.pressedOutside(c, anchor.id)) state.dismiss(c);
    if (!state.sync(c)) return null;
    const rect = anchor.rect orelse {
        // The anchor was not laid out yet: next frame.
        c.animationFrame();
        return null;
    };
    const th = c.theme;
    const lo: u32 = @intCast(c.nodes.items.len);
    const index = base.overlay(c, .{ .absolute = true }, anchor.id);
    const n = c.node(index);
    const opened = state.justOpened(c);
    n.style.opacity = base.fadeIn(c, n.id, opened);
    if (!opts.bare) {
        n.style.width = opts.width;
        n.style.max_width = opts.max_width;
        n.style.padding = opts.padding;
        n.style.gap = opts.gap_children;
        n.style.radius = 10;
        n.style.background = th.surface;
        n.style.border = th.border;
        n.style.shadow = .{ .color = th.shadow.alpha(1.3), .blur = 18, .y = 6 };
    }
    // It takes the pointer: what is under it is not pressed.
    _ = c.interact(index, .{});
    c.describe(c.node(index).id, .{ .role = .popup });
    c.describe(anchor.id, .{ .has_popup = true, .expanded = true });
    return .{ .c = c, .state = state, .index = index, .lo = lo, .anchor = rect, .opts = opts };
}

/// How long the pointer rests on an element before its tip shows, and how
/// soon after a tip goes the next one shows at once.
pub const tooltip_delay: f32 = 0.6;
pub const tooltip_warm: f32 = 0.4;

const salt_start = 0x7101;
const salt_blocked = 0x7102;
const salt_showing = 0x7103;
const salt_hidden_at = 0x7104;
/// Shared by every tip: when the last one went.
const all_tips: u64 = 0x746f6f6c74697073;

/// Shows `tip` above the element `anchor` (below it where there is no room
/// above), centered, once the pointer has rested on it for 0.6 seconds, or
/// at once when it has the focus or a tip went less than 0.4 seconds ago.
/// It goes as the pointer leaves; a press on the element or Escape hides it
/// until the pointer leaves and comes back. The pointer goes through it.
pub fn tooltip(c: *Context, anchor: Interaction, tip: []const u8) void {
    // Read after the element's name, shown or not.
    c.describe(anchor.id, .{ .description = tip });
    _ = tooltipBase(c, anchor) orelse return;
    const th = c.theme;
    widgets.text(c, tip, .{ .size = 12, .color = th.background });
    tooltipEnd(c, anchor);
}

/// A tip of your own (`TooltipBase`): opens the tip's box and returns its
/// index while it shows; add its content, then `tooltipEnd`.
pub fn tooltipBase(c: *Context, anchor: Interaction) ?u32 {
    const now: f32 = @floatCast(c.time);
    const id = anchor.id;
    const hidden_at = base.memo(c, all_tips, salt_hidden_at, -1e9).*;
    const was_showing = base.memo(c, id, salt_showing, 0).* == 1;
    // The keyboard's focus shows it, not a click's.
    const focused = anchor.focused and c.focus_visible;
    const showing = blk: {
        if (!anchor.hovered and !focused) {
            base.memo(c, id, salt_start, -1).* = -1;
            base.memo(c, id, salt_blocked, 0).* = 0;
            break :blk false;
        }
        if (anchor.hovered and c.input.pressed) base.memo(c, id, salt_blocked, 0).* = 1;
        if (was_showing and base.takeKey(c, .escape)) base.memo(c, id, salt_blocked, 0).* = 1;
        if (base.memo(c, id, salt_blocked, 0).* == 1) break :blk false;
        const start = base.memo(c, id, salt_start, -1);
        if (start.* < 0) start.* = now;
        const rested = now - start.*;
        if (was_showing or focused or now - hidden_at < tooltip_warm or rested >= tooltip_delay) break :blk true;
        // Wakes when the delay is over: nothing polls.
        c.frameIn(tooltip_delay - rested);
        break :blk false;
    };
    if (was_showing and !showing) {
        base.memo(c, all_tips, salt_hidden_at, -1e9).* = now;
        // Build again: a tip that follows shows in this frame.
        c.changed = true;
    }
    base.memo(c, id, salt_showing, 0).* = if (showing) 1 else 0;
    if (!showing) return null;
    const th = c.theme;
    const tip = base.overlay(c, .{
        .absolute = true,
        .padding = .xy(8, 4),
        .radius = 6,
        .background = th.text,
        .max_width = 320,
        .shadow = .{ .color = th.shadow, .blur = 8, .y = 2 },
    }, id +% 1);
    c.describe(c.node(tip).id, .{ .role = .tooltip });
    return tip;
}

/// Closes a tip `tooltipBase` opened: placed by its element.
pub fn tooltipEnd(c: *Context, anchor: Interaction) void {
    const index = c.stack.items[c.stack.items.len - 1];
    _ = base.place(c, index, anchor.rect orelse .{}, .above, .center, 6);
    c.end();
}
