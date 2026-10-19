//! The service pages call (`js/watch.js` wraps it): pages watch roots the
//! app names, never paths. Each watch is a task on the app's `Io` taking
//! batches from a `Watcher`; a batch reaches the page as a `myzig-watch`
//! event through the main thread, and the next is not taken before the
//! page acknowledged it.
//!
//!     var watch_service: watch.Service = try .init(gpa, app.io, .{ .roots = &.{
//!         .{ .name = "project", .path = project_dir, .recursive = true },
//!     } });
//!     defer watch_service.deinit();
//!     try app.bind(&watch_service);
//!     try app.registerEvent(watch.BatchEvent);
const std = @import("std");
const myzig = @import("myzig");
const mainthread = @import("mainthread");
const watcher = @import("watcher.zig");
const Io = std.Io;

pub const Root = struct {
    /// Lowercase letters, digits and dashes, starting with a letter.
    name: []const u8,
    /// Absolute: a directory or a file.
    path: []const u8,
    /// Lets pages watch the directories in it too.
    recursive: bool = false,
    ignore: ?*const fn (ctx: ?*anyopaque, path: []const u8, is_dir: bool) bool = null,
    ignore_ctx: ?*anyopaque = null,
};

pub const Options = struct {
    roots: []const Root = &.{},
    /// Asked before each watch: the window, the root's name, the path in
    /// it and whether it is recursive.
    allow: ?*const fn (ctx: ?*anyopaque, window: *myzig.Window, name: []const u8, path: []const u8, recursive: bool) bool = null,
    allow_ctx: ?*anyopaque = null,
    max_watches_per_page: usize = 8,
    max_watches: usize = 128,
};

pub const StartRequest = struct {
    id: []const u8,
    name: []const u8,
    /// In the root, with slashes; "" is the root itself.
    path: []const u8 = "",
    recursive: bool = false,
    debounceMs: i32 = 0,
};

pub const PageEvent = struct {
    op: []const u8,
    path: []const u8,
    oldPath: ?[]const u8 = null,
    isDir: bool = false,
};

pub const Batch = struct {
    id: []const u8,
    kind: enum { batch, end },
    events: []const PageEvent = &.{},
    /// For `end`: "" when it ended as it should, else the error's code.
    code: []const u8 = "",
};

pub const BatchEvent = myzig.Event("myzig-watch", Batch);

const Task = struct {
    svc: *Service,
    serial: u64,
    window: *myzig.Window,
    page_id: []u8,
    w: *watcher.Watcher,
    future: Io.Future(void) = undefined,
    taken: Io.Event = .unset,
};

const Msg = struct {
    svc: *Service,
    serial: u64,
    arena: std.heap.ArenaAllocator,
    batch: Batch,
};

