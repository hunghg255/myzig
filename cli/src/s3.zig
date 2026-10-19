//! Uploads to Amazon S3 and compatible services, such as Cloudflare R2,
//! after mygo's cmd/mygo/s3.go: each object is put with one request signed
//! with AWS Signature Version 4, in Zig, with no other tool.
const std = @import("std");
const fsx = @import("fsx.zig");
const updates = @import("updates.zig");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Ctx = fsx.Ctx;

pub const Header = struct { name: []const u8, value: []const u8 };

/// Puts objects into a bucket.
pub const Client = struct {
    bucket: []const u8,
    prefix: []const u8,
    region: []const u8,
    /// "https", and the host (with its port) of the service.
    scheme: []const u8,
    host: []const u8,
    path_style: bool,
    access_key: []const u8,
    secret_key: []const u8,
    session_token: []const u8,

    pub fn init(ctx: Ctx, s: updates.S3) !Client {
        const access = ctx.env.get("AWS_ACCESS_KEY_ID") orelse "";
        const secret = ctx.env.get("AWS_SECRET_ACCESS_KEY") orelse "";
        if (access.len == 0 or secret.len == 0)
            return updates.fail(ctx, "uploading to updates.s3 needs the credentials in AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY", .{});
        const region = firstOf(&.{ s.region, ctx.env.get("AWS_REGION") orelse "", ctx.env.get("AWS_DEFAULT_REGION") orelse "", "us-east-1" });
        var scheme: []const u8 = "https";
        var host: []const u8 = try ctx.fmt("s3.{s}.amazonaws.com", .{region});
        if (s.endpoint.len > 0) {
            const i = std.mem.indexOf(u8, s.endpoint, "://").?;
            scheme = s.endpoint[0..i];
            host = std.mem.trimEnd(u8, s.endpoint[i + 3 ..], "/");
        }
        return .{
            .bucket = s.bucket,
            .prefix = std.mem.trim(u8, s.prefix, "/"),
            .region = region,
            .scheme = scheme,
            .host = host,
            .path_style = s.path_style orelse (s.endpoint.len > 0 or std.mem.indexOfScalar(u8, s.bucket, '.') != null),
            .access_key = access,
            .secret_key = secret,
            .session_token = ctx.env.get("AWS_SESSION_TOKEN") orelse "",
        };
    }

    /// The key of the file named `name`.
    pub fn key(c: Client, ctx: Ctx, name: []const u8) ![]const u8 {
        return if (c.prefix.len == 0) name else ctx.fmt("{s}/{s}", .{ c.prefix, name });
    }

    /// The host and escaped path of the object of `k`.
    pub fn target(c: Client, ctx: Ctx, k: []const u8) !struct { host: []const u8, path: []const u8 } {
        const path = try escape(ctx.gpa, k);
        if (c.path_style) return .{ .host = c.host, .path = try ctx.fmt("/{s}/{s}", .{ try escape(ctx.gpa, c.bucket), path }) };
        return .{ .host = try ctx.fmt("{s}.{s}", .{ c.bucket, c.host }), .path = try ctx.fmt("/{s}", .{path}) };
    }

    /// The headers that sign a PUT of a body whose SHA-256 is
    /// `payload_hash` (hex) at `amz_date` ("20260919T120000Z"), with the
    /// object's own `headers`: those, x-amz-*, and Authorization.
    pub fn sign(c: Client, ctx: Ctx, host: []const u8, path: []const u8, headers: []const Header, payload_hash: []const u8, amz_date: []const u8) ![]Header {
        var all: std.ArrayList(Header) = .empty;
        try all.append(ctx.gpa, .{ .name = "host", .value = host });
        for (headers) |h| try all.append(ctx.gpa, .{ .name = try std.ascii.allocLowerString(ctx.gpa, h.name), .value = try collapse(ctx.gpa, h.value) });
        try all.append(ctx.gpa, .{ .name = "x-amz-content-sha256", .value = payload_hash });
        try all.append(ctx.gpa, .{ .name = "x-amz-date", .value = amz_date });
        if (c.session_token.len > 0) try all.append(ctx.gpa, .{ .name = "x-amz-security-token", .value = c.session_token });
        std.mem.sort(Header, all.items, {}, struct {
            fn lt(_: void, a: Header, b: Header) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lt);
        var canonical: std.ArrayList(u8) = .empty;
        var signed: std.ArrayList(u8) = .empty;
        for (all.items, 0..) |h, i| {
            try canonical.print(ctx.gpa, "{s}:{s}\n", .{ h.name, h.value });
            if (i > 0) try signed.append(ctx.gpa, ';');
            try signed.appendSlice(ctx.gpa, h.name);
        }
        const request = try ctx.fmt("PUT\n{s}\n\n{s}\n{s}\n{s}", .{ path, canonical.items, signed.items, payload_hash });
        const date = amz_date[0..8];
        const scope = try ctx.fmt("{s}/{s}/s3/aws4_request", .{ date, c.region });
        var hash: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(request, &hash, .{});
        var k = hmac(try ctx.fmt("AWS4{s}", .{c.secret_key}), date);
        for ([_][]const u8{ c.region, "s3", "aws4_request" }) |s| k = hmac(&k, s);
        const to_sign = try ctx.fmt("AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ amz_date, scope, &std.fmt.bytesToHex(hash, .lower) });
        const signature = hmac(&k, to_sign);
        var out: std.ArrayList(Header) = .empty;
        for (all.items) |h| if (!std.mem.eql(u8, h.name, "host")) try out.append(ctx.gpa, h);
        try out.append(ctx.gpa, .{ .name = "authorization", .value = try ctx.fmt("AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}", .{ c.access_key, scope, signed.items, &std.fmt.bytesToHex(signature, .lower) }) });
        return out.items;
    }

    /// Uploads the file at `path` to `k`, with `headers`.
    pub fn put(c: Client, ctx: Ctx, client: *std.http.Client, k: []const u8, path: []const u8, headers: []const Header) !void {
        const body = try fsx.read(ctx, path);
        var hash: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(body, &hash, .{});
        const t = try c.target(ctx, k);
        const amz_date = try amzDate(ctx, fsx.nowSeconds(ctx));
        const signed = try c.sign(ctx, t.host, t.path, headers, &std.fmt.bytesToHex(hash, .lower), amz_date);
        const extra = try ctx.gpa.alloc(std.http.Header, signed.len);
        for (signed, extra) |h, *e| e.* = .{ .name = h.name, .value = h.value };
        const uri = try std.Uri.parse(try ctx.fmt("{s}://{s}{s}", .{ c.scheme, t.host, t.path }));
        // S3 redirects requests for another region, which must not be
        // followed as a GET.
        var req = try client.request(.PUT, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{ .host = .{ .override = t.host }, .user_agent = .{ .override = "myzig/" ++ @import("main.zig").version } },
            .extra_headers = extra,
        });
        defer req.deinit();
        try req.sendBodyComplete(body);
        var redirect_buf: [4096]u8 = undefined;
        var res = try req.receiveHead(&redirect_buf);
        if (@intFromEnum(res.head.status) / 100 == 2) return;
        var region_hint: []const u8 = "";
        var it = res.head.iterateHeaders();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "x-amz-bucket-region") and !std.mem.eql(u8, h.value, c.region)) {
            region_hint = try ctx.fmt(" (the bucket is in {s}: set updates.s3.region)", .{h.value});
        };
        const status = @intFromEnum(res.head.status);
        var transfer: [4096]u8 = undefined;
        const reader = res.reader(&transfer);
        const text = reader.allocRemaining(ctx.gpa, .limited(64 << 10)) catch "";
        return updates.fail(ctx, "uploading to s3://{s}/{s}: {d}{s}{s}", .{ c.bucket, k, status, try errorOf(ctx, text), region_hint });
    }
};

