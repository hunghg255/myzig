//! The service pages call (`js/fetch.js` wraps it in a standard `fetch`):
//! each request runs concurrently on the app's `Io`, and its response
//! comes back to the page that made it as `myzig-fetch` events, through
//! the main thread. Aborting cancels the task; a page that navigates,
//! reloads or closes cancels its requests (`myzig_pageGone`).
//!
//!     var fetch_service: fetch.Service = try .init(gpa, app.io, .{});
//!     defer fetch_service.deinit();
//!     try app.bind(&fetch_service);
const std = @import("std");
const myzig = @import("myzig");
const mainthread = @import("mainthread");
const http = @import("http.zig");
const redirects = @import("redirect.zig");
const Io = std.Io;

pub const Options = struct {
    /// Decides whether pages may make a request (its URL, method and
    /// headers), including each redirect, on the main thread; null lets
    /// them make any.
    allow: ?*const fn (ctx: ?*anyopaque, req: *const http.Request) bool = null,
    allow_ctx: ?*anyopaque = null,
    /// How many body bytes the page may have yet to read before the
    /// request waits for it: a large download does not pile up in the page.
    window_bytes: usize = 1 << 20,
};

/// A request as the page sends it.
pub const PageRequest = struct {
    /// Chosen by the page, unique among its requests in flight.
    id: []const u8,
    url: []const u8,
    method: []const u8 = "GET",
    headers: []const [2][]const u8 = &.{},
    /// Base64, or null for none.
    body: ?[]const u8 = null,
    /// "follow", "manual" or "error".
    redirect: []const u8 = "follow",
};

/// What the page receives about a request: its head, chunks of its body,
/// then its end or error.
pub const Part = struct {
    id: []const u8,
    kind: enum { head, chunk, end, failed },
    status: u16 = 0,
    statusText: []const u8 = "",
    url: []const u8 = "",
    redirected: bool = false,
    headers: []const [2][]const u8 = &.{},
    /// Base64.
    chunk: []const u8 = "",
    message: []const u8 = "",
};

pub const PartEvent = myzig.Event("myzig-fetch", Part);

const Task = struct {
    svc: *Service,
    serial: u64,
    window: *myzig.Window,
    /// The page that made it (`myzig.Call.page`).
    page: ?*anyopaque,
    page_id: []const u8,
    /// The worker's memory: the request, and what `perform` needs.
    arena: std.heap.ArenaAllocator,
    req: http.Request,
    next_req: ?http.Request = null,
    redirected: bool = false,
    future: Io.Future(void) = undefined,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    unread: usize = 0,
};

/// One part on its way to the main thread.
const Msg = struct {
    svc: *Service,
    serial: u64,
    arena: std.heap.ArenaAllocator,
    part: Part,
    redirect: bool = false,
};

