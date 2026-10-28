//! Signed updates: keys, signatures, the configuration, release notes, the
//! update files of a build, and what `--upload` needs before building.
const std = @import("std");
const fsx = @import("fsx.zig");
const config = @import("config.zig");
const updates = @import("updates.zig");
const publish = @import("publish.zig");
const Ed25519 = std.crypto.sign.Ed25519;
const Ctx = fsx.Ctx;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    tmp: std.testing.TmpDir,

    fn init(f: *Fixture) void {
        f.arena = .init(std.testing.allocator);
        f.env = .init(f.arena.allocator());
        f.tmp = std.testing.tmpDir(.{});
    }
    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena.deinit();
    }
    fn ctx(f: *Fixture) Ctx {
        return .{ .gpa = f.arena.allocator(), .io = std.testing.io, .env = &f.env, .quiet = true };
    }
    fn root(f: *Fixture) ![]u8 {
        const c = f.ctx();
        return fsx.absolute(c, try c.join(&.{ ".zig-cache", "tmp", &f.tmp.sub_path }));
    }
};

fn keyPair(seed: u8) !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(@splat(seed));
}

fn encoded(f: *Fixture, bytes: []const u8) ![]u8 {
    return updates.encodeKey(f.arena.allocator(), bytes);
}

test "keys in base64, and signatures of digests" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const kp = try keyPair(1);
    const pk = updates.parsePublicKey(try encoded(&f, &kp.public_key.toBytes())).?;
    const back = updates.parsePrivateKey(try f.ctx().fmt(" {s}\n", .{try encoded(&f, &kp.secret_key.toBytes())})).?;
    try std.testing.expectEqualSlices(u8, &kp.public_key.toBytes(), &back.public_key.toBytes());
    try std.testing.expect(updates.parsePublicKey("not a key") == null);
    try std.testing.expect(updates.parsePrivateKey(try encoded(&f, &kp.public_key.toBytes())) == null);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("the app", &digest, .{});
    const sig = try updates.sign(f.arena.allocator(), kp, digest);
    try std.testing.expect(updates.verify(pk, digest, sig));
    digest[0] ^= 1;
    try std.testing.expect(!updates.verify(pk, digest, sig));
    const other = try keyPair(2);
    digest[0] ^= 1;
    try std.testing.expect(!updates.verify(other.public_key, digest, sig));
}

test "the updates of the configuration" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const gpa = f.arena.allocator();
    const pub_text = try encoded(&f, &(try keyPair(1)).public_key.toBytes());
    const src = try f.ctx().fmt(".{{ .updates = .{{ .public_key = \"{s}\", .url = \"https://dl.example.com/app\", .s3 = .{{ .bucket = \"dl\", .prefix = \"app\", .path_style = false }} }} }}", .{pub_text});
    var c: config.Config = .{ .root = "/a", .file = config.zon_file, .name = "A", .identifier = "com.a", .version = "1.0.0" };
    const v = try config.parseSource(gpa, src, false, config.zon_file);
    try std.testing.expect(v.get("updates") != null);
    c.updates = try updates.decode(gpa, v.get("updates").?);
    try config.validate(gpa, c);
    try std.testing.expectEqualStrings("dl", c.updates.?.s3.?.bucket);
    try std.testing.expectEqual(false, c.updates.?.s3.?.path_style.?);
    try std.testing.expectEqualStrings("v", c.updates.?.tag_prefix);

    const bad = [_]struct { updates.Updates, []const u8 }{
        .{ .{}, "updates needs the public_key of myzig keygen" },
        .{ .{ .public_key = "nope", .github = "a/b" }, "updates.public_key: invalid update public key" },
        .{ .{ .public_key = pub_text }, "updates needs either github (owner/name) or url" },
        .{ .{ .public_key = pub_text, .github = "app" }, "updates.github \"app\" is not owner/name" },
        .{ .{ .public_key = pub_text, .url = "ftp://dl.example.com" }, "updates.url \"ftp://dl.example.com\" is not an http(s) URL" },
        .{ .{ .public_key = pub_text, .url = "http://" }, "updates.url \"http://\" is not an http(s) URL" },
        .{ .{ .public_key = pub_text, .github = "a/b", .s3 = .{ .bucket = "b" } }, "updates.s3 needs url, the HTTPS URL that serves the files of the bucket, in place of github" },
        .{ .{ .public_key = pub_text, .url = "https://x", .s3 = .{ .bucket = "b", .endpoint = "https://r2.example.com/bucket" } }, "updates.s3.endpoint \"https://r2.example.com/bucket\" has a path: the endpoint is the service's, and bucket names the bucket" },
    };
    for (bad) |b| {
        try std.testing.expectError(error.ConfigInvalid, updates.validate(gpa, b[0]));
        try std.testing.expectEqualStrings(b[1], config.message);
    }
}

