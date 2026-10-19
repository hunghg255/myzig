//! Native UI for AT-SPI (Orca), over D-Bus in Zig alone: once the
//! session's accessibility bus says assistive technology is on (or
//! MYZIG_A11Y=1), the app connects to it, embeds its application in the
//! registry's desktop, answers calls on its windows and their elements
//! (`atspi_serve.zig`) from the main loop, and after each frame tells
//! listeners what changed: the focus, states, names, values, children,
//! and announcements. Without assistive technology nothing is built, and
//! the session's status is watched (`atspi_status.zig`, `wait`) so that
//! Orca started after the app finds it.
const std = @import("std");
const c = std.c;
const dbus = @import("dbus.zig");
const conn = @import("dbus_conn.zig");
const proto = @import("atspi_proto.zig");
const serve = @import("atspi_serve.zig");
const text_iface = @import("atspi_text.zig");
const status = @import("atspi_status.zig");
const fdwatch = @import("fdwatch.zig");
const access = @import("../ui/access.zig");
const types = @import("../ui/types.zig");
const tree_mod = @import("../ui/access_tree.zig");
const Context = @import("../ui/context.zig").Context;
const Tree = tree_mod.Tree;
const I = proto.Interface;

/// What the server needs of a surface.
pub const Host = struct {
    ptr: *anyopaque,
    ctx: *Context,
    /// Asks for a frame (after an action was handed to the context).
    request_frame: *const fn (ptr: *anyopaque) void,
    /// The content's top left on the screen, in points, if known.
    origin: ?*const fn (ptr: *anyopaque) types.Point = null,
};

