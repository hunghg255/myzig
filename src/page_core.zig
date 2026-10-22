//! What every platform's page shares: the options it resolved (the dev
//! server, the directory of assets), which origins it trusts, the scripts
//! evaluated for a result, its channels and user scripts, and the events
//! it tells the app about.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("page_types.zig");
const PageOptions = @import("window_types.zig").PageOptions;
const channels = @import("page_channel.zig");

/// Where WebView2 serves the app's schemes: `http://<scheme>.localhost`.
pub const scheme_hosts = builtin.os.tag == .windows;

const shell = switch (builtin.os.tag) {
    .windows => @import("windows/desktop.zig").shell,
    .linux => @import("linux/desktop.zig").shell,
    .macos => @import("desktop.zig").shell,
    else => struct {
        fn openUrl(_: []const u8) bool {
            return false;
        }
    },
};

pub const Core = struct {
    gpa: std.mem.Allocator,
    /// The platform's `*Window`, passed to listeners.
    window: *anyopaque,
    options: PageOptions,
    /// MYZIG_DEV_URL, else `options.dev_url`.
    dev_url: ?[]const u8 = null,
    /// MYZIG_ASSETS_DIR, else `options.assets_dir`.
    assets_dir: ?[]const u8 = null,
    /// Proves that a result comes from the bridge this page was given.
    token: [16]u8,
    evals: std.ArrayList(PendingEval) = .empty,
    next_eval: u32 = 1,
    channels: channels.Registry = .{},
    handles: std.ArrayList(*channels.Handle) = .empty,
    /// Counts documents: channels of an earlier one are gone.
    generation: u32 = 0,
    scripts: std.ArrayList(Script) = .empty,
    next_script: u32 = 1,
    zoom: f64 = 1,
    user_agent: ?[]u8 = null,

    pub const PendingEval = struct { id: u32, cb: types.EvalCallback };
    /// A user script, as the page runs it (wrapped for `at_document_end`).
    pub const Script = struct { id: u32, source: []u8, native: usize = 0 };

    pub fn init(gpa: std.mem.Allocator, window: *anyopaque, app: anytype, options: PageOptions) Core {
        var raw: [8]u8 = undefined;
        app.io.random(&raw);
        var c: Core = .{ .gpa = gpa, .window = window, .options = options, .token = std.fmt.bytesToHex(raw, .lower), .zoom = options.zoom };
        c.dev_url = env(app, "MYZIG_DEV_URL") orelse options.dev_url;
        c.assets_dir = env(app, "MYZIG_ASSETS_DIR") orelse options.assets_dir;
        for (options.user_scripts) |s| _ = c.addScript(s) catch {};
        if (options.user_agent) |ua| c.user_agent = gpa.dupe(u8, ua) catch null;
        return c;
    }

    pub fn deinit(c: *Core) void {
        c.failEvals("the page closed");
        c.evals.deinit(c.gpa);
        c.channels.deinit(c.gpa, .lost);
        c.freeHandles();
        c.handles.deinit(c.gpa);
        for (c.scripts.items) |s| c.gpa.free(s.source);
        c.scripts.deinit(c.gpa);
        if (c.user_agent) |ua| c.gpa.free(ua);
    }

    /// The options' user agent suffix, without the spaces around it.
    pub fn uaSuffix(c: *const Core) []const u8 {
        return std.mem.trim(u8, c.options.user_agent_suffix, " \t");
    }

    /// `ua` with the suffix after a space (`ua` alone without one).
    /// Caller frees it.
    pub fn withSuffix(c: *const Core, gpa: std.mem.Allocator, ua: []const u8) ![]u8 {
        return userAgentWithSuffix(gpa, ua, c.uaSuffix());
    }

    /// The URL a page loads for `url`: a path of the app's frontend is on
    /// the dev server while there is one.
    pub fn startUrl(c: *const Core, buf: []u8, url: []const u8) []const u8 {
        if (std.mem.indexOf(u8, url, "://") != null) return url;
        const dev = c.dev_url orelse return url;
        const base = std.mem.trimEnd(u8, dev, "/");
        if (url.len <= 1) return dev;
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ base, if (url[0] == '/') "" else "/", url }) catch dev;
    }

    pub fn fire(c: *Core, event: types.PageEvent) void {
        if (c.options.on_event) |l| l.func(l.ctx, c.window, event);
    }

    /// A new document: what belonged to the last one is gone.
    pub fn navigated(c: *Core) void {
        c.generation +%= 1;
        // Detach the old document before any callback can destroy the page.
        const gpa = c.gpa;
        var evals = c.evals;
        c.evals = .empty;
        var old_channels = c.channels;
        c.channels = .{ .next_id = old_channels.next_id };
        var handles = c.handles;
        c.handles = .empty;
        defer evals.deinit(gpa);
        defer {
            for (handles.items) |h| gpa.destroy(h);
            handles.deinit(gpa);
        }
        for (evals.items) |e| e.cb.func(e.cb.ctx, .{ .err = "the page navigated" });
        old_channels.deinit(gpa, .lost);
    }

    fn freeHandles(c: *Core) void {
        for (c.handles.items) |h| c.gpa.destroy(h);
        c.handles.clearRetainingCapacity();
    }

    // Trust.

    /// Whether the page at `url` may call bound services: the app's own
    /// schemes, file: and about: pages, the dev server, and the origins
    /// `trusted_origins` lists ("*" for all).
    pub fn isTrusted(c: *const Core, url: []const u8) bool {
        return trusted(c.options, c.dev_url, url);
    }

    // Evaluation.

    /// The script that evaluates `js`, an expression (a promise is
    /// awaited), and reports its value to `cb`.
    pub fn evalScript(c: *Core, js: []const u8, cb: types.EvalCallback) ![]u8 {
        const id = c.next_eval;
        const code = std.mem.trimEnd(u8, js, " \t\r\n;");
        const script = try c.gpa.print("window.__myzig&&__myzig.settle({d},\"{s}\",async()=>(\n{s}\n))", .{ id, &c.token, code });
        errdefer c.gpa.free(script);
        try c.evals.append(c.gpa, .{ .id = id, .cb = cb });
        c.next_eval +%= 1;
        return script;
    }

    /// A result from the bridge.
    pub fn settle(c: *Core, id: u64, token: []const u8, result: types.EvalResult) void {
        if (!std.mem.eql(u8, token, &c.token)) return;
        for (c.evals.items, 0..) |e, i| if (e.id == id) {
            _ = c.evals.orderedRemove(i);
            return e.cb.func(e.cb.ctx, result);
        };
    }

    pub fn failEvals(c: *Core, why: []const u8) void {
        const gpa = c.gpa;
        // A callback may evaluate again: that one fails too.
        while (c.evals.items.len > 0) {
            var pending = c.evals;
            c.evals = .empty;
            defer pending.deinit(gpa);
            for (pending.items) |e| e.cb.func(e.cb.ctx, .{ .err = why });
        }
    }

    // User scripts.

    pub fn addScript(c: *Core, s: types.UserScript) !*Script {
        const source = if (s.at_document_end)
            try c.gpa.print("document.readyState===\"loading\"?document.addEventListener(\"DOMContentLoaded\",()=>{{\n{s}\n}},{{once:true}}):(()=>{{\n{s}\n}})();", .{ s.source, s.source })
        else
            try c.gpa.dupe(u8, s.source);
        errdefer c.gpa.free(source);
        try c.scripts.append(c.gpa, .{ .id = c.next_script, .source = source });
        c.next_script += 1;
        return &c.scripts.items[c.scripts.items.len - 1];
    }

    /// Removes a script; its native handle is returned for the backend.
    pub fn removeScript(c: *Core, id: u32) ?usize {
        for (c.scripts.items, 0..) |s, i| if (s.id == id) {
            c.gpa.free(s.source);
            _ = c.scripts.orderedRemove(i);
            return s.native;
        };
        return null;
    }

    // Questions the page asks.

    /// Whether the page at `origin` gets `kinds`: the listener decides,
    /// else trusted pages get them.
    pub fn permission(c: *Core, kinds: []const types.Permission, origin: []const u8) bool {
        var req: types.PermissionRequest = .{ .kinds = kinds, .origin = origin, .allow = c.isTrusted(origin) };
        c.fire(.{ .permission = &req });
        return req.allow;
    }

    /// The page opens a window: the listener's, else the system browser's
    /// for web URLs.
    pub fn newWindow(c: *Core, url: []const u8) void {
        var req: types.NewWindow = .{ .url = url };
        c.fire(.{ .new_window = &req });
        if (req.handled) return;
        if (std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://"))
            _ = shell.openUrl(url);
    }

    /// Whether a navigation of the main frame may go on.
    pub fn willNavigate(c: *Core, url: []const u8, user: bool) bool {
        var nav: types.Navigate = .{ .url = url, .user_initiated = user };
        c.fire(.{ .will_navigate = &nav });
        return !nav.cancel;
    }

    /// Where a download goes (owned), or null when it is canceled: the
    /// listener's choice, else `dir` (the Downloads directory) and the
    /// suggested name, numbered when a file has it.
    pub fn startDownload(c: *Core, io: std.Io, dir: ?[]const u8, url: []const u8, suggested: []const u8) ?[]u8 {
        const gpa = c.gpa;
        const name = safeName(suggested);
        const default = if (dir) |d| uniquePath(gpa, io, d, name) catch null else null;
        defer if (default) |p| gpa.free(p);
        var e: types.DownloadStart = .{ .url = url, .suggested_name = name, .path = default orelse "" };
        c.fire(.{ .download_started = &e });
        if (e.cancel or e.path.len == 0) return null;
        return gpa.dupe(u8, e.path) catch null;
    }
};

