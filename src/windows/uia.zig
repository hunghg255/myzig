//! Native UI for UI Automation (Narrator, NVDA, JAWS): the window answers
//! WM_GETOBJECT with a fragment root whose fragments are the nodes of the
//! last frame's tree (`ui/access_tree.zig`), COM objects with the control
//! patterns of their roles (`uia_patterns.zig`). Frames are described only
//! once a client asked. After each frame, clients hear what changed: the
//! focus, names, states, values, children, and announcements, read from a
//! polite live region.
const std = @import("std");
const w = @import("win32.zig");
const api_mod = @import("uia_api.zig");
const patterns = @import("uia_patterns.zig");
const access = @import("../ui/access.zig");
const tree_mod = @import("../ui/access_tree.zig");
const Context = @import("../ui/context.zig").Context;
const types = @import("../ui/types.zig");

const Iface = api_mod.Iface;
const HRESULT = api_mod.HRESULT;
const GUID = api_mod.GUID;
const S_OK = api_mod.S_OK;
const Tree = tree_mod.Tree;
const Node = tree_mod.Node;
const none = tree_mod.none;

extern "user32" fn ClientToScreen(hwnd: w.HWND, p: *w.POINT) callconv(.winapi) i32;

/// The id of the live region holding announcements.
pub const announcer_id: u64 = 0xA11A_0000_0000_0001;

/// What the provider needs of its surface.
pub const Host = struct {
    ptr: *anyopaque,
    ctx: *Context,
    /// Does an action of assistive technology (`access.perform` on the
    /// context), then asks for a frame.
    perform: *const fn (ptr: *anyopaque, id: u64, role: access.Role, action: access.Action) void,
    /// Runs a frame now: the first client gets a tree at once.
    frame_now: *const fn (ptr: *anyopaque) void,
    /// Pixels per point.
    scale: *const fn (ptr: *anyopaque) f32,
};

/// A COM interface pointer of an element: COM passes its address as `this`.
pub const Ptr = extern struct {
    vtbl: *const anyopaque,
    owner: *Element,
};

pub const Element = struct {
    ifaces: [api_mod.iface_count]Ptr,
    refs: u32 = 1,
    gpa: std.mem.Allocator,
    /// Gone once `dead`: the element left the tree, or the window closed.
    owner: *Access,
    id: u64,
    is_root: bool,
    dead: bool = false,

    fn create(gpa: std.mem.Allocator, owner: *Access, id: u64, is_root: bool) !*Element {
        const e = try gpa.create(Element);
        e.* = .{ .ifaces = undefined, .gpa = gpa, .owner = owner, .id = id, .is_root = is_root };
        for (&e.ifaces, 0..) |*p, i| p.* = .{ .vtbl = vtables[i], .owner = e };
        return e;
    }

    pub fn of(this: *anyopaque) *Element {
        const p: *Ptr = @ptrCast(@alignCast(this));
        return p.owner;
    }

    pub fn ptr(e: *Element, i: Iface) *anyopaque {
        return @ptrCast(&e.ifaces[@backingInt(i)]);
    }

    pub fn addRef(e: *Element) u32 {
        e.refs += 1;
        return e.refs;
    }

    pub fn release(e: *Element) u32 {
        e.refs -= 1;
        const left = e.refs;
        if (left == 0) e.gpa.destroy(e);
        return left;
    }

    /// Its node in the current tree; null for the root and the gone.
    pub fn node(e: *Element) ?*const Node {
        if (e.dead or e.is_root) return null;
        return e.owner.tree.find(e.id);
    }

    fn index(e: *Element) u32 {
        if (e.dead or e.is_root) return none;
        return e.owner.tree.index.get(e.id) orelse none;
    }

    /// Lets go of an element that left the tree.
    fn disconnect(e: *Element) void {
        e.dead = true;
        if (api_mod.api()) |a| if (a.UiaDisconnectProvider) |f| {
            _ = f(e.ptr(.simple));
        };
        _ = e.release();
    }
};

