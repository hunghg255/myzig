//! Vector drawing in native UI: `ui.canvas` gives a draw function a
//! `Painter`, which records paths filled and stroked with colors and
//! gradients, through transforms and clips; the recording is rasterized
//! on the CPU (`canvas_render.zig`) at the window's scale into a picture
//! of the image atlas, which every renderer draws as it draws `ui.image`.
//! A drawing is rasterized again only when what it records changes: the
//! picture is keyed by a hash of it, so frames that draw the same thing
//! cost the recording and the hash.
//!
//!     fn wave(s: *State, p: *ui.Painter) void {
//!         var line = p.path();
//!         for (0..101) |i| {
//!             const x = p.size.w * @as(f32, @floatFromInt(i)) / 100;
//!             const y = p.size.h / 2 + 30 * @sin(@as(f32, @floatFromInt(i)) / 8 + s.phase);
//!             if (i == 0) line.moveTo(x, y) else line.lineTo(x, y);
//!         }
//!         p.stroke(&line, .color(s.color), .{ .width = 2, .join = .round });
//!     }
//!     _ = ui.canvas(c, .{ .w = 300, .h = 120 }, .{}, s, wave);
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const paths = @import("path.zig");
const render_mod = @import("canvas_render.zig");
const paint_mod = @import("canvas_paint.zig");
const stroke_mod = @import("path_stroke.zig");
const images = @import("images.zig");
const memo = @import("overlay_base.zig").memo;
const Context = ctx_mod.Context;
const Color = types.Color;
const Cmd = render_mod.Cmd;

pub const Path = paths.Path;
pub const Paint = paint_mod.Paint;
pub const Stroke = stroke_mod.Stroke;

