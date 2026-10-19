//! The service pages call for an update window or banner of their own:
//! checks and downloads run on a task of the app's `Io`, and their state
//! reaches every page as `myzig-updater` events. Background checks run
//! once a day (`interval_s`) when the user lets them, the first a while
//! after launch.
//!
//!     var update_service: updater.Service = try .init(gpa, app, .{ .manifest_url = url, .current = version });
//!     defer update_service.deinit();
//!     try app.bind(&update_service);
//!     try app.registerEvent(updater.StateEvent);
//!     update_service.startBackgroundChecks(10_000);
const std = @import("std");
const myzig = @import("myzig");
const mainthread = @import("mainthread");
const core = @import("updater.zig");
const Prefs = @import("prefs.zig").Prefs;
const Io = std.Io;

pub const Options = struct {
    manifest_url: []const u8,
    current: []const u8,
    /// The executable replaced; the running one when null.
    exe_path: ?[]const u8 = null,
    /// Where `updater.json` lives; the app's data directory when null.
    prefs_dir: ?[]const u8 = null,
    /// Seconds between background checks.
    interval_s: i64 = 24 * 3600,
    /// myzig-update.pub's contents: only updates signed with its secret
    /// key install (`Updater.public_key`).
    public_key: ?[]const u8 = null,
};

/// What native code follows of the service (the update window): `state`
/// gets every state pages get, on the main thread; `begin` is called as a
/// check begins, on the main thread, with whether the user asked for it.
pub const Listener = struct {
    ctx: *anyopaque,
    state: *const fn (ctx: *anyopaque, state: State) void,
    begin: ?*const fn (ctx: *anyopaque, user: bool) void = null,
};

pub const State = struct {
    kind: enum { checking, upToDate, available, downloading, ready, failed },
    version: []const u8 = "",
    notes: []const u8 = "",
    done: u64 = 0,
    total: ?u64 = null,
    message: []const u8 = "",
    /// From a background check, not one the user asked for.
    background: bool = false,
};

pub const StateEvent = myzig.Event("myzig-updater", State);

const Msg = struct { svc: *Service, arena: std.heap.ArenaAllocator, state: State };

