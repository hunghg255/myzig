//! The updater against the example's release server, replacing an
//! "executable" in a temporary directory, never the test's own.
const std = @import("std");
const updater = @import("updater");
const Releases = @import("releases").Server;
const testing = std.testing;
const io = testing.io;

const Fixture = struct {
    server: Releases = undefined,
    client: std.http.Client = undefined,
    tmp: testing.TmpDir = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    exe: []const u8 = "",
    url_buf: [128]u8 = undefined,

    fn init(f: *Fixture, version: []const u8) !void {
        try f.server.start(io, version, "the new executable, version " ++ "2");
        f.client = .{ .allocator = testing.allocator, .io = io };
        f.tmp = testing.tmpDir(.{});
        f.arena = .init(testing.allocator);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try f.tmp.dir.realPath(io, &buf);
        f.exe = try std.fs.path.join(f.arena.allocator(), &.{ buf[0..n], "app.exe" });
        try f.tmp.dir.writeFile(io, .{ .sub_path = "app.exe", .data = "the old executable" });
    }
    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.tmp.cleanup();
        f.client.deinit();
        f.server.stop();
    }
    fn updaterFor(f: *Fixture, manifest: []const u8, current: []const u8) updater.Updater {
        return .{ .gpa = testing.allocator, .io = io, .client = &f.client, .manifest_url = f.server.url(&f.url_buf, manifest), .current = current, .exe_path = f.exe };
    }
    fn read(f: *Fixture, name: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(io, name, f.arena.allocator(), .limited(1 << 20));
    }
};

const Seen = struct {
    last: u64 = 0,
    total: ?u64 = null,
    fn progress(ctx: ?*anyopaque, done: u64, total: ?u64) void {
        const s: *Seen = @ptrCast(@alignCast(ctx));
        s.last = done;
        s.total = total;
    }
};

test "a newer version: checked, downloaded with its checksum, installed, cleaned up" {
    var f: Fixture = .{};
    try f.init("2.0.0");
    defer f.deinit();
    const u = f.updaterFor("/latest.json", "1.4.2");
    const a = f.arena.allocator();
    const update = (try u.check(a)).?;
    try testing.expectEqualStrings("2.0.0", update.version);
    try testing.expect(std.mem.endsWith(u8, update.url, "/app-2.0.0"));
    try testing.expectEqualStrings("Faster and *better*.", update.notes);

    var seen: Seen = .{};
    const staged = try u.download(a, update, .{ .ctx = &seen, .func = Seen.progress });
    try testing.expectEqual(update.size, seen.total);
    try testing.expectEqual(update.size.?, seen.last);
    try u.install(staged);
    try testing.expectEqualStrings("the new executable, version 2", try f.read("app.exe"));
    if (@import("builtin").os.tag == .windows) {
        // The old one moved aside, as a running executable must.
        try testing.expectEqualStrings("the old executable", try f.read("app.exe.old"));
    }
    u.cleanup();
    try testing.expectError(error.FileNotFound, f.read("app.exe.old"));
}

test "the same or an older version is no update" {
    var f: Fixture = .{};
    try f.init("2.0.0");
    defer f.deinit();
    try testing.expectEqual(null, try f.updaterFor("/latest.json", "2.0.0").check(f.arena.allocator()));
    try testing.expectEqual(null, try f.updaterFor("/latest.json", "3.0.0-beta.1").check(f.arena.allocator()));
}

test "a download that does not match its checksum is refused and removed" {
    var f: Fixture = .{};
    try f.init("2.0.0");
    defer f.deinit();
    const u = f.updaterFor("/bad.json", "1.0.0");
    const update = (try u.check(f.arena.allocator())).?;
    try testing.expectError(error.ChecksumMismatch, u.download(f.arena.allocator(), update, null));
    try testing.expectError(error.FileNotFound, f.read("app.exe.update"));
    try testing.expectEqualStrings("the old executable", try f.read("app.exe"));
}

test "with the public key, only what its key signs installs" {
    var f: Fixture = .{};
    try f.init("2.0.0");
    defer f.deinit();
    const a = f.arena.allocator();
    var u = f.updaterFor("/signed.json", "1.0.0");
    u.public_key = &f.server.public_key;
    const update = (try u.check(a)).?;
    try u.install(try u.download(a, update, null));
    try testing.expectEqualStrings("the new executable, version 2", try f.read("app.exe"));
    // Unsigned, or signed for another file: refused, and the download removed.
    u.manifest_url = f.server.url(&f.url_buf, "/latest.json");
    try testing.expectError(error.Unsigned, u.check(a));
    u.manifest_url = f.server.url(&f.url_buf, "/forged.json");
    const forged = (try u.check(a)).?;
    try testing.expectError(error.BadSignature, u.download(a, forged, null));
    try testing.expectError(error.FileNotFound, f.read("app.exe.update"));
    // Another key.
    const other = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(8));
    var other_key: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&other_key, &other.public_key.toBytes());
    u.public_key = &other_key;
    u.manifest_url = f.server.url(&f.url_buf, "/signed.json");
    try testing.expectError(error.BadSignature, u.download(a, (try u.check(a)).?, null));
}

test "a manifest that is missing fails the check" {
    var f: Fixture = .{};
    try f.init("2.0.0");
    defer f.deinit();
    try testing.expectError(error.HttpStatus, f.updaterFor("/nope.json", "1.0.0").check(f.arena.allocator()));
}

test {
    _ = updater;
}
