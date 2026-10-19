//! A release server on 127.0.0.1, for the example and the tests: it
//! publishes version `version` of an "executable" (`payload`), with its
//! manifest at /latest.json, as an app's update server would.
//!
//!   GET /latest.json   {"version", "url": "app-<version>", "sha256", "notes", "size"}
//!   GET /app-<version> the payload
//!   GET /bad.json      a manifest whose checksum does not match
//!   GET /signed.json   the manifest signed, as `myzig build` signs it, by
//!                      the key whose public half is `public_key`
//!   GET /forged.json   the manifest with a signature of another file
const std = @import("std");
const Io = std.Io;

pub const Server = struct {
    io: Io,
    listener: Io.net.Server,
    port: u16,
    version: []const u8,
    payload: []const u8,
    future: Io.Future(void) = undefined,
    group: Io.Group = .init,
    manifest_buf: [512]u8 = undefined,
    manifest: []const u8 = "",
    bad_buf: [512]u8 = undefined,
    bad: []const u8 = "",
    path_buf: [64]u8 = undefined,
    path: []const u8 = "",
    signed_buf: [700]u8 = undefined,
    signed: []const u8 = "",
    forged_buf: [700]u8 = undefined,
    forged: []const u8 = "",
    /// The public key of the release's signing key, base64.
    public_key: [44]u8 = undefined,

    pub fn start(s: *Server, io: Io, version: []const u8, payload: []const u8) !void {
        const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const listener = try addr.listen(io, .{ .reuse_address = true });
        s.* = .{ .io = io, .listener = listener, .port = listener.socket.address.getPort(), .version = version, .payload = payload };
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        s.path = try std.fmt.bufPrint(&s.path_buf, "/app-{s}", .{version});
        s.manifest = try std.fmt.bufPrint(&s.manifest_buf, "{{\"version\":\"{s}\",\"url\":\"app-{s}\",\"sha256\":\"{s}\",\"notes\":\"Faster and *better*.\",\"size\":{d}}}", .{ version, version, &hex, payload.len });
        s.bad = try std.fmt.bufPrint(&s.bad_buf, "{{\"version\":\"{s}\",\"url\":\"app-{s}\",\"sha256\":\"{s}\"}}", .{ version, version, "0000000000000000000000000000000000000000000000000000000000000000" });
        // A fixed key: the example is no real release.
        const Ed25519 = std.crypto.sign.Ed25519;
        const kp = try Ed25519.KeyPair.generateDeterministic(@splat(7));
        _ = std.base64.standard.Encoder.encode(&s.public_key, &kp.public_key.toBytes());
        var sig: [88]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&sig, &(try kp.sign(&digest, null)).toBytes());
        s.signed = try std.fmt.bufPrint(&s.signed_buf, "{{\"version\":\"{s}\",\"url\":\"app-{s}\",\"sha256\":\"{s}\",\"signature\":\"{s}\",\"size\":{d}}}", .{ version, version, &hex, &sig, payload.len });
        var other: [32]u8 = digest;
        other[0] ^= 1;
        var forged_sig: [88]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&forged_sig, &(try kp.sign(&other, null)).toBytes());
        s.forged = try std.fmt.bufPrint(&s.forged_buf, "{{\"version\":\"{s}\",\"url\":\"app-{s}\",\"sha256\":\"{s}\",\"signature\":\"{s}\",\"size\":{d}}}", .{ version, version, &hex, &forged_sig, payload.len });
        s.future = try io.concurrent(serve, .{s});
    }

    pub fn stop(s: *Server) void {
        s.future.cancel(s.io);
        s.group.cancel(s.io);
        s.listener.deinit(s.io);
    }

    pub fn url(s: *const Server, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ s.port, path }) catch unreachable;
    }

    fn serve(s: *Server) void {
        while (true) {
            const stream = s.listener.accept(s.io) catch return;
            s.group.concurrent(s.io, connection, .{ s, stream }) catch stream.close(s.io);
        }
    }

    fn connection(s: *Server, stream: Io.net.Stream) void {
        defer stream.close(s.io);
        var in_buf: [8192]u8 = undefined;
        var out_buf: [8192]u8 = undefined;
        var reader = stream.reader(s.io, &in_buf);
        var writer = stream.writer(s.io, &out_buf);
        var http: std.http.Server = .init(&reader.interface, &writer.interface);
        while (true) {
            var req = http.receiveHead() catch return;
            const t = req.head.target;
            const body: ?[]const u8 = if (std.mem.eql(u8, t, "/latest.json")) s.manifest //
                else if (std.mem.eql(u8, t, "/bad.json")) s.bad //
                else if (std.mem.eql(u8, t, "/signed.json")) s.signed //
                else if (std.mem.eql(u8, t, "/forged.json")) s.forged //
                else if (std.mem.eql(u8, t, s.path)) s.payload //
                else null;
            if (body) |b| req.respond(b, .{}) catch return else req.respond("not found", .{ .status = .not_found }) catch return;
        }
    }
};