pub const Service = struct {
    pub const myzig_name = "Fetch";
    pub const myzig_params = .{ .start = .{"request"}, .abort = .{"id"}, .ack = .{ "id", "bytes" } };

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

    /// Cancels the requests still running. After the app's loop ended:
    /// parts still queued for the main thread then never run.
    pub fn deinit(s: *Service) void {
        // Nothing more for pages: parts the tasks post as they stop would
        // never be delivered.
        s.stopping.store(true, .release);
        while (s.tasks.items.len > 0) s.cancel(s.tasks.items.len - 1);
        s.tasks.deinit(s.gpa);
        s.client.deinit();
    }

    /// Starts a request; its response comes as `myzig-fetch` events.
    pub fn start(s: *Service, call: *myzig.Call, request: PageRequest) !void {
        for (s.tasks.items) |t| if (t.window == call.window and std.mem.eql(u8, t.page_id, request.id)) return error.DuplicateId;
        const t = try s.gpa.create(Task);
        t.* = .{ .svc = s, .serial = s.next_serial, .window = call.window, .page = call.page, .page_id = "", .arena = .init(s.gpa), .req = undefined };
        errdefer {
            t.arena.deinit();
            s.gpa.destroy(t);
        }
        const a = t.arena.allocator();
        t.page_id = try a.dupe(u8, request.id);
        const headers = try a.alloc(http.Header, request.headers.len);
        for (request.headers, headers) |h, *out| out.* = .{ .name = try a.dupe(u8, h[0]), .value = try a.dupe(u8, h[1]) };
        t.req = .{
            .url = try a.dupe(u8, request.url),
            .method = try a.dupe(u8, request.method),
            .headers = headers,
            .body = if (request.body) |b| try decodeBase64(a, b) else null,
            .redirect = std.meta.stringToEnum(http.Redirect, request.redirect) orelse return error.InvalidRedirectMode,
        };
        if (s.options.allow) |allow| if (!allow(s.options.allow_ctx, &t.req)) return error.NotAllowed;
        try s.tasks.append(s.gpa, t);
        errdefer _ = s.tasks.pop();
        t.future = try s.io.concurrent(run, .{t});
        s.next_serial += 1;
    }

    /// Cancels a request, before or after its response arrived.
    pub fn abort(s: *Service, call: *myzig.Call, id: []const u8) void {
        for (s.tasks.items, 0..) |t, i| if (t.window == call.window and std.mem.eql(u8, t.page_id, id)) return s.cancel(i);
    }

    /// The page has read `bytes` more of the body.
    pub fn ack(s: *Service, call: *myzig.Call, id: []const u8, bytes: u64) void {
        for (s.tasks.items) |t| if (t.window == call.window and std.mem.eql(u8, t.page_id, id)) {
            t.mutex.lockUncancelable(s.io);
            defer t.mutex.unlock(s.io);
            t.unread -|= @intCast(bytes);
            t.cond.signal(s.io);
            return;
        };
    }

    /// The page that made requests is gone (it navigated, reloaded or
    /// closed): they are canceled, even those waiting for it to read.
    pub fn myzig_pageGone(s: *Service, window: *myzig.Window, page: *anyopaque) void {
        var i = s.tasks.items.len;
        while (i > 0) {
            i -= 1;
            const t = s.tasks.items[i];
            if (t.window == window and t.page == page) s.cancel(i);
        }
    }

    fn cancel(s: *Service, index: usize) void {
        const t = s.tasks.orderedRemove(index);
        t.future.cancel(s.io);
        t.arena.deinit();
        s.gpa.destroy(t);
    }

    fn find(s: *Service, serial: u64) ?usize {
        for (s.tasks.items, 0..) |t, i| if (t.serial == serial) return i;
        return null;
    }

    /// On the main thread: hands a part to its page.
    fn deliver(ctx: ?*anyopaque) callconv(.c) void {
        const msg: *Msg = @ptrCast(@alignCast(ctx));
        const s = msg.svc;
        defer {
            msg.arena.deinit();
            s.gpa.destroy(msg);
        }
        // Gone: aborted, or its window's requests were canceled.
        const i = s.find(msg.serial) orelse return;
        const t = s.tasks.items[i];
        const live = for (t.window.app.windows.items) |w| {
            if (w == t.window) break true;
        } else false;
        if (!live) return s.cancel(i);
        if (msg.redirect) {
            // The worker ended after posting this hop. Policy stays on the
            // main thread and runs before any connection to the next target.
            t.future.await(s.io);
            const next = t.next_req.?;
            const allowed = if (s.options.allow) |allow| allow(s.options.allow_ctx, &next) else true;
            // The policy itself may abort the request or close its page.
            const current_i = s.find(msg.serial) orelse return;
            const current = s.tasks.items[current_i];
            if (!allowed) {
                PartEvent.emit(current.window, .{ .id = current.page_id, .kind = .failed, .message = "NotAllowed" });
                return s.cancel(current_i);
            }
            current.req = next;
            current.next_req = null;
            current.redirected = true;
            current.future = s.io.concurrent(run, .{current}) catch {
                PartEvent.emit(current.window, .{ .id = current.page_id, .kind = .failed, .message = "ConcurrencyUnavailable" });
                return s.cancel(current_i);
            };
            return;
        }
        PartEvent.emit(t.window, msg.part);
        if (msg.part.kind == .end or msg.part.kind == .failed) {
            _ = s.tasks.orderedRemove(i);
            t.future.await(s.io);
            t.arena.deinit();
            s.gpa.destroy(t);
        }
    }
};

