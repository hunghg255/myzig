//! `myzig build --upload`, after mygo's cmd/mygo/publish.go: the packages
//! and signed updates of a build go where `updates` points, the bucket of
//! `updates.s3` (`s3.zig`) or a draft GitHub release of the version (with
//! the gh CLI), the manifests last, so that they never name a file that is
//! not there yet.
const std = @import("std");
const fsx = @import("fsx.zig");
const proc = @import("proc.zig");
const updates = @import("updates.zig");
const s3 = @import("s3.zig");
const Config = @import("config.zig").Config;
const Ctx = fsx.Ctx;

/// Checks, before a build, that `--upload` has somewhere to upload to and
/// the key that signs the updates: without it the build writes no
/// manifests, and installed apps could not update to the release.
pub fn checkUpload(ctx: Ctx, c: Config) !void {
    const u = c.updates orelse return updates.fail(ctx, "--upload needs updates.github or updates.s3 in {s}", .{configName(c)});
    if (u.s3) |b| {
        _ = try s3.Client.init(ctx, b);
    } else if (u.github.len == 0) return updates.fail(ctx, "--upload needs updates.github or updates.s3 in {s}", .{configName(c)});
    if (try updates.signingKey(ctx, c) == null)
        return updates.fail(ctx, "--upload needs the update signing key, or installed apps could not update to this release: set {s} or updates.private_key", .{updates.key_env});
}

fn configName(c: Config) []const u8 {
    return if (c.file.len > 0) c.file else "myzig.zon";
}

/// The files of a build to publish: the packages and updates, and apart
/// the manifests. Directories (a bundle, a staged app) ship inside the
/// packages.
pub fn uploads(ctx: Ctx, built: []const []const u8) !struct { files: []const []const u8, manifests: []const []const u8 } {
    var files: std.ArrayList([]const u8) = .empty;
    var manifests: std.ArrayList([]const u8) = .empty;
    for (built) |f| {
        if (!fsx.isFile(ctx.io, f)) continue;
        const name = std.fs.path.basename(f);
        if (isManifest(name)) try manifests.append(ctx.gpa, f) else try files.append(ctx.gpa, f);
    }
    if (files.items.len + manifests.items.len == 0) return updates.fail(ctx, "nothing to upload", .{});
    return .{ .files = files.items, .manifests = manifests.items };
}

fn isManifest(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "update-") and std.mem.endsWith(u8, name, ".json");
}

/// Uploads what a build made.
pub fn publish(ctx: Ctx, c: Config, built: []const []const u8) !void {
    const u = c.updates.?;
    const list = try uploads(ctx, built);
    if (u.s3) |b| return publishS3(ctx, c, b, list.files, list.manifests);
    return publishGitHub(ctx, c, list.files, list.manifests);
}

fn publishS3(ctx: Ctx, c: Config, b: updates.S3, files: []const []const u8, manifests: []const []const u8) !void {
    const client = try s3.Client.init(ctx, b);
    var http: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer http.deinit();
    for ([_][]const []const u8{ files, manifests }) |batch| for (batch) |f| {
        const name = std.fs.path.basename(f);
        ctx.log("Uploading {s}", .{name});
        try client.put(ctx, &http, try client.key(ctx, name), f, uploadHeaders(name));
    };
    ctx.log("Uploaded to s3://{s}/{s}, which {s} serves", .{ client.bucket, client.prefix, c.updates.?.url });
}

/// The headers of an uploaded file: its type and, for the manifests,
/// whose names stay from version to version, that caches check again.
pub fn uploadHeaders(name: []const u8) []const s3.Header {
    const types = [_][2][]const u8{
        .{ ".dmg", "application/x-apple-diskimage" },        .{ ".exe", "application/vnd.microsoft.portable-executable" },
        .{ ".deb", "application/vnd.debian.binary-package" }, .{ ".gz", "application/gzip" },
        .{ ".zip", "application/zip" },                       .{ ".json", "application/json" },
    };
    const typ = for (types) |t| {
        if (std.mem.endsWith(u8, name, t[0])) break t[1];
    } else "application/octet-stream";
    const S = struct {
        threadlocal var buf: [2]s3.Header = undefined;
    };
    S.buf[0] = .{ .name = "Content-Type", .value = typ };
    if (isManifest(name)) {
        S.buf[1] = .{ .name = "Cache-Control", .value = "no-cache" };
        return S.buf[0..2];
    }
    return S.buf[0..1];
}

fn publishGitHub(ctx: Ctx, c: Config, files: []const []const u8, manifests: []const []const u8) !void {
    const u = c.updates.?;
    const gh = proc.which(ctx, "gh") orelse
        return updates.fail(ctx, "--upload needs the GitHub CLI (https://cli.github.com), signed in with gh auth login or GH_TOKEN", .{});
    const tag = try ctx.fmt("{s}{s}", .{ u.tag_prefix, c.version });
    const view = try proc.capture(ctx, &.{ gh, "release", "view", tag, "--repo", u.github }, null);
    if (!view.ok) {
        const notes = updates.notesOf(ctx, c) catch "";
        ctx.log("Creating the draft release {s} of {s}", .{ tag, u.github });
        try proc.check(ctx, &.{ gh, "release", "create", tag, "--repo", u.github, "--draft", "--title", tag, "--notes", notes }, null);
    }
    for ([_][]const []const u8{ files, manifests }) |batch| {
        if (batch.len == 0) continue;
        ctx.log("Uploading {d} file(s) to {s}", .{ batch.len, tag });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(ctx.gpa, &.{ gh, "release", "upload", tag, "--repo", u.github, "--clobber" });
        try argv.appendSlice(ctx.gpa, batch);
        try proc.check(ctx, argv.items, null);
    }
    ctx.log("Uploaded to the release {s} of {s}; publish it when every platform is there:\n  gh release edit {s} --repo {s} --draft=false", .{ tag, u.github, tag, u.github });
}