test "release notes from the changelog" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const changelog = "# Changelog\n\nIntro.\n\n## 1.2.0 - 2026-09-19\n\nFaster.\n\n### Fixed\n- Drafts\n\n## 1.1.0\n- Tray\n";
    try std.testing.expectEqualStrings("Faster.\n\n### Fixed\n- Drafts", try updates.releaseNotes(a, changelog, "1.2.0"));
    try std.testing.expectEqualStrings("- Tray", try updates.releaseNotes(a, changelog, "v1.1.0"));
    try std.testing.expectEqualStrings("", try updates.releaseNotes(a, changelog, "1.3.0"));
    // Keep a Changelog, with a Windows checkout's line endings.
    const keep = "# Changelog\r\n\r\n## [Unreleased]\r\n\r\n- Soon\r\n\r\n## [1.2.0] - 2026-09-19\r\n\r\n- Faster\r\n\r\n## [v1.1.0](https://example.com/compare/v1.0.0...v1.1.0)\r\n- Tray\r\n";
    const cases = [_][2][]const u8{ .{ "1.2.0", "- Faster" }, .{ "1.1.0", "- Tray" }, .{ "Unreleased", "- Soon" }, .{ "1.0.0", "" } };
    for (cases) |cs| try std.testing.expectEqualStrings(cs[1], try updates.releaseNotes(a, keep, cs[0]));
}

// --upload refuses to build without the key that signs the updates, which
// a release needs for installed apps to update to it (mygo's #466).
test "--upload needs the signing key" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const kp = try keyPair(1);
    const other = try keyPair(2);
    const pub_text = try encoded(&f, &kp.public_key.toBytes());
    try f.env.put("AWS_ACCESS_KEY_ID", "AKIDEXAMPLE");
    try f.env.put("AWS_SECRET_ACCESS_KEY", "secret");
    for ([_]updates.Updates{
        .{ .public_key = pub_text, .github = "owner/app" },
        .{ .public_key = pub_text, .url = "https://downloads.example.com/app", .s3 = .{ .bucket = "app", .region = "us-east-1" } },
    }) |u| {
        const c: config.Config = .{ .root = try f.root(), .updates = u };
        try f.env.put(updates.key_env, "");
        try std.testing.expectError(error.CommandFailed, publish.checkUpload(f.ctx(), c));
        try std.testing.expect(std.mem.indexOf(u8, updates.message, updates.key_env) != null);
        try f.env.put(updates.key_env, try encoded(&f, &other.secret_key.toBytes()));
        try std.testing.expectError(error.CommandFailed, publish.checkUpload(f.ctx(), c));
        try std.testing.expect(std.mem.indexOf(u8, updates.message, "does not match") != null);
        try f.env.put(updates.key_env, try encoded(&f, &kp.secret_key.toBytes()));
        try publish.checkUpload(f.ctx(), c);
    }
    // Nowhere to upload to.
    try std.testing.expectError(error.CommandFailed, publish.checkUpload(f.ctx(), .{ .root = "/a" }));
    try std.testing.expect(std.mem.indexOf(u8, updates.message, "updates.github or updates.s3") != null);
}

