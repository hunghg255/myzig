//! One HTTP(S) request with std.http.Client, its response streamed to a
//! sink as it arrives: the head, then the body's chunks. It blocks, so it
//! runs on a thread of its own (`Service` runs it with `Io.concurrent`,
//! whose cancelation stops it).
const std = @import("std");
const http = std.http;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Redirect = enum {
    /// Follows up to `max_redirects`, as browsers do (20).
    follow,
    /// Returns the redirect response itself.
    manual,
    /// Fails on a redirect.
    @"error",
};

pub const Request = struct {
    url: []const u8,
    /// GET, HEAD, POST, PUT, DELETE, OPTIONS, PATCH, TRACE, QUERY (any case).
    method: []const u8 = "GET",
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    redirect: Redirect = .follow,
    max_redirects: u16 = 20,
};

pub const Head = struct {
    status: u16,
    status_text: []const u8,
    /// Where the response came from, after redirects.
    url: []const u8,
    redirected: bool,
    /// Names in lower case; never Set-Cookie, which pages cannot hold.
    headers: []const Header,
};

/// Where the response goes. Its functions run on the request's thread; an
/// error they return stops the request with it.
pub const Sink = struct {
    ctx: *anyopaque,
    head: *const fn (ctx: *anyopaque, head: Head) anyerror!void,
    chunk: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
};

pub const Error = error{
    UnsupportedUrlScheme,
    UnsupportedMethod,
    BodyNotAllowed,
    /// Redirected with `redirect = .error`.
    Redirected,
    TooManyRedirects,
};

/// The most bytes a chunk holds: what arrived goes out at once, up to this.
pub const chunk_size = 64 << 10;

/// Makes the request and streams its response to `sink`. `arena` holds
/// what the request needs while it runs (the head handed to the sink is
/// in it too).
pub fn perform(client: *http.Client, arena: std.mem.Allocator, req: Request, sink: Sink) !void {
    const uri = try std.Uri.parse(req.url);
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.UnsupportedUrlScheme;
    const method = parseMethod(req.method) orelse return error.UnsupportedMethod;
    if (req.body != null and (method == .GET or method == .HEAD)) return error.BodyNotAllowed;

    var std_headers: http.Client.Request.Headers = .{};
    var extra: std.ArrayList(http.Header) = .empty;
    for (req.headers) |h| {
        if (!validHeader(h)) return error.InvalidHeader;
        const v: http.Client.Request.Headers.Value = .{ .override = h.value };
        if (eql(h.name, "host")) std_headers.host = v //
        else if (eql(h.name, "authorization")) std_headers.authorization = v //
        else if (eql(h.name, "user-agent")) std_headers.user_agent = v //
        else if (eql(h.name, "connection")) std_headers.connection = v //
        else if (eql(h.name, "accept-encoding")) std_headers.accept_encoding = v //
        else if (eql(h.name, "content-type")) std_headers.content_type = v //
        else if (eql(h.name, "content-length") or eql(h.name, "transfer-encoding")) continue // the body's
        else try extra.append(arena, .{ .name = h.name, .value = h.value });
    }
    if (std_headers.user_agent == .default) std_headers.user_agent = .{ .override = "myzig" };

    const behavior: http.Client.Request.RedirectBehavior = switch (req.redirect) {
        .follow => .init(req.max_redirects),
        .manual => .unhandled,
        .@"error" => .not_allowed,
    };
    var r = try client.request(method, uri, .{
        .headers = std_headers,
        .extra_headers = extra.items,
        .redirect_behavior = behavior,
        .keep_alive = true,
    });
    defer r.deinit();

    if (req.body) |body| {
        r.transfer_encoding = .{ .content_length = body.len };
        try r.sendBodyComplete(try arena.dupe(u8, body));
    } else {
        try r.sendBodiless();
    }

    const redirect_buffer = try arena.alloc(u8, 8 * 1024);
    var response = r.receiveHead(redirect_buffer) catch |err| return switch (err) {
        error.TooManyHttpRedirects => if (req.redirect == .@"error") error.Redirected else error.TooManyRedirects,
        else => err,
    };

    // The head's strings live in the connection's buffer until the body
    // is read: copy them first.
    var headers: std.ArrayList(Header) = .empty;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (eql(h.name, "set-cookie")) continue;
        const name = try std.ascii.allocLowerString(arena, h.name);
        try headers.append(arena, .{ .name = name, .value = try arena.dupe(u8, h.value) });
    }
    const url = try std.fmt.allocPrint(arena, "{f}", .{r.uri.fmt(.{ .scheme = true, .authority = true, .path = true, .query = true })});
    try sink.head(sink.ctx, .{
        .status = @intCast(@backingInt(response.head.status)),
        .status_text = try arena.dupe(u8, response.head.reason),
        .url = url,
        .redirected = req.redirect == .follow and r.redirect_behavior.remaining() < req.max_redirects,
        .headers = headers.items,
    });
    if (method == .HEAD) return;

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    var transfer: [4096]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const body = response.readerDecompressing(&transfer, &decompress, decompress_buffer);
    const buf = try arena.alloc(u8, chunk_size);
    while (true) {
        var w: std.Io.Writer = .fixed(buf);
        const n = body.stream(&w, .limited(buf.len)) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => {
                if (response.bodyErr()) |e| return e;
                // The connection's own error: Canceled, ConnectionResetByPeer…
                if (r.connection) |c| if (c.stream_reader.err) |e| return e;
                return error.ReadFailed;
            },
            error.WriteFailed => unreachable,
        };
        if (n > 0) try sink.chunk(sink.ctx, buf[0..n]);
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn parseMethod(m: []const u8) ?http.Method {
    inline for (.{ "GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "PATCH", "TRACE", "QUERY" }) |name| {
        if (eql(m, name)) return @field(http.Method, name);
    }
    return null;
}

/// A token for a name, and no line breaks in either.
fn validHeader(h: Header) bool {
    if (h.name.len == 0) return false;
    for (h.name) |c| if (c <= ' ' or c >= 0x7f or c == ':') return false;
    return std.mem.indexOfAny(u8, h.value, "\r\n\x00") == null;
}
