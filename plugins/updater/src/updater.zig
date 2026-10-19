//! Updates for myzig apps, after mygo's updater plugin: a manifest says the
//! latest version, where its executable is and its SHA-256; the updater
//! checks it, downloads the executable verifying it, and puts it in place
//! of the running one, which takes effect when the app next starts
//! (`relaunch` starts it now). Pages use it through `Service`.
//!
//!     const u: updater.Updater = .{ .gpa = gpa, .io = io, .client = &client, .manifest_url = url, .current = "1.0.0" };
//!     if (try u.check(arena)) |update| {
//!         const staged = try u.download(arena, update, null);
//!         try u.install(staged);
//!     }
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
pub const prefs = @import("prefs.zig");
pub const Prefs = prefs.Prefs;
pub const Service = @import("service.zig").Service;
pub const ServiceOptions = @import("service.zig").Options;
pub const StateEvent = @import("service.zig").StateEvent;
pub const State = @import("service.zig").State;
pub const Listener = @import("service.zig").Listener;
pub const texts = @import("texts.zig");
pub const Texts = texts.Texts;
/// "Check for Updates…" in the language the app shows now.
pub const menuItemLabel = texts.menuItem;
pub const Window = @import("window.zig").Window;
pub const WindowOptions = @import("window.zig").Options;
pub const WindowView = @import("window_view.zig").View;

/// The manifest, as JSON: `{"version": "1.2.0", "url": "https://…/app",
/// "sha256": "<64 hex digits>", "notes": "Markdown", "size": 1234}`, and
/// as `myzig build` writes it, `"signature"`: the Ed25519 signature of the
/// SHA-256, in base64, and the `"date"`.
pub const Manifest = struct {
    version: []const u8,
    /// Absolute, or relative to the manifest's URL.
    url: []const u8,
    sha256: []const u8,
    signature: ?[]const u8 = null,
    notes: []const u8 = "",
    size: ?u64 = null,
};

pub const Update = struct {
    version: []const u8,
    /// Resolved against the manifest's URL.
    url: []const u8,
    sha256: [32]u8,
    notes: []const u8,
    size: ?u64,
    /// The Ed25519 signature of `sha256`, checked with `Updater.public_key`.
    signature: ?[Ed25519.Signature.encoded_length]u8 = null,
};

const Ed25519 = std.crypto.sign.Ed25519;

/// How far a download is: `total` is null when the server did not say.
pub const Progress = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, done: u64, total: ?u64) void,
};

pub const Error = error{ BadManifest, BadVersion, HttpStatus, ChecksumMismatch, TooLarge, SizeMismatch, Unsigned, BadSignature, BadPublicKey };

