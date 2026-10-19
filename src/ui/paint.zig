//! Turns the laid out tree into the renderer's instances, in paint order,
//! and records the visible rectangles of interactive boxes for hit testing.
//! Boxes transformed (`Style.transform`) draw their subtree in its own
//! space (`paint_xf.zig`); gradients, blurs and effects add rows of data
//! after the instances (`gpu.Frame`).
const std = @import("std");
const types = @import("types.zig");
const metal = @import("gpu.zig");
const text_mod = @import("text.zig");
const rich = text_mod.rich;
const ctx_mod = @import("context.zig");
const xf = @import("paint_xf.zig");
const fx = @import("effect.zig");
const pm = @import("paint_motion.zig");
const Context = ctx_mod.Context;
const none = ctx_mod.none;

/// A frame being painted: where its instances and rows go, and the space
/// the box being painted draws in.
pub const Painter = struct {
    c: *Context,
    out: *std.ArrayList(metal.Instance),
    rows: std.ArrayList([4]f32) = .empty,
    sp: xf.Space = .{},
    /// Boxes gone that go to their exit, and those drawn so far.
    going: @import("motion_transition.zig").Going = .{},
    going_drawn: u32 = 0,
    /// Each box's ink (`inks`), when painting skips what is out of view.
    ink: ?[]const Ink = null,
};

/// Whether painting skips the boxes whose ink is clipped out (tests turn
/// it off to compare), and how many it skipped.
pub var cull = true;
pub var skipped: usize = 0;

pub fn paint(c: *Context, out: *std.ArrayList(metal.Instance)) void {
    out.clearRetainingCapacity();
    var p: Painter = .{ .c = c, .out = out };
    if (cull) p.ink = inks(c);
    if (c.motion.boxes.count() > 0) p.going = @import("motion_transition.zig").going(c);
    paintNode(&p, 0, types.Rect.infinite, 1, false);
    pm.finish(&p);
    metal.appendRows(c.gpa, out, p.rows.items) catch {};
}

fn snap(v: f32, scale: f32) f32 {
    return @round(v * scale) / scale;
}

fn push(c: *Context, out: *std.ArrayList(metal.Instance), inst: metal.Instance) void {
    out.append(c.gpa, inst) catch {};
}

/// Places the instances from `first` on in the painter's space.
fn placeFrom(p: *Painter, first: usize) void {
    if (p.sp.mode == .plain) return;
    for (p.out.items[first..]) |*i| i.* = xf.place(&p.sp, i.*);
}