pub const Access = struct {
    gpa: std.mem.Allocator,
    hwnd: w.HWND,
    host: Host,
    tree: Tree,
    prev: Tree,
    elements: std.AutoHashMapUnmanaged(u64, *Element) = .empty,
    root: *Element,
    /// The live region's text: the last announcements.
    announced: std.ArrayList(u8) = .empty,
    /// Building the tree a client asked for: no events then.
    quiet: bool = false,

    pub fn create(gpa: std.mem.Allocator, hwnd: w.HWND, host: Host) !*Access {
        const self = try gpa.create(Access);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .hwnd = hwnd, .host = host, .tree = .init(gpa), .prev = .init(gpa), .root = undefined };
        self.root = try Element.create(gpa, self, 0, true);
        host.ctx.access.enabled = true;
        return self;
    }

    /// Disconnects every element: the window goes.
    pub fn destroy(self: *Access) void {
        if (api_mod.api()) |a| _ = a.UiaReturnRawElementProvider(self.hwnd, 0, 0, null);
        var it = self.elements.valueIterator();
        while (it.next()) |e| e.*.disconnect();
        self.elements.deinit(self.gpa);
        self.root.disconnect();
        self.tree.deinit();
        self.prev.deinit();
        self.announced.deinit(self.gpa);
        self.host.ctx.access.enabled = false;
        self.gpa.destroy(self);
    }

    /// Answers WM_GETOBJECT: UI Automation's root, and object ids from 0
    /// up for its clients' events; MSAA's client object through UI
    /// Automation's proxy. Null leaves the message to the window.
    pub fn getObject(self: *Access, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
        const id: i32 = @truncate(lp);
        if (id < 0 and id != api_mod.UiaRootObjectId and id != api_mod.OBJID_CLIENT) return null;
        const a = api_mod.api() orelse return null;
        if (self.tree.nodes.items.len == 0) {
            self.quiet = true;
            self.host.frame_now(self.host.ptr);
            self.quiet = false;
        }
        return a.UiaReturnRawElementProvider(self.hwnd, wp, lp, self.root.ptr(.simple));
    }

    pub fn element(self: *Access, id: u64) ?*Element {
        return self.elements.get(id);
    }

    /// The element of node index `i`, the root for `none`.
    pub fn elementAt(self: *Access, i: u32) ?*Element {
        if (i == none) return self.root;
        return self.elements.get(self.tree.nodes.items[i].id);
    }

    /// The node's box in pixels of the screen.
    pub fn screenRect(self: *Access, n: *const Node) api_mod.UiaRect {
        return self.toScreen(n.rect);
    }

    /// A box in the window's points, in pixels of the screen.
    pub fn toScreen(self: *Access, r: types.Rect) api_mod.UiaRect {
        var origin: w.POINT = .{};
        _ = ClientToScreen(self.hwnd, &origin);
        const s: f64 = self.host.scale(self.host.ptr);
        return .{ .left = @as(f64, @floatFromInt(origin.x)) + r.x * s, .top = @as(f64, @floatFromInt(origin.y)) + r.y * s, .width = r.w * s, .height = r.h * s };
    }

    /// A point of the screen in the window's points.
    pub fn fromScreen(self: *Access, x: f64, y: f64) types.Point {
        var origin: w.POINT = .{};
        _ = ClientToScreen(self.hwnd, &origin);
        const s: f64 = self.host.scale(self.host.ptr);
        return .{ .x = @floatCast((x - @as(f64, @floatFromInt(origin.x))) / s), .y = @floatCast((y - @as(f64, @floatFromInt(origin.y))) / s) };
    }

    /// Describes the frame just drawn, and tells clients what changed.
    pub fn update(self: *Access) void {
        std.mem.swap(Tree, &self.tree, &self.prev);
        self.tree.build(self.host.ctx);
        self.addAnnouncer();
        // Elements for the nodes, the old ones kept.
        var old = self.elements;
        self.elements = .empty;
        for (self.tree.nodes.items) |n| {
            const e = if (old.fetchRemove(n.id)) |kv| kv.value else Element.create(self.gpa, self, n.id, false) catch continue;
            self.elements.put(self.gpa, n.id, e) catch {
                e.disconnect();
                continue;
            };
        }
        var gone = old.valueIterator();
        while (gone.next()) |e| e.*.disconnect();
        old.deinit(self.gpa);
        const a = api_mod.api() orelse return;
        if (self.quiet or a.UiaClientsAreListening() == 0) return;
        events(self, a);
    }

    fn addAnnouncer(self: *Access) void {
        const t = &self.tree;
        if (t.announcements.len > 0) {
            self.announced.clearRetainingCapacity();
            for (t.announcements, 0..) |s, i| {
                if (i > 0) self.announced.append(self.gpa, ' ') catch {};
                self.announced.appendSlice(self.gpa, s) catch {};
            }
        }
        if (self.announced.items.len == 0) return;
        const name = t.arena.allocator().dupe(u8, self.announced.items) catch return;
        const i: u32 = @intCast(t.nodes.items.len);
        const last = t.lastChild(none);
        t.nodes.append(t.gpa, .{ .id = announcer_id, .role = .text, .name = name, .index_in_parent = t.top_count, .rect = .{ .w = 1, .h = 1 } }) catch return;
        if (last != none) t.nodes.items[last].next_sibling = i;
        t.top_count += 1;
        t.index.put(t.gpa, announcer_id, i) catch {};
    }
};

