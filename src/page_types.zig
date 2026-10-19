//! What pages tell the app and ask it, the same on every platform: their
//! events (navigation, titles, downloads, permissions, new windows), the
//! schemes the app serves them, cookies, finding text and printing.
const std = @import("std");

/// What happened in a page, passed to `PageOptions.on_event`. Some events
/// ask a question: their listener answers in place (`e.permission.allow = true`).
pub const PageEvent = union(enum) {
    /// A navigation of the main frame is about to start; `cancel` stops it.
    will_navigate: *Navigate,
    /// The page started loading `url`.
    load_started: []const u8,
    /// The page's document changed to `url` (after redirects).
    committed: []const u8,
    load_finished: []const u8,
    load_failed: LoadError,
    title_changed: []const u8,
    /// The bridge is in the page and its DOM is ready.
    dom_ready,
    /// The page opens a window (`window.open`, `target=_blank`). Unless a
    /// listener handles it, http and https URLs open in the system browser.
    new_window: *NewWindow,
    /// The page asks for the camera, the microphone, the location or to
    /// notify. Without a listener the app's own (trusted) pages get it.
    permission: *PermissionRequest,
    /// A download starts: `path` is where it goes (the Downloads
    /// directory by default); set it, or `cancel`.
    download_started: *DownloadStart,
    download_progress: DownloadProgress,
    download_done: DownloadDone,
};

pub const Navigate = struct {
    url: []const u8,
    user_initiated: bool = false,
    cancel: bool = false,
};

pub const LoadError = struct {
    url: []const u8,
    code: i32,
    description: []const u8,
};

pub const NewWindow = struct {
    url: []const u8,
    handled: bool = false,
};

pub const Permission = enum { camera, microphone, geolocation, notifications };

pub const PermissionRequest = struct {
    /// Asked together, as the camera and microphone of a call.
    kinds: []const Permission,
    /// The origin of the page asking, e.g. "https://example.com".
    origin: []const u8,
    allow: bool,
};

pub const DownloadStart = struct {
    url: []const u8,
    suggested_name: []const u8,
    /// Where the file is saved; a listener may point it elsewhere (the
    /// string must live until the event returns: it is copied).
    path: []const u8,
    cancel: bool = false,
};

pub const DownloadProgress = struct {
    url: []const u8,
    received: u64,
    /// 0 when the server did not say.
    total: u64,
};

pub const DownloadDone = struct {
    url: []const u8,
    path: []const u8,
    /// Null when it succeeded.
    err: ?[]const u8 = null,
};

/// A listener of a page's events: `myzig.PageListener.of(&state, onPage)`
/// with `fn onPage(state: *State, window: *myzig.Window, event: myzig.PageEvent) void`.
pub const PageListener = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, window: *anyopaque, event: PageEvent) void,

    pub fn of(ptr: anytype, comptime func: anytype) PageListener {
        const P = @TypeOf(ptr);
        const W = @typeInfo(@TypeOf(func)).@"fn".param_types[1].?;
        return .{ .ctx = @ptrCast(ptr), .func = struct {
            fn call(c: *anyopaque, w: *anyopaque, e: PageEvent) void {
                func(@as(P, @ptrCast(@alignCast(c))), @as(W, @ptrCast(@alignCast(w))), e);
            }
        }.call };
    }
};

/// A script every document of the page runs (`Page.addUserScript`).
pub const UserScript = struct {
    source: []const u8,
    /// After the document's DOM is ready rather than before its scripts.
    at_document_end: bool = false,
};

/// The result of `evalResult`: the value as JSON, or the error's message.
/// Both live only while the callback runs.
pub const EvalResult = union(enum) {
    ok: []const u8,
    err: []const u8,
};

pub const EvalCallback = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, result: EvalResult) void,
};

// Schemes the app serves.

pub const Header = struct { name: []const u8, value: []const u8 };

/// A URL scheme served by the app (`PageOptions.schemes`): pages load
/// `<name>://localhost/...` (on Windows `http://<name>.localhost/...`,
/// which the app's handler answers all the same).
pub const Scheme = struct {
    name: []const u8,
    handler: SchemeHandler,
};

pub const SchemeHandler = struct {
    ctx: ?*anyopaque,
    /// Answers with `req.respond(...)`, now or later on the main thread.
    func: *const fn (ctx: ?*anyopaque, req: *SchemeRequest) void,
};