/// A surface's part.
pub const Link = struct {
    server: *Server,
    k: u32,
    host: Host,
    tree: Tree,
    prev: Tree,
    win: serve.Window,

    fn perform(p: *anyopaque, id: u64, role: access.Role, action: access.Action) void {
        const l: *Link = @ptrCast(@alignCast(p));
        access.perform(l.host.ctx, id, role, action);
        l.host.request_frame(l.host.ptr);
    }

    /// After a frame: the tree, and the events of what changed.
    pub fn update(l: *Link) void {
        std.mem.swap(Tree, &l.tree, &l.prev);
        l.tree.build(l.host.ctx);
        if (l.host.origin) |f| l.win.origin = f(l.host.ptr);
        l.server.events(l) catch {};
    }

    pub fn detach(l: *Link) void {
        const s = l.server;
        s.links.items[l.k] = null;
        l.host.ctx.access.enabled = false;
        l.tree.deinit();
        l.prev.deinit();
        s.gpa.destroy(l);
        s.refresh();
    }
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    bus: *conn.Bus,
    name: []u8,
    parent_bus: []u8 = &.{},
    parent_path: []u8 = &.{},
    links: std.ArrayList(?*Link) = .empty,
    windows: std.ArrayList(?*serve.Window) = .empty,

    /// Connects to the accessibility bus at `address` and embeds the
    /// application in the registry's desktop.
    pub fn connect(gpa: std.mem.Allocator, address: []const u8) !*Server {
        const bus = try conn.Bus.open(gpa, address);
        errdefer bus.close();
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{ .gpa = gpa, .bus = bus, .name = &.{} };
        // Our unique name: the destination of a reply to us.
        var id = try bus.call(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "GetId" }, "", "");
        defer id.deinit(gpa);
        s.name = try gpa.dupe(u8, (try id.message()).header.destination);
        var e: dbus.Encoder = .{ .gpa = gpa };
        defer e.deinit();
        try proto.reference(&e, s.name, proto.root_path);
        var reply = bus.call(.{ .destination = "org.a11y.atspi.Registry", .path = proto.root_path, .interface = "org.a11y.atspi.Socket", .member = "Embed" }, "(so)", e.buf.items) catch |err| {
            gpa.free(s.name);
            return err;
        };
        defer reply.deinit(gpa);
        var m = try reply.message();
        try m.body.alignTo(8);
        s.parent_bus = try gpa.dupe(u8, try m.body.string());
        s.parent_path = try gpa.dupe(u8, try m.body.string());
        return s;
    }

    pub fn close(s: *Server) void {
        s.bus.close();
        s.gpa.free(s.name);
        s.gpa.free(s.parent_bus);
        s.gpa.free(s.parent_path);
        s.links.deinit(s.gpa);
        s.windows.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    /// A surface's link; its context then describes its frames.
    pub fn attach(s: *Server, host: Host) !*Link {
        const l = try s.gpa.create(Link);
        errdefer s.gpa.destroy(l);
        var k: u32 = @intCast(s.links.items.len);
        for (s.links.items, 0..) |x, i| if (x == null) {
            k = @intCast(i);
            break;
        };
        l.* = .{ .server = s, .k = k, .host = host, .tree = .init(s.gpa), .prev = .init(s.gpa), .win = undefined };
        l.win = .{ .tree = &l.tree, .ptr = l, .perform = Link.perform };
        if (k == s.links.items.len) try s.links.append(s.gpa, l) else s.links.items[k] = l;
        s.refresh();
        host.ctx.access.enabled = true;
        host.request_frame(host.ptr);
        return l;
    }

    /// The windows as the model sees them (after links come and go).
    fn refresh(s: *Server) void {
        s.windows.clearRetainingCapacity();
        for (s.links.items) |l| s.windows.append(s.gpa, if (l) |x| &x.win else null) catch {};
    }

    pub fn model(s: *Server) serve.Model {
        return .{ .bus_name = s.name, .parent_bus = s.parent_bus, .parent_path = if (s.parent_path.len > 0) s.parent_path else proto.null_path, .windows = s.windows.items };
    }

    fn send(s: *Server, h: dbus.Header, body: []const u8) !void {
        var hh = h;
        s.bus.serial += 1;
        hh.serial = s.bus.serial;
        const msg = try dbus.message(s.gpa, hh, body);
        defer s.gpa.free(msg);
        var sent: usize = 0;
        while (sent < msg.len) {
            const n = c.write(s.bus.fd, msg[sent..].ptr, msg.len - sent);
            if (n <= 0) return error.Write;
            sent += @intCast(n);
        }
    }

    /// Answers one method call.
    pub fn answer(s: *Server, m: *dbus.Message) !void {
        var e: dbus.Encoder = .{ .gpa = s.gpa };
        defer e.deinit();
        const mod = s.model();
        const a = serve.handle(&mod, m, &e) catch serve.Answer{ .error_name = "org.freedesktop.DBus.Error.InvalidArgs" };
        if (m.header.flags & 1 != 0) return; // no reply expected
        if (a.error_name) |name| {
            return s.send(.{ .type = .@"error", .serial = 0, .reply_serial = m.header.serial, .destination = m.header.sender, .error_name = name }, "");
        }
        try s.send(.{ .type = .method_return, .serial = 0, .reply_serial = m.header.serial, .destination = m.header.sender, .signature = a.signature }, e.buf.items);
    }

    /// The connection has bytes (the main loop's watch): answers the
    /// calls among them.
    pub fn dispatch(s: *Server) void {
        var buf: [8192]u8 = undefined;
        const n = c.read(s.bus.fd, &buf, buf.len);
        if (n <= 0) return;
        s.bus.pending.appendSlice(s.gpa, buf[0..@intCast(n)]) catch return;
        while (dbus.messageLen(s.bus.pending.items)) |len| {
            if (s.bus.pending.items.len < len) break;
            const bytes = s.gpa.dupe(u8, s.bus.pending.items[0..len]) catch return;
            defer s.gpa.free(bytes);
            s.bus.pending.replaceRangeAssumeCapacity(0, len, &.{});
            var m = dbus.parse(bytes) catch continue;
            if (m.header.type == .method_call) s.answer(&m) catch {};
        }
    }

    fn signal(s: *Server, path: []const u8, iface: []const u8, member: []const u8, detail: []const u8, d1: i32, d2: i32, v: proto.Variant) !void {
        var e: dbus.Encoder = .{ .gpa = s.gpa };
        defer e.deinit();
        try proto.eventBody(&e, detail, d1, d2, v);
        try s.send(.{ .type = .signal, .serial = 0, .path = path, .interface = iface, .member = member, .signature = "siiva{sv}" }, e.buf.items);
    }

    /// Tells listeners what changed from the link's previous tree.
    fn events(s: *Server, l: *Link) !void {
        const t = &l.tree;
        const p = &l.prev;
        var buf: [96]u8 = undefined;
        var cbuf: [96]u8 = undefined;
        for (t.nodes.items) |*n| {
            const o = p.find(n.id) orelse continue;
            const ch = tree_mod.diff(p, o, t, n);
            if (!ch.any()) continue;
            const path = proto.nodePath(&buf, l.k, n.id);
            if (ch.name) try s.signal(path, I.event_object, "PropertyChange", "accessible-name", 0, 0, .{ .s = n.name });
            if (ch.range and n.role.ranged()) try s.signal(path, I.event_object, "PropertyChange", "accessible-value", 0, 0, .{ .d = n.range.now });
            if (ch.value and !n.states.password) {
                // What was replaced, as Orca echoes it.
                const x = text_iface.edit(o.value, n.value);
                const cp = std.unicode.utf8CountCodepoints;
                if (x.removed.len > 0) try s.signal(path, I.event_object, "TextChanged", "delete", @intCast(x.at), @intCast(cp(x.removed) catch 0), .{ .s = x.removed });
                if (x.inserted.len > 0) try s.signal(path, I.event_object, "TextChanged", "insert", @intCast(x.at), @intCast(cp(x.inserted) catch 0), .{ .s = x.inserted });
            }
            if (ch.selection and text_iface.hasText(n)) {
                try s.signal(path, I.event_object, "TextCaretMoved", "", @intCast(text_iface.charOf(n.value, n.caret)), 0, .{ .i = 0 });
                if (o.sel_start != o.sel_end or n.sel_start != n.sel_end) try s.signal(path, I.event_object, "TextSelectionChanged", "", 0, 0, .{ .i = 0 });
            }
            if (ch.states) {
                const a = proto.statesOf(o);
                const b = proto.statesOf(n);
                inline for (.{ .{ proto.State.checked, "checked" }, .{ proto.State.expanded, "expanded" }, .{ proto.State.selected, "selected" }, .{ proto.State.enabled, "enabled" }, .{ proto.State.sensitive, "sensitive" }, .{ proto.State.indeterminate, "indeterminate" } }) |st| {
                    if (a.has(st[0]) != b.has(st[0])) try s.signal(path, I.event_object, "StateChanged", st[1], @intFromBool(b.has(st[0])), 0, .{ .i = 0 });
                }
            }
            if (ch.children) {
                // Who left, then who came, by their place.
                var k: u32 = 0;
                var at = o.first_child;
                while (at != tree_mod.none) : ({
                    at = p.nodes.items[at].next_sibling;
                    k += 1;
                }) if (t.find(p.nodes.items[at].id) == null)
                    try s.signal(path, I.event_object, "ChildrenChanged", "remove", @intCast(k), 0, .{ .ref = .{ .bus = s.name, .path = proto.nodePath(&cbuf, l.k, p.nodes.items[at].id) } });
                k = 0;
                at = n.first_child;
                while (at != tree_mod.none) : ({
                    at = t.nodes.items[at].next_sibling;
                    k += 1;
                }) if (p.find(t.nodes.items[at].id) == null)
                    try s.signal(path, I.event_object, "ChildrenChanged", "add", @intCast(k), 0, .{ .ref = .{ .bus = s.name, .path = proto.nodePath(&cbuf, l.k, t.nodes.items[at].id) } });
            }
        }
        if (tree_mod.topChanged(p, t)) try s.signal(proto.windowPath(&buf, l.k), I.event_object, "ChildrenChanged", "add", 0, 0, .{ .ref = .{ .bus = s.name, .path = proto.null_path } });
        if (t.focus != p.focus) {
            if (p.focus != 0 and t.find(p.focus) != null) try s.signal(proto.nodePath(&buf, l.k, p.focus), I.event_object, "StateChanged", "focused", 0, 0, .{ .i = 0 });
            if (t.focus != 0) {
                const path = proto.nodePath(&buf, l.k, t.focus);
                try s.signal(path, I.event_object, "StateChanged", "focused", 1, 0, .{ .i = 0 });
                try s.signal(path, I.event_focus, "Focus", "", 0, 0, .{ .i = 0 });
            }
        }
        // Announcements, politely (ATK's announcement signal, read by Orca).
        for (t.announcements) |text| try s.signal(proto.windowPath(&buf, l.k), I.event_object, "Announcement", "", 1, 0, .{ .s = text });
    }
};