fn env(app: anytype, comptime name: [:0]const u8) ?[]const u8 {
    if (@hasField(@TypeOf(app.*), "environ")) return app.environ.get(name);
    if (builtin.os.tag == .wasi or builtin.os.tag == .windows) return null;
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

/// Room for any origin `originOf` gives (a host is at most 253 bytes).
pub const max_origin = 1024;

/// `scheme://host[:port]` of a URL, lowercased into `buf` ("" when it
/// does not fit).
pub fn originOf(buf: []u8, url: []const u8) []const u8 {
    const origin = originSlice(url);
    if (origin.len > buf.len) return "";
    return std.ascii.lowerString(buf[0..origin.len], origin);
}

fn originSlice(url: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return url[0..0];
    var end = sep + 3;
    while (end < url.len and url[end] != '/' and url[end] != '?' and url[end] != '#') end += 1;
    return url[0..end];
}

fn schemeOf(url: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return "";
    return url[0..colon];
}

/// Whether `scheme` is one the app serves: myzig, or one of `options.schemes`.
pub fn isAppScheme(options: PageOptions, scheme: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(scheme, "myzig")) return true;
    for (options.schemes) |s| if (std.ascii.eqlIgnoreCase(s.name, scheme)) return true;
    return false;
}

pub fn trusted(options: PageOptions, dev_url: ?[]const u8, url: []const u8) bool {
    const scheme = schemeOf(url);
    if (std.ascii.eqlIgnoreCase(scheme, "blob")) return trusted(options, dev_url, url[scheme.len + 1 ..]);
    if (std.ascii.eqlIgnoreCase(scheme, "about") or std.ascii.eqlIgnoreCase(scheme, "file")) return true;
    if (isAppScheme(options, scheme)) return true;
    const origin = originSlice(url);
    if (origin.len == 0) return false;
    if (scheme_hosts and std.ascii.startsWithIgnoreCase(origin, "http://") and std.ascii.endsWithIgnoreCase(origin, ".localhost"))
        if (isAppScheme(options, origin["http://".len .. origin.len - ".localhost".len])) return true;
    if (dev_url) |d| {
        if (std.ascii.eqlIgnoreCase(originSlice(d), origin)) return true;
    }
    for (options.trusted_origins) |o| {
        if (std.mem.eql(u8, o, "*") or std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, o, "/"), origin)) return true;
    }
    return false;
}