/// A request of a page for a scheme of the app, answered once with
/// `respond`, or in parts with `begin`, `write` and `finish`; it is freed
/// when answered. Main thread only.
pub const SchemeRequest = struct {
    gpa: std.mem.Allocator,
    /// "GET", "POST", ...
    method: []const u8,
    /// `<scheme>://localhost/path?query`, on every platform.
    url: []const u8,
    /// The path, without the query: "/data.json".
    path: []const u8,
    body: []const u8 = "",
    /// Set by the page's backend: where the answer goes.
    responder: Responder,
    status: u16 = 0,
    headers: std.ArrayList(u8) = .empty,
    /// The body written so far, for backends that answer whole.
    buffer: std.ArrayList(u8) = .empty,
    begun: bool = false,

    pub const Responder = struct {
        ctx: *anyopaque,
        /// Called once with the status and headers ("Name: value\r\n" each).
        begin: *const fn (ctx: *anyopaque, req: *SchemeRequest) void,
        /// Body bytes, after begin; null for backends that take it whole at the end.
        write: ?*const fn (ctx: *anyopaque, req: *SchemeRequest, bytes: []const u8) void,
        /// The answer is complete (`buffer` holds the body when `write` is null);
        /// the backend frees the request.
        finish: *const fn (ctx: *anyopaque, req: *SchemeRequest) void,
    };

    /// Answers whole.
    pub fn respond(req: *SchemeRequest, status: u16, headers: []const Header, body: []const u8) void {
        req.begin(status, headers);
        req.write(body);
        req.finish();
    }

    pub fn begin(req: *SchemeRequest, status: u16, headers: []const Header) void {
        if (req.begun) return;
        req.status = status;
        for (headers) |h| req.addHeader(h.name, h.value);
        req.begun = true;
        req.responder.begin(req.responder.ctx, req);
    }

    pub fn write(req: *SchemeRequest, bytes: []const u8) void {
        if (!req.begun) req.begin(200, &.{});
        if (req.responder.write) |w| return w(req.responder.ctx, req, bytes);
        req.buffer.appendSlice(req.gpa, bytes) catch {};
    }

    /// Completes the answer and frees the request.
    pub fn finish(req: *SchemeRequest) void {
        if (!req.begun) req.begin(200, &.{});
        req.responder.finish(req.responder.ctx, req);
    }

    pub fn addHeader(req: *SchemeRequest, name: []const u8, value: []const u8) void {
        req.headers.print(req.gpa, "{s}: {s}\r\n", .{ name, value }) catch {};
    }

    /// The value of a response header set so far, case-insensitively.
    pub fn header(req: *const SchemeRequest, name: []const u8) ?[]const u8 {
        var it = std.mem.splitSequence(u8, req.headers.items, "\r\n");
        while (it.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
        return null;
    }

    /// Made by the backends: copies what it is given.
    pub fn create(gpa: std.mem.Allocator, method: []const u8, url: []const u8, body: []const u8, responder: Responder) !*SchemeRequest {
        const req = try gpa.create(SchemeRequest);
        errdefer gpa.destroy(req);
        const strings = try std.mem.concat(gpa, u8, &.{ method, url, body });
        const u = strings[method.len..][0..url.len];
        req.* = .{ .gpa = gpa, .method = strings[0..method.len], .url = u, .path = pathOf(u), .body = strings[method.len + url.len ..], .responder = responder };
        return req;
    }

    pub fn destroy(req: *SchemeRequest) void {
        const gpa = req.gpa;
        gpa.free(req.method.ptr[0 .. req.method.len + req.url.len + req.body.len]);
        req.headers.deinit(gpa);
        req.buffer.deinit(gpa);
        gpa.destroy(req);
    }
};

/// The path of a URL, without its query or fragment ("/" when empty).
pub fn pathOf(url: []const u8) []const u8 {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |i| {
        rest = rest[i + 3 ..];
        rest = if (std.mem.indexOfScalar(u8, rest, '/')) |s| rest[s..] else "/";
    }
    if (std.mem.indexOfAny(u8, rest, "?#")) |end| rest = rest[0..end];
    return if (rest.len == 0) "/" else rest;
}

// Cookies.

pub const SameSite = enum { lax, strict, none };

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    /// "example.com", or ".example.com" for its subdomains too.
    domain: []const u8,
    path: []const u8 = "/",
    /// Seconds since 1970; null for a cookie that lasts the session.
    expires: ?i64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: SameSite = .lax,
};

/// Called with the cookies (null and an error's name when it failed); they
/// live while the callback runs.
pub const CookiesCallback = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, cookies: ?[]const Cookie, err: ?[]const u8) void,
};

/// Called when a change is done (`err` null) or failed.
pub const DoneCallback = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, err: ?[]const u8) void,
};

// Finding and printing.

pub const FindOptions = struct {
    match_case: bool = false,
    backward: bool = false,
    /// Moves on from the current match of the same text.
    find_next: bool = false,
};

pub const FindResult = struct { matches: u32 = 0, active: u32 = 0 };

pub const FindCallback = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, result: ?FindResult) void,
};

/// The zero value prints US Letter in portrait with 0.4 inch margins and
/// without backgrounds, as a browser's print dialog does. Inches.
pub const PdfOptions = struct {
    width: f64 = 8.5,
    height: f64 = 11,
    landscape: bool = false,
    margin_top: f64 = 0.4,
    margin_right: f64 = 0.4,
    margin_bottom: f64 = 0.4,
    margin_left: f64 = 0.4,
    background: bool = false,
};

/// Called with the PDF (null and why when it failed); it lives while the
/// callback runs.
pub const PdfCallback = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, pdf: ?[]const u8, err: ?[]const u8) void,
};

test "a scheme request answers once, whole or in parts" {
    const gpa = std.testing.allocator;
    const S = struct {
        var begun: u16 = 0;
        var body: [64]u8 = undefined;
        var len: usize = 0;
        fn begin(_: *anyopaque, req: *SchemeRequest) void {
            begun = req.status;
        }
        fn finish(_: *anyopaque, req: *SchemeRequest) void {
            @memcpy(body[0..req.buffer.items.len], req.buffer.items);
            len = req.buffer.items.len;
            req.destroy();
        }
    };
    var dummy: u8 = 0;
    const req = try SchemeRequest.create(gpa, "GET", "app://localhost/a/b.json?x=1", "", .{ .ctx = &dummy, .begin = S.begin, .write = null, .finish = S.finish });
    try std.testing.expectEqualStrings("/a/b.json", req.path);
    req.begin(201, &.{.{ .name = "Content-Type", .value = "application/json" }});
    try std.testing.expectEqualStrings("application/json", req.header("content-type").?);
    req.write("{\"a\":");
    req.write("1}");
    req.finish();
    try std.testing.expectEqual(@as(u16, 201), S.begun);
    try std.testing.expectEqualStrings("{\"a\":1}", S.body[0..S.len]);
    try std.testing.expectEqualStrings("/", pathOf("myzig://localhost"));
    try std.testing.expectEqualStrings("/x", pathOf("/x#y"));
}