var server: ?*Server = null;
var tried = false;

/// The accessibility bus's address, from the environment or the session bus.
pub fn busAddress(gpa: std.mem.Allocator) !?[]u8 {
    if (c.getenv("AT_SPI_BUS_ADDRESS")) |a| return try gpa.dupe(u8, std.mem.span(a));
    const session = try conn.Bus.session(gpa);
    defer session.close();
    const forced = if (c.getenv("MYZIG_A11Y")) |v| v[0] == '1' else false;
    // On while the desktop's accessibility, or its screen reader, is.
    if (!forced and !try status.get(session, "IsEnabled") and !try status.get(session, "ScreenReaderEnabled")) return null;
    var r = try session.call(.{ .destination = "org.a11y.Bus", .path = "/org/a11y/bus", .interface = "org.a11y.Bus", .member = "GetAddress" }, "", "");
    defer r.deinit(gpa);
    var m = try r.message();
    return try gpa.dupe(u8, try m.body.string());
}

/// The app's server, connected the first time a surface asks; null
/// where no assistive technology is on (asked again once it turns on).
pub fn get(gpa: std.mem.Allocator) ?*Server {
    if (server) |s| return s;
    if (tried) return null;
    tried = true;
    const address = (busAddress(gpa) catch return null) orelse return null;
    defer gpa.free(address);
    const s = Server.connect(gpa, address) catch return null;
    _ = fdwatch.readable(s.bus.fd, s, onReadable) catch {
        s.close();
        return null;
    };
    server = s;
    return s;
}

