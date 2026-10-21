//! What the app's schemes serve pages, the same on every platform: the
//! app's handlers for its own schemes, and for `myzig://` the frontend
//! (files of `assets_dir`, then `assets`, and the generated `/myzig.js`),
//! with client-side routes falling back to `/index.html`.
const std = @import("std");
const types = @import("page_types.zig");
const core_mod = @import("page_core.zig");
const mimeType = @import("window_types.zig").mimeType;

/// Answers `req` for `scheme`. `page_url` is the URL of the page asking:
/// a trusted page of another origin may read the answer (CORS).
pub fn dispatch(core: *core_mod.Core, app: anytype, req: *types.SchemeRequest, scheme: []const u8, page_url: ?[]const u8) void {
    if (page_url) |u| if (core.isTrusted(u)) {
        var buf: [core_mod.max_origin]u8 = undefined;
        const origin = core_mod.originOf(&buf, u);
        if (origin.len > 0) {
            req.addHeader("Access-Control-Allow-Origin", origin);
            req.addHeader("Access-Control-Expose-Headers", "*");
            if (std.mem.eql(u8, req.method, "OPTIONS")) {
                req.addHeader("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE");
                req.addHeader("Access-Control-Allow-Headers", "*");
                return req.respond(204, &.{}, "");
            }
        }
    };
    for (core.options.schemes) |s| if (std.ascii.eqlIgnoreCase(s.name, scheme)) return s.handler.func(s.handler.ctx, req);
    if (std.ascii.eqlIgnoreCase(scheme, "myzig")) return serveFrontend(core, app, req);
    notFound(req);
}

pub fn notFound(req: *types.SchemeRequest) void {
    req.respond(404, &.{.{ .name = "Content-Type", .value = "text/plain; charset=utf-8" }}, "Not Found");
}

fn serveFrontend(core: *core_mod.Core, app: anytype, req: *types.SchemeRequest) void {
    var path_buf: [4096]u8 = undefined;
    const gpa = app.gpa;
    const long_path = if (req.path.len > path_buf.len) gpa.alloc(u8, req.path.len) catch return notFound(req) else null;
    defer if (long_path) |bytes| gpa.free(bytes);
    const decoded = frontendPath(long_path orelse &path_buf, req.path) orelse return notFound(req);
    const path = if (std.mem.eql(u8, decoded, "/")) "/index.html" else decoded;
    if (std.mem.eql(u8, path, "/myzig.js")) {
        const js = app.clientJs() catch return notFound(req);
        return ok(req, js, mimeType(path));
    }
    // A client-side route: a path without an extension that is no file.
    const route = std.fs.path.extension(path).len == 0;
    if (core.assets_dir) |dir| {
        if (readAsset(app, dir, path) orelse if (route) readAsset(app, dir, "/index.html") else null) |data| {
            defer app.gpa.free(data);
            return ok(req, data, mimeType(if (route and !std.mem.eql(u8, path, "/index.html")) "/index.html" else path));
        }
    }
    if (findAsset(core.options.assets, path)) |a| return ok(req, a.data, a.mime orelse mimeType(path));
    if (route) if (findAsset(core.options.assets, "/index.html")) |a| return ok(req, a.data, a.mime orelse mimeType("/index.html"));
    notFound(req);
}