fn paintNode(p: *Painter, index: u32, clip_in: types.Rect, opacity_in: f32, selectable_in: bool) void {
    const c = p.c;
    const out = p.out;
    // Nothing changes the tree while it is painted: read it in place.
    const n = c.node(index);
    const st = &n.style;
    const selectable = (selectable_in or st.selectable) and !st.control;
    const opacity = opacity_in * st.opacity;
    const r = n.rect;
    if (opacity <= 0.001) return;
    var clip = clip_in;
    const saved = p.sp;
    defer p.sp = saved;
    // Its transform about its origin, then the move a transition makes.
    var local: ?types.Affine = null;
    if (st.transform) |t| if (!t.isIdentity()) {
        local = t.about(.{ .x = r.x + st.transform_origin.x * r.w, .y = r.y + st.transform_origin.y * r.h });
    };
    if (pm.offset(p, index)) |m| local = if (local) |l| m.mul(l) else m;
    if (local) |l| {
        const entered = xf.enter(&p.rows, c.alloc(), p.sp, l, clip) orelse return;
        p.sp = entered[0];
        clip = entered[1];
    }
    const visible = r.intersect(clip);
    if (c.canvas_record) |record| record(c, n.id, r, p.sp.m, p.sp.mode == .general, p.sp.outer, clip);
    const clip4 = metal.clip4(clip);
    const rect4: [4]f32 = .{ r.x, r.y, r.w, r.h };
    const first_own = out.items.len;
    const layer = st.blur > 0 and visible.w > 0 and visible.h > 0;
    if (layer) fx.beginLayer(p, st.blur, rect4, clip4);

    if (visible.w > 0 and visible.h > 0) {
        if (st.shadow) |sh| push(c, out, .{
            .rect = .{ r.x, r.y + sh.y, r.w, r.h },
            .color = metal.color4(sh.color.alpha(opacity)),
            .radius = st.corners.signed(st.radius),
            // CSS's blur radius is twice the Gaussian's standard deviation.
            .border_width = sh.blur / 2,
            .kind = metal.Kind.shadow,
            .clip = clip4,
        });
        if (st.effect) |e| fx.paint(p, e, st, rect4, clip4);
        if (st.background != null or (st.border != null and st.gradient == null)) push(c, out, .{
            .rect = rect4,
            .color = metal.color4((st.background orelse types.Color.transparent).alpha(opacity)),
            .border_color = metal.color4((st.border orelse types.Color.transparent).alpha(opacity)),
            .border_width = if (st.border != null and st.gradient == null) st.border_width else 0,
            .radius = st.corners.signed(st.radius),
            .clip = clip4,
        });
        if (st.gradient) |g| @import("gradient.zig").paint(p, g.*, st, rect4, clip4, opacity);
        switch (n.content) {
            .text => |*t| paintText(p, index, n, t, clip4, opacity, selectable),
            .icon => |ic| if (c.text.atlas.symbol(ic.name, ic.size, @intFromEnum(ic.weight))) |sp| {
                // Centered in its box, which may be larger (a fixed frame).
                const inner = r.inset(st.padding);
                const x = inner.x + (inner.w - (sp.w + 2 * sp.x)) / 2;
                const y = inner.y + (inner.h - (sp.h + 2 * sp.y)) / 2;
                push(c, out, .{
                    .rect = .{ snap(x, c.scale) + sp.x, snap(y, c.scale) + sp.y, sp.w, sp.h },
                    .color = metal.color4(ic.color.alpha(opacity)),
                    .uv = sp.uv,
                    .kind = metal.Kind.text,
                    .clip = clip4,
                });
            },
            .image => |im| if (c.text.images.get(im.key, im.bytes)) |e| push(c, out, .{
                .rect = rect4,
                .color = .{ 1, 1, 1, im.opacity * opacity },
                .uv = sourceUv(e, im.source),
                .radius = st.corners.signed(st.radius),
                // Unused by pictures: positive samples the nearest texel.
                .border_width = if (im.pixelated) 1 else 0,
                .kind = metal.Kind.image,
                .clip = clip4,
            }),
            .none => {},
        }
    }
    if (n.interactive and visible.w > 0 and visible.h > 0) c.next_hits.append(c.gpa, xf.hit(&p.sp, n.id, index, visible, false)) catch {};

    var child_clip = clip;
    if (st.clip) child_clip = visible;
    if (st.scroll) {
        child_clip = visible;
        c.next_hits.append(c.gpa, xf.hit(&p.sp, n.id, index, visible, true)) catch {};
    }
    const first = out.items.len;
    // What paints from here on is over a web view's page (`webview.zig`).
    if (c.web) |l| l.mark(l, index, first);
    placeFrom(p, first_own);
    if (p.going.n > 0) pm.drawGoing(p, n.id);
    var child = n.first_child;
    while (child != none) : (child = c.node(child).next) {
        if (p.ink) |ink| if (p.sp.mode == .plain and !ink[child].keep and !meets(ink[child].b, child_clip)) {
            skipped +%= 1;
            continue;
        };
        paintNode(p, child, child_clip, opacity, selectable);
    }
    if ((st.clip or st.scroll) and st.radius > 0) {
        const s = if (p.sp.mode == .similar) p.sp.m.a else 1;
        roundClip(out.items[first..], xf.toInstance(&p.sp, r), xf.toInstance(&p.sp, visible), st.radius * s, st.corners == .continuous);
    }

    if (st.scroll) {
        const before = out.items.len;
        paintScrollbar(c, out, n, visible, opacity);
        placeFrom(p, before);
    }
    if (layer) {
        const before = out.items.len;
        fx.endLayer(p, st.blur, rect4, clip4);
        placeFrom(p, before);
    }
    pm.keep(p, index, first_own);
}