fn onReadable(ctx: ?*anyopaque) callconv(.c) void {
    const s: *Server = @ptrCast(@alignCast(ctx));
    s.dispatch();
}

/// A surface waiting for assistive technology.
const Waiter = struct { ptr: *anyopaque, wake: *const fn (ptr: *anyopaque) void };

var waiters: std.ArrayList(Waiter) = .empty;
var waiters_gpa: std.mem.Allocator = undefined;
var watch: ?*status.Watch = null;
var watch_source: ?fdwatch.Watch = null;

/// After `get` found assistive technology off: calls `wake(ptr)` once it
/// turns on (Orca starts), from the main loop, when the surface tries
/// again (it asks for a frame, whose `get` connects). Until then the
/// session bus's status is watched; nothing polls.
pub fn wait(gpa: std.mem.Allocator, ptr: *anyopaque, wake: *const fn (ptr: *anyopaque) void) void {
    if (server != null) return wake(ptr);
    for (waiters.items) |*x| if (x.ptr == ptr) {
        x.wake = wake;
        return;
    };
    waiters_gpa = gpa;
    waiters.append(gpa, .{ .ptr = ptr, .wake = wake }) catch return;
    if (watch != null) return;
    const w = status.Watch.open(gpa) catch return;
    watch_source = fdwatch.readable(w.bus.fd, w, onStatus) catch {
        w.close();
        return;
    };
    watch = w;
}

/// The surface goes: it waits no more.
pub fn unwait(ptr: *anyopaque) void {
    for (waiters.items, 0..) |x, i| if (x.ptr == ptr) {
        _ = waiters.swapRemove(i);
        if (waiters.items.len == 0) {
            waiters.deinit(waiters_gpa);
            waiters = .empty;
        }
        return;
    };
}

fn onStatus(ctx: ?*anyopaque) callconv(.c) void {
    const w: *status.Watch = @ptrCast(@alignCast(ctx));
    switch (w.dispatch()) {
        .none => {},
        .turned_on => turnedOn(),
        .closed => {
            if (watch_source) |s| s.cancel();
            watch_source = null;
            w.close();
            watch = null;
        },
    }
}

/// Assistive technology turned on: `get` asks again, and the waiting
/// surfaces try (each once).
pub fn turnedOn() void {
    tried = false;
    var list = waiters;
    waiters = .empty;
    defer list.deinit(waiters_gpa);
    for (list.items) |x| x.wake(x.ptr);
}
