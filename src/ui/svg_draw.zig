//! An SVG document drawn with a canvas's `Painter`: the root's viewBox
//! fitted to the canvas (preserveAspectRatio), groups and nested svgs,
//! paths and basic shapes, `use` of elements and symbols, transforms,
//! fills and strokes in colors and gradients (linear and radial, by
//! reference, in either unit system), their opacities, group opacity in a
//! layer, and clip paths. Text, masks, filters, markers and patterns are
//! left out.
const std = @import("std");
const types = @import("types.zig");
const path = @import("path.zig");
const xml = @import("svg_xml.zig");
const style = @import("svg_style.zig");
const pathdata = @import("svg_pathdata.zig");
const paint_mod = @import("canvas_paint.zig");
const stroke_mod = @import("path_stroke.zig");
const Painter = @import("canvas.zig").Painter;
const Color = types.Color;
const Transform = path.Transform;
const Paint = paint_mod.Paint;

/// What children get from their parents.
const Inherited = struct {
    fill: style.PaintValue = .{ .color = .black },
    fill_opacity: f32 = 1,
    fill_rule: path.Rule = .nonzero,
    clip_rule: path.Rule = .nonzero,
    stroke: style.PaintValue = .none,
    stroke_opacity: f32 = 1,
    stroke_width: f32 = 1,
    cap: stroke_mod.Cap = .butt,
    join: stroke_mod.Join = .miter,
    miter_limit: f32 = 4,
    dash: []const f32 = &.{},
    dash_offset: f32 = 0,
    color: Color = .black,
    visible: bool = true,
};

/// What each element has of its own.
const Own = struct {
    opacity: f32 = 1,
    display: bool = true,
    transform: Transform = .identity,
    clip: ?[]const u8 = null,
};

