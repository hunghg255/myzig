//! Drag and drop within a window: boxes that drag data (`DragDrop.draggable`)
//! and boxes that take it (`DragDrop.target`). Once the pointer pressing a
//! draggable moves 4 points, a translucent copy of it follows the pointer
//! and the press is no click; the innermost target under the pointer that
//! takes one of the data's formats gets it when the pointer lets go, with
//! the effect both ends allow (copy, move, link). Escape gives up a drag.
//!
//!     var dnd: ui.DragDrop = .{}; // the app's, kept across frames
//!
//!     for (s.todo.items) |*task| {
//!         ui.key(c, task.name);
//!         var d = s.dnd.draggable(c, .{ .padding = .all(8) }, .{ .effects = .copy_move });
//!         if (d.starting) d.offer(try transfer.valueData(gpa, Task, task));
//!         ui.text(c, task.name, .{});
//!         if (d.end().finished) |f| if (f.effect == .move) s.remove(task);
//!     }
//!     const done = c.open(.{ .grow = 1, .padding = .all(12) }, "done");
//!     const t = s.dnd.target(c, done, .{ .formats = &.{transfer.value_format(Task)}, .effects = .copy_move });
//!     if (t.over) c.node(done).style.border = c.theme.accent;
//!     if (t.dropped) |drop| drop.data.value(Task).?.done = true;
//!     c.end();
//!     s.dnd.preview(c); // last: the copy that follows the pointer
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const transfer = @import("../transfer.zig");
const Context = ctx_mod.Context;
const Point = types.Point;

/// How far the pointer moves before a press drags.
pub const threshold: f32 = 4;

pub const DraggableOptions = struct {
    /// What a drop may do with the data: copy unless it says more.
    effects: transfer.Effects = .{},
    /// How many values the drag holds: shown beside the pointer when
    /// several (the rows chosen in a list, dragged together).
    count: u32 = 1,
    /// Dims the box while its data drags.
    dim: bool = true,
};

pub const TargetOptions = struct {
    /// The formats it takes; empty takes any.
    formats: []const []const u8 = &.{},
    effects: transfer.Effects = .{},
    disabled: bool = false,
};

/// What a source hears once its drag is over.
pub const Finished = struct {
    /// What the target did: move means the source removes its value.
    effect: transfer.Effect,
    /// Escape, or let go over nothing that takes it.
    canceled: bool,
    /// Canceled because the user gave it up (Escape, `DragDrop.cancel`),
    /// not let go over no target: a tab let go outside every window is
    /// `canceled` and not `escaped`, at `screen`.
    escaped: bool = false,
    /// Where the drag ended on the screen, in points from the primary
    /// display's top left, when it ended in the system's drag (out of the
    /// window); null when it ended in the window, at the pointer.
    screen: ?Point = null,
};

/// How the system's drag ended (`DragDrop.externalEnd`).
pub const ExternalEnd = struct {
    /// What the target did; none when no target took it.
    effect: transfer.Effect,
    /// Given up (Escape) rather than let go over no target.
    escaped: bool = false,
    /// Where it ended, in screen points.
    screen: ?Point = null,
};

/// What a target got: the data, valid until the next frame (read it, or
/// `clone` it to keep it), and the effect agreed.
pub const Drop = struct {
    data: *transfer.Data,
    effect: transfer.Effect,
    /// Where the pointer let go, in the window.
    at: Point,
};

const Target = struct { id: u64, rect: types.Rect, accepts: bool, effects: transfer.Effects };

const Active = struct {
    source: u64,
    data: transfer.Data,
    effects: transfer.Effects,
    /// Where in the box it was grabbed, and the box's size.
    grab: Point,
    size: types.Size,
    count: u32,
};

/// Goes on with a drag that left the window in the system's drag and
/// drop (other windows, other apps): `start` is called in the frame the
/// pointer leaves and must not block; later, outside the frame, the
/// platform drags `DragDrop.active`'s data, then calls `externalDone`
/// and draws a frame. `myzig.systemDrag(window)` where there is one.
pub const External = struct {
    ctx: ?*anyopaque = null,
    start: *const fn (ctx: ?*anyopaque, dd: *DragDrop) void,
};

