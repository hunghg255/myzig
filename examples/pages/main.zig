//! The pages test: a hidden page and the app check each other. The page
//! (frontend/test.js) calls services, fetches the app's scheme, streams
//! through channels both ways, asks for a permission, opens a window and
//! downloads a file; then Zig evaluates scripts for their results, finds
//! text, prints to PDF, sets and deletes cookies, adds a user script and
//! loads an untrusted document, which may not call Zig. It prints
//! "page: ok" (or "page: FAIL ...") and quits: `zig build test-pages`.
const std = @import("std");
const myzig = @import("myzig");

const Line = struct { text: []const u8 };
const Logs = myzig.ChannelKind("logs", Line);
const Downloaded = myzig.Event("downloaded", struct { ok: bool });

var app: *myzig.App = undefined;
var window: *myzig.Window = undefined;
var temp_dir: []u8 = &.{};
/// `MYZIG_MEMORY_PROBE`: which probe the page runs instead of the test.
var probe_mode: []const u8 = "";

/// What the page's listener saw.
const Seen = struct {
    load_started: u32 = 0,
    load_finished: u32 = 0,
    title: [64]u8 = undefined,
    title_len: usize = 0,
    permission: bool = false,
    opened: bool = false,
    download_path: [512]u8 = undefined,
    download_len: usize = 0,
    logs_opened: bool = false,
    waiting_title: ?[]const u8 = null,
    /// The profile does not remember an answer from an earlier run.
    permission_default: bool = false,
};
var seen: Seen = .{};

var ended = false;

fn fail(comptime fmt: []const u8, args: anytype) void {
    if (ended) return;
    std.debug.print("page: FAIL " ++ fmt ++ "\n", args);
    end();
}

/// Closes the window once: the app quits.
fn end() void {
    if (ended) return;
    ended = true;
    // Not from inside the engine's callback that got here: on the next turn.
    myzig.App.after(0, null, struct {
        fn f(_: ?*anyopaque) callconv(.c) void {
            window.close();
        }
    }.f);
}

const Test = struct {
    iframe_calls: u32 = 0,
    uploaded_buf: [64]u8 = undefined,
    uploaded_len: usize = 0,
    flood_sent: u32 = 0,

    pub const myzig_params = .{ .count = .{ "n", "into" }, .upload = .{"from"}, .flood = .{"into"} };

    pub fn permissionWas(_: *Test, state: []const u8) void {
        seen.permission_default = std.mem.eql(u8, state, "default");
    }

    pub fn ping(_: *Test) []const u8 {
        return "pong";
    }

    pub fn echo(_: *Test, value: []const u8) []const u8 {
        return value;
    }

    /// Restore and reduce memory without hiding scripts or replacing the document.
    pub fn memoryPolicy(_: *Test) ?bool {
        if (comptime @import("builtin").os.tag == .windows) {
            const p = window.page orelse return false;
            const state = &p.memory_target;
            if (state.unsupported) return null;
            if (state.applied != .low) return false;
            _ = @import("memory.zig").target(window, true) catch return false;
            _ = @import("memory.zig").target(window, false) catch return false;
            return true;
        }
        return null;
    }

    pub fn memoryMode(_: *Test) []const u8 {
        return probe_mode;
    }

    pub fn memoryTarget(_: *Test, normal: bool) !?i32 {
        return @import("memory.zig").target(window, normal);
    }

    pub fn iframeProbe(self: *Test) void {
        self.iframe_calls += 1;
    }

    pub fn iframeCalls(self: *Test) u32 {
        return self.iframe_calls;
    }

    /// Sends 0..n-1, then closes the channel.
    pub fn count(_: *Test, n: u32, into: myzig.Channel(u32)) !void {
        for (0..n) |i| try into.send(@intCast(i));
        into.close();
    }

    pub fn upload(self: *Test, from: myzig.Channel([]const u8)) void {
        self.uploaded_len = 0;
        from.onMessage(self, gotUpload);
    }

    fn gotUpload(self: *Test, _: myzig.Channel([]const u8), v: []const u8) void {
        if (self.uploaded_len > 0) self.append(",");
        self.append(v);
    }

    fn append(self: *Test, s: []const u8) void {
        const n = @min(s.len, self.uploaded_buf.len - self.uploaded_len);
        @memcpy(self.uploaded_buf[self.uploaded_len..][0..n], s[0..n]);
        self.uploaded_len += n;
    }

    pub fn uploaded(self: *Test) []const u8 {
        return self.uploaded_buf[0..self.uploaded_len];
    }

    /// Sends big values until the page's window is full, and "drained"
    /// once it took them.
    pub fn flood(self: *Test, into: myzig.Channel([]const u8)) u32 {
        const big: [65536]u8 = @splat(0x78);
        self.flood_sent = 0;
        while (true) {
            into.send(&big) catch break;
            self.flood_sent += 1;
        }
        into.onDrain(self, drained);
        return self.flood_sent;
    }

    fn drained(_: *Test, ch: myzig.Channel([]const u8)) void {
        ch.send("drained") catch return fail("send after drain", .{});
        ch.close();
    }

    /// The page is done: Zig's half.
    pub fn zigChecks(_: *Test) void {
        if (seen.permission_default and !seen.permission) return fail("no permission request", .{});
        if (!seen.opened) return fail("no new window request", .{});
        if (seen.load_started == 0 or seen.load_finished == 0) return fail("load events {d} {d}", .{ seen.load_started, seen.load_finished });
        if (!std.mem.eql(u8, seen.title[0..seen.title_len], "Pages")) return fail("title {s}", .{seen.title[0..seen.title_len]});
        myzig.App.after(0, null, checkEval);
    }
};