/// What a box and the boxes inside it may paint, in the window (x0, y0,
/// x1, y1), and whether they are painted wherever they are (`keep`):
/// painting skips a box whose ink its clip leaves out, after mygo's (as
/// Blink and Flutter skip what lies outside the cull rect by its visual
/// overflow). A scrolled page of a thousand rows then paints the rows in
/// view, not the others.
pub const Ink = struct { b: [4]f32, keep: bool };

fn meets(b: [4]f32, clip: types.Rect) bool {
    return b[0] < clip.x + clip.w and b[1] < clip.y + clip.h and b[2] > clip.x and b[3] > clip.y;
}

/// Each box's ink, from the boxes as laid out: its own (its box, grown by
/// its shadow, its blur, text and icons reaching out of it), and those
/// inside it. Kept wherever they are: transformed boxes, which paint
/// elsewhere, and selectable text, whose place counts for selecting out of
/// view; and no ink at all while boxes move or go (transitions paint them
/// elsewhere, and keep what they painted), or with web views (which follow
/// what paints over them). Boxes are in the tree's order: those inside a
/// box come after it.
fn inks(c: *Context) ?[]const Ink {
    const nodes = c.nodes.items;
    if (nodes.len < 64 or c.web != null or c.motion.boxes.count() > 0 or c.motion.moving_boxes > 0) return null;
    const ink = c.alloc().alloc(Ink, nodes.len) catch return null;
    const sel = c.alloc().alloc(bool, nodes.len) catch return null;
    for (nodes, ink, sel, 0..) |*n, *k, *s, i| {
        const st = &n.style;
        const up = n.parent != none and n.parent < i and sel[n.parent];
        s.* = (up or st.selectable) and !st.control;
        const r = n.rect;
        var m: f32 = 4 + st.blur * 3;
        if (st.shadow) |sh| m = @max(m, 4 + @abs(sh.y) + sh.blur * 1.5);
        var ox: f32 = 0;
        var oy: f32 = 0;
        switch (n.content) {
            .text => {
                ox = @max(0, n.measured.w - r.w);
                oy = @max(0, n.measured.h - r.h);
            },
            .icon => |ic| m = @max(m, 4 + ic.size),
            else => {},
        }
        const turned = if (st.transform) |t| !t.isIdentity() else false;
        k.* = .{
            .b = .{ r.x - m - ox, r.y - m, r.x + r.w + m + ox, r.y + r.h + m + oy },
            .keep = turned or (s.* and n.content == .text) or n.parent >= i and n.parent != none,
        };
    }
    var i = nodes.len;
    while (i > 1) {
        i -= 1;
        const parent = nodes[i].parent;
        if (parent == none) continue;
        const a = &ink[parent];
        const b = ink[i];
        a.b = .{ @min(a.b[0], b.b[0]), @min(a.b[1], b.b[1]), @max(a.b[2], b.b[2]), @max(a.b[3], b.b[3]) };
        a.keep = a.keep or b.keep;
    }
    return ink;
}

fn paintText(p: *Painter, index: u32, n: *const ctx_mod.Node, t: *const ctx_mod.Content.Text, clip4: [4]f32, opacity: f32, selectable: bool) void {
    const c = p.c;
    const out = p.out;
    const sel: ?Sel = if (selectable) .{ .id = n.id, .index = index, .x0 = n.rect.x, .x1 = n.rect.x + n.rect.w } else null;
    const inner = n.rect.inset(n.style.padding);
    const f = c.text.font(t.style);
    const lh = if (t.style.leading == 1) f.lineHeight() else @ceil(f.lineHeight() * t.style.leading);
    if (t.style.wrap) {
        for (t.lines, 0..) |l, i| {
            const y = inner.y + lh * @as(f32, @floatFromInt(i));
            textRun(c, out, t, l.start, l.end, inner.x, y, f, lh, clip4, opacity, sel);
        }
    } else {
        textRun(c, out, t, 0, t.str.len, inner.x, inner.y, f, lh, clip4, opacity, sel);
    }
}

/// Draws bytes [start, end) of `t`, each glyph in its span's color.
/// A selectable text: its id, its place in the tree, and the box's
/// horizontal extent.
const Sel = struct { id: u64, index: u32, x0: f32, x1: f32 };