/// Records a drawing, in points from the canvas's top left. Paths, stops
/// and dashes are copied: pass any memory.
pub const Painter = struct {
    arena: std.mem.Allocator,
    cmds: std.ArrayList(Cmd) = .empty,
    /// The canvas's size, in points.
    size: types.Size,
    /// Pixels per point it is rasterized at.
    scale: f32 = 2,
    /// The canvas's box, whose part in view `visible` gives
    /// (`canvas_visible.zig`).
    c: ?*Context = null,
    id: u64 = 0,
    /// The transform set (`transform`), and those `save` kept.
    ctm: paths.Transform = .identity,
    saved: std.ArrayList(paths.Transform) = .empty,

    /// A path in the frame's memory.
    pub fn path(p: *Painter) Path {
        return .init(p.arena);
    }

    fn push(p: *Painter, cmd: Cmd) void {
        p.cmds.append(p.arena, cmd) catch @panic("OOM");
    }

    fn own(p: *Painter, d: paths.Data) paths.Data {
        return d.dupe(p.arena) catch @panic("OOM");
    }

    fn ownPaint(p: *Painter, paint: Paint) Paint {
        var out = paint;
        switch (out) {
            .solid => {},
            .linear => |*g| g.stops = p.arena.dupe(paint_mod.Stop, g.stops) catch @panic("OOM"),
            .radial => |*g| g.stops = p.arena.dupe(paint_mod.Stop, g.stops) catch @panic("OOM"),
        }
        return out;
    }

    pub fn fill(p: *Painter, pt: *const Path, paint: Paint) void {
        p.fillData(pt.data(), paint, .nonzero);
    }

    pub fn fillRule(p: *Painter, pt: *const Path, paint: Paint, rule: paths.Rule) void {
        p.fillData(pt.data(), paint, rule);
    }

    pub fn fillData(p: *Painter, d: paths.Data, paint: Paint, rule: paths.Rule) void {
        if (d.verbs.len == 0) return;
        p.push(.{ .fill = .{ .path = p.own(d), .paint = p.ownPaint(paint), .rule = rule } });
    }

    pub fn stroke(p: *Painter, pt: *const Path, paint: Paint, style: Stroke) void {
        p.strokeData(pt.data(), paint, style);
    }

    pub fn strokeData(p: *Painter, d: paths.Data, paint: Paint, style: Stroke) void {
        if (d.verbs.len == 0 or !(style.width > 0)) return;
        var s = style;
        s.dash = p.arena.dupe(f32, style.dash) catch @panic("OOM");
        p.push(.{ .stroke = .{ .path = p.own(d), .paint = p.ownPaint(paint), .style = s } });
    }

    pub fn fillRect(p: *Painter, r: types.Rect, color: Color) void {
        var pt = p.path();
        pt.rect(r.x, r.y, r.w, r.h);
        p.fill(&pt, .color(color));
    }

    pub fn fillRoundRect(p: *Painter, r: types.Rect, radius: f32, paint: Paint) void {
        var pt = p.path();
        pt.roundRect(r.x, r.y, r.w, r.h, radius, radius);
        p.fill(&pt, paint);
    }

    pub fn fillCircle(p: *Painter, cx: f32, cy: f32, r: f32, paint: Paint) void {
        var pt = p.path();
        pt.circle(cx, cy, r);
        p.fill(&pt, paint);
    }

    pub fn strokeCircle(p: *Painter, cx: f32, cy: f32, r: f32, width: f32, color: Color) void {
        var pt = p.path();
        pt.circle(cx, cy, r);
        p.stroke(&pt, .color(color), .{ .width = width });
    }

    /// A straight line, `width` wide, with butt ends.
    pub fn line(p: *Painter, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, color: Color) void {
        var pt = p.path();
        pt.moveTo(x0, y0);
        pt.lineTo(x1, y1);
        p.stroke(&pt, .color(color), .{ .width = width });
    }

    /// Keeps the transform, the clip and the opacity until `restore`.
    pub fn save(p: *Painter) void {
        p.saved.append(p.arena, p.ctm) catch @panic("OOM");
        p.push(.save);
    }

    pub fn restore(p: *Painter) void {
        if (p.saved.pop()) |t| p.ctm = t;
        p.push(.restore);
    }

    /// Draws what follows through `t` (after the transforms already set).
    pub fn transform(p: *Painter, t: paths.Transform) void {
        p.ctm = t.then(p.ctm);
        p.push(.{ .transform = t });
    }

    /// The part of the canvas in view, in the coordinates it draws in now:
    /// its box within the scrolling boxes and clips around it and the
    /// window, as the last frame painted it, taken back through the
    /// transforms of its boxes and the painter's own (`transform`), so a
    /// canvas zoomed in sees as much less of itself as shows. A drawing
    /// taller than the window (a long document, a chart's many points)
    /// skips what falls outside it. All of it until a frame painted it.
    pub fn visible(p: *Painter) types.Rect {
        const whole: types.Rect = .{ .w = p.size.w, .h = p.size.h };
        const v = if (p.c) |c| @import("canvas_visible.zig").of(c, p.id, whole) else whole;
        if (p.ctm.a == 1 and p.ctm.b == 0 and p.ctm.c == 0 and p.ctm.d == 1 and p.ctm.e == 0 and p.ctm.f == 0) return v;
        const inv = p.ctm.invert() orelse return v;
        const m: types.Affine = .{ .a = inv.a, .b = inv.b, .c = inv.c, .d = inv.d, .x = inv.e, .y = inv.f };
        return m.bounds(v);
    }

    pub fn translate(p: *Painter, x: f32, y: f32) void {
        p.transform(.translation(x, y));
    }

    pub fn scaleBy(p: *Painter, sx: f32, sy: f32) void {
        p.transform(.scaling(sx, sy));
    }

    /// Turns what follows by `rad` radians, clockwise, around (cx, cy).
    pub fn rotate(p: *Painter, rad: f32, cx: f32, cy: f32) void {
        p.transform(paths.Transform.translation(-cx, -cy).then(.rotation(rad)).then(.translation(cx, cy)));
    }

    /// Keeps what follows inside the path (and the clips already set).
    pub fn clip(p: *Painter, pt: *const Path, rule: paths.Rule) void {
        p.push(.{ .clip = .{ .path = p.own(pt.data()), .rule = rule } });
    }

    pub fn clipRect(p: *Painter, r: types.Rect) void {
        var pt = p.path();
        pt.rect(r.x, r.y, r.w, r.h);
        p.clip(&pt, .nonzero);
    }

    /// Fades what follows, until `restore`.
    pub fn setAlpha(p: *Painter, a: f32) void {
        p.push(.{ .alpha = a });
    }

    /// Draws what follows apart, until `endLayer`, then blends it with
    /// `opacity`: a translucent group whose overlaps do not show.
    pub fn beginLayer(p: *Painter, opacity: f32) void {
        p.push(.{ .begin_layer = opacity });
    }

    pub fn endLayer(p: *Painter) void {
        p.push(.end_layer);
    }

    /// A hash of everything recorded: equal drawings have equal hashes.
    pub fn hash(p: *const Painter) u64 {
        var h = std.hash.Wyhash.init(0x63616e76);
        for (p.cmds.items) |cmd| {
            h.update(&.{@intFromEnum(cmd)});
            switch (cmd) {
                .fill, .clip => |f| {
                    hashData(&h, f.path);
                    hashPaint(&h, f.paint);
                    h.update(&.{@intFromEnum(f.rule)});
                },
                .stroke => |s| {
                    hashData(&h, s.path);
                    hashPaint(&h, s.paint);
                    const st = s.style;
                    h.update(std.mem.asBytes(&[_]f32{ st.width, st.miter_limit, st.dash_offset }));
                    h.update(&.{ @intFromEnum(st.join), @intFromEnum(st.cap) });
                    h.update(std.mem.sliceAsBytes(st.dash));
                },
                .transform => |t| h.update(std.mem.asBytes(&t)),
                .alpha, .begin_layer => |a| h.update(std.mem.asBytes(&a)),
                .save, .restore, .end_layer => {},
            }
        }
        return h.final();
    }
};

