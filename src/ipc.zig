//! Typed IPC: services bound with `App.bind`, their methods called by pages,
//! and typed events sent to them.
const std = @import("std");
const builtin = @import("builtin");
const tsgen = @import("tsgen.zig");
pub const Window = switch (builtin.os.tag) {
    .windows => @import("windows/window.zig").Window,
    .linux => @import("linux/window.zig").Window,
    else => @import("window.zig").Window,
};
const App = switch (builtin.os.tag) {
    .windows => @import("windows/app.zig").App,
    .linux => @import("linux/app.zig").App,
    else => @import("app.zig").App,
};

/// The context of a call, for methods that take `*myzig.Call` after self.
pub const Call = struct {
    pub const myzig_call_context = {};
    /// Freed when the reply is sent: allocate results here.
    arena: std.mem.Allocator,
    window: *Window,
    /// The page that called: the window's, or a web view's in its native UI.
    page: ?*anyopaque = null,
};

pub const Service = struct {
    name: []const u8,
    ctx: *anyopaque,
    dispatch: *const fn (ctx: *anyopaque, call: *Call, method: []const u8, args: []const std.json.Value, out: *std.Io.Writer) anyerror!void,
    client: tsgen.Service,
};

pub fn service(comptime T: type, ptr: *T) Service {
    const Impl = struct {
        fn dispatch(ctx: *anyopaque, call: *Call, method: []const u8, args: []const std.json.Value, out: *std.Io.Writer) anyerror!void {
            const self: *T = @ptrCast(@alignCast(ctx));
            inline for (comptime tsgen.methodNames(T)) |name| {
                if (std.mem.eql(u8, method, name)) return invoke(T, name, self, call, args, out);
            }
            return error.UnknownMethod;
        }
    };
    return .{ .name = tsgen.shortName(T), .ctx = ptr, .dispatch = Impl.dispatch, .client = comptime tsgen.service(T) };
}

fn invoke(comptime T: type, comptime name: []const u8, self: *T, call: *Call, args: []const std.json.Value, out: *std.Io.Writer) !void {
    const func = @field(T, name);
    const F = @typeInfo(@TypeOf(func)).@"fn";
    var tuple: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
    tuple[0] = switch (F.param_types[0].?) {
        T => self.*,
        else => self,
    };
    comptime var next = 0;
    inline for (F.param_types[1..], 1..) |P, i| {
        if (P.? == *Call) {
            tuple[i] = call;
        } else if (comptime isChannel(P.?)) {
            if (next >= args.len) return error.MissingArgument;
            tuple[i] = P.?.fromArgOf(call.window, @ptrCast(@alignCast(call.page)), args[next]) catch return error.InvalidArgument;
            next += 1;
        } else {
            if (next >= args.len) return error.MissingArgument;
            tuple[i] = std.json.parseFromValueLeaky(P.?, call.arena, args[next], .{ .ignore_unknown_fields = true }) catch
                return error.InvalidArgument;
            next += 1;
        }
    }
    if (args.len > next) return error.TooManyArguments;
    const result = @call(.auto, func, tuple);
    const value = if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
    try writeJson(value, out);
}

fn isChannel(comptime P: type) bool {
    return @typeInfo(P) == .@"struct" and @hasDecl(P, "myzig_channel");
}

pub fn writeJson(value: anytype, out: *std.Io.Writer) !void {
    if (@TypeOf(value) == void) return out.writeAll("null");
    try std.json.Stringify.value(value, .{}, out);
}

/// A typed event: `const Tick = myzig.Event("tick", struct { n: u32 });`
/// Pages listen with the generated `onTick(fn)`.
pub fn Event(comptime event_name: []const u8, comptime T: type) type {
    return struct {
        pub const name = event_name;
        pub const Payload = T;
        pub const client = tsgen.event(event_name, T);

        /// Sends `payload` to one window's page. Safe from any thread.
        pub fn emit(window: *Window, payload: T) void {
            const msg = encode(window.app.gpa, payload) catch return;
            window.sendOwned(msg);
        }

        /// Sends `payload` to every window's page. Main thread only.
        pub fn broadcast(app: *App, payload: T) void {
            const msg = encode(app.gpa, payload) catch return;
            defer app.gpa.free(msg);
            for (app.windows.items) |w| {
                if (w.page) |p| p.enqueue(msg, true);
                for (w.web_views.items) |p| p.enqueue(msg, true);
            }
        }

        fn encode(gpa: std.mem.Allocator, payload: T) ![]u8 {
            var aw: std.Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            try aw.writer.writeAll("{\"t\":\"event\",\"n\":");
            try std.json.Stringify.encodeJsonString(event_name, .{}, &aw.writer);
            try aw.writer.writeAll(",\"p\":");
            try writeJson(payload, &aw.writer);
            try aw.writer.writeByte('}');
            return aw.toOwnedSlice();
        }
    };
}

const Envelope = struct {
    t: []const u8,
    id: ?f64 = null,
    m: []const u8 = "",
    a: []const std.json.Value = &.{},
    op: []const u8 = "",
    v: ?[]const u8 = null,
    /// Channels: the id, and the sequence number of a value or acknowledgment.
    c: i64 = 0,
    n: u64 = 0,
    /// Results of evaluations: the page's token, success, and the error.
    k: []const u8 = "",
    ok: bool = false,
    e: []const u8 = "",
};