/// Raises the events of what changed from `prev` to `tree`.
fn events(self: *Access, a: *const api_mod.Api) void {
    const t = &self.tree;
    const p = &self.prev;
    if (tree_mod.topChanged(p, t)) _ = a.UiaRaiseStructureChangedEvent(self.root.ptr(.simple), 2, null, 0);
    for (t.nodes.items) |*n| {
        const o = p.find(n.id) orelse continue;
        const e = self.elements.get(n.id) orelse continue;
        const ch = tree_mod.diff(p, o, t, n);
        if (!ch.any()) continue;
        if (ch.children) {
            const rid = runtimeId(n.id);
            _ = a.UiaRaiseStructureChangedEvent(e.ptr(.simple), 2, &rid, rid.len);
        }
        patterns.changed(e, a, o, n, ch);
    }
    if (t.focus != p.focus and t.focus != 0) if (self.elements.get(t.focus)) |e| {
        _ = a.UiaRaiseAutomationEvent(e.ptr(.simple), api_mod.Event.focus_changed);
        // Clients following the focus through WinEvents ask the window.
        a.NotifyWinEvent(api_mod.EVENT_OBJECT_FOCUS, self.hwnd, api_mod.OBJID_CLIENT, 0);
    };
    if (t.announcements.len > 0) if (self.elements.get(announcer_id)) |e| {
        _ = a.UiaRaiseAutomationEvent(e.ptr(.simple), api_mod.Event.live_region_changed);
    };
}

/// UiaAppendRuntimeId, then the node's id in two halves.
pub fn runtimeId(id: u64) [3]i32 {
    return .{ 3, @bitCast(@as(u32, @truncate(id))), @bitCast(@as(u32, @truncate(id >> 32))) };
}

// The interfaces' methods. `this` is a `Ptr`.

pub fn out(p: *?*anyopaque, e: ?*Element, i: Iface) HRESULT {
    const el = e orelse {
        p.* = null;
        return S_OK;
    };
    _ = el.addRef();
    p.* = el.ptr(i);
    return S_OK;
}

/// The element, unless it is gone.
pub fn live(this: *anyopaque) ?*Element {
    const e = Element.of(this);
    return if (e.dead) null else e;
}

fn queryInterface(this: *anyopaque, iid: *const GUID, p: *?*anyopaque) callconv(.winapi) HRESULT {
    const e = Element.of(this);
    if (iid.eql(api_mod.iid_unknown)) return out(p, e, .simple);
    for (api_mod.iids, 0..) |id, i| if (iid.eql(id) and patterns.supports(e, @fromBackingInt(@intCast(i)))) return out(p, e, @fromBackingInt(@intCast(i)));
    p.* = null;
    return api_mod.E_NOINTERFACE;
}

fn addRefImpl(this: *anyopaque) callconv(.winapi) u32 {
    return Element.of(this).addRef();
}

fn releaseImpl(this: *anyopaque) callconv(.winapi) u32 {
    return Element.of(this).release();
}

fn providerOptions(_: *anyopaque, p: *i32) callconv(.winapi) HRESULT {
    p.* = 0x1 | 0x20; // ServerSideProvider, UseComThreading
    return S_OK;
}

fn patternProvider(this: *anyopaque, pattern: i32, p: *?*anyopaque) callconv(.winapi) HRESULT {
    const e = live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    if (api_mod.patternIface(pattern)) |i| if (patterns.supports(e, i)) return out(p, e, i);
    return out(p, null, .simple);
}

fn propertyValue(this: *anyopaque, prop: i32, v: *api_mod.VARIANT) callconv(.winapi) HRESULT {
    v.* = .{};
    const e = live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    patterns.property(e, prop, v);
    return S_OK;
}

