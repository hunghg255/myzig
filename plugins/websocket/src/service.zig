//! The service pages call (`js/websocket.js` wraps it in a browser-like
//! `WebSocket`): each connection is two tasks on the app's `Io`, one that
//! connects and reads, one that writes what the page sends, in order. What
//! happens comes back to the page as `myzig-websocket` events, through the
//! main thread; a window that closed drops its connections when their next
//! event arrives.
//!
//!     var ws_service: websocket.Service = try .init(gpa, app.io, .{});
//!     defer ws_service.deinit();
//!     try app.bind(&ws_service);
//!     try app.registerEvent(websocket.PartEvent);
const std = @import("std");
const myzig = @import("myzig");
const mainthread = @import("mainthread");
const conn_mod = @import("conn.zig");
const frame = @import("frame.zig");
const Conn = conn_mod.Conn;
const Io = std.Io;

pub const Options = struct {
    /// Decides whether pages may open a connection to `url`; null lets them.
    allow: ?*const fn (ctx: ?*anyopaque, url: []const u8, headers: []const conn_mod.Header) bool = null,
    allow_ctx: ?*anyopaque = null,
    max_message_size: usize = 64 << 20,
    /// How long a connection the page closes waits for the server's close.
    close_timeout_ms: u32 = 5000,
    /// How many bytes of messages the page may have yet to handle before
    /// the connection stops reading.
    window_bytes: usize = 1 << 20,
};

pub const ConnectRequest = struct {
    id: []const u8,
    url: []const u8,
    protocols: []const []const u8 = &.{},
    headers: []const [2][]const u8 = &.{},
};

pub const Part = struct {
    id: []const u8,
    kind: enum { open, text, binary, sent, close },
    protocol: []const u8 = "",
    /// The text, or a binary message as base64.
    data: []const u8 = "",
    /// For `sent`: bytes written since the last.
    bytes: u64 = 0,
    code: u16 = 0,
    reason: []const u8 = "",
    clean: bool = false,
    /// Why the connection failed, for the console.
    message: []const u8 = "",
};

pub const PartEvent = myzig.Event("myzig-websocket", Part);

const Out = struct { kind: enum { text, binary, close }, data: []u8, code: u16 = 0 };

const Task = struct {
    svc: *Service,
    serial: u64,
    window: *myzig.Window,
    page_id: []u8,
    url: []u8,
    protocols: []const []const u8,
    headers: []conn_mod.Header,
    arena: std.heap.ArenaAllocator,
    conn: ?*Conn = null,
    reader: Io.Future(void) = undefined,
    writer: Io.Future(void) = undefined,
    lock: Io.Mutex = .init,
    cond: Io.Condition = .init,
    outbox: std.ArrayList(Out) = .empty,
    /// Set once connected (or failed: `conn` stays null).
    ready: bool = false,
    done: bool = false,
    unread: usize = 0,
    /// The server answered the page's close.
    server_closed: Io.Event = .unset,
};

const Msg = struct {
    svc: *Service,
    serial: u64,
    arena: std.heap.ArenaAllocator,
    part: Part,
};