pub const Service = struct {
    pub const myzig_name = "Updater";
    pub const myzig_params = .{ .setAutomaticChecks = .{"on"}, .setAutomaticDownloads = .{"on"} };

    gpa: std.mem.Allocator,
    app: *myzig.App,
    options: Options,
    client: std.http.Client,
    prefs_path: []u8,
    prefs_arena: std.heap.ArenaAllocator,
    prefs: Prefs,
    task: ?Io.Future(void) = null,
    busy: std.atomic.Value(bool) = .init(false),
    /// What the last check found, for `install` (owned by `found_arena`).
    found: ?core.Update = null,
    found_arena: std.heap.ArenaAllocator,
    stopping: std.atomic.Value(bool) = .init(false),
    /// The update window, or other native code following the states.
    listener: ?Listener = null,
    /// Set once a check began since launch: until then the next background
    /// check is soon, however recent the last check of an earlier launch.
    launch_checked: bool = false,

    /// Main thread. Removes what an earlier update left (`cleanup`).
    pub fn init(gpa: std.mem.Allocator, app: *myzig.App, options: Options) !Service {
        try mainthread.init();
        const dir = if (options.prefs_dir) |d| try gpa.dupe(u8, d) else try myzig.path(gpa, .data, app.options.name);
        defer gpa.free(dir);
        Io.Dir.cwd().createDirPath(app.io, dir) catch {};
        var s: Service = .{
            .gpa = gpa,
            .app = app,
            .options = options,
            .client = .{ .allocator = gpa, .io = app.io },
            .prefs_path = try std.fs.path.join(gpa, &.{ dir, "updater.json" }),
            .prefs_arena = .init(gpa),
            .prefs = .{},
            .found_arena = .init(gpa),
        };
        s.prefs = Prefs.load(app.io, s.prefs_arena.allocator(), s.prefs_path);
        s.updater().cleanup();
        return s;
    }

    pub fn deinit(s: *Service) void {
        s.stopping.store(true, .release);
        if (s.task) |*t| _ = t.cancel(s.app.io);
        s.client.deinit();
        s.gpa.free(s.prefs_path);
        s.prefs_arena.deinit();
        s.found_arena.deinit();
    }

    fn updater(s: *Service) core.Updater {
        return .{ .gpa = s.gpa, .io = s.app.io, .client = &s.client, .manifest_url = s.options.manifest_url, .current = s.options.current, .exe_path = s.options.exe_path, .public_key = s.options.public_key };
    }

    /// Checks now, as the user asked: skipped versions are offered too.
    pub fn check(s: *Service) !void {
        try s.start(.check, false);
    }

    /// Downloads and installs what the last check found.
    pub fn install(s: *Service) !void {
        if (s.found == null) return error.NothingToInstall;
        try s.start(.install, false);
    }

    /// Skips the version the last check found, for background checks.
    pub fn skip(s: *Service) !void {
        const f = s.found orelse return;
        s.prefs.skippedVersion = try s.prefs_arena.allocator().dupe(u8, f.version);
        try s.prefs.save(s.app.io, s.prefs_path);
    }

    /// Starts the installed version and quits.
    pub fn relaunch(s: *Service) !void {
        try s.updater().relaunch(&.{});
        s.app.quit();
    }

    pub fn preferences(s: *Service) Prefs {
        return s.prefs;
    }

    pub fn setAutomaticChecks(s: *Service, on: bool) !void {
        s.prefs.automaticChecks = on;
        try s.prefs.save(s.app.io, s.prefs_path);
    }

    pub fn setAutomaticDownloads(s: *Service, on: bool) !void {
        s.prefs.automaticDownloads = on;
        try s.prefs.save(s.app.io, s.prefs_path);
    }

    /// Checks in the background after `delay_ms`, whenever the last check
    /// was, so that a version that came out since the app last ran shows
    /// when it opens again; then every `interval_s`, when the user lets it.
    /// Main thread.
    pub fn startBackgroundChecks(s: *Service, delay_ms: u64) void {
        myzig.App.after(delay_ms, s, background);
    }

    fn background(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Service = @ptrCast(@alignCast(ctx));
        if (s.stopping.load(.acquire)) return;
        const now = Io.Clock.real.now(s.app.io).toSeconds();
        if (s.prefs.dueAt(now, s.options.interval_s, s.launch_checked)) s.start(.check, true) catch {};
        // An hour from now, it looks whether one is due.
        myzig.App.after(3600 * 1000, s, background);
    }

    const Job = enum { check, install };

    fn start(s: *Service, job: Job, bg: bool) !void {
        if (s.busy.swap(true, .acq_rel)) return error.Busy;
        // The last task finished (busy was clear): collect it.
        if (s.task) |*t| t.await(s.app.io);
        if (job == .check) {
            s.launch_checked = true;
            if (s.listener) |l| if (l.begin) |b| b(l.ctx, !bg);
        }
        s.task = s.app.io.concurrent(run, .{ s, job, bg }) catch |err| {
            s.task = null;
            s.busy.store(false, .release);
            return err;
        };
    }

    fn run(s: *Service, job: Job, bg: bool) void {
        defer s.busy.store(false, .release);
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const u = s.updater();
        switch (job) {
            .check => {
                if (!bg) s.post(.{ .kind = .checking });
                const found = u.check(a) catch |err| return s.post(.{ .kind = .failed, .message = @errorName(err), .background = bg });
                const now = Io.Clock.real.now(s.app.io).toSeconds();
                s.post(.{ .kind = .upToDate, .done = @intCast(now), .background = true, .message = "checked" });
                const update = found orelse return if (!bg) s.post(.{ .kind = .upToDate });
                if (bg and !s.prefs.offers(update.version)) return;
                const fa = s.found_arena.allocator();
                s.found = .{ .version = fa.dupe(u8, update.version) catch return, .url = fa.dupe(u8, update.url) catch return, .sha256 = update.sha256, .notes = "", .size = update.size, .signature = update.signature };
                s.post(.{ .kind = .available, .version = update.version, .notes = update.notes, .total = update.size, .background = bg });
                if (bg and s.prefs.automaticDownloads) s.download(a, s.found.?, bg);
            },
            .install => s.download(a, s.found.?, bg),
        }
    }

    fn download(s: *Service, a: std.mem.Allocator, update: core.Update, bg: bool) void {
        const u = s.updater();
        const P = struct {
            fn progress(ctx: ?*anyopaque, done: u64, total: ?u64) void {
                const svc: *Service = @ptrCast(@alignCast(ctx));
                svc.post(.{ .kind = .downloading, .done = done, .total = total });
            }
        };
        const staged = u.download(a, update, .{ .ctx = s, .func = P.progress }) catch |err| return s.post(.{ .kind = .failed, .message = @errorName(err), .background = bg });
        u.install(staged) catch |err| return s.post(.{ .kind = .failed, .message = @errorName(err), .background = bg });
        s.post(.{ .kind = .ready, .version = update.version, .background = bg });
    }

    /// Hands a state to the main thread, which tells every page.
    fn post(s: *Service, state: State) void {
        if (s.stopping.load(.acquire)) return;
        const msg = s.gpa.create(Msg) catch return;
        msg.* = .{ .svc = s, .arena = .init(s.gpa), .state = state };
        const a = msg.arena.allocator();
        msg.state.version = a.dupe(u8, state.version) catch "";
        msg.state.notes = a.dupe(u8, state.notes) catch "";
        msg.state.message = a.dupe(u8, state.message) catch "";
        if (!mainthread.post(msg, deliver)) {
            msg.arena.deinit();
            s.gpa.destroy(msg);
        }
    }

    fn deliver(ctx: ?*anyopaque) callconv(.c) void {
        const msg: *Msg = @ptrCast(@alignCast(ctx));
        const s = msg.svc;
        defer {
            msg.arena.deinit();
            s.gpa.destroy(msg);
        }
        // "checked": the time of a check, kept, not shown.
        if (std.mem.eql(u8, msg.state.message, "checked")) {
            s.prefs.lastCheck = @intCast(msg.state.done);
            s.prefs.save(s.app.io, s.prefs_path) catch {};
            return;
        }
        StateEvent.broadcast(s.app, msg.state);
        if (s.listener) |l| l.state(l.ctx, msg.state);
    }
};

test {
    std.testing.refAllDecls(Service);
}