fn hostProvider(this: *anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    const e = Element.of(this);
    if (!e.is_root or e.dead) return S_OK;
    const a = api_mod.api() orelse return S_OK;
    return a.UiaHostProviderFromHwnd(e.owner.hwnd, p);
}

fn navigate(this: *anyopaque, direction: i32, p: *?*anyopaque) callconv(.winapi) HRESULT {
    const e = live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    const self = e.owner;
    const t = &self.tree;
    const i = if (e.is_root) none else e.index();
    if (!e.is_root and i == none) return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    const to: ?*Element = switch (direction) {
        0 => if (e.is_root) null else self.elementAt(t.nodes.items[i].parent), // Parent
        1 => if (e.is_root) null else (if (t.nodes.items[i].next_sibling == none) null else self.elementAt(t.nodes.items[i].next_sibling)),
        2 => if (e.is_root) null else (if (t.prevSibling(i) == none) null else self.elementAt(t.prevSibling(i))),
        3 => if (t.firstChild(i) == none) null else self.elementAt(t.firstChild(i)),
        4 => if (t.lastChild(i) == none) null else self.elementAt(t.lastChild(i)),
        else => return api_mod.E_INVALIDARG,
    };
    return out(p, to, .fragment);
}

fn getRuntimeId(this: *anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    const e = live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    // The root's is its window's.
    if (e.is_root) return S_OK;
    const id = runtimeId(e.id);
    p.* = api_mod.intArray(&id);
    return S_OK;
}

fn boundingRectangle(this: *anyopaque, r: *api_mod.UiaRect) callconv(.winapi) HRESULT {
    r.* = .{};
    const e = live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    if (e.node()) |n| r.* = e.owner.screenRect(n);
    return S_OK;
}

fn embeddedRoots(_: *anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    return S_OK;
}

fn setFocus(this: *anyopaque) callconv(.winapi) HRESULT {
    const e = live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    _ = w.SetFocus(e.owner.hwnd);
    const n = e.node() orelse return S_OK;
    if (!n.actions.focus) return S_OK;
    return act(e, .focus);
}

fn fragmentRoot(this: *anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    const e = live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    return out(p, e.owner.root, .root);
}

fn fromPoint(this: *anyopaque, x: f64, y: f64, p: *?*anyopaque) callconv(.winapi) HRESULT {
    p.* = null;
    const e = live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    const self = e.owner;
    const n = self.tree.at(self.fromScreen(x, y)) orelse return S_OK;
    return out(p, self.elements.get(n.id), .fragment);
}

fn getFocus(this: *anyopaque, p: *?*anyopaque) callconv(.winapi) HRESULT {
    const e = live(this) orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    const self = e.owner;
    return out(p, if (self.tree.focus != 0) self.elements.get(self.tree.focus) else null, .fragment);
}

/// Does an action on the element, unless it is gone or disabled.
pub fn act(e: *Element, action: access.Action) HRESULT {
    const n = e.node() orelse return api_mod.UIA_E_ELEMENTNOTAVAILABLE;
    if (n.states.disabled) return api_mod.UIA_E_ELEMENTNOTENABLED;
    e.owner.host.perform(e.owner.host.ptr, n.id, n.role, action);
    return S_OK;
}

pub const unknown_methods = [_]*const anyopaque{ @ptrCast(&queryInterface), @ptrCast(&addRefImpl), @ptrCast(&releaseImpl) };

const simple_vtbl = unknown_methods ++ [_]*const anyopaque{ @ptrCast(&providerOptions), @ptrCast(&patternProvider), @ptrCast(&propertyValue), @ptrCast(&hostProvider) };
const fragment_vtbl = unknown_methods ++ [_]*const anyopaque{ @ptrCast(&navigate), @ptrCast(&getRuntimeId), @ptrCast(&boundingRectangle), @ptrCast(&embeddedRoots), @ptrCast(&setFocus), @ptrCast(&fragmentRoot) };
const root_vtbl = unknown_methods ++ [_]*const anyopaque{ @ptrCast(&fromPoint), @ptrCast(&getFocus) };

const vtables = blk: {
    var v: [api_mod.iface_count]*const anyopaque = undefined;
    v[@backingInt(Iface.simple)] = &simple_vtbl;
    v[@backingInt(Iface.fragment)] = &fragment_vtbl;
    v[@backingInt(Iface.root)] = &root_vtbl;
    for (patterns.vtables) |pv| v[@backingInt(pv[0])] = pv[1];
    break :blk v;
};