fn hashData(h: *std.hash.Wyhash, d: paths.Data) void {
    h.update(std.mem.asBytes(&d.verbs.len));
    h.update(std.mem.sliceAsBytes(d.verbs));
    h.update(std.mem.sliceAsBytes(d.pts));
}

fn hashColor(h: *std.hash.Wyhash, c: Color) void {
    h.update(std.mem.asBytes(&[_]f32{ c.r, c.g, c.b, c.a }));
}

fn hashPaint(h: *std.hash.Wyhash, paint: Paint) void {
    h.update(&.{@intFromEnum(paint)});
    switch (paint) {
        .solid => |c| hashColor(h, c),
        inline .linear, .radial => |g| {
            if (@TypeOf(g) == paint_mod.Linear) {
                h.update(std.mem.asBytes(&[_]f32{ g.from[0], g.from[1], g.to[0], g.to[1] }));
            } else {
                const f = g.focal orelse g.center;
                h.update(std.mem.asBytes(&[_]f32{ g.center[0], g.center[1], g.radius, f[0], f[1] }));
            }
            h.update(std.mem.asBytes(&g.transform));
            h.update(&.{@intFromEnum(g.spread)});
            for (g.stops) |s| {
                h.update(std.mem.asBytes(&s.offset));
                hashColor(h, s.color);
            }
        },
    }
}

pub const CanvasOptions = struct {
    /// Names the canvas among its siblings, for an id that survives reordering.
    key: ?[]const u8 = null,
    opacity: f32 = 1,
    /// Rounds the picture's corners (and clips what is drawn there).
    radius: f32 = 0,
};

/// A canvas `size` points large (a side of 0 fills its parent along it,
/// drawn at the size it had in the last layout): `draw(ctx, painter)`
/// records the drawing, rasterized when it changes. Returns the canvas's
/// box, for `c.interact`.
pub fn canvas(c: *Context, size: types.Size, opts: CanvasOptions, ctx: anytype, comptime draw: fn (@TypeOf(ctx), *Painter) void) u32 {
    const id = c.peekId(opts.key);
    const real = resolve(c, id, size);
    var p: Painter = .{ .arena = c.alloc(), .size = real, .scale = c.scale, .c = c, .id = id };
    if (real.w > 0 and real.h > 0) draw(ctx, &p);
    const Source = struct {
        cmds: []const Cmd,
        pub fn render(s: @This(), gpa: std.mem.Allocator, out: []u8, w: usize, h: usize, base: paths.Transform) !void {
            try render_mod.render(gpa, s.cmds, out, w, h, base);
        }
    };
    return picture(c, id, size, real, opts, p.hash(), Source{ .cmds = p.cmds.items });
}