pub const Service = struct {
    pub const myzig_name = "Watch";
    pub const myzig_params = .{ .start = .{"request"}, .stop = .{"id"}, .ack = .{"id"} };

    gpa: std.mem.Allocator,
    io: Io,
    options: Options,
    tasks: std.ArrayList(*Task) = .empty,
    next_serial: u64 = 1,

    /// Checks the roots (names, absolute paths that exist). Main thread.
    pub fn init(gpa: std.mem.Allocator, io: Io, options: Options) !Service {
        try mainthread.init();
        for (options.roots) |r| {
            if (!validName(r.name)) return error.InvalidRootName;
            if (!std.fs.path.isAbsolute(r.path)) return error.RootNotAbsolute;
            _ = try Io.Dir.cwd().statFile(io, r.path, .{});
        }
        return .{ .gpa = gpa, .io = io, .options = options };
    }

    pub fn deinit(s: *Service) void {
        while (s.tasks.items.len > 0) s.drop(s.tasks.items.len - 1);
        s.tasks.deinit(s.gpa);
    }

    /// Starts a watch; returns once everything is watched. Errors are the
    /// page's codes: Denied, NotFound, Limit, PathEncoding, Io.
    pub fn start(s: *Service, call: *myzig.Call, request: StartRequest) !void {
        s.sweep(call.window.app);
        const root = for (s.options.roots) |r| {
            if (std.mem.eql(u8, r.name, request.name)) break r;
        } else return error.Denied;
        if (request.recursive and !root.recursive) return error.Denied;
        const rel = std.mem.trim(u8, request.path, "/");
        if (rel.len > 0 and !root.recursive and std.mem.indexOfScalar(u8, rel, '/') != null) return error.Denied;
        if (!std.unicode.utf8ValidateSlice(rel)) return error.PathEncoding;
        var it = std.mem.splitScalar(u8, rel, '/');
        while (it.next()) |part| if (rel.len > 0 and (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.indexOfAny(u8, part, "\\:\x00") != null)) return error.Denied;
        if (s.options.allow) |allow| if (!allow(s.options.allow_ctx, call.window, request.name, rel, request.recursive)) return error.Denied;
        var mine: usize = 0;
        for (s.tasks.items) |t| {
            if (t.window != call.window) continue;
            if (std.mem.eql(u8, t.page_id, request.id)) return error.DuplicateId;
            mine += 1;
        }
        if (mine >= s.options.max_watches_per_page or s.tasks.items.len >= s.options.max_watches) return error.Limit;

        // Not through a symbolic link: each step of the path is checked.
        const a = call.arena;
        var full: []const u8 = root.path;
        var steps = std.mem.splitScalar(u8, rel, '/');
        while (steps.next()) |part| {
            if (part.len == 0) continue;
            full = try std.fs.path.join(a, &.{ full, part });
            const st = Io.Dir.cwd().statFile(s.io, full, .{ .follow_symlinks = false }) catch return error.NotFound;
            if (st.kind == .sym_link) return error.Denied;
            if (st.kind == .directory and !root.recursive and steps.rest().len == 0 and rel.len > 0) return error.Denied;
        }
        const w = watcher.Watcher.init(s.gpa, s.io, full, .{
            .recursive = request.recursive,
            .ignore = root.ignore,
            .ignore_ctx = root.ignore_ctx,
            .debounce_ms = request.debounceMs,
        }) catch |err| return switch (err) {
            error.NotFound => error.NotFound,
            error.TooManyEntries => error.Limit,
            error.PathEncoding => error.PathEncoding,
            else => error.Io,
        };
        errdefer w.deinit();
        const t = try s.gpa.create(Task);
        errdefer s.gpa.destroy(t);
        t.* = .{ .svc = s, .serial = s.next_serial, .window = call.window, .page_id = try s.gpa.dupe(u8, request.id), .w = w };
        errdefer s.gpa.free(t.page_id);
        try s.tasks.append(s.gpa, t);
        errdefer _ = s.tasks.pop();
        t.future = try s.io.concurrent(run, .{t});
        s.next_serial += 1;
    }

    pub fn stop(s: *Service, call: *myzig.Call, id: []const u8) void {
        for (s.tasks.items, 0..) |t, i| if (t.window == call.window and std.mem.eql(u8, t.page_id, id)) return s.drop(i);
    }

    /// The page took the last batch: the watch may look again.
    pub fn ack(s: *Service, call: *myzig.Call, id: []const u8) void {
        for (s.tasks.items) |t| if (t.window == call.window and std.mem.eql(u8, t.page_id, id)) t.taken.set(s.io);
    }

    fn drop(s: *Service, index: usize) void {
        const t = s.tasks.orderedRemove(index);
        t.w.close();
        t.future.cancel(s.io);
        s.free(t);
    }

    fn free(s: *Service, t: *Task) void {
        t.w.deinit();
        s.gpa.free(t.page_id);
        s.gpa.destroy(t);
    }

    /// Stops the watches of windows that closed.
    fn sweep(s: *Service, app: *myzig.App) void {
        var i: usize = 0;
        while (i < s.tasks.items.len) {
            const t = s.tasks.items[i];
            const live = for (app.windows.items) |w| {
                if (w == t.window) break true;
            } else false;
            if (live) i += 1 else s.drop(i);
        }
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
        s.sweep(t.window.app);
        if (s.tasks.items.len <= i or s.tasks.items[i] != t) return;
        BatchEvent.emit(t.window, msg.batch);
        if (msg.batch.kind == .end) {
            _ = s.tasks.orderedRemove(i);
            t.future.await(s.io);
            s.free(t);
        }
    }
};

fn run(t: *Task) void {
    var arena: std.heap.ArenaAllocator = .init(t.svc.gpa);
    defer arena.deinit();
    while (true) {
        _ = arena.reset(.retain_capacity);
        const events = t.w.next(arena.allocator()) catch |err| {
            if (err == error.Canceled) return;
            const code: []const u8 = switch (err) {
                error.EndOfStream => "",
                error.TooManyEntries => "Limit",
                error.PathEncoding => "PathEncoding",
                else => "Io",
            };
            post(t, .end, &.{}, code) catch {};
            return;
        };
        t.taken.reset();
        const ended = events.len > 0 and events[events.len - 1].op == .remove and std.mem.eql(u8, events[events.len - 1].path, ".");
        post(t, .batch, events, "") catch return;
        if (ended) {
            post(t, .end, &.{}, "") catch {};
            return;
        }
        t.taken.wait(t.svc.io) catch return;
    }
}

fn post(t: *Task, kind: @FieldType(Batch, "kind"), events: []const watcher.Event, code: []const u8) !void {
    const s = t.svc;
    const msg = try s.gpa.create(Msg);
    msg.* = .{ .svc = s, .serial = t.serial, .arena = .init(s.gpa), .batch = .{ .id = "", .kind = kind } };
    errdefer {
        msg.arena.deinit();
        s.gpa.destroy(msg);
    }
    const a = msg.arena.allocator();
    msg.batch.id = try a.dupe(u8, t.page_id);
    msg.batch.code = code;
    const out = try a.alloc(PageEvent, events.len);
    for (events, out) |e, *o| o.* = .{
        .op = @tagName(e.op),
        .path = try a.dupe(u8, e.path),
        .oldPath = if (e.old_path) |p| try a.dupe(u8, p) else null,
        .isDir = e.is_dir,
    };
    msg.batch.events = out;
    if (!mainthread.post(msg, Service.deliver)) return error.MainThreadUnavailable;
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    return true;
}

test validName {
    try std.testing.expect(validName("project"));
    try std.testing.expect(validName("picked-1"));
    for ([_][]const u8{ "", "1a", "Project", "a_b", "a/b" }) |n| try std.testing.expect(!validName(n));
}

test {
    std.testing.refAllDecls(Service);
}
