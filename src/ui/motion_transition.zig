//! Transitions of boxes (`motion.transition`), after mygo's: a box moves
//! smoothly where the layout changes it, from where the last frame showed
//! it to where it is now in its parent (`position`), at its size (`size`,
//! for sizes in points) and in its colors (`colors`); it comes from its
//! `enter` as it appears, and goes to its `exit` as it leaves, a copy of it
//! as the last frame drew it, under its siblings, taking no room.
//!
//!     const row = c.open(.{ .direction = .row, .padding = .all(8) }, key);
//!     ... its children ...
//!     ui.motion.transition(c, row, .{ .enter = .{ .collapse = true }, .exit = .{ .collapse = true } });
//!     c.end();
//!
//! Call it once the box's children are built (a collapse measures them).
//! A box appears with its `enter` only in a parent that was there the
//! frame before, so a page showing all at once does not animate every box
//! in it. With less motion, nothing moves: colors change smoothly, and an
//! enter or exit that fades without collapsing fades in place.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const curve = @import("motion_curve.zig");
const motion = @import("motion.zig");
const store = @import("motion_store.zig");
const Context = @import("context.zig").Context;

/// Where a box comes from as it appears, or goes as it leaves, from its
/// place in the layout: moved by `x` and `y`, at `opacity`, scaled by
/// `scale` (0 keeps its size), turned by `rotate` degrees about its
/// center, and with `collapse`, without height in a column (width in a
/// row), its content clipped.
pub const Motion = struct {
    x: f32 = 0,
    y: f32 = 0,
    opacity: f32 = 0,
    scale: f32 = 0,
    rotate: f32 = 0,
    collapse: bool = false,
};

pub const Transition = struct {
    /// How it moves: a curve of `duration` seconds along `ease`, unless
    /// `animation` says otherwise (a spring keeps its velocity).
    animation: ?curve.Animation = null,
    duration: f32 = 0.2,
    ease: curve.Easing = .ease_out,
    /// What animates; all three when none is set.
    position: bool = false,
    size: bool = false,
    colors: bool = false,
    enter: ?Motion = null,
    exit: ?Motion = null,
};

/// What a box with a transition keeps between frames.
pub const Record = struct {
    frame: u64 = 0,
    parent: u64 = 0,
    position: bool = false,
    /// Where it was in its parent when last painted.
    rel: ?types.Point = null,
    window: types.Size = .{},
    anim: curve.Animation = .{},
    exit: ?Motion = null,
    /// Its instances as last painted, for its exit; their box.
    snapshot: std.ArrayListUnmanaged(gpu.Instance) = .empty,
    box: types.Rect = .{},
    row: bool = false,
    exiting: bool = false,
    /// Where it was among its siblings when last built, which orders the
    /// copies of boxes leaving one parent together.
    index: u32 = 0,

    pub fn deinit(r: *Record, gpa: std.mem.Allocator) void {
        r.snapshot.deinit(gpa);
    }
};

fn animationOf(t: Transition) curve.Animation {
    return t.animation orelse .curve(if (t.duration > 0) t.duration else 0.2, t.ease);
}

