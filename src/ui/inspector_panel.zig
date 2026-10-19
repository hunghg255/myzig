//! The inspector's panel (`inspector.zig`): its toolbar, the last frames'
//! costs, the tree of boxes, and the details of the box chosen or under
//! the pointer. It always reads left to right.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const widgets = @import("widgets.zig");
const list = @import("list.zig");
const direction = @import("direction.zig");
const insp = @import("inspector.zig");
const Context = ctx_mod.Context;
const Node = ctx_mod.Node;
const State = insp.State;

const row_h: f32 = 20;
const small: types.TextStyle = .{ .size = 11 };
const mono: types.TextStyle = .{ .size = 11, .mono = true };

pub fn build(c: *Context, s: *State, app_nodes: u32) void {
    const th = c.theme;
    const box = c.openOverlay(.{
        .absolute = true,
        .offset = .{ .x = if (insp.panelAtLeft(c)) 0 else c.size.w - s.width },
        .width = .{ .px = s.width },
        .height = .fill,
        .background = th.surface,
        .border = th.border,
        .direction = .column,
        .clip = true,
    }, "myzig.inspector");
    direction.scope(c, box, .ltr);
    // It takes the pointer: nothing under it does.
    _ = c.interact(box, .{});
    defer c.end();
    toolbar(c, s);
    performance(c, s);
    widgets.divider(c);
    tree(c, s, app_nodes);
    widgets.divider(c);
    details(c, s, app_nodes);
}

fn toolbar(c: *Context, s: *State) void {
    _ = c.open(.{ .direction = .row, .width = .fill, .padding = .xy(8, 6), .gap = 4, .align_items = .center }, null);
    defer c.end();
    widgets.text(c, "Inspector", .{ .size = 12, .weight = .semibold });
    widgets.spacer(c);
    if (widgets.button(c, if (s.picking) "Picking…" else "Pick", .{ .size = 11, .variant = if (s.picking) .primary else .ghost }).clicked) {
        if (s.picking) s.picking = false else s.pick();
    }
    if (widgets.button(c, if (s.rtl) "RTL ✓" else "RTL", .{ .size = 11, .variant = .ghost }).clicked) {
        s.rtl = !s.rtl;
        direction.set(c, if (s.rtl) .rtl else .ltr);
    }
    if (widgets.button(c, "Close", .{ .size = 11, .variant = .ghost }).clicked) s.toggle();
}

fn performance(c: *Context, s: *State) void {
    const th = c.theme;
    _ = c.open(.{ .width = .fill, .padding = .xy(8, 4), .gap = 4 }, null);
    defer c.end();
    const f = c.stats;
    widgets.text(c, c.print("build {d:.2} ms · layout {d:.2} · paint {d:.2}", .{ f.build_ms, f.layout_ms, f.paint_ms }), mono);
    widgets.text(c, c.print("{d} boxes · {d} instances · {d} pass(es)", .{ f.nodes, f.instances, f.passes }), .{ .size = 11, .mono = true, .color = th.muted });
    // A bar a frame, against a refresh at 60 Hz.
    _ = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = 24 }, .gap = 1, .align_items = .end }, "myzig.inspector.graph");
    defer c.end();
    var i: usize = 0;
    while (i < s.stats_count) : (i += 1) {
        const at = (s.stats_at + insp.history - s.stats_count + i) % insp.history;
        const st = s.stats[at];
        const ms = st.build_ms + st.layout_ms + st.paint_ms;
        const h: f32 = @floatCast(@max(1, @min(24, ms / 16.7 * 24)));
        _ = c.leaf(.{ .width = .{ .px = 3 }, .height = .{ .px = h }, .background = if (ms > 16.7) th.danger else th.accent }, .none, null);
    }
}

/// What a box is, as the tree names it.
pub fn describe(c: *Context, n: *const Node) []const u8 {
    return switch (n.content) {
        .text => |t| c.print("Text \"{s}\"", .{t.str[0..@min(t.str.len, 40)]}),
        .icon => |ic| c.print("Icon {s}", .{ic.name}),
        .image => "Image",
        .none => blk: {
            const st = n.style;
            const kind = if (st.scroll) "Scroll" else if (n.interactive) "Pressable" else if (st.direction == .row) "Row" else "Column";
            break :blk if (n.child_count > 0) c.print("{s} ({d})", .{ kind, n.child_count }) else kind;
        },
    };
}

fn tree(c: *Context, s: *State, app_nodes: u32) void {
    const th = c.theme;
    const depth = c.alloc().alloc(u8, app_nodes) catch return;
    for (c.nodes.items[0..app_nodes], 0..) |n, i| depth[i] = if (i == 0) 0 else depth[n.parent] +| 1;
    const height: f32 = @max(80, (c.size.h - 120) * 0.55);
    var rows = list.list(c, .{ .count = app_nodes, .row_height = row_h, .height = .{ .px = height } });
    while (rows.next()) |i| {
        const n = c.nodes.items[i];
        const id = n.id;
        const chosen = s.selected == id;
        const r = c.open(.{
            .direction = .row,
            .width = .fill,
            .height = .{ .px = row_h },
            .padding = .{ .left = 8 + 10 * @as(f32, @floatFromInt(depth[i])), .right = 8 },
            .align_items = .center,
            .background = if (chosen) th.accent.alpha(0.25) else null,
        }, null);
        const it = c.interact(r, .{});
        if (it.hovered and !s.picking) {
            s.hovered = id;
            c.wants_moves = true;
        }
        if (it.clicked) {
            s.selected = id;
            c.changed = true;
        }
        widgets.text(c, describe(c, &n), .{ .size = 11, .mono = true, .color = if (it.hovered) th.accent else th.text });
        c.end();
    }
    rows.end();
}