pub const Updater = struct {
    gpa: std.mem.Allocator,
    io: Io,
    client: *std.http.Client,
    manifest_url: []const u8,
    /// The running version (semantic: 1.2.3, with a pre-release maybe).
    current: []const u8,
    /// The executable replaced; the running one when null.
    exe_path: ?[]const u8 = null,
    /// The most bytes a download may have.
    max_size: u64 = 1 << 30,
    /// The contents of myzig-update.pub (`myzig keygen`), base64: with it,
    /// only updates signed with its secret key install, and a manifest
    /// without a signature is refused. Without it the manifest's SHA-256
    /// is the trust, so serve it over HTTPS.
    public_key: ?[]const u8 = null,

    /// Reads the manifest: the update when its version is newer than the
    /// running one, else null. Allocates in `arena`.
    pub fn check(u: *const Updater, arena: std.mem.Allocator) !?Update {
        const body = try get(u.client, arena, u.manifest_url, 1 << 20, null);
        const m = std.json.parseFromSliceLeaky(Manifest, arena, body, .{ .ignore_unknown_fields = true }) catch return error.BadManifest;
        if (!(try isNewer(m.version, u.current))) return null;
        var sha: [32]u8 = undefined;
        if (m.sha256.len != 64) return error.BadManifest;
        _ = std.fmt.hexToBytes(&sha, m.sha256) catch return error.BadManifest;
        var update: Update = .{ .version = m.version, .url = try resolve(arena, u.manifest_url, m.url), .sha256 = sha, .notes = m.notes, .size = m.size };
        if (u.public_key != null) {
            const text = m.signature orelse return error.Unsigned;
            var sig: [Ed25519.Signature.encoded_length]u8 = undefined;
            const n = std.base64.standard.Decoder.calcSizeForSlice(text) catch return error.BadSignature;
            if (n != sig.len) return error.BadSignature;
            std.base64.standard.Decoder.decode(&sig, text) catch return error.BadSignature;
            update.signature = sig;
        }
        return update;
    }

    /// Downloads the update next to the executable (`<exe>.update`),
    /// verifying its SHA-256; returns that path. A file that does not match
    /// is removed.
    pub fn download(u: *const Updater, arena: std.mem.Allocator, update: Update, progress: ?Progress) ![]const u8 {
        const exe = try u.exePath(arena);
        const staged = try std.fmt.allocPrint(arena, "{s}.update", .{exe});
        const cwd = Io.Dir.cwd();
        var file = try cwd.createFile(u.io, staged, .{ .permissions = .executable_file });
        var ok = false;
        defer if (!ok) cwd.deleteFile(u.io, staged) catch {};
        {
            defer file.close(u.io);
            var sink: FileSink = .{ .io = u.io, .file = file };
            _ = try get(u.client, arena, update.url, u.max_size, .{ .sink = &sink, .progress = progress, .expected = update.size });
            var digest: [32]u8 = undefined;
            sink.sha.final(&digest);
            if (!std.mem.eql(u8, &digest, &update.sha256)) return error.ChecksumMismatch;
            if (u.public_key) |key| try verify(key, digest, update.signature orelse return error.Unsigned);
        }
        ok = true;
        return staged;
    }

    /// Puts `staged` in place of the executable. Windows lets a running
    /// executable be renamed, not replaced: it moves aside to `<exe>.old`
    /// (`cleanup` removes it on the next start). Elsewhere the rename
    /// replaces it at once. Either way the running app goes on as it was.
    pub fn install(u: *const Updater, staged: []const u8) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const exe = try u.exePath(fba.allocator());
        const cwd = Io.Dir.cwd();
        if (builtin.os.tag == .windows) {
            var old_buf: [std.fs.max_path_bytes]u8 = undefined;
            const old = try std.fmt.bufPrint(&old_buf, "{s}.old", .{exe});
            cwd.deleteFile(u.io, old) catch {};
            try cwd.rename(exe, cwd, old, u.io);
            cwd.rename(staged, cwd, exe, u.io) catch |err| {
                // Put it back.
                cwd.rename(old, cwd, exe, u.io) catch {};
                return err;
            };
        } else {
            try cwd.rename(staged, cwd, exe, u.io);
        }
    }

    /// Removes what an update left: the executable moved aside, a download
    /// never installed. Call it when the app starts.
    pub fn cleanup(u: *const Updater) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const exe = u.exePath(fba.allocator()) catch return;
        var p: [std.fs.max_path_bytes]u8 = undefined;
        for ([_][]const u8{ ".old", ".update" }) |ext| {
            const path = std.fmt.bufPrint(&p, "{s}{s}", .{ exe, ext }) catch continue;
            Io.Dir.cwd().deleteFile(u.io, path) catch {};
        }
    }

    /// Starts the executable (the new one once installed) with `args`;
    /// the caller then quits.
    pub fn relaunch(u: *const Updater, args: []const []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(u.gpa);
        defer arena.deinit();
        const exe = try u.exePath(arena.allocator());
        const argv = try arena.allocator().alloc([]const u8, args.len + 1);
        argv[0] = exe;
        @memcpy(argv[1..], args);
        _ = try std.process.spawn(u.io, .{ .argv = argv });
    }

    fn exePath(u: *const Updater, gpa: std.mem.Allocator) ![]const u8 {
        if (u.exe_path) |p| return gpa.dupe(u8, p);
        return std.process.executablePathAlloc(u.io, gpa);
    }
};

/// Checks that `signature` signs the SHA-256 `digest` with the public key
/// `key` (base64), as `myzig build` signs updates.
pub fn verify(key: []const u8, digest: [32]u8, signature: [Ed25519.Signature.encoded_length]u8) !void {
    const text = std.mem.trim(u8, key, " \t\r\n");
    var raw: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    const n = std.base64.standard.Decoder.calcSizeForSlice(text) catch return error.BadPublicKey;
    if (n != raw.len) return error.BadPublicKey;
    std.base64.standard.Decoder.decode(&raw, text) catch return error.BadPublicKey;
    const pk = Ed25519.PublicKey.fromBytes(raw) catch return error.BadPublicKey;
    Ed25519.Signature.fromBytes(signature).verify(&digest, pk) catch return error.BadSignature;
}