fn textRun(c: *Context, out: *std.ArrayList(metal.Instance), t: *const ctx_mod.Content.Text, start: usize, end: usize, x: f32, y: f32, f: text_mod.Font, lh: f32, clip4: [4]f32, opacity: f32, sel: ?Sel) void {
    const style = t.style;
    // Cull lines wholly above or below the clip before shaping them; a
    // selectable one still counts for where the pointer is.
    if (y > clip4[3] or y + lh < clip4[1] or x > clip4[2]) {
        if (sel) |s| if (y + lh <= c.input.mouse.y) {
            c.selection.below = .{ .id = s.id, .at = end };
            if (!c.selection.next_order.contains(s.id)) c.selection.next_order.put(c.gpa, s.id, @intCast(c.selection.next_order.count())) catch {};
        };
        return;
    }
    const styled = t.spans.len > 0 and rich.styled(t.spans);
    const lay = if (styled) rich.layout(c.text, t.str[start..end], style, t.spans, start) else c.text.layout(t.str[start..end], style);
    if (lay.glyphs.len == 0 or x + lay.width < clip4[0]) return;
    const scale = c.scale;
    // The line's extra height (its leading) goes half above, half below.
    const baseline = snap(y + (lh - f.lineHeight()) / 2 + f.leading / 2 + f.ascent, scale);
    const base = metal.color4(t.color.alpha(opacity));
    if (sel) |s| @import("selection.zig").line(c, out, s.id, s.index, t.str, start, end, lay, x, y, lh, s.x0, s.x1, clip4);
    if (t.spans.len > 0) decorations(c, out, t, lay, start, end, x, baseline, f, clip4, opacity);
    var span_i: usize = 0;
    for (lay.glyphs) |g| {
        const pen = (x + g.x) * scale;
        if (pen / scale > clip4[2]) break;
        const px = @floor(pen);
        const bin: u8 = @intFromFloat(@min(text_mod.subpixel_bins - 1, @floor((pen - px) * text_mod.subpixel_bins)));
        const sp = c.text.glyph(g, bin) orelse continue;
        var color = base;
        if (t.spans.len > 0) {
            const at = start + g.index;
            while (span_i < t.spans.len and t.spans[span_i].end <= at) span_i += 1;
            // Glyphs of a run are mostly in order; a ligature or bidi may step back.
            if (span_i < t.spans.len and t.spans[span_i].start > at) {
                span_i = 0;
                while (span_i < t.spans.len and t.spans[span_i].end <= at) span_i += 1;
            }
            if (span_i < t.spans.len and t.spans[span_i].start <= at) if (t.spans[span_i].color) |sc| {
                color = metal.color4(sc.alpha(opacity));
            };
        }
        push(c, out, .{
            .rect = .{ px / scale + sp.x, baseline - g.y + sp.y, sp.w, sp.h },
            .color = color,
            .uv = sp.uv,
            .kind = metal.Kind.text,
            .clip = clip4,
        });
    }
}

/// The x of the first glyph at or after byte `at` of the line, else its end.
fn xAt(lay: text_mod.Layout, at: usize) f32 {
    for (lay.glyphs) |g| if (g.index >= at) return g.x;
    return lay.width;
}

/// What spans draw besides their glyphs: backgrounds (inline code, marks)
/// behind the text, underlines (links) and lines through.
fn decorations(c: *Context, out: *std.ArrayList(metal.Instance), t: *const ctx_mod.Content.Text, lay: text_mod.Layout, start: usize, end: usize, x: f32, baseline: f32, f: text_mod.Font, clip4: [4]f32, opacity: f32) void {
    for (t.spans) |sp| {
        if (sp.end <= start or sp.start >= end) continue;
        if (sp.background == null and !sp.underline and !sp.strike) continue;
        const a = @max(sp.start, start) - start;
        const b = @min(sp.end, end) - start;
        const x0 = x + xAt(lay, a);
        const x1 = x + xAt(lay, b);
        if (x1 <= x0) continue;
        const color = sp.color orelse t.color;
        if (sp.background) |bg| push(c, out, .{
            .rect = .{ x0 - 3, baseline - f.ascent * 0.92 - 2, x1 - x0 + 6, (f.ascent + f.descent) * 0.92 + 4 },
            .color = metal.color4(bg.alpha(opacity)),
            .radius = 4,
            .clip = clip4,
        });
        if (sp.underline) push(c, out, .{
            .rect = .{ x0, baseline + 2, x1 - x0, 1 },
            .color = metal.color4(color.alpha(0.6 * opacity)),
            .clip = clip4,
        });
        if (sp.strike) push(c, out, .{
            .rect = .{ x0, baseline - f.ascent * 0.32, x1 - x0, 1 },
            .color = metal.color4(color.alpha(opacity)),
            .clip = clip4,
        });
    }
}

