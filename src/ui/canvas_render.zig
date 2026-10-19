//! A canvas's drawing, as recorded (`Cmd`), rasterized on the CPU into
//! premultiplied BGRA: paths flattened through the current transform,
//! strokes made polygons before it (so a stretched stroke stretches),
//! coverage swept row by row into the paint, under the clip.
const std = @import("std");
const path = @import("path.zig");
const raster = @import("path_raster.zig");
const stroke_mod = @import("path_stroke.zig");
const paint_mod = @import("canvas_paint.zig");
const Point = path.Point;
const Transform = path.Transform;
const Paint = paint_mod.Paint;

/// How far flattened curves may be from the real ones, in device pixels.
pub const tolerance: f32 = 0.1;

pub const Cmd = union(enum) {
    fill: Fill,
    stroke: StrokeCmd,
    /// Keeps the transform, the clip and the opacity, for `restore`.
    save,
    restore,
    /// Applies before the current transform: what follows is drawn through both.
    transform: Transform,
    /// Intersects the clip with a path.
    clip: Fill,
    /// Fades what follows (times the current opacity).
    alpha: f32,
    /// What follows until `end_layer` is drawn apart, then blended down
    /// with this opacity (SVG's group opacity: overlaps do not show).
    begin_layer: f32,
    end_layer,

    pub const Fill = struct {
        path: path.Data,
        paint: Paint = .{ .solid = .{} },
        rule: path.Rule = .nonzero,
    };

    pub const StrokeCmd = struct {
        path: path.Data,
        paint: Paint,
        style: stroke_mod.Stroke,
    };
};

const State = struct {
    ctm: Transform,
    clip: ?[]const u8,
    alpha: f32,
};

const Renderer = struct {
    arena: std.mem.Allocator,
    w: usize,
    h: usize,
    cv: raster.Coverage,
    scratch: []f32,
    pl: path.Polylines = .{},
    state: State,
    saved: std.ArrayList(State) = .empty,
    layers: std.ArrayList(Layer) = .empty,
    target: paint_mod.Target,

    const Layer = struct { px: []u8, opacity: f32, below: []u8 };

    fn fill(r: *Renderer, f: Cmd.Fill) !void {
        if (r.state.alpha <= 0) return;
        r.pl.clear();
        try path.flatten(r.arena, f.path, r.state.ctm, tolerance, &r.pl);
        for (r.pl.runs.items) |run| r.cv.polygon(r.pl.run(run));
        try r.sweep(f.rule, f.paint);
    }

    fn sweep(r: *Renderer, rule: path.Rule, paint: Paint) !void {
        const shader = try r.arena.create(paint_mod.Shader);
        shader.* = paint_mod.Shader.init(paint, r.state.ctm, r.state.alpha);
        if (shader.kind == .none) {
            r.cv.sweep(rule, r.scratch, NullSink{});
            return;
        }
        r.target.clip = r.state.clip;
        r.cv.sweep(rule, r.scratch, paint_mod.FillSink{ .t = &r.target, .shader = shader });
    }

    fn stroke(r: *Renderer, s: Cmd.StrokeCmd) !void {
        if (r.state.alpha <= 0) return;
        const stretch = r.state.ctm.stretch();
        if (!(stretch > 0)) return;
        const tol = tolerance / stretch;
        r.pl.clear();
        try path.flatten(r.arena, s.path, .identity, tol, &r.pl);
        var st: stroke_mod.Stroker(PolySink) = .{
            .gpa = r.arena,
            .sink = .{ .r = r },
            .style = s.style,
            .tol = tol,
        };
        try st.polylines(&r.pl);
        try r.sweep(.nonzero, s.paint);
    }

    fn clip(r: *Renderer, f: Cmd.Fill) !void {
        const mask = try r.arena.alloc(u8, r.w * r.h);
        @memset(mask, 0);
        r.pl.clear();
        try path.flatten(r.arena, f.path, r.state.ctm, tolerance, &r.pl);
        for (r.pl.runs.items) |run| r.cv.polygon(r.pl.run(run));
        r.cv.sweep(f.rule, r.scratch, paint_mod.ClipSink{ .out = mask, .outer = r.state.clip, .w = r.w });
        r.state.clip = mask;
    }
};

/// A stroke's polygons, through the transform, into the coverage.
const PolySink = struct {
    r: *Renderer,

    pub fn polygon(s: PolySink, pts: []const Point) !void {
        if (pts.len < 2) return;
        const t = s.r.state.ctm;
        const first = t.apply(pts[0]);
        var prev = first;
        for (pts[1..]) |p| {
            const q = t.apply(p);
            s.r.cv.line(prev, q);
            prev = q;
        }
        s.r.cv.line(prev, first);
    }
};

const NullSink = struct {
    pub fn row(_: NullSink, _: usize, _: usize, _: []const f32) void {}
};

/// Draws `cmds` into `out` (premultiplied BGRA, `w` × `h`, as it is: the
/// drawing goes over it), through `base` (points to pixels).
pub fn render(gpa: std.mem.Allocator, cmds: []const Cmd, out: []u8, w: usize, h: usize, base: Transform) !void {
    std.debug.assert(out.len == w * h * 4);
    if (w == 0 or h == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: Renderer = .{
        .arena = arena,
        .w = w,
        .h = h,
        .cv = try raster.Coverage.init(arena, w, h),
        .scratch = try arena.alloc(f32, w),
        .state = .{ .ctm = base, .clip = null, .alpha = 1 },
        .target = .{ .w = w, .h = h, .px = out },
    };
    for (cmds) |cmd| switch (cmd) {
        .fill => |f| try r.fill(f),
        .stroke => |s| try r.stroke(s),
        .save => try r.saved.append(arena, r.state),
        .restore => if (r.saved.pop()) |s| {
            r.state = s;
        },
        .transform => |t| r.state.ctm = t.then(r.state.ctm),
        .clip => |f| try r.clip(f),
        .alpha => |a| r.state.alpha *= std.math.clamp(a, 0, 1),
        .begin_layer => |o| {
            const px = try arena.alloc(u8, w * h * 4);
            @memset(px, 0);
            try r.layers.append(arena, .{ .px = px, .opacity = o, .below = r.target.px });
            r.target.px = px;
        },
        .end_layer => if (r.layers.pop()) |l| {
            r.target.px = l.below;
            paint_mod.compositeLayer(l.below, l.px, l.opacity);
        },
    };
    // Layers left open are blended down.
    while (r.layers.pop()) |l| {
        r.target.px = l.below;
        paint_mod.compositeLayer(l.below, l.px, l.opacity);
    }
}
