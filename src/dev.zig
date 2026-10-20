//! Command line flags for trying and testing apps without touching the
//! screen, the mouse or the keyboard:
//!
//!   --myzig-generate=DIR    write the generated client (myzig.js, myzig.d.ts) and exit
//!   --myzig-snapshot=PNG    render the first native UI window offscreen to PNG and exit
//!   --myzig-script=STEPS    with --myzig-snapshot: steps run first (see ui.Tester.runScript:
//!                            click, move, type, key, scroll, drag:A>B, wait, frames:N, live, resize)
//!   --myzig-dark            with --myzig-snapshot: the dark appearance
//!   --myzig-wait=SECONDS    with --myzig-snapshot: run the event loop that long first, so
//!                            processes, timers and replies the app waits for arrive
//!   --myzig-hidden          never show windows
//!   --myzig-eval=JS         evaluate JS in each page once its DOM is ready (implies hidden);
//!                            pages report with myzig.log() and finish with myzig.window.close()
const std = @import("std");
const ui = @import("ui/ui.zig");
const runFor = @import("platform.zig").runFor;

pub const Flags = struct {
    generate_dir: ?[]const u8 = null,
    snapshot: ?[]const u8 = null,
    script: []const u8 = "",
    dark: bool = false,
    hidden: bool = false,
    eval: ?[]const u8 = null,
    wait: f64 = 0,

    pub fn parse(init: std.process.Init) !Flags {
        const arena = init.arena.allocator();
        var f: Flags = .{};
        // Windows decodes its command line: that needs memory.
        for (try init.minimal.args.toSlice(arena)) |arg| {
            if (value(arg, "--myzig-generate=")) |v| f.generate_dir = try arena.dupe(u8, v);
            if (value(arg, "--myzig-snapshot=")) |v| f.snapshot = try arena.dupe(u8, v);
            if (value(arg, "--myzig-script=")) |v| f.script = try arena.dupe(u8, v);
            if (value(arg, "--myzig-eval=")) |v| f.eval = try arena.dupe(u8, v);
            if (value(arg, "--myzig-wait=")) |v| f.wait = std.fmt.parseFloat(f64, v) catch 0;
            if (std.mem.eql(u8, arg, "--myzig-dark")) f.dark = true;
            if (std.mem.eql(u8, arg, "--myzig-hidden")) f.hidden = true;
        }
        if (f.snapshot != null or f.eval != null or f.generate_dir != null) f.hidden = true;
        return f;
    }

    /// Whether the run is headless (a snapshot, evaluating pages, writing
    /// the client): the app's directories are then a temporary one's
    /// (`headless.zig`), so no user state is touched.
    pub fn headless(f: Flags) bool {
        return f.snapshot != null or f.eval != null or f.generate_dir != null;
    }

    fn value(arg: []const u8, comptime flag: []const u8) ?[]const u8 {
        return if (std.mem.startsWith(u8, arg, flag)) arg[flag.len..] else null;
    }
};

/// Renders the first window of native UI offscreen, after the script.
pub fn snapshot(app: anytype, path: []const u8) !void {
    // Live state first: the event loop runs, without a visible window.
    var waited: f64 = 0;
    while (waited < app.flags.wait) : (waited += 0.05) runFor(0.05);
    for (app.windows.items) |w| {
        const s = w.nativeView() orelse continue;
        var t: ui.Tester = undefined;
        try t.init(app.gpa, s.view, .{ .width = s.width, .height = s.height, .scale = s.scale, .dark = app.flags.dark, .theme = s.theme });
        defer t.deinit();
        const App = @TypeOf(app.*);
        if (@hasDecl(App, "accelerator")) t.accelerator = .{ .ctx = app, .run = struct {
            fn f(ctx: *anyopaque, sc: ui.Shortcut) bool {
                const a: *App = @ptrCast(@alignCast(ctx));
                return a.accelerator(sc);
            }
        }.f };
        t.settle(2);
        try t.runScript(app.flags.script);
        try t.screenshot(path);
        std.debug.print("myzig: wrote {s} ({d}x{d} points at {d}x)\n", .{ path, t.size.w, t.size.h, t.scale });
        return;
    }
    return error.NoNativeWindow;
}