pub const Service = struct {
    pub const myzig_name = "WebSocket";
    pub const myzig_params = .{
        .connect = .{"request"},
        .send = .{ "id", "kind", "data" },
        .close = .{ "id", "code", "reason" },
        .ack = .{ "id", "bytes" },
    };

    gpa: std.mem.Allocator,
    io: Io,
    options: Options,
    client: std.http.Client,
    tasks: std.ArrayList(*Task) = .empty,
    next_serial: u64 = 1,
    stopping: std.atomic.Value(bool) = .init(false),

    /// Call on the main thread.
    pub fn init(gpa: std.mem.Allocator, io: Io, options: Options) !Service {
        try mainthread.init();
        return .{ .gpa = gpa, .io = io, .options = options, .client = .{ .allocator = gpa, .io = io } };
    }

    /// Drops the connections still open, after the app's loop ended.
    pub fn deinit(s: *Service) void {
        // Nothing more for pages: what the tasks post as they stop would
        // never be delivered.
        s.stopping.store(true, .release);
        while (s.tasks.items.len > 0) s.drop(s.tasks.items.len - 1);
        s.tasks.deinit(s.gpa);
        s.client.deinit();
    }

    /// Opens a connection: `open` (or `close` with 1006) comes as an event.
    pub fn connect(s: *Service, call: *myzig.Call, request: ConnectRequest) !void {
        for (s.tasks.items) |t| if (t.window == call.window and std.mem.eql(u8, t.page_id, request.id)) return error.DuplicateId;
        const t = try s.gpa.create(Task);
        t.* = .{ .svc = s, .serial = s.next_serial, .window = call.window, .page_id = &.{}, .url = &.{}, .protocols = &.{}, .headers = &.{}, .arena = .init(s.gpa) };
        errdefer {
            t.arena.deinit();
            s.gpa.destroy(t);
        }
        const a = t.arena.allocator();
        t.page_id = try a.dupe(u8, request.id);
        t.url = try a.dupe(u8, request.url);
        const protocols = try a.alloc([]const u8, request.protocols.len);
        for (request.protocols, protocols) |p, *o| o.* = try a.dupe(u8, p);
        t.protocols = protocols;
        t.headers = try a.alloc(conn_mod.Header, request.headers.len);
        for (request.headers, t.headers) |h, *o| o.* = .{ .name = try a.dupe(u8, h[0]), .value = try a.dupe(u8, h[1]) };
        if (s.options.allow) |allow| if (!allow(s.options.allow_ctx, t.url, t.headers)) return error.NotAllowed;
        try s.tasks.append(s.gpa, t);
        errdefer _ = s.tasks.pop();
        t.reader = try s.io.concurrent(readLoop, .{t});
        t.writer = s.io.concurrent(writeLoop, .{t}) catch |err| {
            _ = t.reader.cancel(s.io);
            return err;
        };
        s.next_serial += 1;
    }

    /// Queues a message: "text", or "binary" with `data` in base64.
    pub fn send(s: *Service, call: *myzig.Call, id: []const u8, kind: []const u8, data: []const u8) !void {
        const t = s.find(call.window, id) orelse return error.NotOpen;
        const k = std.meta.stringToEnum(conn_mod.Kind, kind) orelse return error.InvalidKind;
        const bytes = switch (k) {
            .text => try s.gpa.dupe(u8, data),
            .binary => try decodeBase64(s.gpa, data),
        };
        try s.queue(t, .{ .kind = if (k == .text) .text else .binary, .data = bytes });
    }

    /// Starts the closing handshake: the server's close (or 1006 after the
    /// close timeout) comes as an event.
    pub fn close(s: *Service, call: *myzig.Call, id: []const u8, code: u16, reason: []const u8) !void {
        if (code != frame.Code.normal and code != frame.Code.no_status and (code < 3000 or code > 4999)) return error.InvalidCloseCode;
        if (reason.len > 123) return error.ReasonTooLong;
        const t = s.find(call.window, id) orelse return;
        try s.queue(t, .{ .kind = .close, .data = try s.gpa.dupe(u8, reason), .code = code });
    }

    /// The page has handled `bytes` more of the messages.
    pub fn ack(s: *Service, call: *myzig.Call, id: []const u8, bytes: u64) void {
        const t = s.find(call.window, id) orelse return;
        t.lock.lockUncancelable(s.io);
        defer t.lock.unlock(s.io);
        t.unread -|= @intCast(bytes);
        t.cond.broadcast(s.io);
    }

    fn find(s: *Service, window: *myzig.Window, id: []const u8) ?*Task {
        for (s.tasks.items) |t| if (t.window == window and std.mem.eql(u8, t.page_id, id)) return t;
        return null;
    }

    fn queue(s: *Service, t: *Task, out: Out) !void {
        t.lock.lockUncancelable(s.io);
        defer t.lock.unlock(s.io);
        errdefer s.gpa.free(out.data);
        if (t.done) return error.NotOpen;
        try t.outbox.append(s.gpa, out);
        t.cond.broadcast(s.io);
    }

    /// Stops both tasks and frees the connection (main thread).
    fn drop(s: *Service, index: usize) void {
        const t = s.tasks.orderedRemove(index);
        t.lock.lockUncancelable(s.io);
        const c = t.conn;
        const done = t.done;
        t.lock.unlock(s.io);
        // Going away, as when a page navigates or closes.
        if (c) |cn| {
            if (!done) cn.fail(frame.Code.going_away);
            cn.shutdown();
        }
        t.writer.cancel(s.io);
        t.reader.cancel(s.io);
        s.free(t);
    }

    fn free(s: *Service, t: *Task) void {
        if (t.conn) |c| c.deinit();
        for (t.outbox.items) |o| s.gpa.free(o.data);
        t.outbox.deinit(s.gpa);
        t.arena.deinit();
        s.gpa.destroy(t);
    }

    fn deliver(ctx: ?*anyopaque) callconv(.c) void {
        const msg: *Msg = @ptrCast(@alignCast(ctx));
        const s = msg.svc;
        defer {
            msg.arena.deinit();
            s.gpa.destroy(msg);
        }
        const i = for (s.tasks.items, 0..) |t, i| {
            if (t.serial == msg.serial) break i;
        } else return;
        const t = s.tasks.items[i];
        const live = for (t.window.app.windows.items) |w| {
            if (w == t.window) break true;
        } else false;
        if (!live) return s.drop(i);
        PartEvent.emit(t.window, msg.part);
        if (msg.part.kind == .close) {
            _ = s.tasks.orderedRemove(i);
            t.reader.await(s.io);
            t.writer.await(s.io);
            s.free(t);
        }
    }
};