/// The state of drags in one window, kept by the app.
pub const DragDrop = struct {
    /// Drags leaving the window go on in the system's; within it only
    /// when null.
    external: ?External = null,
    /// The drag went on in the system's: this window waits for its end.
    handed_off: bool = false,
    /// The system's drag took the button's release.
    lift: bool = false,
    gpa: ?std.mem.Allocator = null,
    synced: u64 = std.math.maxInt(u64),
    /// A press on a draggable that hasn't moved far enough yet.
    press: ?struct { id: u64, at: Point, origin: Point, size: types.Size } = null,
    active: ?Active = null,
    targets: std.ArrayList(Target) = .empty,
    next_targets: std.ArrayList(Target) = .empty,
    /// The target the data would drop on, from the last frame's.
    over: u64 = 0,
    dropped: ?struct { target: u64, data: transfer.Data, effect: transfer.Effect, at: Point, taken: bool = false } = null,
    finished: ?struct { source: u64, result: Finished } = null,
    /// The nodes of the source's box in this frame, copied by `preview`.
    preview_lo: u32 = 0,
    preview_hi: u32 = 0,
    preview_frame: u64 = std.math.maxInt(u64),
    /// Where a drag from another app (or one of this app's that left the
    /// window and came back) is over the window: the system's pointer,
    /// which the window's own input doesn't follow meanwhile.
    incoming: ?Point = null,
    /// It was let go at `incoming`: the next frame drops it.
    incoming_drop: bool = false,
    drop_effect: transfer.Effect = .none,

    pub fn deinit(dd: *DragDrop) void {
        const gpa = dd.gpa orelse return;
        if (dd.active) |*a| a.data.deinit();
        if (dd.dropped) |*d| d.data.deinit();
        dd.targets.deinit(gpa);
        dd.next_targets.deinit(gpa);
        dd.* = .{};
    }

    /// The system's drag (`External`) ended with `effect` (none: no
    /// target took it).
    pub fn externalDone(dd: *DragDrop, effect: transfer.Effect) void {
        dd.externalEnd(.{ .effect = effect });
    }

    /// The system's drag (`External`) ended so: with an effect, given up
    /// or let go over no target, where on the screen.
    pub fn externalEnd(dd: *DragDrop, how: ExternalEnd) void {
        dd.handed_off = false;
        dd.lift = true;
        dd.incoming = null;
        dd.incoming_drop = false;
        // Dropped back in this window: the frame did it already.
        const a = if (dd.active) |*x| x else return;
        const canceled = how.effect == .none;
        dd.finished = .{ .source = a.source, .result = .{ .effect = how.effect, .canceled = canceled, .escaped = canceled and how.escaped, .screen = how.screen } };
        a.data.deinit();
        dd.active = null;
        dd.handed_off = false;
        dd.lift = true;
    }

    /// A drag from another app entered the window at `at` (points), with
    /// `data` (owned by the drag now: its formats at least; bytes may come
    /// at the drop) and the effects its source allows. The platform calls
    /// these four, outside frames, and draws a frame after each.
    pub fn externalEnter(dd: *DragDrop, data: transfer.Data, effects: transfer.Effects, at: Point) void {
        var owned = data;
        dd.incoming = at;
        dd.incoming_drop = false;
        // One of this window's own drags, back from the system's.
        if (dd.active != null) return owned.deinit();
        dd.active = .{ .source = 0, .data = owned, .effects = effects, .grab = .{}, .size = .{}, .count = 1 };
    }

    /// The drag moved to `at`: what a drop there would do (none where no
    /// target takes it), from the last frame's targets.
    pub fn externalOver(dd: *DragDrop, at: Point, suggested_effect: ?transfer.Effect) transfer.Effect {
        dd.incoming = at;
        return dd.effectAt(at, suggested_effect);
    }

    /// The drag left the window, or was given up.
    pub fn externalLeave(dd: *DragDrop) void {
        dd.incoming = null;
        dd.incoming_drop = false;
        dd.over = 0;
        if (dd.active) |*a| if (a.source == 0) {
            a.data.deinit();
            dd.active = null;
        };
    }

    /// The drag was let go at `at`: the target there gets it in the next
    /// frame, with `data` when given (the bytes, read now), else what
    /// entered. Returns the effect (none: nothing takes it).
    pub fn externalDrop(dd: *DragDrop, at: Point, data: ?transfer.Data, suggested_effect: ?transfer.Effect) transfer.Effect {
        var given = data;
        const a = if (dd.active) |*x| x else {
            if (given) |*d| d.deinit();
            return .none;
        };
        if (given) |*d| {
            if (a.source == 0) {
                a.data.deinit();
                a.data = d.*;
            } else d.deinit();
        }
        const effect = dd.effectAt(at, suggested_effect);
        if (effect == .none) {
            dd.externalLeave();
            return .none;
        }
        dd.incoming = at;
        dd.incoming_drop = true;
        dd.drop_effect = effect;
        return effect;
    }

    /// The innermost of `list` taking the data at `at` (registered after
    /// the boxes it is in).
    fn targetAt(list: []const Target, at: Point) ?Target {
        var i = list.len;
        while (i > 0) {
            i -= 1;
            const t = list[i];
            if (t.accepts and t.rect.contains(at)) return t;
        }
        return null;
    }

    fn effectAt(dd: *const DragDrop, at: Point, suggested_effect: ?transfer.Effect) transfer.Effect {
        const a = if (dd.active) |*x| x else return .none;
        // Between frames: the last frame's targets.
        const t = targetAt(dd.next_targets.items, at) orelse return .none;
        return transfer.negotiate(a.effects, t.effects, suggested_effect);
    }

    /// Whether data drags in this window.
    pub fn dragging(dd: *const DragDrop) bool {
        return dd.active != null;
    }

    /// Gives up the drag, as Escape does.
    pub fn cancel(dd: *DragDrop) void {
        dd.end(true);
    }

    /// Ends the drag without a drop: given up (`escaped`), or let go over
    /// no target.
    fn end(dd: *DragDrop, escaped: bool) void {
        dd.incoming = null;
        dd.incoming_drop = false;
        if (dd.active) |*a| {
            if (a.source != 0) dd.finished = .{ .source = a.source, .result = .{ .effect = .none, .canceled = true, .escaped = escaped } };
            a.data.deinit();
            dd.active = null;
        }
        dd.over = 0;
    }

    /// Once a frame, before any of its boxes: the last frame's targets,
    /// Escape, and the drop when the pointer let go.
    fn sync(dd: *DragDrop, c: *Context) void {
        if (dd.synced == c.frame) return;
        dd.synced = c.frame;
        if (dd.gpa == null) dd.gpa = c.gpa;
        const gpa = dd.gpa.?;
        if (dd.dropped) |*d| {
            d.data.deinit();
            dd.dropped = null;
        }
        std.mem.swap(std.ArrayList(Target), &dd.targets, &dd.next_targets);
        dd.next_targets.clearRetainingCapacity();
        _ = gpa;
        if (dd.lift) {
            dd.lift = false;
            c.input.down = false;
            c.active = 0;
        }
        if (dd.press != null and !c.input.down and !c.input.pressed) dd.press = null;
        const a = if (dd.active) |*x| x else return;
        // Every move draws a frame: the copy follows the pointer.
        c.wants_moves = true;
        const incoming = dd.incoming;
        const at = incoming orelse c.input.mouse;
        const escape = c.input.key == .escape or (if (c.input.shortcut) |s| s.key == ctx_mod.Shortcut.escape else false);
        if (escape and incoming == null) {
            c.input.key = null;
            c.input.shortcut = null;
            c.shortcut_taken = true;
            dd.cancel();
            c.changed = true;
            return;
        }
        if (dd.handed_off and incoming == null) return;
        // Out of the window with the button down: the system's drag.
        if (dd.external) |ext| if (incoming == null and c.input.down and !inside(c)) {
            dd.handed_off = true;
            dd.over = 0;
            ext.start(ext.ctx, dd);
            return;
        };
        const t = targetAt(dd.targets.items, at);
        dd.over = if (t) |x| x.id else 0;
        if (if (incoming != null) !dd.incoming_drop else c.input.down) return;
        // Let go: over a target, it drops there (with the effect the
        // system's drag agreed, for one from another app).
        if (t) |x| {
            const effect = if (incoming != null) dd.drop_effect else transfer.negotiate(a.effects, x.effects, suggested(c));
            if (effect != .none) {
                dd.dropped = .{ .target = x.id, .data = a.data, .effect = effect, .at = at };
                if (a.source != 0) dd.finished = .{ .source = a.source, .result = .{ .effect = effect, .canceled = false } };
                dd.active = null;
                dd.over = 0;
                dd.incoming = null;
                dd.incoming_drop = false;
                c.changed = true;
                return;
            }
        }
        // Let go over no target: canceled, not given up.
        dd.end(false);
        c.changed = true;
    }

    /// The effect the modifier keys ask for: Option copies and Command
    /// moves on macOS, Ctrl copies and Shift moves elsewhere.
    fn suggested(c: *Context) ?transfer.Effect {
        const i = c.input;
        if (@import("builtin").os.tag == .macos) return if (i.cmd) .move else null;
        if (i.ctrl) return .copy;
        if (i.shift) return .move;
        return null;
    }

    /// Opens a box whose data drags: add its children, then `end`.
    pub fn draggable(dd: *DragDrop, c: *Context, style: types.Style, opts: DraggableOptions) Draggable {
        dd.sync(c);
        const index = c.open(style, null);
        const it = c.interact(index, .{});
        const id = it.id;
        var d: Draggable = .{ .dd = dd, .c = c, .index = index, .id = id, .opts = opts };
        // A press inside (on its buttons too) may become a drag.
        if (it.hovered and c.input.pressed and dd.active == null) {
            const r = it.rect orelse types.Rect{};
            dd.press = .{ .id = id, .at = c.input.mouse, .origin = .{ .x = r.x, .y = r.y }, .size = .{ .w = r.w, .h = r.h } };
        }
        if (dd.press) |p| if (p.id == id and c.input.down and dd.active == null) {
            const dx = c.input.mouse.x - p.at.x;
            const dy = c.input.mouse.y - p.at.y;
            if (dx * dx + dy * dy >= threshold * threshold) d.starting = true;
        };
        d.dragging = if (dd.active) |a| a.source == id else false;
        if (d.dragging and opts.dim) c.node(index).style.opacity *= 0.4;
        return d;
    }

    /// Makes the box `index` take drops of `opts.formats`. Read `over`
    /// to show it would take the data, and `dropped` in the frame it drops.
    pub fn target(dd: *DragDrop, c: *Context, index: u32, opts: TargetOptions) TargetResult {
        dd.sync(c);
        const id = c.node(index).id;
        const accepts = !opts.disabled and if (dd.active) |*a| takes(&a.data, opts.formats) and transfer.negotiate(a.effects, opts.effects, null) != .none else false;
        const entry: Target = .{ .id = id, .rect = c.rects.get(id) orelse .{}, .accepts = accepts, .effects = opts.effects };
        // A frame built again replaces its target.
        for (dd.next_targets.items) |*t| {
            if (t.id == id) {
                t.* = entry;
                break;
            }
        } else dd.next_targets.append(c.gpa, entry) catch {};
        var result: TargetResult = .{ .over = dd.active != null and dd.over == id and accepts };
        if (dd.dropped) |*d| if (d.target == id and !d.taken) {
            d.taken = true;
            result.dropped = .{ .data = &d.data, .effect = d.effect, .at = d.at };
        };
        return result;
    }

    /// The copy of the dragged box that follows the pointer, over
    /// everything: call it last in the view.
    pub fn preview(dd: *DragDrop, c: *Context) void {
        dd.sync(c);
        const a = if (dd.active) |*x| x else return;
        // The system draws drags from other apps, and this one's outside.
        if (dd.handed_off or a.source == 0) return;
        const pos: Point = .{ .x = c.input.mouse.x - a.grab.x, .y = c.input.mouse.y - a.grab.y };
        const ov = c.openOverlay(.{ .absolute = true, .offset = pos, .opacity = 0.75 }, "myzig.drag");
        defer c.end();
        if (dd.preview_frame == c.frame and dd.preview_hi > dd.preview_lo) {
            copySubtree(c, ov, dd.preview_lo, dd.preview_hi, a.size);
        } else {
            // The source isn't built (scrolled away): a plain box of its size.
            _ = c.leaf(.{ .width = .{ .px = a.size.w }, .height = .{ .px = a.size.h }, .radius = 6, .background = c.theme.surface, .border = c.theme.accent }, .none, "box");
        }
        if (a.count > 1) {
            const label = c.print("{d}", .{a.count});
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = a.grab.x + 10, .y = a.grab.y + 6 }, .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 }, .radius = 9, .background = c.theme.accent }, .{ .text = .{ .str = label, .style = .{ .size = 11, .weight = .bold }, .color = c.theme.accent_text } }, "count");
        }
    }
};