/// What a box with rounded corners clips is cut by its corners too: each
/// instance it clipped whose clip shares one of the box's corners (one the
/// box's own clip didn't cut off) has that corner rounded. A clip within
/// keeps its own rounding. Continuous corners cut as the box's do.
fn roundClip(items: []metal.Instance, box: types.Rect, visible: types.Rect, radius: f32, continuous: bool) void {
    const round = if (continuous) &metal.clipContinuous else &metal.clipRound;
    const near = struct {
        fn f(a: f32, b: f32) bool {
            return @abs(a - b) < 0.01;
        }
    }.f;
    const v = metal.clip4(visible);
    const b = metal.clip4(box);
    // The box's corners left whole by its own clip: 1 top left, 2 top
    // right, 4 bottom right, 8 bottom left.
    var whole: u4 = 0;
    if (near(v[0], b[0]) and near(v[1], b[1])) whole |= 1;
    if (near(v[2], b[2]) and near(v[1], b[1])) whole |= 2;
    if (near(v[2], b[2]) and near(v[3], b[3])) whole |= 4;
    if (near(v[0], b[0]) and near(v[3], b[3])) whole |= 8;
    if (whole == 0) return;
    for (items) |*i| {
        const k = i.clip;
        var corners: u4 = 0;
        if (near(k[0], v[0]) and near(k[1], v[1])) corners |= 1;
        if (near(k[2], v[2]) and near(k[1], v[1])) corners |= 2;
        if (near(k[2], v[2]) and near(k[3], v[3])) corners |= 4;
        if (near(k[0], v[0]) and near(k[3], v[3])) corners |= 8;
        corners &= whole;
        if (corners == 0) continue;
        const had = metal.clipCorners(i.clip_round);
        if (had.corners == 0) {
            i.clip_round = round(radius, corners);
        } else if (near(had.radius, radius) and had.continuous == continuous) i.clip_round = round(radius, had.corners | corners);
    }
}

fn paintScrollbar(c: *Context, out: *std.ArrayList(metal.Instance), n: *const ctx_mod.Node, visible: types.Rect, opacity: f32) void {
    const offset = c.scroll.get(n.id) orelse 0;
    // The content's height: from the first child's top to the last child's bottom.
    if (n.first_child == none) return;
    const first = c.node(n.first_child).rect;
    const last = c.node(n.last_child).rect;
    const content_h = last.y + last.h - first.y + n.style.padding.vertical();
    const view_h = n.rect.h;
    if (content_h <= view_h + 0.5) return;
    const bar_h = @max(24, view_h * view_h / content_h);
    const t = offset / (content_h - view_h);
    const y = n.rect.y + (view_h - bar_h) * std.math.clamp(t, 0, 1);
    push(c, out, .{
        .rect = .{ n.rect.x + n.rect.w - 7, y + 2, 4, bar_h - 4 },
        .color = metal.color4(c.theme.muted.alpha(0.5 * opacity)),
        .radius = 2,
        .clip = metal.clip4(visible),
    });
}

/// The atlas coordinates of the part `source` (x, y, w, h in the picture's
/// own pixels) of picture `e`; all of it when null.
pub fn sourceUv(e: @import("images.zig").Entry, source: ?[4]f32) [4]f32 {
    const r = source orelse return e.uv;
    const w: f32 = @floatFromInt(@max(e.width, 1));
    const h: f32 = @floatFromInt(@max(e.height, 1));
    const du = e.uv[2] - e.uv[0];
    const dv = e.uv[3] - e.uv[1];
    return .{ e.uv[0] + du * r[0] / w, e.uv[1] + dv * r[1] / h, e.uv[0] + du * (r[0] + r[2]) / w, e.uv[1] + dv * (r[1] + r[3]) / h };
}