pub const Drawer = struct {
    arena: std.mem.Allocator,
    doc: xml.Doc,
    rules: []const style.Rule,
    p: *Painter,
    /// The viewport's size in user units, for percentages.
    vw: f32 = 100,
    vh: f32 = 100,
    depth: u32 = 0,

    fn el(d: *const Drawer, i: u32) xml.Element {
        return d.doc.elements[i];
    }

    /// The element's style: its parent's, its attributes, the style
    /// sheet's rules (by specificity) and its `style` attribute, in turn.
    fn styleOf(d: *const Drawer, i: u32, parent: Inherited) struct { Inherited, Own } {
        var inh = parent;
        var own: Own = .{};
        const e = d.el(i);
        for (e.attrs) |a| d.apply(&inh, &own, a.name, a.value);
        for ([_]u32{ 0, 1, 10, 11, 100, 101, 110, 111 }) |spec| for (d.rules) |r| {
            if (r.specificity() != spec or !r.matches(e)) continue;
            var decls = style.Declarations.init(r.decls);
            while (decls.next()) |a| d.apply(&inh, &own, a.name, a.value);
        };
        if (e.attr("style")) |s| {
            var decls = style.Declarations.init(s);
            while (decls.next()) |a| d.apply(&inh, &own, a.name, a.value);
        }
        if (e.attr("transform")) |t| own.transform = style.transform(t);
        return .{ inh, own };
    }

    fn apply(d: *const Drawer, inh: *Inherited, own: *Own, name: []const u8, v: []const u8) void {
        const eq = std.mem.eql;
        if (eq(u8, v, "inherit")) return;
        if (eq(u8, name, "fill")) {
            if (style.paint(v)) |pv| inh.fill = pv;
        } else if (eq(u8, name, "stroke")) {
            if (style.paint(v)) |pv| inh.stroke = pv;
        } else if (eq(u8, name, "color")) {
            if (style.color(v)) |c| inh.color = c;
        } else if (eq(u8, name, "fill-opacity")) {
            inh.fill_opacity = opacity(v) orelse inh.fill_opacity;
        } else if (eq(u8, name, "stroke-opacity")) {
            inh.stroke_opacity = opacity(v) orelse inh.stroke_opacity;
        } else if (eq(u8, name, "opacity")) {
            own.opacity = opacity(v) orelse 1;
        } else if (eq(u8, name, "fill-rule")) {
            inh.fill_rule = if (eq(u8, v, "evenodd")) .evenodd else .nonzero;
        } else if (eq(u8, name, "clip-rule")) {
            inh.clip_rule = if (eq(u8, v, "evenodd")) .evenodd else .nonzero;
        } else if (eq(u8, name, "stroke-width")) {
            inh.stroke_width = style.length(v, d.diagonal()) orelse inh.stroke_width;
        } else if (eq(u8, name, "stroke-linecap")) {
            inh.cap = std.meta.stringToEnum(stroke_mod.Cap, v) orelse inh.cap;
        } else if (eq(u8, name, "stroke-linejoin")) {
            inh.join = if (eq(u8, v, "miter-clip") or eq(u8, v, "arcs")) .miter else std.meta.stringToEnum(stroke_mod.Join, v) orelse inh.join;
        } else if (eq(u8, name, "stroke-miterlimit")) {
            inh.miter_limit = style.number(v) orelse inh.miter_limit;
        } else if (eq(u8, name, "stroke-dasharray")) {
            inh.dash = if (eq(u8, v, "none")) &.{} else d.list(v);
        } else if (eq(u8, name, "stroke-dashoffset")) {
            inh.dash_offset = style.length(v, d.diagonal()) orelse 0;
        } else if (eq(u8, name, "display")) {
            own.display = !eq(u8, v, "none");
        } else if (eq(u8, name, "visibility")) {
            inh.visible = eq(u8, v, "visible");
        } else if (eq(u8, name, "clip-path")) {
            const pv = style.paint(v) orelse return;
            own.clip = if (pv == .url) pv.url.id else null;
        }
    }

    fn diagonal(d: *const Drawer) f32 {
        return @sqrt((d.vw * d.vw + d.vh * d.vh) / 2);
    }

    fn list(d: *const Drawer, v: []const u8) []const f32 {
        var out: std.ArrayList(f32) = .empty;
        var it = std.mem.tokenizeAny(u8, v, " ,\t\n");
        while (it.next()) |tok| out.append(d.arena, style.length(tok, d.diagonal()) orelse return &.{}) catch return &.{};
        return out.items;
    }

    fn len(_: *const Drawer, e: xml.Element, name: []const u8, percent_of: f32, default: f32) f32 {
        return style.length(e.attr(name) orelse return default, percent_of) orelse default;
    }

    /// Draws the element `i` and what it holds.
    pub fn element(d: *Drawer, i: u32, parent: Inherited) void {
        if (d.depth > 24) return;
        d.depth += 1;
        defer d.depth -= 1;
        const e = d.el(i);
        const skip = [_][]const u8{ "defs", "linearGradient", "radialGradient", "clipPath", "mask", "pattern", "marker", "symbol", "style", "title", "desc", "metadata", "text", "filter", "script" };
        for (skip) |s| if (std.mem.eql(u8, e.name, s)) return;
        const inh, const own = d.styleOf(i, parent);
        if (!own.display or own.opacity <= 0) return;
        const p = d.p;
        p.save();
        defer p.restore();
        p.transform(own.transform);
        if (own.clip) |id| d.clipTo(id, inh);
        const group = std.mem.eql(u8, e.name, "g") or std.mem.eql(u8, e.name, "a") or std.mem.eql(u8, e.name, "switch") or std.mem.eql(u8, e.name, "svg") or std.mem.eql(u8, e.name, "use");
        const layered = own.opacity < 1 and (group or (paints(inh.fill) and paints(inh.stroke)));
        if (layered) p.beginLayer(own.opacity) else if (own.opacity < 1) p.setAlpha(own.opacity);
        defer if (layered) p.endLayer();
        if (std.mem.eql(u8, e.name, "svg")) return d.nested(i, inh);
        if (std.mem.eql(u8, e.name, "use")) return d.use(i, inh);
        if (group) {
            var it = d.doc.children(i);
            while (it.next()) |ch| d.element(ch, inh);
            return;
        }
        var shape = path.Path.init(d.arena);
        if (!d.build(e, &shape)) return;
        if (!inh.visible) return;
        d.paintShape(e, &shape, inh);
    }

    /// The outline of a shape element, false for what is not one.
    fn build(d: *const Drawer, e: xml.Element, out: *path.Path) bool {
        const eq = std.mem.eql;
        if (eq(u8, e.name, "path")) {
            pathdata.parse(e.attr("d") orelse "", out);
        } else if (eq(u8, e.name, "rect")) {
            const w = d.len(e, "width", d.vw, 0);
            const h = d.len(e, "height", d.vh, 0);
            if (!(w > 0 and h > 0)) return false;
            var rx = style.length(e.attr("rx") orelse "", d.vw);
            var ry = style.length(e.attr("ry") orelse "", d.vh);
            if (rx == null) rx = ry;
            if (ry == null) ry = rx;
            out.roundRect(d.len(e, "x", d.vw, 0), d.len(e, "y", d.vh, 0), w, h, rx orelse 0, ry orelse 0);
        } else if (eq(u8, e.name, "circle")) {
            const r = d.len(e, "r", d.diagonal(), 0);
            if (!(r > 0)) return false;
            out.circle(d.len(e, "cx", d.vw, 0), d.len(e, "cy", d.vh, 0), r);
        } else if (eq(u8, e.name, "ellipse")) {
            const rx = d.len(e, "rx", d.vw, 0);
            const ry = d.len(e, "ry", d.vh, 0);
            if (!(rx > 0 and ry > 0)) return false;
            out.ellipse(d.len(e, "cx", d.vw, 0), d.len(e, "cy", d.vh, 0), rx, ry);
        } else if (eq(u8, e.name, "line")) {
            out.moveTo(d.len(e, "x1", d.vw, 0), d.len(e, "y1", d.vh, 0));
            out.lineTo(d.len(e, "x2", d.vw, 0), d.len(e, "y2", d.vh, 0));
        } else if (eq(u8, e.name, "polyline") or eq(u8, e.name, "polygon")) {
            var n: style.Numbers = .{ .s = e.attr("points") orelse "" };
            var first = true;
            while (n.next()) |x| {
                const y = n.next() orelse break;
                if (first) out.moveTo(x, y) else out.lineTo(x, y);
                first = false;
            }
            if (eq(u8, e.name, "polygon") and !first) out.close();
        } else return false;
        return out.verbs.items.len > 0;
    }

    fn paintShape(d: *Drawer, e: xml.Element, shape: *const path.Path, inh: Inherited) void {
        const bbox = shape.data().bounds();
        const is_line = std.mem.eql(u8, e.name, "line");
        if (!is_line) if (d.resolve(inh.fill, inh, bbox, inh.fill_opacity)) |fp| d.p.fillRule(shape, fp, inh.fill_rule);
        if (d.resolve(inh.stroke, inh, bbox, inh.stroke_opacity)) |sp| d.p.stroke(shape, sp, .{
            .width = inh.stroke_width,
            .join = inh.join,
            .cap = inh.cap,
            .miter_limit = inh.miter_limit,
            .dash = inh.dash,
            .dash_offset = inh.dash_offset,
        });
    }

    /// A nested `<svg>`: its own viewport, at x, y.
    fn nested(d: *Drawer, i: u32, inh: Inherited) void {
        const e = d.el(i);
        const w = d.len(e, "width", d.vw, d.vw);
        const h = d.len(e, "height", d.vh, d.vh);
        d.p.translate(d.len(e, "x", d.vw, 0), d.len(e, "y", d.vh, 0));
        var clip = path.Path.init(d.arena);
        clip.rect(0, 0, w, h);
        d.p.clip(&clip, .nonzero);
        d.content(i, inh, w, h);
    }

    /// The children of an svg or a symbol, through its viewBox into w × h.
    fn content(d: *Drawer, i: u32, inh: Inherited, w: f32, h: f32) void {
        const e = d.el(i);
        const saved_w = d.vw;
        const saved_h = d.vh;
        defer {
            d.vw = saved_w;
            d.vh = saved_h;
        }
        if (viewBox(e)) |vb| {
            d.p.transform(fit(vb, w, h, e.attr("preserveAspectRatio") orelse ""));
            d.vw = vb[2];
            d.vh = vb[3];
        } else {
            d.vw = w;
            d.vh = h;
        }
        var it = d.doc.children(i);
        while (it.next()) |ch| d.element(ch, inh);
    }

    fn use(d: *Drawer, i: u32, inh: Inherited) void {
        const e = d.el(i);
        var id = e.href() orelse return;
        if (id.len > 0 and id[0] == '#') id = id[1..];
        const target = d.doc.byId(id) orelse return;
        d.p.translate(d.len(e, "x", d.vw, 0), d.len(e, "y", d.vh, 0));
        const t = d.el(target);
        if (std.mem.eql(u8, t.name, "symbol")) {
            const w = d.len(e, "width", d.vw, d.vw);
            const h = d.len(e, "height", d.vh, d.vh);
            const sym, _ = d.styleOf(target, inh);
            return d.content(target, sym, w, h);
        }
        d.element(target, inh);
    }

    fn clipTo(d: *Drawer, id: []const u8, inh: Inherited) void {
        const ci = d.doc.byId(id) orelse return;
        const ce = d.el(ci);
        if (!std.mem.eql(u8, ce.name, "clipPath")) return;
        var all = path.Path.init(d.arena);
        var rule = inh.clip_rule;
        const base = if (ce.attr("transform")) |t| style.transform(t) else Transform.identity;
        var it = d.doc.children(ci);
        while (it.next()) |ch| {
            var one = path.Path.init(d.arena);
            const che = d.el(ch);
            if (!d.build(che, &one)) continue;
            const cs, const co = d.styleOf(ch, inh);
            rule = cs.clip_rule;
            all.append(one.data(), co.transform.then(base));
        }
        d.p.clip(&all, rule);
    }

    /// A paint for the canvas, faded by `alpha`; null paints nothing.
    fn resolve(d: *Drawer, pv: style.PaintValue, inh: Inherited, bbox: [4]f32, alpha: f32) ?Paint {
        return switch (pv) {
            .none => null,
            .color => |c| .color(c.alpha(alpha)),
            .current => .color(inh.color.alpha(alpha)),
            .url => |u| d.gradient(u.id, bbox, alpha) orelse if (u.fallback) |c| Paint.color(c.alpha(alpha)) else null,
        };
    }

    fn gradient(d: *Drawer, id: []const u8, bbox: [4]f32, alpha: f32) ?Paint {
        var chain: [6]u32 = undefined;
        var n: usize = 0;
        var at = d.doc.byId(id) orelse return null;
        while (n < chain.len) {
            const ge = d.el(at);
            if (!std.mem.eql(u8, ge.name, "linearGradient") and !std.mem.eql(u8, ge.name, "radialGradient")) break;
            chain[n] = at;
            n += 1;
            var next = ge.href() orelse break;
            if (next.len > 0 and next[0] == '#') next = next[1..];
            at = d.doc.byId(next) orelse break;
        }
        if (n == 0) return null;
        const first = d.el(chain[0]);
        const attr = struct {
            fn f(dd: *Drawer, ch: []const u32, name: []const u8) ?[]const u8 {
                for (ch) |k| if (dd.el(k).attr(name)) |v| return v;
                return null;
            }
        }.f;
        const links = chain[0..n];
        // The stops: those of the first in the chain that has any.
        var stops: std.ArrayList(paint_mod.Stop) = .empty;
        for (links) |k| {
            var it = d.doc.children(k);
            while (it.next()) |si| {
                const se = d.el(si);
                if (!std.mem.eql(u8, se.name, "stop")) continue;
                var color: Color = .black;
                var op: f32 = 1;
                if (se.attr("stop-color")) |v| color = style.color(v) orelse color;
                if (se.attr("stop-opacity")) |v| op = opacity(v) orelse op;
                if (se.attr("style")) |s| {
                    var decls = style.Declarations.init(s);
                    while (decls.next()) |a| {
                        if (std.mem.eql(u8, a.name, "stop-color")) color = style.color(a.value) orelse color;
                        if (std.mem.eql(u8, a.name, "stop-opacity")) op = opacity(a.value) orelse op;
                    }
                }
                var off = fraction(se.attr("offset") orelse "0") orelse 0;
                off = std.math.clamp(off, 0, 1);
                if (stops.items.len > 0) off = @max(off, stops.items[stops.items.len - 1].offset);
                stops.append(d.arena, .{ .offset = off, .color = color.alpha(op * alpha) }) catch return null;
            }
            if (stops.items.len > 0) break;
        }
        if (stops.items.len == 0) return null;
        if (stops.items.len == 1) return .color(stops.items[0].color);
        const user = std.mem.eql(u8, attr(d, links, "gradientUnits") orelse "", "userSpaceOnUse");
        var t = if (attr(d, links, "gradientTransform")) |v| style.transform(v) else Transform.identity;
        if (!user) {
            const bw = bbox[2] - bbox[0];
            const bh = bbox[3] - bbox[1];
            if (!(bw > 0 and bh > 0)) return null;
            t = t.then(.{ .a = bw, .d = bh, .e = bbox[0], .f = bbox[1] });
        }
        const spread: paint_mod.Spread = std.meta.stringToEnum(paint_mod.Spread, attr(d, links, "spreadMethod") orelse "pad") orelse .pad;
        const coord = struct {
            fn f(dd: *Drawer, ch: []const u32, name: []const u8, default: []const u8, is_user: bool, ref: f32) f32 {
                const v = attr(dd, ch, name) orelse default;
                return if (is_user) style.length(v, ref) orelse 0 else fraction(v) orelse 0;
            }
        }.f;
        if (std.mem.eql(u8, first.name, "linearGradient")) return .{ .linear = .{
            .from = .{ coord(d, links, "x1", "0%", user, d.vw), coord(d, links, "y1", "0%", user, d.vh) },
            .to = .{ coord(d, links, "x2", "100%", user, d.vw), coord(d, links, "y2", "0%", user, d.vh) },
            .stops = stops.items,
            .spread = spread,
            .transform = t,
        } };
        const cx = coord(d, links, "cx", "50%", user, d.vw);
        const cy = coord(d, links, "cy", "50%", user, d.vh);
        const fx = if (attr(d, links, "fx") != null) coord(d, links, "fx", "50%", user, d.vw) else cx;
        const fy = if (attr(d, links, "fy") != null) coord(d, links, "fy", "50%", user, d.vh) else cy;
        return .{ .radial = .{
            .center = .{ cx, cy },
            .radius = coord(d, links, "r", "50%", user, d.diagonal()),
            .focal = .{ fx, fy },
            .stops = stops.items,
            .spread = spread,
            .transform = t,
        } };
    }
};