fn inside(c: *Context) bool {
    const m = c.input.mouse;
    return m.x >= 0 and m.y >= 0 and m.x < c.size.w and m.y < c.size.h;
}

/// Whether data offering some format takes one of `formats` (any if empty).
fn takes(data: *const transfer.Data, formats: []const []const u8) bool {
    if (formats.len == 0) return data.items.len > 0;
    for (formats) |f| if (data.has(f)) return true;
    return false;
}

/// Adds copies of nodes [lo, hi) (a box and what it holds) under `parent`,
/// the first fixed to `size`: not interactive, with ids of their own.
fn copySubtree(c: *Context, parent: u32, lo: u32, hi: u32, size: types.Size) void {
    const none = ctx_mod.none;
    const base: u32 = @intCast(c.nodes.items.len);
    const shift = struct {
        fn f(x: u32, l: u32, h: u32, b: u32) u32 {
            return if (x != none and x >= l and x < h) x - l + b else none;
        }
    }.f;
    var i = lo;
    while (i < hi) : (i += 1) {
        var n = c.nodes.items[i];
        n.id = std.hash.Wyhash.hash(n.id, "myzig.drag.copy");
        n.interactive = false;
        n.parent = shift(n.parent, lo, hi, base);
        n.first_child = shift(n.first_child, lo, hi, base);
        n.last_child = shift(n.last_child, lo, hi, base);
        n.next = shift(n.next, lo, hi, base);
        if (i == lo) {
            n.parent = parent;
            n.next = none;
            n.style.width = .{ .px = size.w };
            n.style.height = .{ .px = size.h };
            n.style.absolute = false;
            n.style.offset = .{};
            n.style.grow = 0;
            n.style.opacity = 1;
        }
        c.nodes.append(c.gpa, n) catch return;
    }
    const p = c.node(parent);
    if (p.last_child == none) p.first_child = base else c.node(p.last_child).next = base;
    p.last_child = base;
    p.child_count += 1;
}