fn firstOf(list: []const []const u8) []const u8 {
    for (list) |s| if (s.len > 0) return s;
    return "";
}

fn hmac(k: []const u8, data: []const u8) [HmacSha256.mac_length]u8 {
    var out: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&out, data, k);
    return out;
}

/// A header's value as Signature Version 4 signs it: runs of spaces as one.
fn collapse(gpa: std.mem.Allocator, v: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, v, " \t");
    while (it.next()) |w| {
        if (out.items.len > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, w);
    }
    return out.items;
}

/// Escapes a key for the path of a URL as Signature Version 4 wants it:
/// every byte but letters, digits, "-._~" and "/".
pub fn escape(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~/", ch) != null) {
            try out.append(gpa, ch);
        } else try out.print(gpa, "%{X:0>2}", .{ch});
    }
    return out.items;
}

/// "20260919T120000Z".
pub fn amzDate(ctx: Ctx, secs: u64) ![]u8 {
    const t = try updates.rfc3339(ctx, secs); // 2026-09-19T12:00:00Z
    return ctx.fmt("{s}{s}{s}T{s}{s}{s}Z", .{ t[0..4], t[5..7], t[8..10], t[11..13], t[14..16], t[17..19] });
}

/// S3's code and message of an error, from its XML.
fn errorOf(ctx: Ctx, xml: []const u8) ![]const u8 {
    const code = element(xml, "Code") orelse return "";
    return ctx.fmt(": {s}: {s}", .{ code, element(xml, "Message") orelse "" });
}

