//! The tree assistive technology sees of the last frame: built from the
//! laid out boxes and the widgets' descriptions (`access.zig`), owned
//! (the frame's memory goes with the next frame), and compared with the
//! previous tree to tell the platform what changed.
const std = @import("std");
const types = @import("types.zig");
const access = @import("access.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const Role = access.Role;

pub const none = std.math.maxInt(u32);

pub const Node = struct {
    id: u64,
    /// Index of the parent in `Tree.nodes`; `none` at the top, where
    /// siblings link too (the first node is the first at the top).
    parent: u32 = none,
    first_child: u32 = none,
    next_sibling: u32 = none,
    child_count: u32 = 0,
    /// Its place among its parent's children.
    index_in_parent: u32 = 0,
    role: Role,
    name: []const u8 = "",
    value: []const u8 = "",
    description: []const u8 = "",
    placeholder: []const u8 = "",
    /// Its box in points from the window's content's top left, clipped to
    /// what shows (its whole box when out of view).
    rect: types.Rect = .{},
    states: access.States = .{},
    actions: access.Actions = .{},
    range: access.Range = .{},
    level: u32 = 0,
    pos_in_set: u32 = 0,
    set_size: u32 = 0,
    /// A text field's selection, in bytes of `value`, and its caret (one
    /// of its ends).
    sel_start: u32 = 0,
    sel_end: u32 = 0,
    caret: u32 = 0,
    /// Where its text is drawn (`access.TextRow`), in the window's points.
    rows: []const access.TextRow = &.{},
};

pub const Tree = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node) = .empty,
    /// The index of each id's node.
    index: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// The element with the keyboard focus; 0 for none.
    focus: u64 = 0,
    /// The nodes at the top (the window's children).
    top_count: u32 = 0,
    /// Texts to read once (`Context.announce`), of this frame.
    announcements: []const []const u8 = &.{},

    pub fn init(gpa: std.mem.Allocator) Tree {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(t: *Tree) void {
        t.nodes.deinit(t.gpa);
        t.index.deinit(t.gpa);
        t.arena.deinit();
    }

    pub fn find(t: *const Tree, id: u64) ?*const Node {
        const i = t.index.get(id) orelse return null;
        return &t.nodes.items[i];
    }

    /// The first node of `role` named `name` (`.auto`: any role).
    pub fn byName(t: *const Tree, role: Role, name: []const u8) ?*const Node {
        for (t.nodes.items) |*n| if ((role == .auto or n.role == role) and std.mem.eql(u8, n.name, name)) return n;
        return null;
    }

    pub fn count(t: *const Tree, role: Role) usize {
        var k: usize = 0;
        for (t.nodes.items) |n| k += @intFromBool(n.role == role);
        return k;
    }

    /// The first child of node `i`, or of the top for `none`.
    pub fn firstChild(t: *const Tree, i: u32) u32 {
        if (i != none) return t.nodes.items[i].first_child;
        return if (t.nodes.items.len > 0) 0 else none;
    }

    pub fn childCount(t: *const Tree, i: u32) u32 {
        return if (i != none) t.nodes.items[i].child_count else t.top_count;
    }

    /// The `k`th child of node `i` (`none`: the top); `none` past the last.
    pub fn childAt(t: *const Tree, i: u32, k: u32) u32 {
        var ch = t.firstChild(i);
        var n: u32 = 0;
        while (ch != none and n < k) : (n += 1) ch = t.nodes.items[ch].next_sibling;
        return ch;
    }

    pub fn lastChild(t: *const Tree, i: u32) u32 {
        const n = t.childCount(i);
        return if (n == 0) none else t.childAt(i, n - 1);
    }

    pub fn prevSibling(t: *const Tree, i: u32) u32 {
        const k = t.nodes.items[i].index_in_parent;
        return if (k == 0) none else t.childAt(t.nodes.items[i].parent, k - 1);
    }

    /// The topmost deepest node at `p` (points), as drawn.
    pub fn at(t: *const Tree, p: types.Point) ?*const Node {
        var i = t.nodes.items.len;
        while (i > 0) {
            i -= 1;
            const n = &t.nodes.items[i];
            if (!n.states.offscreen and n.rect.contains(p)) return n;
        }
        return null;
    }

    /// Describes the last frame of `c` (between frames, its boxes are laid
    /// out), and takes its announcements.
    pub fn build(t: *Tree, c: *Context) void {
        _ = t.arena.reset(.retain_capacity);
        t.nodes.clearRetainingCapacity();
        t.index.clearRetainingCapacity();
        t.focus = 0;
        t.top_count = 0;
        t.announcements = &.{};
        if (c.nodes.items.len == 0) return;
        var focusable: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer focusable.deinit(c.gpa);
        for (c.focus_order.items) |id| focusable.put(c.gpa, id, {}) catch {};
        var b: Builder = .{ .t = t, .c = c, .a = t.arena.allocator(), .focusable = &focusable };

        // What is behind a modal dialog is inert: the overlay it is in,
        // and the overlays opened after it, alone.
        if (b.modalOverlay()) |first| {
            for (c.overlays.items[first..]) |o| b.element(o, none, types.Rect.infinite, false);
        } else b.element(0, none, types.Rect.infinite, false);

        // The focus, on what is described as having it for the box.
        if (c.focus != 0) {
            var f = c.focus;
            if (c.access.described.get(f)) |d| if (d.active_descendant != 0 and t.index.contains(d.active_descendant)) {
                f = d.active_descendant;
            };
            if (t.index.get(f)) |i| {
                t.focus = f;
                t.nodes.items[i].states.focused = true;
            }
        }
        const taken = c.access.takeAnnouncements(c.gpa) catch &.{};
        defer {
            for (taken) |s| c.gpa.free(s);
            c.gpa.free(taken);
        }
        const out: [][]const u8 = b.a.alloc([]const u8, taken.len) catch &.{};
        for (out, taken) |*o, s| o.* = b.a.dupe(u8, s) catch "";
        t.announcements = out;
    }
};

