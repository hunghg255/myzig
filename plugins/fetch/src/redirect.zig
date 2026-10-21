//! Builds a redirect's next request before the main thread checks its policy.
const std = @import("std");
const http = @import("http.zig");

pub fn isRedirect(status: u16) bool {
    return switch (status) {
        301, 302, 303, 307, 308 => true,
        else => false,
    };
}

pub fn next(arena: std.mem.Allocator, req: http.Request, head: http.Head) !http.Request {
    if (req.max_redirects == 0) return error.TooManyRedirects;
    const location = for (head.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "location")) break h.value;
    } else return error.HttpRedirectLocationMissing;
    const base = try std.Uri.parse(req.url);
    var aux = try arena.alloc(u8, req.url.len + location.len + 32);
    @memcpy(aux[0..location.len], location);
    const uri = try base.resolveInPlace(location.len, &aux);
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.UnsupportedUrlScheme;
    const host = try (uri.host orelse return error.UriMissingHost).toRawMaybeAlloc(arena);
    const old_host = try (base.host orelse return error.UriMissingHost).toRawMaybeAlloc(arena);
    const same_origin = std.ascii.eqlIgnoreCase(base.scheme, uri.scheme) and
        std.ascii.eqlIgnoreCase(old_host, host) and port(base) == port(uri);
    // As Fetch: 303 makes anything but HEAD a GET, 301 and 302 only POST.
    const method = http.parseMethod(req.method);
    const get = (head.status == 303 and method != .HEAD) or ((head.status == 301 or head.status == 302) and method == .POST);
    if (!get and req.body != null) return error.RedirectRequiresResend;
    var headers: std.ArrayList(http.Header) = .empty;
    for (req.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "host")) continue;
        if (get and (std.ascii.eqlIgnoreCase(h.name, "content-type") or std.ascii.eqlIgnoreCase(h.name, "content-length"))) continue;
        if (!same_origin and (std.ascii.eqlIgnoreCase(h.name, "authorization") or
            std.ascii.eqlIgnoreCase(h.name, "cookie") or std.ascii.eqlIgnoreCase(h.name, "proxy-authorization"))) continue;
        try headers.append(arena, h);
    }
    return .{
        .url = try std.fmt.allocPrint(arena, "{f}", .{uri.fmt(.{ .scheme = true, .authority = true, .path = true, .query = true })}),
        .method = if (get) "GET" else req.method,
        .headers = headers.items,
        .body = if (get) null else req.body,
        .redirect = req.redirect,
        .max_redirects = req.max_redirects - 1,
    };
}

fn port(uri: std.Uri) u16 {
    return uri.port orelse if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) @as(u16, 443) else 80;
}

test "redirect requests resolve URLs and strip credentials on origin changes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const req: http.Request = .{ .url = "https://one.test/a", .method = "POST", .body = "body", .headers = &.{
        .{ .name = "Authorization", .value = "secret" },
        .{ .name = "Cookie", .value = "secret" },
        .{ .name = "Host", .value = "one.test" },
        .{ .name = "Content-Type", .value = "text/plain" },
        .{ .name = "X-Custom", .value = "kept" },
    } };
    const head: http.Head = .{ .status = 302, .status_text = "Found", .url = req.url, .redirected = false, .headers = &.{.{ .name = "location", .value = "https://two.test/b" }} };
    const r = try next(arena.allocator(), req, head);
    try std.testing.expectEqualStrings("https://two.test/b", r.url);
    try std.testing.expectEqualStrings("GET", r.method);
    try std.testing.expect(r.body == null);
    try std.testing.expectEqual(@as(usize, 1), r.headers.len);
    try std.testing.expectEqualStrings("X-Custom", r.headers[0].name);
    var same = head;
    same.headers = &.{.{ .name = "location", .value = "../b" }};
    const local = try next(arena.allocator(), req, same);
    try std.testing.expectEqualStrings("https://one.test/b", local.url);
    try std.testing.expectEqual(@as(usize, 3), local.headers.len);
    var resend = head;
    resend.status = 307;
    try std.testing.expectError(error.RedirectRequiresResend, next(arena.allocator(), req, resend));
    var head_req = req;
    head_req.method = "HEAD";
    head_req.body = null;
    var see_other = head;
    see_other.status = 303;
    try std.testing.expectEqualStrings("HEAD", (try next(arena.allocator(), head_req, see_other)).method);
    var exhausted = req;
    exhausted.max_redirects = 0;
    try std.testing.expectError(error.TooManyRedirects, next(arena.allocator(), exhausted, head));
}
