//! The context a view builds its UI with, every frame: the tree of boxes,
//! their ids, the input, what the pointer is over, and animated values.
//!
//! Views are immediate mode: a function of the app's state, run again on
//! every event. Interactions are answered from the previous frame's layout,
//! and a frame whose interactions changed state is built again before it is
//! drawn, so the screen never lags the state.
const std = @import("std");
const types = @import("types.zig");
const Theme = @import("theme.zig").Theme;
const text = @import("text.zig");

const node_mod = @import("node.zig");
pub const none = node_mod.none;
pub const Content = node_mod.Content;
pub const Node = node_mod.Node;

const input = @import("input.zig");
pub const Key = input.Key;
pub const Shortcut = input.Shortcut;
pub const TextOp = input.TextOp;
pub const Command = input.Command;
pub const FocusedText = input.FocusedText;
pub const pasteText = input.pasteText;
pub const Clipboard = input.Clipboard;
pub const EditState = input.EditState;
pub const Input = input.Input;

pub const Interaction = struct {
    id: u64,
    rect: ?types.Rect,
    /// The pointer is over it, or over a box inside it (its button, its
    /// link), as CSS's :hover: a row that shows its buttons on hover keeps
    /// them while the pointer goes to them.
    hovered: bool,
    /// Held down: pressed on this box and not yet released.
    pressed: bool,
    clicked: bool,
    /// The second click of a double click (it is a click too): opens what
    /// a click selects, as a row's inspector.
    double_clicked: bool = false,
    focused: bool,
};

const Hit = @import("hit.zig").Hit;
const events = @import("context_events.zig");
const access = @import("access.zig");

pub const Cursor = enum { arrow, hand, text, resize_left_right, resize_up_down };

/// What the last frame cost, for profiling and the hill-climb benchmarks.
pub const FrameStats = struct {
    build_ms: f64 = 0,
    layout_ms: f64 = 0,
    paint_ms: f64 = 0,
    /// Builds of the view: more than one when interactions changed state.
    passes: u32 = 0,
    nodes: usize = 0,
    instances: usize = 0,
};
const Anim = struct { value: f32, frame: u64 };