const Builder = struct {
    t: *Tree,
    c: *Context,
    a: std.mem.Allocator,
    focusable: *const std.AutoHashMapUnmanaged(u64, void),
    /// The last node at the top, which the next one follows.
    last_top: u32 = none,

    fn modalOverlay(b: *Builder) ?usize {
        const c = b.c;
        var found: ?usize = null;
        for (c.overlays.items, 0..) |o, k| if (b.hasModal(o)) {
            found = k;
        };
        return found;
    }

    fn hasModal(b: *Builder, index: u32) bool {
        const n = b.c.nodes.items[index];
        if (b.c.access.described.get(n.id)) |d| if (d.modal) return true;
        var ch = n.first_child;
        while (ch != ctx_mod.none) : (ch = b.c.nodes.items[ch].next) if (b.hasModal(ch)) return true;
        return false;
    }

    fn hidden(n: *const ctx_mod.Node) bool {
        return n.style.opacity <= 0.01;
    }

    /// The role of a box, from its description or what it is; `.none`
    /// for boxes assistive technology does not see.
    fn roleOf(b: *Builder, n: *const ctx_mod.Node, d: ?access.Description) Role {
        if (d) |v| if (v.role != .auto) return v.role;
        const labeled = if (d) |v| v.label != null else false;
        switch (n.content) {
            .text => |tx| return if (tx.str.len > 0) .text else .none,
            .icon, .image => return if (labeled) .image else .none,
            .none => {},
        }
        const focusable = b.focusable.contains(n.id);
        if (n.interactive and focusable) return .button;
        if (n.style.scroll) return .scroll_area;
        if (labeled or focusable) return .group;
        return .none;
    }

    fn element(b: *Builder, index: u32, parent_in: u32, clip: types.Rect, scrolled: bool) void {
        const c = b.c;
        const n = &c.nodes.items[index];
        if (hidden(n)) return;
        const d = c.access.described.get(n.id);
        const role = b.roleOf(n, d);
        var parent = parent_in;
        if (role != .none) {
            parent = b.add(n, d orelse .{}, role, parent_in, clip, scrolled);
            if (role.leaf()) return;
        }
        var inner = clip;
        if (n.style.scroll or n.style.clip) inner = inner.intersect(n.rect);
        const in_scroll = scrolled or n.style.scroll;
        var ch = n.first_child;
        // Overlays are the root's last children: they show above all.
        while (ch != ctx_mod.none) : (ch = c.nodes.items[ch].next) b.element(ch, parent, inner, in_scroll);
    }

    fn add(b: *Builder, n: *const ctx_mod.Node, d: access.Description, role: Role, parent: u32, clip: types.Rect, scrolled: bool) u32 {
        const t = b.t;
        const vis = n.rect.intersect(clip);
        var node: Node = .{ .id = n.id, .parent = parent, .role = role, .rect = if (vis.w > 0 and vis.h > 0) vis else n.rect };
        node.states.offscreen = vis.w <= 0 or vis.h <= 0;
        node.name = if (d.label) |l| b.str(l) else switch (n.content) {
            .text => |tx| b.str(tx.str),
            else => if (role.namedByContent()) b.innerText(n) else "",
        };
        node.value = if (d.value) |v| b.str(v) else "";
        node.description = b.str(d.description);
        node.placeholder = b.str(d.placeholder);
        node.level = d.level;
        node.pos_in_set = d.pos_in_set;
        node.set_size = d.set_size;
        if (d.selection) |s| {
            node.sel_start = @min(s[0], s[1]);
            node.sel_end = @max(s[0], s[1]);
            node.caret = s[1];
        }
        node.rows = b.rows(d.rows, n.rect);
        var st = &node.states;
        st.disabled = d.disabled;
        if (d.checked) |ch| {
            st.checked = ch == .on;
            st.mixed = ch == .mixed;
        }
        if (d.selected) |v| {
            st.selected = v;
            st.selectable = true;
        }
        if (d.expanded) |v| st.expanded = v;
        st.expandable = d.expandable or d.expanded != null;
        st.multiline = d.multiline;
        st.password = d.password;
        st.read_only = d.read_only;
        st.selectable = st.selectable or d.selectable;
        st.multiselectable = d.multiselectable;
        st.invalid = d.invalid;
        st.vertical = d.vertical;
        st.has_popup = d.has_popup or role == .popup_button or role == .menu_button or role == .combo_box;
        st.modal = d.modal;
        if (d.range) |r| node.range = r;
        if (!d.disabled) {
            var ac = &node.actions;
            st.focusable = b.focusable.contains(n.id);
            ac.focus = st.focusable;
            ac.press = n.interactive;
            if (role == .slider or role == .stepper) {
                ac.increment = true;
                ac.decrement = true;
            }
            ac.set_value = (role == .text_field or role == .combo_box) and !d.read_only;
            ac.select_text = (role == .text_field or role == .combo_box) and !d.password and d.selection != null;
            ac.expand = st.expandable;
            ac.scroll_into_view = scrolled;
        }
        const i: u32 = @intCast(t.nodes.items.len);
        if (parent != none) {
            const p = &t.nodes.items[parent];
            node.index_in_parent = p.child_count;
            if (p.first_child == none) p.first_child = i else t.nodes.items[b.lastChild(parent)].next_sibling = i;
            p.child_count += 1;
        } else {
            if (b.last_top != none) t.nodes.items[b.last_top].next_sibling = i;
            b.last_top = i;
            node.index_in_parent = t.top_count;
            t.top_count += 1;
        }
        t.nodes.append(t.gpa, node) catch return parent;
        t.index.put(t.gpa, n.id, i) catch {};
        return i;
    }

    fn lastChild(b: *Builder, parent: u32) u32 {
        var ch = b.t.nodes.items[parent].first_child;
        while (b.t.nodes.items[ch].next_sibling != none) ch = b.t.nodes.items[ch].next_sibling;
        return ch;
    }

    /// A widget's rows, kept, moved from its box's top left (`box`) to the window's.
    fn rows(b: *Builder, from: []const access.TextRow, box: types.Rect) []const access.TextRow {
        if (from.len == 0) return &.{};
        const out = b.a.alloc(access.TextRow, from.len) catch return &.{};
        for (out, from) |*o, r| {
            o.* = r;
            o.rect.x += box.x;
            o.rect.y += box.y;
            o.xs = b.a.dupe(f32, r.xs) catch &.{};
        }
        return out;
    }

    fn str(b: *Builder, s: []const u8) []const u8 {
        if (s.len == 0) return "";
        return b.a.dupe(u8, s) catch "";
    }

    /// The texts inside a box, joined by spaces.
    fn innerText(b: *Builder, n: *const ctx_mod.Node) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        b.collect(n, &out, true);
        return out.items;
    }

    /// Controls inside (a toast's button) name themselves, not the box.
    fn collect(b: *Builder, n: *const ctx_mod.Node, out: *std.ArrayList(u8), top: bool) void {
        if (hidden(n) or (!top and n.interactive and b.focusable.contains(n.id))) return;
        if (b.c.access.described.get(n.id)) |d| if (d.label) |l| if (l.len > 0) {
            b.append(out, l);
            return;
        };
        switch (n.content) {
            .text => |tx| return b.append(out, tx.str),
            else => {},
        }
        var ch = n.first_child;
        while (ch != ctx_mod.none) : (ch = b.c.nodes.items[ch].next) b.collect(&b.c.nodes.items[ch], out, false);
    }

    fn append(b: *Builder, out: *std.ArrayList(u8), s: []const u8) void {
        if (s.len == 0) return;
        if (out.items.len > 0) out.append(b.a, ' ') catch return;
        out.appendSlice(b.a, s) catch {};
    }
};