fn element(xml: []const u8, comptime name: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, xml, "<" ++ name ++ ">") orelse return null) + name.len + 2;
    const end = std.mem.indexOfPos(u8, xml, start, "</" ++ name ++ ">") orelse return null;
    return xml[start..end];
}

test "signature version 4, as AWS documents it" {
    // AWS's example of a signed PUT ("Example: PUT Object" in the
    // Signature Version 4 documentation of S3).
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    try env.put("AWS_ACCESS_KEY_ID", "AKIAIOSFODNN7EXAMPLE");
    try env.put("AWS_SECRET_ACCESS_KEY", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY");
    const ctx: Ctx = .{ .gpa = arena.allocator(), .io = std.testing.io, .env = &env, .quiet = true };
    const c = try Client.init(ctx, .{ .bucket = "examplebucket" });
    const t = try c.target(ctx, "test$file.text");
    try std.testing.expectEqualStrings("examplebucket.s3.us-east-1.amazonaws.com", t.host);
    try std.testing.expectEqualStrings("/test%24file.text", t.path);
    const headers = try c.sign(ctx, "examplebucket.s3.amazonaws.com", t.path, &.{
        .{ .name = "Date", .value = "Fri, 24 May 2013 00:00:00 GMT" },
        .{ .name = "x-amz-storage-class", .value = "REDUCED_REDUNDANCY" },
    }, "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072", "20130524T000000Z");
    const auth = headers[headers.len - 1];
    try std.testing.expectEqualStrings("authorization", auth.name);
    try std.testing.expectEqualStrings("AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd", auth.value);
}

test "buckets in paths, keys escaped, regions and errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    const ctx: Ctx = .{ .gpa = arena.allocator(), .io = std.testing.io, .env = &env, .quiet = true };
    try std.testing.expectError(error.CommandFailed, Client.init(ctx, .{ .bucket = "b" }));
    try env.put("AWS_ACCESS_KEY_ID", "AKID");
    try env.put("AWS_SECRET_ACCESS_KEY", "secret");
    try env.put("AWS_REGION", "eu-west-1");
    const r2 = try Client.init(ctx, .{ .bucket = "downloads", .prefix = "/my-app/", .endpoint = "https://acc.r2.cloudflarestorage.com/" });
    try std.testing.expect(r2.path_style);
    try std.testing.expectEqualStrings("eu-west-1", r2.region);
    const t = try r2.target(ctx, try r2.key(ctx, "My App 1.0 Setup.exe"));
    try std.testing.expectEqualStrings("acc.r2.cloudflarestorage.com", t.host);
    try std.testing.expectEqualStrings("/downloads/my-app/My%20App%201.0%20Setup.exe", t.path);
    const dotted = try Client.init(ctx, .{ .bucket = "my.bucket", .region = "us-west-2" });
    try std.testing.expect(dotted.path_style);
    try std.testing.expectEqualStrings("s3.us-west-2.amazonaws.com", dotted.host);
    try std.testing.expectEqualStrings("20130524T000000Z", try amzDate(ctx, 1369353600));
    try std.testing.expectEqualStrings(": NoSuchBucket: The specified bucket does not exist", try errorOf(ctx, "<Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist</Message></Error>"));
}