test "a build writes the signed update and its manifest" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const ctx = f.ctx();
    const root = try f.root();
    const kp = try keyPair(1);
    const exe = try ctx.join(&.{ root, "My App.exe" });
    try fsx.write(ctx.io, exe, "the new executable");
    try fsx.write(ctx.io, try ctx.join(&.{ root, "CHANGELOG.md" }), "## 2.0.0\n\nFaster and *better*.\n\n## 1.0.0\n- First\n");
    try fsx.write(ctx.io, try ctx.join(&.{ root, "keys", "myzig-update.key" }), try encoded(&f, &kp.secret_key.toBytes()));
    try f.env.put("SOURCE_DATE_EPOCH", "1369353600");
    var c: config.Config = .{ .root = root, .name = "My App", .executable = "my_app", .version = "2.0.0", .updates = .{ .public_key = try encoded(&f, &kp.public_key.toBytes()), .github = "you/my-app" } };
    // Without a key: nothing, after a warning.
    try std.testing.expectEqual(@as(usize, 0), (try updates.writeUpdate(ctx, c, root, "windows-x86_64", exe)).len);
    c.updates.?.private_key = "keys/myzig-update.key";
    const files = try updates.writeUpdate(ctx, c, root, "windows-x86_64", exe);
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expect(std.mem.endsWith(u8, files[0], "my-app-2.0.0-windows-x86_64.exe"));
    try std.testing.expectEqualStrings("the new executable", try fsx.read(ctx, files[0]));
    try std.testing.expect(std.mem.endsWith(u8, files[1], "update-windows-x86_64.json"));
    const M = struct { version: []const u8, url: []const u8, sha256: []const u8, signature: []const u8, notes: []const u8, date: []const u8, size: u64 };
    const m = try std.json.parseFromSliceLeaky(M, ctx.gpa, try fsx.read(ctx, files[1]), .{});
    try std.testing.expectEqualStrings("2.0.0", m.version);
    try std.testing.expectEqualStrings("https://github.com/you/my-app/releases/download/v2.0.0/my-app-2.0.0-windows-x86_64.exe", m.url);
    try std.testing.expectEqualStrings("Faster and *better*.", m.notes);
    try std.testing.expectEqualStrings("2013-05-24T00:00:00Z", m.date);
    try std.testing.expectEqual(@as(u64, 18), m.size);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("the new executable", &digest, .{});
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), m.sha256);
    try std.testing.expect(updates.verify(kp.public_key, digest, m.signature));
    try std.testing.expectEqualStrings("https://github.com/you/my-app/releases/latest/download/update-windows-x86_64.json", try updates.fileUrl(ctx, c, "update-windows-x86_64.json", true));

    // The manifests go last.
    const list = try publish.uploads(ctx, &.{ files[1], root, files[0] });
    try std.testing.expectEqual(@as(usize, 1), list.files.len);
    try std.testing.expectEqualStrings(files[1], list.manifests[0]);
    try std.testing.expectEqualStrings("Cache-Control", publish.uploadHeaders("update-linux-x86_64.json")[1].name);
    try std.testing.expectEqual(@as(usize, 1), publish.uploadHeaders("app.dmg").len);

    // From a server of url: the executable beside the manifest, relative.
    c.updates.?.github = "";
    c.updates.?.url = "http://192.168.7.10/my-app";
    const served = try updates.writeUpdate(ctx, c, root, "windows-x86", exe);
    const sm = try std.json.parseFromSliceLeaky(M, ctx.gpa, try fsx.read(ctx, served[1]), .{});
    try std.testing.expectEqualStrings("my-app-2.0.0-windows-x86.exe", sm.url);

    // A changelog without the version's notes stops it.
    c.version = "3.0.0";
    try std.testing.expectError(error.CommandFailed, updates.writeUpdate(ctx, c, root, "windows-x86_64", exe));
}

test "keygen writes a pair that signs and checks" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const ctx = f.ctx();
    const dir = try ctx.join(&.{ try f.root(), "keys" });
    try updates.keygen(ctx, dir, false);
    const kp = updates.parsePrivateKey(try fsx.read(ctx, try ctx.join(&.{ dir, "myzig-update.key" }))).?;
    const pk = updates.parsePublicKey(try fsx.read(ctx, try ctx.join(&.{ dir, "myzig-update.pub" }))).?;
    try std.testing.expectEqualSlices(u8, &pk.toBytes(), &kp.public_key.toBytes());
    try std.testing.expectError(error.CommandFailed, updates.keygen(ctx, dir, false));
    try updates.keygen(ctx, dir, true);
}