/// Handles one message from `page` (the window's, or one inside its
/// native UI), on the main thread.
pub fn handleMessage(window: *Window, page: anytype, body: []const u8) void {
    const app = window.app;
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Envelope.a holds a call's arguments, but a channel message's "a" is a flag.
    const env = std.json.parseFromSliceLeaky(Envelope, a, body, .{ .ignore_unknown_fields = true }) catch
        parseChannelMessage(a, body) orelse {
        std.log.warn("myzig: malformed message from page", .{});
        return;
    };
    if (std.mem.eql(u8, env.t, "call")) {
        const id = messageId(env.id) orelse return;
        var aw: std.Io.Writer.Allocating = .init(a);
        aw.writer.print("{{\"t\":\"reply\",\"id\":{d},", .{id}) catch return;
        const mark = aw.written().len;
        const result = if (pageTrusted(page, a)) callMethod(app, window, page, a, env.m, env.a, &aw.writer) else error.Untrusted;
        // The method may have closed the window: its page is gone.
        if (!stillOpen(app, window, page)) return;
        result catch |err| {
            aw.shrinkRetainingCapacity(mark);
            aw.writer.writeAll("\"ok\":false,\"e\":") catch return;
            const text = std.fmt.allocPrint(a, "{s}: {s}", .{ env.m, @errorName(err) }) catch return;
            std.json.Stringify.encodeJsonString(text, .{}, &aw.writer) catch return;
            aw.writer.writeByte('}') catch return;
            page.enqueue(aw.written(), false);
            return;
        };
        aw.writer.writeByte('}') catch return;
        page.enqueue(aw.written(), false);
    } else if (std.mem.eql(u8, env.t, "eval")) {
        const id = messageId(env.id) orelse return;
        page.core.settle(id, env.k, if (env.ok) .{ .ok = env.v orelse "null" } else .{ .err = env.e });
    } else if (std.mem.eql(u8, env.t, "chan-msg")) {
        const flagged = std.mem.indexOf(u8, body, "\"a\":1") != null;
        if (page.core.channels.received(app.gpa, env.c, env.v orelse "null", env.n, flagged)) |ack| {
            defer app.gpa.free(ack);
            // The listener may have closed the window.
            if (stillOpen(app, window, page)) page.enqueue(ack, true);
        }
    } else if (std.mem.eql(u8, env.t, "chan-ack")) {
        page.core.channels.ack(env.c, env.n);
    } else if (std.mem.eql(u8, env.t, "chan-close")) {
        if (page.core.channels.close(app.gpa, env.c, .page)) |m| app.gpa.free(m);
    } else if (std.mem.eql(u8, env.t, "dom-ready")) {
        page.domReady();
        page.core.fire(.dom_ready);
    } else if (std.mem.eql(u8, env.t, "log")) {
        std.debug.print("page: {s}\n", .{env.v orelse ""});
    } else if (std.mem.eql(u8, env.t, "drag")) {
        page.startDrag();
    } else if (std.mem.eql(u8, env.t, "dblclick")) {
        window.zoom();
    } else if (std.mem.eql(u8, env.t, "win")) {
        // A page inside native UI leaves its window open.
        if (std.mem.eql(u8, env.op, "close")) (if (page.embed == null) window.close()) //
        else if (std.mem.eql(u8, env.op, "minimize")) window.minimize() //
        else if (std.mem.eql(u8, env.op, "zoom")) window.zoom() //
        else if (std.mem.eql(u8, env.op, "title")) window.setTitle(env.v orelse "");
    }
}

/// IDs cross JavaScript's Number representation: reject lossy or unsafe casts.
fn messageId(value: ?f64) ?u64 {
    const n = value orelse return null;
    if (!std.math.isFinite(n) or n < 0 or n > 9007199254740991 or @trunc(n) != n) return null;
    return @intFromFloat(n);
}

/// A channel message, whose "a" (ask for an acknowledgment) is a number.
fn parseChannelMessage(a: std.mem.Allocator, body: []const u8) ?Envelope {
    const Msg = struct { t: []const u8, c: i64 = 0, n: u64 = 0, v: ?[]const u8 = null };
    const m = std.json.parseFromSliceLeaky(Msg, a, body, .{ .ignore_unknown_fields = true }) catch return null;
    return .{ .t = m.t, .c = m.c, .n = m.n, .v = m.v };
}

/// Whether the page's current document may call bound services.
fn pageTrusted(page: anytype, a: std.mem.Allocator) bool {
    const url = page.currentUrl(a) catch return false;
    return page.core.isTrusted(url);
}

fn callMethod(app: *App, window: *Window, page: anytype, arena: std.mem.Allocator, method: []const u8, args: []const std.json.Value, out: *std.Io.Writer) !void {
    const dot = std.mem.indexOfScalar(u8, method, '.') orelse return error.UnknownMethod;
    const svc = app.bindings.services.get(method[0..dot]) orelse return error.UnknownService;
    try out.writeAll("\"ok\":true,\"v\":");
    var call: Call = .{ .arena = arena, .window = window, .page = page };
    try svc.dispatch(svc.ctx, &call, method[dot + 1 ..], args, out);
}

/// Whether `window` still shows `page`, after app code that may close it.
pub fn stillOpen(app: *App, window: *Window, page: anytype) bool {
    for (app.windows.items) |w| if (w == window)
        return w.page == page or std.mem.indexOfScalar(@TypeOf(page), w.web_views.items, page) != null;
    return false;
}