/// The request's task, concurrent with the main thread.
fn run(t: *Task) void {
    const sink: http.Sink = .{ .ctx = t, .head = onHead, .chunk = onChunk };
    var req = t.req;
    if (t.svc.options.allow != null and req.redirect == .follow) req.redirect = .manual;
    http.perform(&t.svc.client, t.arena.allocator(), req, sink) catch |err| {
        // Canceled: nobody is listening any more.
        if (err == error.Canceled or err == error.PolicyRedirect) return;
        post(t, .{ .id = t.page_id, .kind = .failed, .message = @errorName(err) }, &.{}) catch {};
        return;
    };
    post(t, .{ .id = t.page_id, .kind = .end }, &.{}) catch {};
}

fn onHead(ctx: *anyopaque, head: http.Head) !void {
    const t: *Task = @ptrCast(@alignCast(ctx));
    if (t.svc.options.allow != null and t.req.redirect == .follow and redirects.isRedirect(head.status)) {
        t.next_req = try redirects.next(t.arena.allocator(), t.req, head);
        const s = t.svc;
        if (s.stopping.load(.acquire)) return error.Stopping;
        const msg = try s.gpa.create(Msg);
        msg.* = .{ .svc = s, .serial = t.serial, .arena = .init(s.gpa), .part = .{ .id = "", .kind = .head }, .redirect = true };
        if (!mainthread.post(msg, Service.deliver)) {
            s.gpa.destroy(msg);
            return error.MainThreadUnavailable;
        }
        return error.PolicyRedirect;
    }
    try post(t, .{
        .id = t.page_id,
        .kind = .head,
        .status = head.status,
        .statusText = head.status_text,
        .url = head.url,
        .redirected = t.redirected or head.redirected,
    }, head.headers);
}

fn onChunk(ctx: *anyopaque, bytes: []const u8) !void {
    const t: *Task = @ptrCast(@alignCast(ctx));
    const io = t.svc.io;
    {
        // Waits while the page has more than its window to read.
        try t.mutex.lock(io);
        defer t.mutex.unlock(io);
        while (t.unread > t.svc.options.window_bytes) try t.cond.wait(io, &t.mutex);
        t.unread += bytes.len;
    }
    try post(t, .{ .id = t.page_id, .kind = .chunk, .chunk = bytes }, &.{});
}

/// Copies `part` (and `headers`, and the chunk as base64) for the main thread.
fn post(t: *Task, part: Part, headers: []const http.Header) !void {
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
    msg.part.statusText = try a.dupe(u8, part.statusText);
    msg.part.url = try a.dupe(u8, part.url);
    msg.part.message = try a.dupe(u8, part.message);
    const hs = try a.alloc([2][]const u8, headers.len);
    for (headers, hs) |h, *o| o.* = .{ try a.dupe(u8, h.name), try a.dupe(u8, h.value) };
    msg.part.headers = hs;
    if (part.chunk.len > 0) {
        const enc = std.base64.standard.Encoder;
        msg.part.chunk = enc.encode(try a.alloc(u8, enc.calcSize(part.chunk.len)), part.chunk);
    }
    if (!mainthread.post(msg, Service.deliver)) return error.MainThreadUnavailable;
}

fn decodeBase64(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const out = try a.alloc(u8, dec.calcSizeForSlice(s) catch return error.InvalidBody);
    dec.decode(out, s) catch return error.InvalidBody;
    return out;
}

test {
    std.testing.refAllDecls(Service);
}