/// What changed of an element between two trees, for the platform's events.
pub const Change = packed struct(u8) {
    name: bool = false,
    value: bool = false,
    states: bool = false,
    range: bool = false,
    selection: bool = false,
    /// Its children are others, or in another order.
    children: bool = false,
    rect: bool = false,
    _pad: u1 = 0,

    pub fn any(c: Change) bool {
        return @as(u8, @bitCast(c)) != 0;
    }
};

pub fn diff(old: *const Tree, o: *const Node, new: *const Tree, n: *const Node) Change {
    var ch: Change = .{};
    ch.name = !std.mem.eql(u8, o.name, n.name);
    ch.value = !std.mem.eql(u8, o.value, n.value);
    var os = o.states;
    var ns = n.states;
    // The focus is told on its own.
    os.focused = false;
    ns.focused = false;
    ch.states = @as(u32, @bitCast(os)) != @as(u32, @bitCast(ns));
    ch.range = !std.meta.eql(o.range, n.range);
    ch.selection = o.sel_start != n.sel_start or o.sel_end != n.sel_end or o.caret != n.caret;
    ch.rect = !std.meta.eql(o.rect, n.rect);
    if (o.child_count != n.child_count) ch.children = true else {
        var a = o.first_child;
        var b = n.first_child;
        while (a != none and b != none) : ({
            a = old.nodes.items[a].next_sibling;
            b = new.nodes.items[b].next_sibling;
        }) if (old.nodes.items[a].id != new.nodes.items[b].id) {
            ch.children = true;
            break;
        };
    }
    return ch;
}

/// Whether the top-level elements differ (the root's children).
pub fn topChanged(old: *const Tree, new: *const Tree) bool {
    var a: usize = 0;
    var b: usize = 0;
    while (true) {
        while (a < old.nodes.items.len and old.nodes.items[a].parent != none) a += 1;
        while (b < new.nodes.items.len and new.nodes.items[b].parent != none) b += 1;
        const ea = a >= old.nodes.items.len;
        const eb = b >= new.nodes.items.len;
        if (ea or eb) return ea != eb;
        if (old.nodes.items[a].id != new.nodes.items[b].id) return true;
        a += 1;
        b += 1;
    }
}