/// Connects, then reads until the connection ends; its last event is `close`.
fn readLoop(t: *Task) void {
    const s = t.svc;
    var close_part: Part = .{ .id = t.page_id, .kind = .close, .code = frame.Code.abnormal };
    var reason_buf: [123]u8 = undefined;
    defer {
        {
            t.lock.lockUncancelable(s.io);
            defer t.lock.unlock(s.io);
            t.done = true;
            t.ready = true;
            t.cond.broadcast(s.io);
        }
        // The page's last event; the main thread then frees the task, once
        // both tasks returned.
        post(t, close_part) catch {};
    }
    const c = Conn.connect(&s.client, s.gpa, t.url, .{ .protocols = t.protocols, .headers = t.headers, .max_message_size = s.options.max_message_size }) catch |err| {
        close_part.message = @errorName(err);
        return;
    };
    {
        t.lock.lockUncancelable(s.io);
        defer t.lock.unlock(s.io);
        t.conn = c;
        t.ready = true;
        t.cond.broadcast(s.io);
    }
    post(t, .{ .id = t.page_id, .kind = .open, .protocol = c.protocol }) catch return;
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    while (true) {
        _ = arena.reset(.retain_capacity);
        const m = c.read(arena.allocator()) catch |err| {
            if (frame.failCode(err)) |code| c.fail(code);
            // A connection the page closed ends when the server answers.
            if (!c.close_sent or frame.failCode(err) != null) close_part.message = @errorName(err);
            return;
        };
        switch (m) {
            .close => |cl| {
                close_part.code = cl.code;
                // The arena goes before the deferred post: keep a copy.
                const n = @min(cl.reason.len, reason_buf.len);
                @memcpy(reason_buf[0..n], cl.reason[0..n]);
                close_part.reason = reason_buf[0..n];
                close_part.clean = true;
                t.server_closed.set(s.io);
                return;
            },
            .text, .binary => |bytes| {
                t.lock.lock(s.io) catch return;
                defer t.lock.unlock(s.io);
                while (t.unread > s.options.window_bytes) t.cond.wait(s.io, &t.lock) catch return;
                t.unread += bytes.len;
            },
        }
        post(t, switch (m) {
            .text => |text| .{ .id = t.page_id, .kind = .text, .data = text },
            .binary => |b| .{ .id = t.page_id, .kind = .binary, .data = b },
            .close => unreachable,
        }) catch return;
    }
}

/// Writes what the page sends, in order, once connected.
fn writeLoop(t: *Task) void {
    const s = t.svc;
    while (true) {
        var out: Out = undefined;
        {
            t.lock.lock(s.io) catch return;
            defer t.lock.unlock(s.io);
            while (!t.ready or (t.outbox.items.len == 0 and !t.done)) t.cond.wait(s.io, &t.lock) catch return;
            if (t.done or t.conn == null) return;
            out = t.outbox.orderedRemove(0);
        }
        defer s.gpa.free(out.data);
        const c = t.conn.?;
        switch (out.kind) {
            .text, .binary => {
                c.send(if (out.kind == .text) .text else .binary, out.data) catch {
                    c.shutdown();
                    return;
                };
                post(t, .{ .id = t.page_id, .kind = .sent, .bytes = out.data.len }) catch {};
            },
            .close => {
                c.close(out.code, out.data) catch {};
                // The server has close_timeout to answer; then the read stops.
                t.server_closed.waitTimeout(s.io, .{ .duration = .{
                    .raw = .fromMilliseconds(s.options.close_timeout_ms),
                    .clock = .awake,
                } }) catch |err| switch (err) {
                    error.Timeout => c.shutdown(),
                    error.Canceled => return,
                };
                return;
            },
        }
    }
}

/// Copies `part` (a binary message as base64) for the main thread.
fn post(t: *Task, part: Part) !void {
    const s = t.svc;
    if (s.stopping.load(.acquire)) return error.Stopping;
    const msg = try s.gpa.create(Msg);
    msg.* = .{ .svc = s, .serial = t.serial, .arena = .init(s.gpa), .part = part };
    errdefer {
        msg.arena.deinit();
        s.gpa.destroy(msg);
    }
    const a = msg.arena.allocator();
    msg.part.id = try a.dupe(u8, part.id);
    msg.part.protocol = try a.dupe(u8, part.protocol);
    msg.part.reason = try a.dupe(u8, part.reason);
    msg.part.message = try a.dupe(u8, part.message);
    if (part.kind == .binary) {
        const enc = std.base64.standard.Encoder;
        msg.part.data = enc.encode(try a.alloc(u8, enc.calcSize(part.data.len)), part.data);
    } else msg.part.data = try a.dupe(u8, part.data);
    if (!mainthread.post(msg, Service.deliver)) return error.MainThreadUnavailable;
}

fn decodeBase64(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const out = try gpa.alloc(u8, dec.calcSizeForSlice(s) catch return error.InvalidData);
    errdefer gpa.free(out);
    dec.decode(out, s) catch return error.InvalidData;
    return out;
}

test {
    std.testing.refAllDecls(Service);
}
