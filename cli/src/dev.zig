//! `myzig dev`: builds the app, writes its client, runs it, and watches its
//! files: a change rebuilds it, and the new build replaces the running one
//! (which quits first, so the two never hold the same files at once). A
//! build that fails keeps the running app. With a dev server
//! (`dev_command`, `dev_url`), the frontend is the server's to reload: the
//! app loads `dev_url` (`MYZIG_DEV_URL`) and only Zig changes rebuild it.
//! Quitting the app ends `myzig dev`.
const std = @import("std");
const builtin = @import("builtin");
const fsx = @import("fsx.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const appbuild = @import("appbuild.zig");
const watch = @import("watch.zig");
const Running = @import("child.zig").Running;
const waitForServer = @import("child.zig").waitForServer;
const Ctx = fsx.Ctx;

pub const Options = struct {
    dir: []const u8 = ".",
    /// Don't run dev_command (its server already runs).
    skip_dev_command: bool = false,
    /// Arguments passed to the app.
    app_args: []const []const u8 = &.{},
};

/// How long changes settle before a rebuild, in milliseconds: an editor's
/// save, or a branch switch, is many changes at once.
const settle_ms = 150;
/// How often the loop looks whether the app quit, in milliseconds.
const exit_check_ms = 1000;
/// What an app built for dev exits with to be started again
/// (`App.relaunch` under `MYZIG_DEV`).
const relaunch_code = 75;

pub fn run(base: Ctx, o: Options) !void {
    const c = try config.load(base, o.dir);
    const ctx = base;
    var env = try ctx.env.clone(ctx.gpa);
    try env.put("MYZIG_DEV", "1");
    if (c.dev_url.len > 0) try env.put("MYZIG_DEV_URL", c.dev_url);

    var server: ?Running = null;
    defer if (server) |*s| s.stop(ctx);
    if (c.dev_command.len > 0 and !o.skip_dev_command) {
        ctx.log("Running {s}", .{c.dev_command});
        const sh = proc.shell(c.dev_command);
        server = try Running.start(ctx, &sh, c.root, &env);
    }
    if (c.dev_url.len > 0) {
        ctx.log("Waiting for {s}", .{c.dev_url});
        waitForServer(ctx, c.dev_url, if (server) |*s| s else null) catch |e| {
            std.debug.print("error: {s} did not answer ({t})\n", .{ c.dev_url, e });
            return e;
        };
    }

    // The frontend is watched when the app embeds it, not when a dev
    // server serves it.
    var ignored: std.ArrayList([]const u8) = .empty;
    try ignored.append(ctx.gpa, c.out);
    if (c.dev_url.len > 0 and c.frontend.len > 0) try ignored.append(ctx.gpa, c.frontend);
    const watcher = try watch.Watcher.init(ctx, c.root, .{ .paths = ignored.items });
    defer watcher.deinit();

    var app: ?Running = null;
    defer if (app) |*a| a.stop(ctx);
    // The executable that runs, kept across rounds for relaunches.
    var running_exe: ?[]u8 = null;
    defer if (running_exe) |e| ctx.gpa.free(e);
    // Two install prefixes taken in turn: a build never overwrites the
    // executable that runs (Windows keeps it locked).
    var slot: u1 = 0;
    var first = true;
    while (true) {
        var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
        defer arena.deinit();
        var round = ctx;
        round.gpa = arena.allocator();
        if (rebuild(round, c, slot)) |exe| {
            if (app) |*a| a.stop(round);
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(round.gpa, exe);
            try argv.appendSlice(round.gpa, o.app_args);
            ctx.log("{s} {s}", .{ if (first) "Starting" else "Restarting", c.name });
            app = try Running.start(ctx, argv.items, c.root, &env);
            if (running_exe) |old| ctx.gpa.free(old);
            running_exe = try ctx.gpa.dupe(u8, exe);
            slot +%= 1;
            first = false;
        } else |e| switch (e) {
            error.BuildFailed, error.GenerateFailed => ctx.log("The build failed; {s}", .{if (app != null) "the app keeps running, fix it and save" else "fix it and save"}),
            else => return e,
        }
        // Sleep until a file changes or the app quits.
        while (true) {
            if (try watcher.wait(exit_check_ms)) |path| {
                while (try watcher.wait(settle_ms)) |_| {}
                ctx.log("Changed: {s}", .{if (path.len > 0) path else "many files"});
                break;
            }
            if (app) |*a| if (a.exited(ctx)) {
                // `App.relaunch` under dev: the same build, started again.
                if (a.code == relaunch_code) if (running_exe) |exe| {
                    ctx.log("Relaunching {s}", .{c.name});
                    var argv: std.ArrayList([]const u8) = .empty;
                    try argv.append(round.gpa, exe);
                    try argv.appendSlice(round.gpa, o.app_args);
                    app = try Running.start(ctx, argv.items, c.root, &env);
                    continue;
                };
                ctx.log("{s} quit", .{c.name});
                app = null;
                return;
            };
            if (server) |*s| if (s.exited(ctx)) {
                std.debug.print("error: {s} ended\n", .{c.dev_command});
                server = null;
                return error.DevCommandExited;
            };
        }
    }
}

/// Builds the app into the slot's prefix and writes its client; returns
/// the executable.
fn rebuild(ctx: Ctx, c: config.Config, slot: u1) ![]u8 {
    _ = try appbuild.prepareFrontend(ctx, c);
    const declared = try proc.BuildOptions.read(ctx, c.root);
    const prefix = try ctx.join(&.{ c.root, ".myzig", "dev", if (slot == 0) "a" else "b" });
    ctx.log("Building {s}", .{c.name});
    const exe = try appbuild.build(ctx, c, declared, .{ .prefix = prefix });
    if (try appbuild.clientDir(ctx, c)) |dir| try appbuild.writeClient(ctx, exe, dir);
    return exe;
}