/// The last part of a suggested file name, never empty or a directory.
pub fn safeName(suggested: []const u8) []const u8 {
    var name = suggested;
    if (std.mem.lastIndexOfAny(u8, name, "/\\")) |i| name = name[i + 1 ..];
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return "download";
    return name;
}

/// `dir/name`, numbered as "name (2).ext" when a file has that name.
pub fn uniquePath(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) ![]u8 {
    const sep = if (builtin.os.tag == .windows) "\\" else "/";
    const ext = std.fs.path.extension(name);
    const stem = name[0 .. name.len - ext.len];
    var i: u32 = 1;
    while (true) : (i += 1) {
        const p = if (i == 1)
            try gpa.print("{s}{s}{s}", .{ dir, sep, name })
        else
            try gpa.print("{s}{s}{s} ({d}){s}", .{ dir, sep, stem, i, ext });
        std.Io.Dir.cwd().access(io, p, .{}) catch return p;
        gpa.free(p);
        if (i > 9999) return error.NoName;
    }
}

const testing = std.testing;

/// `ua` and `suffix` joined by a space; `ua` alone without a suffix,
/// and the suffix alone without a user agent. Caller frees it.
pub fn userAgentWithSuffix(gpa: std.mem.Allocator, ua: []const u8, suffix: []const u8) ![]u8 {
    if (suffix.len == 0) return gpa.dupe(u8, ua);
    if (ua.len == 0) return gpa.dupe(u8, suffix);
    // Already there (a user agent read back from the web view).
    if (std.mem.endsWith(u8, ua, suffix) and ua.len > suffix.len and ua[ua.len - suffix.len - 1] == ' ') return gpa.dupe(u8, ua);
    return std.mem.concat(gpa, u8, &.{ ua, " ", suffix });
}