// Zig's half, a step per callback.

fn expectEval(js: []const u8, comptime next: fn (myzig.EvalResult) void) void {
    window.evalResult(js, myzig.EvalCallback{ .ctx = null, .func = struct {
        fn f(_: ?*anyopaque, r: myzig.EvalResult) void {
            next(r);
        }
    }.f });
}

fn checkEval(_: ?*anyopaque) callconv(.c) void {
    expectEval("document.title", struct {
        fn f(r: myzig.EvalResult) void {
            if (r != .ok or !std.mem.eql(u8, r.ok, "\"Pages\"")) return fail("eval title {any}", .{r});
            expectEval("new Promise((r) => setTimeout(() => r({ n: 41 + 1 }), 0))", struct {
                fn g(r2: myzig.EvalResult) void {
                    if (r2 != .ok or !std.mem.eql(u8, r2.ok, "{\"n\":42}")) return fail("eval promise {any}", .{r2});
                    expectEval("(() => { throw new Error('boom') })()", struct {
                        fn h(r3: myzig.EvalResult) void {
                            if (r3 != .err or std.mem.indexOf(u8, r3.err, "boom") == null) return fail("eval error {any}", .{r3});
                            checkEvalSerialization();
                        }
                    }.h);
                }
            }.g);
        }
    }.f);
}

fn checkEvalSerialization() void {
    expectEval("1n", struct {
        fn bigint(r: myzig.EvalResult) void {
            if (r != .err or r.err.len == 0) return fail("eval bigint {any}", .{r});
            expectEval("(() => { const v = {}; v.self = v; return v; })()", struct {
                fn cyclic(r2: myzig.EvalResult) void {
                    if (r2 != .err or r2.err.len == 0) return fail("eval cyclic {any}", .{r2});
                    expectEval("42", struct {
                        fn recovered(r3: myzig.EvalResult) void {
                            if (r3 != .ok or !std.mem.eql(u8, r3.ok, "42")) return fail("eval recovery {any}", .{r3});
                            checkFind();
                        }
                    }.recovered);
                }
            }.cyclic);
        }
    }.bigint);
}

fn checkFind() void {
    window.page.?.findInPage("needle", .{}, .{ .ctx = null, .func = struct {
        fn f(_: ?*anyopaque, r: ?myzig.page.FindResult) void {
            const res = r orelse return fail("find", .{});
            if (res.matches != 3 or res.active != 1) return fail("find {d} {d}", .{ res.matches, res.active });
            window.page.?.findInPage("needle", .{ .find_next = true, .match_case = true }, .{ .ctx = null, .func = struct {
                fn g(_: ?*anyopaque, r2: ?myzig.page.FindResult) void {
                    const res2 = r2 orelse return fail("find next", .{});
                    if (res2.matches != 2 or res2.active != 1) return fail("find case {d} {d}", .{ res2.matches, res2.active });
                    window.page.?.stopFind();
                    checkPdf();
                }
            }.g });
        }
    }.f });
}