/// Decode exactly once, then validate before either disk lookup or SPA fallback.
fn frontendPath(buf: []u8, raw: []const u8) ?[]const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < raw.len) {
        if (n == buf.len) return null;
        if (raw[i] == '%') {
            if (raw.len - i < 3) return null;
            const hi = std.fmt.charToDigit(raw[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(raw[i + 2], 16) catch return null;
            buf[n] = hi * 16 + lo;
            i += 3;
        } else {
            buf[n] = raw[i];
            i += 1;
        }
        n += 1;
    }
    const path = buf[0..n];
    return if (safePath(path)) path else null;
}

fn ok(req: *types.SchemeRequest, data: []const u8, mime: []const u8) void {
    req.respond(200, &.{ .{ .name = "Content-Type", .value = mime }, .{ .name = "Cache-Control", .value = "no-cache" } }, data);
}

fn findAsset(assets: anytype, path: []const u8) ?@import("window_types.zig").Asset {
    for (assets) |a| if (std.mem.eql(u8, a.path, path)) return a;
    return null;
}

/// A file of the assets directory, never outside it.
fn readAsset(app: anytype, dir: []const u8, path: []const u8) ?[]u8 {
    if (!safePath(path)) return null;
    var buf: [1024]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}{s}", .{ std.mem.trimEnd(u8, dir, "/\\"), path }) catch return null;
    return std.Io.Dir.cwd().readFileAlloc(app.io, full, app.gpa, .limited(256 << 20)) catch null;
}

/// A path of plain segments: no "..", no backslashes, no drive.
pub fn safePath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    if (std.mem.indexOfAny(u8, path, "\\:\x00") != null) return false;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return false;
    return true;
}

/// `url` with a URL of an app scheme in the form the web view loads: on
/// Windows `http://<scheme>.localhost/...`, elsewhere as it is.
pub fn webUrl(buf: []u8, options: anytype, url: []const u8) []const u8 {
    if (!core_mod.scheme_hosts) return url;
    const sep = std.mem.indexOf(u8, url, "://localhost") orelse return url;
    const rest = url[sep + "://localhost".len ..];
    if (rest.len > 0 and rest[0] != '/' and rest[0] != '?' and rest[0] != '#') return url;
    if (!core_mod.isAppScheme(options, url[0..sep])) return url;
    return std.fmt.bufPrint(buf, "http://{s}.localhost{s}", .{ url[0..sep], rest }) catch url;
}

/// The reverse of `webUrl`: `<scheme>://localhost/...` for what the web view shows.
pub fn appUrl(buf: []u8, options: anytype, url: []const u8) []const u8 {
    if (!core_mod.scheme_hosts or !std.mem.startsWith(u8, url, "http://")) return url;
    const host_end = std.mem.indexOfAnyPos(u8, url, 7, "/?#") orelse url.len;
    const host = url[7..host_end];
    if (!std.mem.endsWith(u8, host, ".localhost")) return url;
    const scheme = host[0 .. host.len - ".localhost".len];
    if (!core_mod.isAppScheme(options, scheme)) return url;
    return std.fmt.bufPrint(buf, "{s}://localhost{s}", .{ scheme, url[host_end..] }) catch url;
}

/// The file: URL of an absolute path ("C:\a b.html" → "file:///C:/a%20b.html").
pub fn fileUrl(buf: []u8, path: []const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(if (path.len > 0 and path[0] == '/') "file://" else "file:///") catch return null;
    for (path) |ch| switch (ch) {
        '\\' => w.writeByte('/') catch return null,
        ' ', '#', '?', '%' => w.print("%{X:0>2}", .{ch}) catch return null,
        else => w.writeByte(ch) catch return null,
    };
    return w.buffered();
}

test "file URLs" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("file:///C:/a%20b/c.html", fileUrl(&buf, "C:\\a b\\c.html").?);
    try std.testing.expectEqualStrings("file:///tmp/x%23.html", fileUrl(&buf, "/tmp/x#.html").?);
}

test "safe paths" {
    try std.testing.expect(safePath("/index.html"));
    try std.testing.expect(safePath("/a/b.js"));
    try std.testing.expect(!safePath("/../secret"));
    try std.testing.expect(!safePath("/a/./b"));
    try std.testing.expect(!safePath("/C:/x"));
    try std.testing.expect(!safePath("/a\\..\\b"));
}