test "a user agent suffix appends once" {
    const gpa = std.testing.allocator;
    const cases = [_][3][]const u8{
        .{ "agent", "MyApp/1.2", "agent MyApp/1.2" },
        .{ "agent MyApp/1.2", "MyApp/1.2", "agent MyApp/1.2" },
        .{ "agent", "", "agent" },
        .{ "", "MyApp/1.2", "MyApp/1.2" },
    };
    for (cases) |c| {
        const got = try userAgentWithSuffix(gpa, c[0], c[1]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c[2], got);
    }
    const options: PageOptions = .{ .user_agent_suffix = "  MyApp/1.2 " };
    try std.testing.expectEqualStrings("MyApp/1.2", std.mem.trim(u8, options.user_agent_suffix, " \t"));
}

test "trusted origins" {
    const S = struct {
        fn h(_: ?*anyopaque, _: *types.SchemeRequest) void {}
    };
    const o: PageOptions = .{ .schemes = &.{.{ .name = "app", .handler = .{ .ctx = null, .func = S.h } }}, .trusted_origins = &.{"https://Example.com/"} };
    try testing.expect(trusted(o, null, "myzig://localhost/index.html"));
    try testing.expect(trusted(o, null, "app://localhost/x"));
    try testing.expect(trusted(o, null, "about:blank"));
    try testing.expect(trusted(o, null, "file:///tmp/a.html"));
    try testing.expect(trusted(o, null, "https://example.com/page"));
    try testing.expect(trusted(o, null, "blob:https://example.com/1234"));
    try testing.expect(!trusted(o, null, "https://example.com.evil.org/"));
    try testing.expect(!trusted(o, null, "http://example.com/"));
    try testing.expect(!trusted(o, null, "https://other.org/"));
    try testing.expect(trusted(o, "http://localhost:5173/", "http://localhost:5173/src/main.ts"));
    try testing.expect(!trusted(o, "http://localhost:5173/", "http://localhost:5174/"));
    try testing.expectEqual(scheme_hosts, trusted(o, null, "http://app.localhost/x"));
    try testing.expect(!trusted(o, null, "http://evil.localhost/x"));
    try testing.expect(trusted(.{ .trusted_origins = &.{"*"} }, null, "https://any.org/"));
}

test "origins, names and paths" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("https://a.org:8080", originOf(&buf, "HTTPS://A.org:8080/x?y"));
    try testing.expectEqualStrings("", originOf(&buf, "about:blank"));
    try testing.expectEqualStrings("report.pdf", safeName("../../report.pdf"));
    try testing.expectEqualStrings("download", safeName("dir\\"));
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const first = try uniquePath(testing.allocator, io, dir, "a.txt");
    defer testing.allocator.free(first);
    try testing.expect(std.mem.endsWith(u8, first, "a.txt"));
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "x" });
    const second = try uniquePath(testing.allocator, io, dir, "a.txt");
    defer testing.allocator.free(second);
    try testing.expect(std.mem.endsWith(u8, second, "a (2).txt"));
}