fn checkPdf() void {
    window.page.?.printToPdf(.{ .background = true }, .{ .ctx = null, .func = struct {
        fn f(_: ?*anyopaque, pdf: ?[]const u8, err: ?[]const u8) void {
            const bytes = pdf orelse return fail("pdf: {s}", .{err orelse "?"});
            if (!std.mem.startsWith(u8, bytes, "%PDF")) return fail("pdf bytes", .{});
            checkCookies();
        }
    }.f });
}

fn checkCookies() void {
    window.page.?.setCookie(.{ .name = "flavor", .value = "oat", .domain = "example.com", .path = "/" }, .{ .ctx = null, .func = struct {
        fn f(_: ?*anyopaque, err: ?[]const u8) void {
            if (err) |e| return fail("set cookie: {s}", .{e});
            window.page.?.listCookies(null, .{ .ctx = null, .func = listed });
        }
    }.f });
}

fn findCookie(cookies: []const myzig.page.Cookie) bool {
    for (cookies) |c| if (std.mem.eql(u8, c.name, "flavor") and std.mem.eql(u8, c.value, "oat")) return true;
    return false;
}

fn listed(_: ?*anyopaque, cookies: ?[]const myzig.page.Cookie, err: ?[]const u8) void {
    const list = cookies orelse return fail("list cookies: {s}", .{err orelse "?"});
    if (!findCookie(list)) return fail("the cookie set is not listed ({d} cookies)", .{list.len});
    window.page.?.deleteCookie("flavor", "example.com", "/", .{ .ctx = null, .func = struct {
        fn f(_: ?*anyopaque, e: ?[]const u8) void {
            if (e) |x| return fail("delete cookie: {s}", .{x});
            window.page.?.listCookies(null, .{ .ctx = null, .func = struct {
                fn g(_: ?*anyopaque, c2: ?[]const myzig.page.Cookie, e2: ?[]const u8) void {
                    const l2 = c2 orelse return fail("list cookies again: {s}", .{e2 orelse "?"});
                    if (findCookie(l2)) return fail("the cookie deleted is listed", .{});
                    checkUntrusted();
                }
            }.g });
        }
    }.f });
}

/// A user script, a user agent and zoom, in a document of another origin,
/// which may not call Zig: it tells its findings in its title.
fn checkUntrusted() void {
    const p = window.page.?;
    _ = p.addUserScript(.{ .source = "window.__added = 7;" }) catch return fail("add script", .{});
    p.setUserAgent("myzig-test/1");
    p.setZoom(1.25);
    if (@abs(p.zoom() - 1.25) > 0.01) return fail("zoom {d}", .{p.zoom()});
    seen.waiting_title = "untrusted script agent";
    p.loadHtml(
        \\<!doctype html><title>loading</title><script>
        \\const t = [];
        \\myzig.call("Test.ping").then(() => t.push("trusted"), (e) => { if (String(e).includes("Untrusted")) t.push("untrusted"); })
        \\  .then(() => { if (window.__added === 7) t.push("script");
        \\    if (navigator.userAgent === "myzig-test/1") t.push("agent");
        \\    document.title = t.join(" "); });
        \\</script>
    , "https://example.com/");
}

fn finish() void {
    // The download, where the listener put it.
    const path = seen.download_path[0..seen.download_len];
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1024)) catch return fail("read download {s}", .{path});
    defer app.gpa.free(data);
    std.Io.Dir.cwd().deleteFile(app.io, path) catch {};
    if (!std.mem.eql(u8, data, "downloaded bytes")) return fail("download content {s}", .{data});
    if (ended) return;
    std.debug.print("page: ok\n", .{});
    end();
}

fn onPage(_: *Seen, w: *myzig.Window, e: myzig.PageEvent) void {
    switch (e) {
        .load_started => seen.load_started += 1,
        .load_finished => seen.load_finished += 1,
        .title_changed => |t| {
            if (seen.waiting_title) |want| {
                if (std.mem.eql(u8, t, "loading")) return;
                seen.waiting_title = null;
                if (!std.mem.eql(u8, t, want)) return fail("untrusted page: {s}", .{t});
                return finish();
            }
            const n = @min(t.len, seen.title.len);
            @memcpy(seen.title[0..n], t[0..n]);
            seen.title_len = n;
        },
        .dom_ready => if (!seen.logs_opened) {
            seen.logs_opened = true;
            const ch = Logs.open(w) catch return fail("open logs", .{});
            ch.send(.{ .text = "hello" }) catch return fail("send logs", .{});
            ch.send(.{ .text = "world" }) catch return fail("send logs", .{});
            ch.close();
        },
        .permission => |req| {
            if (req.kinds.len == 1 and req.kinds[0] == .notifications) {
                seen.permission = true;
                req.allow = true;
            }
        },
        .new_window => |req| {
            if (std.mem.eql(u8, req.url, "https://example.org/opened")) seen.opened = true;
            req.handled = true; // never the system browser in a test
        },
        .download_started => |d| {
            const path = std.fmt.bufPrint(&seen.download_path, "{s}{c}myzig-pages-{s}", .{ temp_dir, std.fs.path.sep, d.suggested_name }) catch return;
            seen.download_len = path.len;
            d.path = path;
        },
        .download_done => |d| Downloaded.emit(w, .{ .ok = d.err == null and std.mem.eql(u8, d.path, seen.download_path[0..seen.download_len]) }),
        else => {},
    }
}

