//! Global shortcuts on Wayland, through the desktop portal's
//! GlobalShortcuts: Wayland lets apps grab no keys, the desktop binds
//! the shortcuts apps ask for, in a session. A session binds its
//! shortcuts once, so a change replaces it with a new session binding
//! them all; a change while one is on its way waits for it (`stale`).
//! Desktops remember the keys the user picks by each shortcut's id (the
//! XDG trigger of its accelerator), and may ask the user to confirm.
//! Requests answer with Response signals, which the app's bus hands to
//! `signal`, as it does the Activated signals of presses.
const std = @import("std");
const dbus = @import("dbus.zig");
const Bus = @import("dbus_conn.zig").Bus;
const msgs = @import("dbus_portal.zig");
const hotkeys = @import("../hotkeys.zig");
const menu_types = @import("../menu_types.zig");

const Entry = struct { hotkey: u32, id: []u8, description: []u8 };
const Kind = enum { create, bind };

pub const Pressed = *const fn (ctx: *anyopaque, hotkey: u32, activation_token: ?[]const u8) void;

pub const Portal = struct {
    gpa: std.mem.Allocator,
    bus: *Bus,
    /// The portal's bus name (a mock's in tests).
    destination: []const u8 = msgs.name,
    /// The app's id, its desktop entry's name without ".desktop".
    app_id: []const u8,
    pressed: Pressed,
    ctx: *anyopaque,
    entries: std.ArrayList(Entry) = .empty,
    /// The session the shortcuts are bound in (owned).
    session: ?[]u8 = null,
    /// The request on its way (owned path) and what it is.
    pending: ?struct { path: []u8, kind: Kind } = null,
    /// The shortcuts changed while a request was on its way.
    stale: bool = false,
    tokens: u32 = 0,
    listening: bool = false,

    /// The portal for `bus`, when the desktop has GlobalShortcuts; null else.
    pub fn open(gpa: std.mem.Allocator, bus: *Bus, app_id: []const u8, ctx: *anyopaque, pressed: Pressed, destination: []const u8) ?*Portal {
        // The app's id first: portals know it only for apps the desktop
        // launched (and sandboxed ones), and take it before any other call.
        if (msgs.register(gpa, app_id)) |body| {
            defer gpa.free(body);
            if (bus.call(.{ .destination = destination, .path = msgs.path, .interface = msgs.registry, .member = "Register" }, msgs.register_signature, body)) |r| {
                var reply = r;
                reply.deinit(gpa);
            } else |_| {}
        } else |_| {}
        if (version(gpa, bus, destination) == 0) return null;
        const p = gpa.create(Portal) catch return null;
        p.* = .{ .gpa = gpa, .bus = bus, .destination = destination, .app_id = app_id, .ctx = ctx, .pressed = pressed };
        return p;
    }

    pub fn close(p: *Portal) void {
        p.closeSession();
        if (p.pending) |q| p.gpa.free(q.path);
        for (p.entries.items) |e| p.free(e);
        p.entries.deinit(p.gpa);
        p.gpa.destroy(p);
    }

    fn free(p: *Portal, e: Entry) void {
        p.gpa.free(e.id);
        p.gpa.free(e.description);
    }

    /// Binds `a` for shortcut `hotkey` (with the others, in a new session).
    pub fn add(p: *Portal, hotkey: u32, a: hotkeys.Accelerator, keys: []const u8) hotkeys.Error!void {
        var kb: [16]u8 = undefined;
        const sym = hotkeys.x11Key(a.key, &kb) orelse return error.UnsupportedKey;
        var tb: [64]u8 = undefined;
        const ctrl = hotkeys.has(a, menu_types.mod_ctrl) or hotkeys.has(a, menu_types.mod_cmd);
        const t = msgs.trigger(&tb, ctrl, hotkeys.has(a, menu_types.mod_alt), hotkeys.has(a, menu_types.mod_shift), std.mem.span(sym)) catch return error.UnsupportedKey;
        var db: [64]u8 = undefined;
        const desc = menu_types.acceleratorText(&db, keys);
        const id = try p.gpa.dupe(u8, t);
        errdefer p.gpa.free(id);
        const d = try p.gpa.dupe(u8, if (desc.len > 0) desc else t);
        errdefer p.gpa.free(d);
        try p.entries.append(p.gpa, .{ .hotkey = hotkey, .id = id, .description = d });
        p.sync() catch {
            p.free(p.entries.pop().?);
            return error.Unavailable;
        };
    }

    pub fn remove(p: *Portal, hotkey: u32) void {
        for (p.entries.items, 0..) |e, i| if (e.hotkey == hotkey) {
            p.free(p.entries.orderedRemove(i));
            p.sync() catch {};
            return;
        };
    }

    fn nextToken(p: *Portal, buf: []u8) []const u8 {
        p.tokens += 1;
        return std.fmt.bufPrint(buf, "myzig{d}", .{p.tokens}) catch unreachable;
    }

    fn listen(p: *Portal) void {
        if (p.listening) return;
        p.listening = true;
        p.bus.addMatch("type='signal',interface='org.freedesktop.portal.Request',member='Response'") catch {};
        p.bus.addMatch("type='signal',interface='org.freedesktop.portal.GlobalShortcuts',member='Activated'") catch {};
    }

    fn closeSession(p: *Portal) void {
        const s = p.session orelse return;
        _ = p.bus.send(.{ .destination = p.destination, .path = s, .interface = msgs.session, .member = "Close" }, "", "", true) catch {};
        p.gpa.free(s);
        p.session = null;
    }

    fn list(p: *Portal, a: std.mem.Allocator) ![]msgs.Shortcut {
        const out = try a.alloc(msgs.Shortcut, p.entries.items.len);
        for (p.entries.items, out) |e, *s| s.* = .{ .id = e.id, .description = e.description, .trigger = e.id };
        return out;
    }

    /// Calls a request method; what it answers comes as a Response.
    fn request(p: *Portal, member: []const u8, signature: []const u8, body: []const u8, kind: Kind, handle_token: []const u8) !void {
        p.listen();
        var pb: [256]u8 = undefined;
        // Pending before the call: the Response may come before its reply.
        p.pending = .{ .path = try p.gpa.dupe(u8, try msgs.requestPath(&pb, p.bus.uniqueName(), handle_token)), .kind = kind };
        var reply = p.bus.call(.{ .destination = p.destination, .path = msgs.path, .interface = msgs.shortcuts, .member = member }, signature, body) catch |e| {
            if (p.pending) |q| p.gpa.free(q.path);
            p.pending = null;
            return e;
        };
        defer reply.deinit(p.gpa);
        var m = reply.message() catch return;
        // Portals before 0.9 pick the path themselves.
        const got = m.body.string() catch return;
        if (p.pending) |*q| if (q.kind == kind and !std.mem.eql(u8, q.path, got) and got.len > 0) {
            const owned = p.gpa.dupe(u8, got) catch return;
            p.gpa.free(q.path);
            q.path = owned;
        };
    }

    /// Replaces the session with one binding the shortcuts.
    fn sync(p: *Portal) !void {
        if (p.pending != null) {
            p.stale = true;
            return;
        }
        p.closeSession();
        if (p.entries.items.len == 0) return;
        var arena = std.heap.ArenaAllocator.init(p.gpa);
        defer arena.deinit();
        var hb: [32]u8 = undefined;
        const handle = p.nextToken(&hb);
        var sb: [80]u8 = undefined;
        const session_token = msgs.safeToken(&sb, "myzig_", p.app_id);
        const body = try msgs.createSession(arena.allocator(), handle, session_token, try p.list(arena.allocator()));
        try p.request("CreateSession", msgs.create_session_signature, body, .create, handle);
        p.stale = false;
    }

    fn bindAll(p: *Portal) !void {
        var arena = std.heap.ArenaAllocator.init(p.gpa);
        defer arena.deinit();
        var hb: [32]u8 = undefined;
        const handle = p.nextToken(&hb);
        const body = try msgs.bindShortcuts(arena.allocator(), p.session.?, try p.list(arena.allocator()), "", handle);
        try p.request("BindShortcuts", msgs.bind_shortcuts_signature, body, .bind, handle);
    }

    /// A signal of the bus: true when it was the portal's for these shortcuts.
    pub fn signal(p: *Portal, m: *dbus.Message) bool {
        if (msgs.parseActivated(m)) |a| {
            const s = p.session orelse return true;
            if (!std.mem.eql(u8, a.session_handle, s)) return true;
            for (p.entries.items) |e| if (std.mem.eql(u8, e.id, a.id)) {
                p.pressed(p.ctx, e.hotkey, a.activation_token);
                break;
            };
            return true;
        }
        const q = p.pending orelse return false;
        if (!std.mem.eql(u8, m.header.path, q.path)) return false;
        const r = msgs.parseResponse(m) orelse return false;
        p.gpa.free(q.path);
        p.pending = null;
        switch (q.kind) {
            .create => {
                const handle = r.session_handle orelse "";
                if (r.code != 0 or handle.len == 0) {
                    std.log.warn("myzig: global shortcuts: the desktop portal made no session (response {d})", .{r.code});
                    return true;
                }
                p.session = p.gpa.dupe(u8, handle) catch return true;
                if (p.entries.items.len == 0) {
                    p.closeSession();
                    return true;
                }
                p.bindAll() catch |e| std.log.warn("myzig: global shortcuts: {s}", .{@errorName(e)});
            },
            .bind => {
                if (r.code != 0) std.log.warn("myzig: global shortcuts: the desktop bound none (response {d})", .{r.code});
                if (p.stale) p.sync() catch |e| std.log.warn("myzig: global shortcuts: {s}", .{@errorName(e)});
            },
        }
        return true;
    }
};

/// The version of GlobalShortcuts the desktop offers, 0 for none.
pub fn version(gpa: std.mem.Allocator, bus: *Bus, destination: []const u8) u32 {
    const body = msgs.versionQuery(gpa, msgs.shortcuts) catch return 0;
    defer gpa.free(body);
    var reply = bus.call(.{ .destination = destination, .path = msgs.path, .interface = "org.freedesktop.DBus.Properties", .member = "Get" }, "ss", body) catch return 0;
    defer reply.deinit(gpa);
    var m = reply.message() catch return 0;
    return msgs.parseVersion(&m) orelse 0;
}