fn paints(pv: style.PaintValue) bool {
    return pv != .none;
}

fn opacity(v: []const u8) ?f32 {
    return std.math.clamp(fraction(v) orelse return null, 0, 1);
}

/// A number, or a percentage as a fraction.
fn fraction(v_in: []const u8) ?f32 {
    const v = std.mem.trim(u8, v_in, " \t\r\n");
    if (std.mem.endsWith(u8, v, "%")) return (style.number(v[0 .. v.len - 1]) orelse return null) / 100;
    return style.number(v);
}

pub fn viewBox(e: xml.Element) ?[4]f32 {
    var n: style.Numbers = .{ .s = e.attr("viewBox") orelse return null };
    var vb: [4]f32 = undefined;
    for (&vb) |*v| v.* = n.next() orelse return null;
    if (!(vb[2] > 0 and vb[3] > 0)) return null;
    return vb;
}

/// The viewBox `vb` into a w × h viewport, as preserveAspectRatio says.
pub fn fit(vb: [4]f32, w: f32, h: f32, par: []const u8) Transform {
    var sx = w / vb[2];
    var sy = h / vb[3];
    var it = std.mem.tokenizeScalar(u8, par, ' ');
    const al = it.next() orelse "xMidYMid";
    const slice = std.mem.eql(u8, it.next() orelse "meet", "slice");
    if (std.mem.eql(u8, al, "none")) return Transform.translation(-vb[0], -vb[1]).then(.scaling(sx, sy));
    const s = if (slice) @max(sx, sy) else @min(sx, sy);
    sx = s;
    sy = s;
    const ax: f32 = if (std.mem.indexOf(u8, al, "xMin") != null) 0 else if (std.mem.indexOf(u8, al, "xMax") != null) 1 else 0.5;
    const ay: f32 = if (std.mem.indexOf(u8, al, "YMin") != null) 0 else if (std.mem.indexOf(u8, al, "YMax") != null) 1 else 0.5;
    const tx = (w - vb[2] * s) * ax;
    const ty = (h - vb[3] * s) * ay;
    return Transform.translation(-vb[0], -vb[1]).then(.scaling(s, s)).then(.translation(tx, ty));
}