// The app's scheme.

var later: ?*myzig.SchemeRequest = null;

fn serveApp(_: ?*anyopaque, req: *myzig.SchemeRequest) void {
    if (std.mem.eql(u8, req.path, "/data.json"))
        return req.respond(200, &.{ .{ .name = "Content-Type", .value = "application/json" }, .{ .name = "X-Test", .value = "1" } }, "{\"hello\":\"scheme\"}");
    if (std.mem.eql(u8, req.path, "/later")) {
        // Answered in parts, on a later turn of the loop.
        req.begin(200, &.{.{ .name = "Content-Type", .value = "text/plain" }});
        req.write("part1");
        later = req;
        return myzig.App.after(0, null, answerLater);
    }
    if (std.mem.eql(u8, req.path, "/echo")) {
        var buf: [64]u8 = undefined;
        return req.respond(200, &.{.{ .name = "Content-Type", .value = "text/plain" }}, std.fmt.bufPrint(&buf, "{s} {s}", .{ req.method, req.body }) catch "");
    }
    req.respond(404, &.{}, "no");
}

fn answerLater(_: ?*anyopaque) callconv(.c) void {
    const req = later orelse return;
    later = null;
    req.write("part2");
    req.finish();
}

fn guard(_: ?*anyopaque) callconv(.c) void {
    // Turns a hang into a failure; the test never waits for it otherwise.
    fail("timed out", .{});
}

const assets = [_]myzig.Asset{
    .{ .path = "/index.html", .data = @embedFile("frontend/index.html") },
    .{ .path = "/test.js", .data = @embedFile("frontend/test.js") },
    .{ .path = "/memory.js", .data = @embedFile("frontend/memory.js") },
    .{ .path = "/ipc.js", .data = @embedFile("frontend/ipc.js") },
    .{ .path = "/embedded name.txt", .data = "embedded space" },
    .{ .path = "/caf\xc3\xa9.txt", .data = "unicode" },
};

pub fn main(init: std.process.Init) !void {
    probe_mode = init.environ_map.get("MYZIG_MEMORY_PROBE") orelse "";
    app = try myzig.App.create(init, .{ .name = "MyzigPagesTest" });
    defer app.destroy();
    var t: Test = .{};
    try app.bind(&t);
    try app.registerEvent(Logs);
    try app.registerEvent(Downloaded);

    // A frontend directory on disk, served before the embedded assets.
    temp_dir = try myzig.path(init.gpa, .temp, "MyzigPagesTest");
    defer init.gpa.free(temp_dir);
    const dir = try std.fmt.allocPrint(init.gpa, "{s}{c}myzig-pages-assets", .{ temp_dir, std.fs.path.sep });
    defer init.gpa.free(dir);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, dir);
    defer cwd.deleteTree(init.io, dir) catch {};
    var sub = try cwd.openDir(init.io, dir, .{});
    try sub.writeFile(init.io, .{ .sub_path = "fromdisk.txt", .data = "from disk" });
    try sub.writeFile(init.io, .{ .sub_path = "disk name.txt", .data = "disk space" });
    sub.close(init.io);

    window = try app.newWindow(.{
        .title = "Pages",
        .visible = false,
        .content = .{ .page = .{
            .url = "/",
            .assets = &assets,
            .assets_dir = dir,
            .schemes = &.{.{ .name = "app", .handler = .{ .ctx = null, .func = serveApp } }},
            .on_event = .of(&seen, onPage),
        } },
    });
    myzig.App.after(60_000, null, guard);
    try app.run();
}