test "evaluations settle once, with the page's token" {
    const S = struct {
        var got: [32]u8 = undefined;
        var len: usize = 0;
        var calls: u32 = 0;
        fn cb(_: ?*anyopaque, r: types.EvalResult) void {
            calls += 1;
            const s = switch (r) {
                .ok => |v| v,
                .err => |e| e,
            };
            @memcpy(got[0..s.len], s);
            len = s.len;
        }
    };
    var w: u8 = 0;
    var c: Core = .{ .gpa = testing.allocator, .window = &w, .options = .{}, .token = "0123456789abcdef".* };
    defer c.deinit();
    const script = try c.evalScript("1 + 1;", .{ .ctx = null, .func = S.cb });
    defer testing.allocator.free(script);
    try testing.expectEqualStrings("window.__myzig&&__myzig.settle(1,\"0123456789abcdef\",async()=>(\n1 + 1\n))", script);
    c.settle(1, "wrong", .{ .ok = "2" });
    try testing.expectEqual(@as(u32, 0), S.calls);
    c.settle(1, "0123456789abcdef", .{ .ok = "2" });
    c.settle(1, "0123456789abcdef", .{ .ok = "3" });
    try testing.expectEqual(@as(u32, 1), S.calls);
    try testing.expectEqualStrings("2", S.got[0..S.len]);
    const again = try c.evalScript("x", .{ .ctx = null, .func = S.cb });
    defer testing.allocator.free(again);
    c.navigated();
    try testing.expectEqualStrings("the page navigated", S.got[0..S.len]);
}

test "a dev server serves the frontend's paths" {
    var w: u8 = 0;
    var c: Core = .{ .gpa = testing.allocator, .window = &w, .options = .{}, .token = undefined, .dev_url = "http://localhost:5173/" };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("http://localhost:5173/", c.startUrl(&buf, "/"));
    try testing.expectEqualStrings("http://localhost:5173/settings", c.startUrl(&buf, "/settings"));
    try testing.expectEqualStrings("https://a.org/", c.startUrl(&buf, "https://a.org/"));
}

test "navigation preserves evaluations created by cancellation callbacks" {
    const Probe = struct {
        core: *Core,
        calls: usize = 0,
        fn canceled(ctx: ?*anyopaque, result: types.EvalResult) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            std.debug.assert(result == .err);
            p.calls += 1;
            const next = p.core.evalScript("2", .{ .ctx = p, .func = done }) catch unreachable;
            p.core.gpa.free(next);
        }
        fn done(ctx: ?*anyopaque, result: types.EvalResult) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            std.debug.assert(result == .ok and std.mem.eql(u8, result.ok, "2"));
            p.calls += 1;
        }
    };
    var window: u8 = 0;
    var core: Core = .{ .gpa = testing.allocator, .window = &window, .options = .{}, .token = "0123456789abcdef".* };
    defer core.deinit();
    var probe: Probe = .{ .core = &core };
    const script = try core.evalScript("1", .{ .ctx = &probe, .func = Probe.canceled });
    defer testing.allocator.free(script);
    core.navigated();
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(@as(usize, 1), core.evals.items.len);
    core.settle(2, "0123456789abcdef", .{ .ok = "2" });
    try testing.expectEqual(@as(usize, 2), probe.calls);
}

test "trusted origins compare complete long authorities" {
    const a: [63]u8 = @splat('a');
    const b: [63]u8 = @splat('b');
    const c: [63]u8 = @splat('c');
    const d: [53]u8 = @splat('d');
    const prefix = "https://" ++ a ++ "." ++ b ++ "." ++ c ++ "." ++ d;
    const dev = prefix ++ ".com";
    const attacker = prefix ++ ".co";
    try testing.expect(!trusted(.{}, dev, attacker));
    try testing.expect(trusted(.{}, dev, dev ++ "/page"));
    try testing.expect(trusted(.{ .trusted_origins = &.{dev} }, null, dev ++ "/page"));
    var small: [256]u8 = undefined;
    try testing.expectEqualStrings("", originOf(&small, dev));
    var full: [512]u8 = undefined;
    try testing.expectEqualStrings(dev, originOf(&full, dev ++ "/page"));
}