/// The document's own size, in points: its width and height, or its
/// viewBox's, or 300 × 150 as browsers take.
pub fn intrinsic(doc: xml.Doc) types.Size {
    if (doc.elements.len == 0) return .{};
    const root = doc.elements[0];
    const vb = viewBox(root);
    const w = style.length(root.attr("width") orelse "", if (vb) |v| v[2] else 300);
    const h = style.length(root.attr("height") orelse "", if (vb) |v| v[3] else 150);
    if (w != null and h != null) return .{ .w = w.?, .h = h.? };
    if (vb) |v| {
        if (w) |ww| return .{ .w = ww, .h = ww * v[3] / v[2] };
        if (h) |hh| return .{ .w = hh * v[2] / v[3], .h = hh };
        return .{ .w = v[2], .h = v[3] };
    }
    return .{ .w = w orelse 300, .h = h orelse 150 };
}

/// Draws a parsed document into the painter's whole canvas.
pub fn draw(arena: std.mem.Allocator, doc: xml.Doc, p: *Painter, current_color: Color) !void {
    if (doc.elements.len == 0 or !std.mem.eql(u8, doc.elements[0].name, "svg")) return error.NotSvg;
    var rules: std.ArrayList(style.Rule) = .empty;
    for (doc.elements) |e| if (std.mem.eql(u8, e.name, "style")) try style.css(arena, e.text, &rules);
    var d: Drawer = .{ .arena = arena, .doc = doc, .rules = rules.items, .p = p, .vw = p.size.w, .vh = p.size.h };
    const root = doc.elements[0];
    const own = intrinsic(doc);
    // A root without a viewBox scales its own size to the canvas.
    const vb = viewBox(root) orelse [4]f32{ 0, 0, own.w, own.h };
    p.save();
    defer p.restore();
    p.transform(fit(vb, p.size.w, p.size.h, root.attr("preserveAspectRatio") orelse ""));
    d.vw = vb[2];
    d.vh = vb[3];
    const inh, const ro = d.styleOf(0, .{ .color = current_color });
    if (!ro.display) return;
    p.transform(ro.transform);
    if (ro.opacity < 1) p.beginLayer(ro.opacity);
    var it = doc.children(0);
    while (it.next()) |ch| d.element(ch, inh);
    if (ro.opacity < 1) p.endLayer();
}