pub const TargetResult = struct {
    /// Data that drags is over it, and it would take it.
    over: bool = false,
    dropped: ?Drop = null,
};

/// A box whose data drags, open until `end`.
pub const Draggable = struct {
    dd: *DragDrop,
    c: *Context,
    index: u32,
    id: u64,
    opts: DraggableOptions,
    /// The pointer pressing it moved far enough: `offer` the data to drag
    /// it (or don't, and the press goes on as a press).
    starting: bool = false,
    /// Its data drags (dim it where it was).
    dragging: bool = false,

    /// Starts the drag with `data`, which the drag then owns.
    pub fn offer(d: *Draggable, data: transfer.Data) void {
        const dd = d.dd;
        var owned = data;
        if (!d.starting or dd.active != null) return owned.deinit();
        const p = dd.press.?;
        dd.active = .{ .source = d.id, .data = owned, .effects = d.opts.effects, .grab = .{ .x = p.at.x - p.origin.x, .y = p.at.y - p.origin.y }, .size = p.size, .count = d.opts.count };
        dd.press = null;
        d.starting = false;
        d.dragging = true;
        // The press is no click: nothing inside it takes the release.
        d.c.active = 0;
        d.c.changed = true;
        if (d.opts.dim) d.c.node(d.index).style.opacity *= 0.4;
    }

    pub const Result = struct {
        dragging: bool,
        /// Its last drag ended (dropped, or given up), in this frame.
        finished: ?Finished = null,
    };

    pub fn end(d: *Draggable) Result {
        const dd = d.dd;
        const c = d.c;
        if (d.dragging) {
            dd.preview_lo = d.index;
            dd.preview_hi = @intCast(c.nodes.items.len);
            dd.preview_frame = c.frame;
        }
        c.end();
        var r: Result = .{ .dragging = d.dragging };
        if (dd.finished) |f| if (f.source == d.id) {
            r.finished = f.result;
            dd.finished = null;
        };
        return r;
    }
};