pub const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    text: *text.TextSystem,
    theme: Theme = .light,
    size: types.Size = .{},
    scale: f32 = 2,
    /// Seconds since the previous frame, for animations.
    dt: f32 = 1.0 / 60.0,
    /// Seconds since the first frame: the clock of animations a view drives itself.
    time: f64 = 0,
    frame: u64 = 0,
    input: Input = .{},

    nodes: std.ArrayList(Node) = .empty,
    stack: std.ArrayList(u32) = .empty,
    /// Boxes over everything else (`openOverlay`), in the order opened:
    /// the root's last children once the view is built.
    overlays: std.ArrayList(u32) = .empty,

    // Kept across frames.
    rects: std.AutoHashMapUnmanaged(u64, types.Rect) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    next_hits: std.ArrayList(Hit) = .empty,
    anims: std.AutoHashMapUnmanaged(u64, Anim) = .empty,
    /// What `motion.zig` animates: values, keyframes, timelines, transitions.
    motion: @import("motion_store.zig").Store = .{},
    scroll: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    edits: std.AutoHashMapUnmanaged(u64, EditState) = .empty,
    /// The largest scroll offset of each scrolling box in the last layout,
    /// for boxes that follow their end.
    scroll_max: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    /// Whether each of those follows its end, and the offset layout last
    /// left it at (a different one was moved by the reader or the app).
    scroll_follow: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    scroll_seen: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    /// How far such a box may follow this frame (`capScroll`), and the
    /// boxes whose offset the reader or the app moved in the last layout.
    scroll_cap: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    scroll_moved: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The glides of boxes following their end (`follow_glide.zig`).
    follow_glides: @import("follow_glide.zig").Glides = .empty,
    /// What of each canvas asking for it the last frame showed
    /// (`canvas_visible.zig`).
    canvas_visible: @import("canvas_visible.zig").Map = .empty,
    /// What painting calls for them, set by the first canvas asking: apps
    /// without one don't carry it.
    canvas_record: ?*const fn (c: *Context, id: u64, r: types.Rect, m: types.Affine, general: bool, outer: types.Rect, clip: types.Rect) void = null,
    /// The largest offset of every scrolling box in the last layout, and
    /// the notches of a mouse wheel gliding through them (`wheel.zig`).
    scroll_limit: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    wheel: @import("wheel.zig").Glides = .empty,
    /// The frame's layout pass while it runs (0 outside it), of
    /// `layout_seq`: boxes measured again at a width in one pass are as
    /// they were (`Node.measured_at`); and what layout keeps across
    /// frames (`layout_cache.zig`).
    layout_pass: u32 = 0,
    layout_seq: u32 = 0,
    layout_cache: @import("layout_cache.zig").Cache = .{},
    /// Text selected in `selectable` boxes, and this frame's Copy: asked
    /// for, and done by a text field of its own selection.
    selection: @import("selection.zig").Selection = .{},
    copy_requested: bool = false,
    /// The soonest a view asked for another frame (`frameIn`), seconds.
    frame_in: ?f32 = null,
    copy_done: bool = false,
    /// Set when the view took the offered shortcut: it goes no further.
    shortcut_taken: bool = false,
    /// Set by the view, kept across frames: shortcuts go to the view
    /// before the menu bar's accelerators (a terminal that has the
    /// keyboard keeps Ctrl+L and Ctrl+W for its shell). On Windows and Linux.
    keys_first: bool = false,
    /// Set by the focused text field each frame.
    focused_text: ?FocusedText = null,
    clipboard: Clipboard = .{},
    /// The key of the next box, for ids that survive reordering.
    next_key: ?[]const u8 = null,
    next_key_int: ?u64 = null,
    /// The topmost interactive box under the pointer: it takes presses.
    hot: u64 = 0,
    /// The hot box and the boxes it is in, innermost first: all hovered.
    hot_path: std.ArrayList(u64) = .empty,
    active: u64 = 0,
    focus: u64 = 0,
    /// The boxes that take the focus, in the order built: where Tab goes.
    focus_order: std.ArrayList(u64) = .empty,
    /// The focus came from the keyboard (Tab), not a press: focused
    /// controls draw their ring.
    focus_visible: bool = false,

    /// How far down from the top of a window with a hidden title bar
    /// its empty space moves the window, as a title bar does: a view with
    /// a toolbar there makes it the toolbar's height.
    title_bar_height: f32 = 28,
    /// Set by a view that follows the pointer inside one box (a graph's
    /// column under it, a crosshair): every move draws a frame while it is
    /// set, not only moves onto another box. Cleared each frame.
    wants_moves: bool = false,
    /// Set by a view that takes the wheel where nothing scrolls (a
    /// terminal's full-screen program): it then comes as `input.scroll`.
    wants_wheel: bool = false,
    /// Set by a view that follows keys going down and up (a game): their
    /// edges then come as `input.key_down` and `input.key_up`, each in a
    /// frame of its own. Cleared each frame.
    wants_keys: bool = false,
    /// Set by widgets whose interaction changed the app's state.
    changed: bool = false,
    /// Set while an animated value has not reached its target.
    animating: bool = false,
    stats: FrameStats = .{},
    /// Set when the pointer is over something clickable.
    cursor_hand: bool = false,
    cursor_text: bool = false,
    /// A cursor a view asks for, over what widgets set (dividers).
    cursor: ?Cursor = null,
    /// What assistive technology reads of the frame (`access.zig`).
    access: access.State = .{},
    /// The platform's window showing the frames (null in a Tester), which
    /// native views placed in it reach (`webview.zig`).
    host: ?*anyopaque = null,
    /// The web views of the frames, made by the first one built.
    web: ?*@import("webview.zig").List = null,

    pub fn init(gpa: std.mem.Allocator, ts: *text.TextSystem) Context {
        return .{ .gpa = gpa, .arena = .init(gpa), .text = ts };
    }

    pub fn deinit(c: *Context) void {
        c.arena.deinit();
        c.nodes.deinit(c.gpa);
        c.stack.deinit(c.gpa);
        c.overlays.deinit(c.gpa);
        c.rects.deinit(c.gpa);
        c.hits.deinit(c.gpa);
        c.next_hits.deinit(c.gpa);
        c.hot_path.deinit(c.gpa);
        c.focus_order.deinit(c.gpa);
        c.anims.deinit(c.gpa);
        c.motion.deinit(c.gpa);
        c.scroll.deinit(c.gpa);
        c.edits.deinit(c.gpa);
        c.scroll_max.deinit(c.gpa);
        c.scroll_follow.deinit(c.gpa);
        c.scroll_seen.deinit(c.gpa);
        c.scroll_cap.deinit(c.gpa);
        c.scroll_moved.deinit(c.gpa);
        c.follow_glides.deinit(c.gpa);
        c.canvas_visible.deinit(c.gpa);
        c.scroll_limit.deinit(c.gpa);
        c.wheel.deinit(c.gpa);
        c.layout_cache.deinit(c.gpa);
        c.selection.deinit(c.gpa);
        c.access.deinit(c.gpa);
        if (c.web) |l| l.destroy(c.gpa);
    }

    /// Memory that lives until the end of the frame, for formatted text.
    /// Scales every text by `z` (1 is as written): an app's zoom, ⌘= ⌘-.
    pub fn setZoom(c: *Context, z: f32) void {
        c.text.setZoom(std.math.clamp(z, 0.5, 3));
    }

    pub fn alloc(c: *Context) std.mem.Allocator {
        return c.arena.allocator();
    }

    pub fn print(c: *Context, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(c.alloc(), fmt, args) catch "…";
    }

    /// Starts building a frame: the root fills the window.
    pub fn begin(c: *Context) void {
        _ = c.arena.reset(.retain_capacity);
        c.nodes.clearRetainingCapacity();
        c.stack.clearRetainingCapacity();
        c.overlays.clearRetainingCapacity();
        c.focus_order.clearRetainingCapacity();
        c.next_hits.clearRetainingCapacity();
        c.cursor_hand = false;
        c.cursor_text = false;
        c.cursor = null;
        c.focused_text = null;
        c.wants_wheel = false;
        c.wants_keys = false;
        c.wants_moves = false;
        c.scroll_cap.clearRetainingCapacity();
        c.access.begin();
        if (c.web) |l| l.built.clearRetainingCapacity();
        c.nodes.append(c.gpa, .{
            .id = 0x9e3779b97f4a7c15,
            .style = .{ .width = .{ .px = c.size.w }, .height = .{ .px = c.size.h }, .background = c.theme.background },
        }) catch @panic("OOM");
        c.stack.append(c.gpa, 0) catch @panic("OOM");
    }

    /// A frame whose interactions changed state is built again: the edges
    /// of the input (the press, the key) are consumed by the first build.
    pub fn rebuild(c: *Context) void {
        c.input.clearEdges();
        c.changed = false;
        c.begin();
    }

    pub fn finish(c: *Context) void {
        c.input.clearEdges();
        c.changed = false;
        if (!c.input.down) c.active = 0;
        // What assistive technology asked for was done, or is gone.
        c.access.press = 0;
        c.access.expand = 0;
        c.frame += 1;
        // Forget animations of widgets gone for a while.
        if (c.frame % 120 == 0) {
            var stale: [64]u64 = undefined;
            var n: usize = 0;
            var it = c.anims.iterator();
            while (it.next()) |e| {
                if (n == stale.len) break;
                if (c.frame - e.value_ptr.frame > 120) {
                    stale[n] = e.key_ptr.*;
                    n += 1;
                }
            }
            for (stale[0..n]) |k| _ = c.anims.remove(k);
        }
    }

    fn childId(c: *Context, key: ?[]const u8) u64 {
        const parent = &c.nodes.items[c.stack.items[c.stack.items.len - 1]];
        var h = std.hash.Wyhash.init(parent.id);
        const k = key orelse c.next_key;
        c.next_key = null;
        if (k) |v| {
            h.update(v);
        } else if (c.next_key_int) |n| {
            h.update("#");
            h.update(std.mem.asBytes(&n));
        } else h.update(std.mem.asBytes(&parent.child_count));
        c.next_key_int = null;
        return h.final();
    }

    fn add(c: *Context, new_node: Node) u32 {
        const parent_index = c.stack.items[c.stack.items.len - 1];
        const index: u32 = @intCast(c.nodes.items.len);
        var n = new_node;
        n.parent = parent_index;
        c.nodes.append(c.gpa, n) catch @panic("OOM");
        const parent = &c.nodes.items[parent_index];
        if (parent.last_child == none) parent.first_child = index else c.nodes.items[parent.last_child].next = index;
        parent.last_child = index;
        parent.child_count += 1;
        return index;
    }

    /// Opens a box; its children follow until `end`.
    pub fn open(c: *Context, style: types.Style, key: ?[]const u8) u32 {
        const index = c.add(.{ .id = c.childId(key), .style = style });
        c.stack.append(c.gpa, index) catch @panic("OOM");
        return index;
    }

    /// Opens a box over everything else in the window, wherever the view
    /// is (a popover, a menu, a dialog, a toast): drawn after every other
    /// box, it takes the pointer first. Its children follow until `end`.
    /// It is placed in the window: give it `absolute` and an `offset`, or
    /// make it fill the window.
    pub fn openOverlay(c: *Context, style: types.Style, key: ?[]const u8) u32 {
        const index: u32 = @intCast(c.nodes.items.len);
        // Its id comes from where it is opened and its key (or its place
        // among the frame's overlays), not from its siblings: the boxes
        // after it keep their ids whether it shows or not.
        const parent = &c.nodes.items[c.stack.items[c.stack.items.len - 1]];
        var h = std.hash.Wyhash.init(parent.id);
        h.update("overlay");
        if (key orelse c.next_key) |k| {
            h.update(k);
        } else if (c.next_key_int) |n| {
            h.update("#");
            h.update(std.mem.asBytes(&n));
        } else h.update(std.mem.asBytes(&c.overlays.items.len));
        c.next_key = null;
        c.next_key_int = null;
        c.nodes.append(c.gpa, .{ .id = h.final(), .style = style, .parent = 0 }) catch @panic("OOM");
        c.overlays.append(c.gpa, index) catch @panic("OOM");
        c.stack.append(c.gpa, index) catch @panic("OOM");
        return index;
    }

    /// Makes the overlays the root's last children (before layout).
    pub fn linkOverlays(c: *Context) void {
        const root = &c.nodes.items[0];
        for (c.overlays.items) |index| {
            if (root.last_child == none) root.first_child = index else c.nodes.items[root.last_child].next = index;
            root.last_child = index;
            root.child_count += 1;
        }
    }

    /// Whether this frame's press was outside the interactive box `id`
    /// and what it holds: what closes a popover or a menu.
    pub fn pressedOutside(c: *Context, id: u64) bool {
        if (!c.input.pressed) return false;
        return c.hot != id and std.mem.indexOfScalar(u64, c.hot_path.items, id) == null;
    }

    pub fn end(c: *Context) void {
        std.debug.assert(c.stack.items.len > 1);
        _ = c.stack.pop();
    }

    /// Adds a box without children.
    pub fn leaf(c: *Context, style: types.Style, content: Content, key: ?[]const u8) u32 {
        return c.add(.{ .id = c.childId(key), .style = style, .content = content });
    }

    pub fn node(c: *Context, index: u32) *Node {
        return &c.nodes.items[index];
    }

    /// Keys the next box by `k` as Zig compares it (`keyhash.zig`): a
    /// pointer keys the object it points to, whatever the object holds;
    /// a string its bytes; an integer, enum, struct or array its value,
    /// values of different types apart. Keys are unique among siblings.
    pub fn keyed(c: *Context, k: anytype) void {
        c.next_key = null;
        c.next_key_int = @import("keyhash.zig").of(k);
    }

    /// The id the next child of the open box will get.
    pub fn peekId(c: *Context, key: ?[]const u8) u64 {
        const saved = c.next_key;
        const saved_int = c.next_key_int;
        defer {
            c.next_key = saved;
            c.next_key_int = saved_int;
        }
        return c.childId(key);
    }

    /// How the pointer relates to the box `index`, from the last layout.
    pub fn interact(c: *Context, index: u32, opts: struct {
        /// Takes the focus when pressed, and with Tab.
        focusable: bool = false,
        /// Focused, Enter and Space click it (a button, a checkbox).
        keys: bool = false,
    }) Interaction {
        const n = c.node(index);
        n.interactive = true;
        const id = n.id;
        if (opts.focusable) c.focus_order.append(c.gpa, id) catch {};
        var by_key = false;
        if (opts.keys and c.focus == id) {
            // Enter and Space come as a key combination, a key or text.
            if (c.input.shortcut) |s| if ((s.key == ' ' or s.key == Shortcut.enter) and !s.cmd and !s.ctrl and !s.alt) {
                c.input.shortcut = null;
                c.shortcut_taken = true;
                by_key = true;
            };
            if (c.input.key == .enter or std.mem.eql(u8, c.input.chars, " ")) {
                c.input.key = null;
                c.input.chars = "";
                by_key = true;
            }
        }
        // Pressed by assistive technology, as a click.
        if (access.takePress(c, id)) by_key = true;
        const rect = c.rects.get(id);
        // Presses go to the topmost box alone; hover to the boxes it is in too.
        const top = c.hot == id;
        const hovered = top or std.mem.indexOfScalar(u64, c.hot_path.items, id) != null;
        if (top and c.input.pressed) {
            c.active = id;
            c.focus = if (opts.focusable) id else 0;
        }
        // A drag that selected text is not a click.
        const clicked = by_key or (c.input.released and c.active == id and top and !c.selection.moved);
        if (top) c.cursor_hand = true;
        return .{
            .id = id,
            .rect = rect,
            .hovered = hovered,
            .pressed = c.active == id and c.input.down,
            .clicked = clicked,
            .double_clicked = clicked and c.input.click_count >= 2,
            .focused = c.focus == id,
        };
    }

    /// Whether this event is the key combination `want`, which the view then
    /// takes: `if (c.shortcut(.{ .key = 'k', .cmd = true })) clear();`
    pub fn shortcut(c: *Context, want_in: Shortcut) bool {
        // Command shortcuts are Control ones where there is no Command key.
        const want = want_in.native();
        const s = (c.input.shortcut orelse return false).native();
        if (s.key != want.key or s.cmd != want.cmd or s.ctrl != want.ctrl or s.alt != want.alt or s.shift != want.shift) return false;
        c.shortcut_taken = true;
        c.changed = true;
        c.input.shortcut = null;
        return true;
    }

    /// Asks for another frame as soon as the display can show it: for
    /// views that animate from `time` every frame.
    pub fn animationFrame(c: *Context) void {
        c.animating = true;
    }

    /// Whether the pointer is over text that selects (as last painted):
    /// for the cursor when it moves without a frame being drawn.
    pub fn pointerOverText(c: *Context) bool {
        for (c.selection.lines.items) |r| if (r.contains(c.input.mouse)) return true;
        return c.selection.dragging;
    }

    /// Lets the box `id`, which follows its end, follow no further than
    /// `offset` this frame: what was just started stays at the top while
    /// what it prints grows below, to be read from its start.
    pub fn capScroll(c: *Context, id: u64, offset: f32) void {
        c.scroll_cap.put(c.gpa, id, @max(0, offset)) catch {};
    }

    /// Whether box `id`'s offset was moved (by the wheel, a drag, the app)
    /// in the last layout, rather than by following its end.
    pub fn scrollMoved(c: *Context, id: u64) bool {
        return c.scroll_moved.contains(id);
    }

    /// Asks for another frame within `seconds`: for what changes now and
    /// then (a spinner's step, a clock's second), without drawing every
    /// refresh in between.
    pub fn frameIn(c: *Context, seconds: f32) void {
        c.frame_in = if (c.frame_in) |f| @min(f, seconds) else seconds;
    }

    /// Moves `id`'s animated value toward `target`; returns the current value.
    pub fn animate(c: *Context, id: u64, salt: u32, target: f32, speed: f32) f32 {
        var h = std.hash.Wyhash.init(id);
        h.update(std.mem.asBytes(&salt));
        const key = h.final();
        const gop = c.anims.getOrPut(c.gpa, key) catch return target;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .value = target, .frame = c.frame };
            return target;
        }
        const a = gop.value_ptr;
        a.frame = c.frame;
        const k = 1 - @exp(-speed * @min(c.dt, 0.1));
        a.value += (target - a.value) * k;
        if (@abs(target - a.value) < 0.002) a.value = target else c.animating = true;
        return a.value;
    }

    // Accessibility (`access.zig`).
    pub const describe = access.describe;
    pub const describeOpen = access.describeOpen;
    pub const announce = access.announce;
    pub const expandRequest = access.expandRequest;

    // Called by the surface between frames (`context_events.zig`).
    pub const addHit = events.addHit;
    pub const commitHits = events.commitHits;
    pub const updateHot = events.updateHot;
    pub const applyScroll = events.applyScroll;
    pub const applyWheel = @import("wheel.zig").applyWheel;
    pub const pointerUp = events.pointerUp;
    pub const moveFocus = events.moveFocus;
    pub const tabPressed = events.tabPressed;
    pub const pointerDown = events.pointerDown;
};