test "frontend asset URLs decode once and reject unsafe paths" {
    const t = std.testing;
    const App = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        fn clientJs(_: *@This()) ![]const u8 {
            return "client";
        }
    };
    const Response = struct {
        status: u16 = 0,
        body: [64]u8 = undefined,
        len: usize = 0,
        fn begin(_: *anyopaque, _: *types.SchemeRequest) void {}
        fn finish(ctx: *anyopaque, req: *types.SchemeRequest) void {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            r.status = req.status;
            r.len = req.buffer.items.len;
            @memcpy(r.body[0..r.len], req.buffer.items);
            req.destroy();
        }
    };
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "disk name.txt", .data = "disk" });
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    var app: App = .{ .gpa = t.allocator, .io = t.io };
    var window: u8 = 0;
    var core: core_mod.Core = .{
        .gpa = t.allocator,
        .window = &window,
        .token = undefined,
        .assets_dir = dir,
        .options = .{ .assets = &.{
            .{ .path = "/index.html", .data = "index" },
            .{ .path = "/hello world.txt", .data = "space" },
            .{ .path = "/caf\xc3\xa9.txt", .data = "unicode" },
            .{ .path = "/a+b.txt", .data = "plus" },
            .{ .path = "/%2e%2e.txt", .data = "literal" },
        } },
    };
    defer core.deinit();
    const long_route = try t.allocator.alloc(u8, 5001);
    defer t.allocator.free(long_route);
    @memset(long_route, 'a');
    long_route[0] = '/';
    const Case = struct { path: []const u8, status: u16 = 200, body: []const u8 = "Not Found" };
    const cases = [_]Case{
        .{ .path = "/hello%20world.txt", .body = "space" },
        .{ .path = "/disk%20name.txt", .body = "disk" },
        .{ .path = "/caf%C3%A9.txt", .body = "unicode" },
        .{ .path = "/a+b.txt", .body = "plus" },
        .{ .path = "/%252e%252e.txt", .body = "literal" },
        .{ .path = "/some%20route", .body = "index" },
        .{ .path = long_route, .body = "index" },
        .{ .path = "/%2e%2e/secret", .status = 404 },
        .{ .path = "/a%2f..%2fsecret", .status = 404 },
        .{ .path = "/a%5c..%5csecret", .status = 404 },
        .{ .path = "/C%3a/secret", .status = 404 },
        .{ .path = "/nul%00.txt", .status = 404 },
        .{ .path = "/bad%2", .status = 404 },
        .{ .path = "/bad%zz", .status = 404 },
    };
    for (cases) |c| {
        const url = try std.mem.concat(t.allocator, u8, &.{ "myzig://localhost", c.path });
        defer t.allocator.free(url);
        var response: Response = .{};
        const req = try types.SchemeRequest.create(t.allocator, "GET", url, "", .{ .ctx = &response, .begin = Response.begin, .write = null, .finish = Response.finish });
        dispatch(&core, &app, req, "myzig", null);
        try t.expectEqual(c.status, response.status);
        try t.expectEqualStrings(c.body, response.body[0..response.len]);
    }
}

test "URLs of app schemes" {
    const S = struct {
        fn h(_: ?*anyopaque, _: *types.SchemeRequest) void {}
    };
    const o: @import("window_types.zig").PageOptions = .{ .schemes = &.{.{ .name = "app", .handler = .{ .ctx = null, .func = S.h } }} };
    var buf: [128]u8 = undefined;
    var buf2: [128]u8 = undefined;
    const web = webUrl(&buf, o, "app://localhost/a?b");
    if (core_mod.scheme_hosts) {
        try std.testing.expectEqualStrings("http://app.localhost/a?b", web);
        try std.testing.expectEqualStrings("app://localhost/a?b", appUrl(&buf2, o, web));
        try std.testing.expectEqualStrings("http://other.localhost/", appUrl(&buf2, o, "http://other.localhost/"));
    } else {
        try std.testing.expectEqualStrings("app://localhost/a?b", web);
    }
    try std.testing.expectEqualStrings("https://a.org/", webUrl(&buf, o, "https://a.org/"));
}