/// True when `candidate` is a newer semantic version than `current`.
pub fn isNewer(candidate: []const u8, current: []const u8) !bool {
    const a = std.SemanticVersion.parse(std.mem.trimStart(u8, candidate, "v")) catch return error.BadVersion;
    const b = std.SemanticVersion.parse(std.mem.trimStart(u8, current, "v")) catch return error.BadVersion;
    return a.order(b) == .gt;
}

/// `url` against the manifest's: absolute ones stay as they are.
pub fn resolve(arena: std.mem.Allocator, base: []const u8, url: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, url, "://") != null) return url;
    const b = try std.Uri.parse(base);
    const buf = try arena.alloc(u8, base.len + url.len + 16);
    @memcpy(buf[0..url.len], url);
    var aux: []u8 = buf;
    const r = b.resolveInPlace(url.len, &aux) catch return error.BadManifest;
    return std.fmt.allocPrint(arena, "{f}", .{r.fmt(.{ .scheme = true, .authority = true, .path = true, .query = true })});
}

const FileSink = struct {
    io: Io,
    file: Io.File,
    sha: std.crypto.hash.sha2.Sha256 = .init(.{}),

    fn write(s: *FileSink, bytes: []const u8) !void {
        s.sha.update(bytes);
        try s.file.writeStreamingAll(s.io, bytes);
    }
};

const Stream = struct { sink: *FileSink, progress: ?Progress, expected: ?u64 };

/// GETs `url`: the body in memory (null `stream`), or written to a file.
fn get(client: *std.http.Client, arena: std.mem.Allocator, url: []const u8, max: u64, stream: ?Stream) ![]const u8 {
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{ .redirect_behavior = .init(10), .headers = .{ .user_agent = .{ .override = "myzig-updater" } } });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [8192]u8 = undefined;
    var res = try req.receiveHead(&redirect_buf);
    if (res.head.status != .ok) return error.HttpStatus;
    const total = res.head.content_length;
    if (total) |t| if (t > max) return error.TooLarge;
    var transfer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const window: []u8 = switch (res.head.content_encoding) {
        .identity => &.{},
        else => try arena.alloc(u8, std.compress.flate.max_window_len),
    };
    const body = res.readerDecompressing(&transfer, &decompress, window);
    var out: std.ArrayList(u8) = .empty;
    var buf: [64 << 10]u8 = undefined;
    var done: u64 = 0;
    while (true) {
        var w: Io.Writer = .fixed(&buf);
        const n = body.stream(&w, .limited(buf.len)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return res.bodyErr() orelse error.ReadFailed,
            error.WriteFailed => unreachable,
        };
        done += n;
        if (done > max) return error.TooLarge;
        if (stream) |s| {
            try s.sink.write(buf[0..n]);
            if (s.progress) |p| p.func(p.ctx, done, total orelse s.expected);
        } else try out.appendSlice(arena, buf[0..n]);
    }
    if (stream) |s| if (s.expected) |e| if (e != done) return error.SizeMismatch;
    return out.items;
}

test isNewer {
    try std.testing.expect(try isNewer("1.2.0", "1.1.9"));
    try std.testing.expect(try isNewer("v2.0.0", "1.9.9"));
    try std.testing.expect(!try isNewer("1.2.0", "1.2.0"));
    try std.testing.expect(try isNewer("1.2.0", "1.2.0-beta.1"));
    try std.testing.expect(!try isNewer("1.2.0-beta.1", "1.2.0"));
    try std.testing.expectError(error.BadVersion, isNewer("one", "1.0.0"));
}

test resolve {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("http://h:8/releases/app-2", try resolve(a, "http://h:8/releases/latest.json", "app-2"));
    try std.testing.expectEqualStrings("http://h:8/app", try resolve(a, "http://h:8/releases/latest.json", "/app"));
    try std.testing.expectEqualStrings("https://cdn/x", try resolve(a, "http://h/m.json", "https://cdn/x"));
}

test verify {
    const kp = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("the app", &digest, .{});
    const sig = (try kp.sign(&digest, null)).toBytes();
    var key: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &kp.public_key.toBytes());
    try verify(&key, digest, sig);
    digest[0] ^= 1;
    try std.testing.expectError(error.BadSignature, verify(&key, digest, sig));
    try std.testing.expectError(error.BadPublicKey, verify("nope", digest, sig));
}

test {
    _ = prefs;
    _ = @import("service.zig");
    _ = @import("texts.zig");
    _ = @import("window_view.zig");
    std.testing.refAllDecls(@import("window.zig").Window);
}