fn details(c: *Context, s: *State, app_nodes: u32) void {
    const th = c.theme;
    _ = c.open(.{ .width = .fill, .grow = 1, .padding = .all(8), .gap = 3, .scroll = true }, "myzig.inspector.details");
    defer c.end();
    const id = if (s.hovered != 0) s.hovered else s.selected;
    const at = insp.find(c, app_nodes, id) orelse {
        widgets.text(c, "Choose a box in the tree, or pick one.", .{ .size = 11, .color = th.muted });
        return;
    };
    const n = c.nodes.items[at];
    widgets.text(c, describe(c, &n), .{ .size = 12, .weight = .semibold, .mono = true });
    const r = c.rects.get(id) orelse types.Rect{};
    prop(c, "rect", c.print("x {d:.1}  y {d:.1}  w {d:.1}  h {d:.1}", .{ r.x, r.y, r.w, r.h }));
    const st = n.style;
    const p = st.padding;
    if (!std.meta.eql(p, types.Edges{})) prop(c, "padding", c.print("{d} {d} {d} {d}", .{ p.top, p.right, p.bottom, p.left }));
    prop(c, "direction", c.print("{s}, {s}", .{ @tagName(st.direction), @tagName(direction.of(c, at)) }));
    if (st.gap != 0) prop(c, "gap", c.print("{d}", .{st.gap}));
    prop(c, "width", length(c, st.width));
    prop(c, "height", length(c, st.height));
    if (st.grow != 0) prop(c, "grow", c.print("{d}", .{st.grow}));
    if (st.align_items != .start) prop(c, "align-items", @tagName(st.align_items));
    if (st.justify != .start) prop(c, "justify", @tagName(st.justify));
    if (st.background) |b| prop(c, "background", color(c, b));
    if (st.border) |b| prop(c, "border", c.print("{d} {s}", .{ st.border_width, color(c, b) }));
    if (st.radius != 0) prop(c, "radius", c.print("{d}", .{st.radius}));
    if (st.opacity != 1) prop(c, "opacity", c.print("{d:.2}", .{st.opacity}));
    if (st.offset.x != 0 or st.offset.y != 0) prop(c, "offset", c.print("{d} {d}", .{ st.offset.x, st.offset.y }));
    var flags: std.ArrayList(u8) = .empty;
    const a = c.alloc();
    inline for (.{ "scroll", "absolute", "clip", "follow_end", "selectable", "control" }) |name| {
        if (@field(st, name)) {
            flags.appendSlice(a, name) catch {};
            flags.append(a, ' ') catch {};
        }
    }
    if (n.interactive) flags.appendSlice(a, "interactive ") catch {};
    if (c.focus == id) flags.appendSlice(a, "focused ") catch {};
    if (flags.items.len > 0) prop(c, "flags", flags.items);
    switch (n.content) {
        .text => |t| {
            prop(c, "text", t.str[0..@min(t.str.len, 200)]);
            prop(c, "font", c.print("{d} {s}{s}{s}", .{ t.style.size, @tagName(t.style.weight), if (t.style.mono) " mono" else "", if (t.style.wrap) " wrap" else "" }));
            prop(c, "color", color(c, t.color));
        },
        .icon => |ic| prop(c, "icon", c.print("{s} {d}", .{ ic.name, ic.size })),
        .image => |im| prop(c, "image", c.print("{x}", .{im.key})),
        .none => {},
    }
    prop(c, "id", c.print("{x:0>16}", .{id}));
}

fn prop(c: *Context, name: []const u8, value: []const u8) void {
    _ = c.open(.{ .direction = .row, .width = .fill, .gap = 6 }, null);
    defer c.end();
    _ = c.leaf(.{ .width = .{ .px = 80 } }, .{ .text = .{ .str = name, .style = small, .color = c.theme.muted } }, null);
    widgets.text(c, value, .{ .size = 11, .mono = true, .wrap = true });
}

fn length(c: *Context, l: types.Length) []const u8 {
    return switch (l) {
        .auto => "auto",
        .fill => "fill",
        .px => |v| c.print("{d}px", .{v}),
    };
}

fn color(c: *Context, k: types.Color) []const u8 {
    const b = struct {
        fn byte(v: f32) u8 {
            return @intFromFloat(std.math.clamp(v, 0, 1) * 255 + 0.5);
        }
    }.byte;
    return if (k.a >= 1) c.print("#{x:0>2}{x:0>2}{x:0>2}", .{ b(k.r), b(k.g), b(k.b) }) else c.print("#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ b(k.r), b(k.g), b(k.b), b(k.a) });
}