/// The size a canvas is drawn at: its own, or the last layout's along a
/// side that fills (asking for a frame when the window's size changed, so
/// it is drawn again at the new size).
pub fn resolve(c: *Context, id: u64, size: types.Size) types.Size {
    if (size.w > 0 and size.h > 0) return size;
    const last = c.rects.get(id);
    const seen = memo(c, id, 0xca10, 0);
    const now = c.size.w * 4096 + c.size.h;
    if (last == null or seen.* != now) c.animationFrame();
    seen.* = now;
    const r = last orelse return .{};
    return .{ .w = if (size.w > 0) size.w else r.w, .h = if (size.h > 0) size.h else r.h };
}

/// Pixels of a picture, at most what the atlas holds on a side.
fn pixelSize(c: *const Context, real: types.Size) struct { w: u32, h: u32, scale: f32 } {
    var scale = c.scale;
    const side: f32 = @floatFromInt(images.size);
    const longest = @max(real.w, real.h) * scale;
    if (longest > side) scale *= side / longest;
    return .{
        .w = @intFromFloat(@max(0, @min(side, @round(real.w * scale)))),
        .h = @intFromFloat(@max(0, @min(side, @round(real.h * scale)))),
        .scale = scale,
    };
}

/// Shows the picture `source` renders for the box `id`, rendered again
/// only when `content` (a hash of what it draws) or its size changes: in
/// the same room of the atlas (`Images.replace`), so a drawing that changes
/// every frame does not fill it.
pub fn picture(c: *Context, id: u64, size: types.Size, real: types.Size, opts: CanvasOptions, content: u64, source: anytype) u32 {
    const style: types.Style = .{
        .width = if (size.w > 0) .{ .px = size.w } else .fill,
        .height = if (size.h > 0) .{ .px = size.h } else .fill,
        .radius = opts.radius,
    };
    const px = pixelSize(c, real);
    if (px.w == 0 or px.h == 0) return c.leaf(style, .none, opts.key);
    var h = std.hash.Wyhash.init(id);
    h.update(std.mem.asBytes(&[_]u64{ px.w, px.h }));
    const k = h.final();
    const im = &c.text.images;
    const had = ready(im, k);
    if (!had or remember(c, id, 0xcb00, content)) {
        const bgra = im.gpa.alloc(u8, @as(usize, px.w) * px.h * 4) catch @panic("OOM");
        @memset(bgra, 0);
        source.render(c.gpa, bgra, px.w, px.h, .scaling(px.scale, px.scale)) catch {
            im.gpa.free(bgra);
            return c.leaf(style, .none, opts.key);
        };
        const d: images.Decoded = .{ .width = px.w, .height = px.h, .w = px.w, .h = px.h, .bgra = bgra };
        if (had) im.replace(k, d) else im.put(k, d);
        _ = remember(c, id, 0xcb00, content);
    }
    swap(c, id, k);
    return c.leaf(style, .{ .image = .{ .key = k, .bytes = "", .opacity = opts.opacity } }, opts.key);
}

/// Whether the picture `k` is decoded and kept (a key whose decoding
/// failed, as one let go and asked for again, is forgotten).
fn ready(im: *images.Images, k: u64) bool {
    const d = im.decoded.get(k) orelse return false;
    if (d == null) {
        im.remove(k);
        return false;
    }
    return true;
}

/// Keeps `v` for the box `id` (in four 16-bit memos from `salt`); whether
/// it differs from what was kept.
fn remember(c: *Context, id: u64, salt: u32, v: u64) bool {
    var prev: u64 = 0;
    for (0..4) |i| {
        const part: u64 = @intFromFloat(memo(c, id, salt + @as(u32, @intCast(i)), 0).*);
        prev |= part << @intCast(16 * i);
    }
    if (prev == v) return false;
    for (0..4) |i| memo(c, id, salt + @as(u32, @intCast(i)), 0).* = @floatFromInt((v >> @intCast(16 * i)) & 0xffff);
    return true;
}

/// Remembers the box's picture, letting its last one go when it changed:
/// a drawing that changes every frame keeps one picture, not one a frame.
fn swap(c: *Context, id: u64, k: u64) void {
    var prev: u64 = 0;
    for (0..4) |i| {
        const part: u64 = @intFromFloat(memo(c, id, 0xca00 + @as(u32, @intCast(i)), 0).*);
        prev |= part << @intCast(16 * i);
    }
    if (prev == k) return;
    if (prev != 0) c.text.images.remove(prev);
    _ = remember(c, id, 0xca00, k);
}