fn mix(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// A pose of `m`, `k` of the way to it from the box's place: its
/// transform and opacity.
fn poseOf(m: Motion, k: f32, still: bool) struct { ?types.Affine, f32 } {
    const opacity = mix(1, m.opacity, k);
    if (still) return .{ null, opacity };
    const s = mix(1, if (m.scale == 0) 1 else m.scale, k);
    const a = types.Affine.scaling(s, s).then(.rotation(m.rotate * k)).then(.translation(m.x * k, m.y * k));
    return .{ if (a.isIdentity()) null else a, opacity };
}

/// Gives box `index` its transition (see the file's comment).
pub fn apply(c: *Context, index: u32, t: Transition) void {
    const n = c.node(index);
    const id = n.id;
    const pid = if (n.parent != @import("context.zig").none) c.node(n.parent).id else 0;
    const a = animationOf(t);
    const reduce = motion.reduced(c);
    c.motion.sweep(c.gpa, c.frame);
    const gop = c.motion.boxes.getOrPut(c.gpa, id) catch return;
    const fresh = !gop.found_existing;
    if (fresh) gop.value_ptr.* = .{};
    const rec = gop.value_ptr;
    const all = !t.position and !t.size and !t.colors;
    const position = all or t.position;
    if (position != rec.position) {
        if (position) c.motion.moving_boxes += 1 else c.motion.moving_boxes -|= 1;
        rec.position = position;
    }
    rec.frame = c.frame;
    rec.parent = pid;
    rec.anim = a;
    rec.exit = t.exit;
    rec.row = n.parent != @import("context.zig").none and c.node(n.parent).style.direction == .row;
    rec.index = siblingIndex(c, index);
    var came_back: ?f32 = null;
    if (rec.exiting) {
        // Built again on its way out: it comes back from where its copy was.
        rec.exiting = false;
        c.motion.exiting -|= 1;
        const out = motion.channel(c, id, "tr.out", 0);
        came_back = if (out) |o| @floatCast(o[0].value) else 0;
    }
    const st = &c.node(index).style;
    if (all or t.colors) {
        if (st.background) |bg| st.background = motion.animateColor(c, id, "tr.bg", bg, a);
        if (st.border) |b| st.border = motion.animateColor(c, id, "tr.border", b, a);
    }
    if (all or t.size) {
        if (st.width == .px) st.width = .{ .px = motion.animateTo(c, id, "tr.w", st.width.px, a) };
        if (st.height == .px) st.height = .{ .px = motion.animateTo(c, id, "tr.h", st.height.px, a) };
    }
    const m = t.enter orelse return;
    // It enters in a parent that showed the frame before, or coming back.
    const entering = (fresh and pid != 0 and c.rects.contains(pid)) or came_back != null;
    const got = motion.channel(c, id, "tr.in", if (entering) 0 else 1) orelse return;
    const ch = got[0];
    if (entering) {
        ch.* = .init(if (came_back) |k| 1 - k else 0, c.time);
        ch.frame = c.frame;
        if (reduce and m.collapse) ch.value = 1 else ch.retarget(1, a);
    }
    ch.advance(c.time);
    if (ch.moving) c.animationFrame();
    const p: f32 = @floatCast(std.math.clamp(ch.value, 0, 1));
    if (p >= 1 and !ch.moving) return;
    const pose = poseOf(m, 1 - p, reduce);
    if (pose[0]) |x| st.transform = if (st.transform) |own| own.then(x) else x;
    st.opacity *= pose[1];
    if (m.collapse) collapse(c, index, p, rec.row);
}

/// Where box `index` is among its parent's children: the last so far, as
/// its children were just built, unless it was given its transition later.
fn siblingIndex(c: *Context, index: u32) u32 {
    const none = @import("context.zig").none;
    const n = c.node(index);
    if (n.parent == none) return 0;
    const p = c.node(n.parent);
    if (p.last_child == index) return p.child_count - 1;
    var k: u32 = 0;
    var at = p.first_child;
    while (at != none and at != index) : (at = c.node(at).next) k += 1;
    return k;
}

/// Gives box `index` `k` of its natural height (width, in a row), its
/// content clipped.
fn collapse(c: *Context, index: u32, k: f32, row: bool) void {
    const layout = @import("layout.zig");
    const n = c.node(index);
    const avail = if (c.rects.get(if (n.parent != @import("context.zig").none) c.node(n.parent).id else 0)) |r| r.w else c.size.w;
    const st = &c.node(index).style;
    const saved_h = st.max_height;
    const saved_w = st.max_width;
    st.max_height = std.math.inf(f32);
    st.max_width = std.math.inf(f32);
    const natural = layout.measure(c, index, avail);
    st.max_height = saved_h;
    st.max_width = saved_w;
    st.clip = true;
    if (row) st.width = .{ .px = natural.w * k } else st.height = .{ .px = natural.h * k };
}

/// Whether box `id`'s transition moved it in the frame before.
pub fn transitioning(c: *Context, id: u64) bool {
    const rec = c.motion.boxes.getPtr(id) orelse return false;
    if (rec.exiting) return true;
    inline for (.{ "tr.in", "tr.dx", "tr.dy", "tr.w", "tr.h" }) |k| if (!motion.settled(c, id, k)) return true;
    return false;
}

// Called by paint.

/// The move of box `index` from where it was in its parent to where it is
/// (for a box with a `position` transition): an offset that goes to zero.
pub fn offsetOf(c: *Context, index: u32) ?types.Point {
    const n = c.node(index);
    const rec = c.motion.boxes.getPtr(n.id) orelse return null;
    if (!rec.position or rec.frame != c.frame) return null;
    const parent = if (n.parent != @import("context.zig").none) c.node(n.parent).rect else types.Rect{};
    const rel: types.Point = .{ .x = n.rect.x - parent.x, .y = n.rect.y - parent.y };
    const resized = rec.window.w != c.size.w or rec.window.h != c.size.h;
    rec.window = c.size;
    const was = rec.rel;
    rec.rel = rel;
    const still = motion.reduced(c) or resized;
    var out: types.Point = .{};
    inline for (.{ "tr.dx", "tr.dy" }, .{ "x", "y" }) |key, axis| {
        const got = motion.channel(c, n.id, key, 0);
        if (got) |g| {
            const ch = g[0];
            ch.advance(c.time);
            if (was) |w| {
                const d = @field(w, axis) - @field(rel, axis);
                if (d != 0 and !still) {
                    // Continuous: what it showed stays where it was, and goes on.
                    ch.value += d;
                    if (!ch.moving) ch.retarget(0, rec.anim);
                } else if (still) {
                    ch.value = 0;
                    ch.moving = false;
                }
            }
            if (ch.moving) c.animationFrame();
            @field(out, axis) = @floatCast(ch.value);
        }
    }
    return if (out.x == 0 and out.y == 0) null else out;
}

/// Keeps what box `index` painted (instances `items`, in the window), for
/// its exit. Instances that read the frame's rows are left out.
pub fn keep(c: *Context, index: u32, items: []const gpu.Instance) void {
    const n = c.node(index);
    const rec = c.motion.boxes.getPtr(n.id) orelse return;
    if (rec.exit == null or rec.frame != c.frame) return;
    rec.snapshot.clearRetainingCapacity();
    for (items) |i| {
        if (i.kind >= 16 or i.kind == gpu.Kind.gradient or gpu.isMarker(i.kind) or i.kind == gpu.Kind.trailer) continue;
        rec.snapshot.append(c.gpa, i) catch return;
    }
    rec.box = n.rect;
}

/// Boxes going away under the boxes painted this frame: found once a frame.
pub const Going = struct {
    list: [32]Box = undefined,
    n: usize = 0,

    pub const Box = struct { id: u64, parent: u64, index: u32 = 0 };
};

fn before(x: Going.Box, y: Going.Box) bool {
    if (x.index != y.index) return x.index < y.index;
    return x.id < y.id;
}

/// The boxes not built this frame that go to their exit.
pub fn going(c: *Context) Going {
    var g: Going = .{};
    if (c.motion.boxes.count() == 0) return g;
    var it = c.motion.boxes.iterator();
    while (it.next()) |e| {
        const rec = e.value_ptr;
        if (rec.frame == c.frame or rec.exit == null or rec.snapshot.items.len == 0) continue;
        if (!rec.exiting) {
            // It just went: its copy heads for its exit.
            if (rec.frame + 1 != c.frame) continue;
            rec.exiting = true;
            c.motion.exiting += 1;
            if (motion.channel(c, e.key_ptr.*, "tr.out", 0)) |ch| {
                ch[0].* = .init(0, c.time);
                const m = rec.exit.?;
                if (motion.reduced(c) and m.collapse) ch[0].value = 1 else ch[0].retarget(1, rec.anim);
            }
        }
        if (g.n == g.list.len) break;
        g.list[g.n] = .{ .id = e.key_ptr.*, .parent = rec.parent, .index = rec.index };
        g.n += 1;
    }
    // In the order the boxes had, not the map's, which changes from run to
    // run: copies overlapping on their way paint alike every time. An
    // insertion sort, as few go at once.
    var i: usize = 1;
    while (i < g.n) : (i += 1) {
        var j = i;
        while (j > 0 and before(g.list[j], g.list[j - 1])) : (j -= 1) std.mem.swap(Going.Box, &g.list[j], &g.list[j - 1]);
    }
    return g;
}

/// The copy of going box `id` as it goes, `k` of the way: the instances
/// placed (in the window) and faded; null when it is gone.
pub fn exitPose(c: *Context, id: u64) ?struct { rec: *Record, pose: ?types.Affine, opacity: f32, clip: ?types.Rect } {
    const rec = c.motion.boxes.getPtr(id) orelse return null;
    const got = motion.channel(c, id, "tr.out", 0) orelse return null;
    const ch = got[0];
    ch.advance(c.time);
    const k: f32 = @floatCast(std.math.clamp(ch.value, 0, 1));
    if (k >= 1 and !ch.moving) return null;
    c.animationFrame();
    const m = rec.exit.?;
    const p = poseOf(m, k, motion.reduced(c));
    const b = rec.box;
    const o: types.Point = .{ .x = b.x + b.w / 2, .y = b.y + b.h / 2 };
    var clip: ?types.Rect = null;
    if (m.collapse) clip = if (rec.row) .{ .x = b.x, .y = b.y, .w = b.w * (1 - k), .h = b.h } else .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h * (1 - k) };
    return .{ .rec = rec, .pose = if (p[0]) |x| x.about(o) else null, .opacity = p[1], .clip = clip };
}

/// Forgets going box `id` (its exit is over, or its parent went too).
pub fn gone(c: *Context, id: u64) void {
    if (c.motion.boxes.fetchRemove(id)) |kv| {
        var r = kv.value;
        if (r.exiting) c.motion.exiting -|= 1;
        if (r.position) c.motion.moving_boxes -|= 1;
        r.deinit(c.gpa);
    }
}
