//! Signed updates, after mygo's cmd/mygo/updates.go: `myzig keygen` makes
//! the Ed25519 key pair, `myzig build` signs the SHA-256 of each platform's
//! update (its executable, which the updater plugin replaces) with the
//! secret key and writes `update-<platform>-<arch>.json` beside it, and apps
//! given the public key (`updater.Updater.public_key`) install only what it
//! signed.
//!
//!     .updates = .{
//!         .public_key = "…the contents of myzig-update.pub…",
//!         .github = "you/my-app", // or .url = "https://downloads.example.com/my-app"
//!         .s3 = .{ .bucket = "downloads", .prefix = "my-app" }, // with url: `--upload` puts there
//!     },
const std = @import("std");
const builtin = @import("builtin");
const fsx = @import("fsx.zig");
const config = @import("config.zig");
const zon = @import("zon.zig");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64 = std.base64.standard;
const Ctx = fsx.Ctx;
const Config = config.Config;
const LoadError = config.LoadError;

/// A bucket of Amazon S3, or of a compatible service such as Cloudflare
/// R2 (`s3.zig`). The credentials come from AWS_ACCESS_KEY_ID,
/// AWS_SECRET_ACCESS_KEY and AWS_SESSION_TOKEN.
pub const S3 = struct {
    bucket: []const u8 = "",
    /// The directory of the files in the bucket ("my-app"; default: its root).
    prefix: []const u8 = "",
    /// Default: AWS_REGION, else AWS_DEFAULT_REGION, else us-east-1.
    region: []const u8 = "",
    /// A compatible service's URL, "https://<account>.r2.cloudflarestorage.com".
    endpoint: []const u8 = "",
    /// The bucket in the path rather than in the host name (default: with
    /// an endpoint, or a bucket name with dots).
    path_style: ?bool = null,
};

pub const Updates = struct {
    /// The contents of myzig-update.pub (`myzig keygen`).
    public_key: []const u8 = "",
    /// The public repository ("owner/name") whose releases hold the
    /// updates, tagged `tag_prefix` ++ version; the latest serves the manifests.
    github: []const u8 = "",
    tag_prefix: []const u8 = "v",
    /// Where the files are served from instead, an HTTPS directory.
    url: []const u8 = "",
    /// The bucket that serves `url`, which `--upload` puts the files into.
    s3: ?S3 = null,
    /// The path of myzig-update.key; MYZIG_UPDATER_PRIVATE_KEY, holding the
    /// key itself, comes first.
    private_key: []const u8 = "",
    /// The Markdown file whose "## <version>" section is the release notes
    /// (default CHANGELOG.md when it exists).
    changelog: []const u8 = "",
};

pub const key_env = "MYZIG_UPDATER_PRIVATE_KEY";

pub fn decode(gpa: std.mem.Allocator, v: zon.Value) LoadError!Updates {
    var u: Updates = .{};
    try config.checkKeys(gpa, v, "updates", &.{ "public_key", "github", "tag_prefix", "url", "s3", "private_key", "changelog" });
    inline for (.{ "public_key", "github", "tag_prefix", "url", "private_key", "changelog" }) |k| try config.str(gpa, v, k, &@field(u, k));
    if (v.get("s3")) |s| {
        var b: S3 = .{};
        try config.checkKeys(gpa, s, "updates.s3", &.{ "bucket", "prefix", "region", "endpoint", "path_style" });
        inline for (.{ "bucket", "prefix", "region", "endpoint" }) |k| try config.str(gpa, s, k, &@field(b, k));
        if (s.get("path_style") != null) {
            var on = false;
            try config.boolean(gpa, s, "path_style", &on);
            b.path_style = on;
        }
        u.s3 = b;
    }
    return u;
}

pub fn validate(gpa: std.mem.Allocator, u: Updates) LoadError!void {
    if (u.public_key.len == 0) return config.invalid(gpa, "updates needs the public_key of myzig keygen", .{});
    if (parsePublicKey(u.public_key) == null) return config.invalid(gpa, "updates.public_key: invalid update public key", .{});
    if ((u.github.len == 0) == (u.url.len == 0)) return config.invalid(gpa, "updates needs either github (owner/name) or url", .{});
    if (u.github.len > 0 and std.mem.count(u8, u.github, "/") != 1) return config.invalid(gpa, "updates.github \"{s}\" is not owner/name", .{u.github});
    // http too (an intranet's server): the signature, not the transport,
    // is what installed apps trust, and public_key is required.
    if (u.url.len > 0) {
        const rest = if (std.mem.startsWith(u8, u.url, "https://")) u.url["https://".len..] else if (std.mem.startsWith(u8, u.url, "http://")) u.url["http://".len..] else "";
        if (rest.len == 0) return config.invalid(gpa, "updates.url \"{s}\" is not an http(s) URL", .{u.url});
    }
    if (u.s3) |s| {
        if (u.url.len == 0) return config.invalid(gpa, "updates.s3 needs url, the HTTPS URL that serves the files of the bucket, in place of github", .{});
        if (s.bucket.len == 0) return config.invalid(gpa, "updates.s3 needs a bucket", .{});
        if (s.endpoint.len > 0) {
            const scheme_end = std.mem.indexOf(u8, s.endpoint, "://") orelse return config.invalid(gpa, "updates.s3.endpoint \"{s}\" is not an http(s) URL", .{s.endpoint});
            const scheme = s.endpoint[0..scheme_end];
            const rest = s.endpoint[scheme_end + 3 ..];
            if (!(std.mem.eql(u8, scheme, "https") or std.mem.eql(u8, scheme, "http")) or rest.len == 0 or rest[0] == '/')
                return config.invalid(gpa, "updates.s3.endpoint \"{s}\" is not an http(s) URL", .{s.endpoint});
            if (std.mem.indexOfAny(u8, std.mem.trimEnd(u8, rest, "/"), "/?") != null)
                return config.invalid(gpa, "updates.s3.endpoint \"{s}\" has a path: the endpoint is the service's, and bucket names the bucket", .{s.endpoint});
        }
    }
}

/// What went wrong, for tests; it is printed too.
pub var message: []const u8 = "";

pub fn fail(ctx: Ctx, comptime f: []const u8, args: anytype) error{ CommandFailed, OutOfMemory } {
    message = try ctx.fmt(f, args);
    if (!ctx.quiet) std.debug.print("error: {s}\n", .{message});
    return error.CommandFailed;
}

/// Keys are kept in base64: the 32 bytes of the public key, the 64 of the
/// secret one (its seed, then the public key), as mygo keeps them.
pub fn parsePublicKey(text: []const u8) ?Ed25519.PublicKey {
    var raw: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    decodeExact(&raw, std.mem.trim(u8, text, " \t\r\n")) orelse return null;
    return Ed25519.PublicKey.fromBytes(raw) catch null;
}

pub fn parsePrivateKey(text: []const u8) ?Ed25519.KeyPair {
    var raw: [Ed25519.SecretKey.encoded_length]u8 = undefined;
    decodeExact(&raw, std.mem.trim(u8, text, " \t\r\n")) orelse return null;
    const sk = Ed25519.SecretKey.fromBytes(raw) catch return null;
    return Ed25519.KeyPair.fromSecretKey(sk) catch null;
}

fn decodeExact(out: []u8, text: []const u8) ?void {
    const n = b64.Decoder.calcSizeForSlice(text) catch return null;
    if (n != out.len) return null;
    b64.Decoder.decode(out, text) catch return null;
}

pub fn encodeKey(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, b64.Encoder.calcSize(bytes.len));
    _ = b64.Encoder.encode(out, bytes);
    return out;
}

/// The signature of the SHA-256 digest of an update, in base64.
pub fn sign(gpa: std.mem.Allocator, kp: Ed25519.KeyPair, digest: [Sha256.digest_length]u8) ![]u8 {
    const sig = kp.sign(&digest, null) catch return error.SigningFailed;
    return encodeKey(gpa, &sig.toBytes());
}

/// Whether `signature` (base64) signs `digest` with `pk`.
pub fn verify(pk: Ed25519.PublicKey, digest: [Sha256.digest_length]u8, signature: []const u8) bool {
    var raw: [Ed25519.Signature.encoded_length]u8 = undefined;
    decodeExact(&raw, signature) orelse return false;
    Ed25519.Signature.fromBytes(raw).verify(&digest, pk) catch return false;
    return true;
}

/// The key that signs updates, or null when none is given:
/// MYZIG_UPDATER_PRIVATE_KEY, else the file of `updates.private_key`
/// (which may start with `~/`). It must match `updates.public_key`.
pub fn signingKey(ctx: Ctx, c: Config) !?Ed25519.KeyPair {
    const u = c.updates orelse return null;
    var text: []const u8 = ctx.env.get(key_env) orelse "";
    if (text.len == 0 and u.private_key.len > 0) {
        var p = u.private_key;
        if (std.mem.startsWith(u8, p, "~/")) p = try ctx.join(&.{ home(ctx) orelse "", p[2..] });
        text = fsx.read(ctx, try c.path(ctx.gpa, p)) catch |e| return fail(ctx, "updates: reading {s}: {t}", .{ u.private_key, e });
    }
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return null;
    const kp = parsePrivateKey(text) orelse return fail(ctx, "updates: invalid update private key", .{});
    const pk = parsePublicKey(u.public_key) orelse return fail(ctx, "updates: invalid update public key", .{});
    if (!std.mem.eql(u8, &kp.public_key.toBytes(), &pk.toBytes()))
        return fail(ctx, "updates: the update signing key does not match updates.public_key in {s}", .{if (c.file.len > 0) c.file else config.zon_file});
    return kp;
}

fn home(ctx: Ctx) ?[]const u8 {
    return ctx.env.get("HOME") orelse ctx.env.get("USERPROFILE");
}

/// The user's configuration directory, where `myzig keygen` keeps keys.
pub fn configDir(ctx: Ctx) ![]const u8 {
    if (builtin.os.tag == .windows) if (ctx.env.get("APPDATA")) |d| return d;
    const h = home(ctx) orelse ".";
    if (builtin.os.tag == .macos) return ctx.join(&.{ h, "Library", "Application Support" });
    if (ctx.env.get("XDG_CONFIG_HOME")) |d| if (d.len > 0) return d;
    return ctx.join(&.{ h, ".config" });
}

/// The section of `version` in a changelog, under "## 1.2.0", "## [1.2.0]
/// - date" or "## [v1.2.0](link)" as Keep a Changelog writes them, or ""
/// when it has none. Trimmed; allocates in `gpa`.
pub fn releaseNotes(gpa: std.mem.Allocator, changelog: []const u8, version: []const u8) ![]const u8 {
    const want = std.mem.trimStart(u8, version, "v");
    var out: std.ArrayList(u8) = .empty;
    var in = false;
    var lines = std.mem.splitScalar(u8, changelog, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "## ")) {
            if (in) break;
            var fields = std.mem.tokenizeAny(u8, line[3..], " \t");
            const first = fields.next() orelse "";
            in = std.mem.eql(u8, std.mem.trimStart(u8, headingVersion(first), "v"), want);
            continue;
        }
        if (in) {
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
        }
    }
    return std.mem.trim(u8, out.items, " \t\r\n");
}

fn headingVersion(s: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, s, "[")) return s;
    const rest = s[1..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, ']') orelse rest.len];
}

/// The release notes of the app's version, from its changelog.
pub fn notesOf(ctx: Ctx, c: Config) ![]const u8 {
    const u = c.updates.?;
    const name = if (u.changelog.len > 0) u.changelog else "CHANGELOG.md";
    const p = try c.path(ctx.gpa, name);
    if (u.changelog.len == 0 and !fsx.exists(ctx.io, p)) return "";
    const text = fsx.read(ctx, p) catch |e| return fail(ctx, "updates: reading {s}: {t}", .{ name, e });
    const notes = try releaseNotes(ctx.gpa, text, c.version);
    if (notes.len == 0) return fail(ctx, "{s} has no notes for {s}: add a \"## {s}\" section", .{ name, c.version, c.version });
    return notes;
}

/// "update-macos-aarch64.json": each platform's manifest, which its builds
/// check.
pub fn manifestName(ctx: Ctx, target: []const u8) ![]u8 {
    return ctx.fmt("update-{s}.json", .{target});
}

/// The URL of a published file: manifests from the latest GitHub release
/// (`latest`), the rest from the release of this version, or from `url`.
pub fn fileUrl(ctx: Ctx, c: Config, name: []const u8, latest: bool) ![]u8 {
    const u = c.updates.?;
    if (u.github.len == 0) return ctx.fmt("{s}/{s}", .{ std.mem.trimEnd(u8, u.url, "/"), name });
    if (latest) return ctx.fmt("https://github.com/{s}/releases/latest/download/{s}", .{ u.github, name });
    return ctx.fmt("https://github.com/{s}/releases/download/{s}{s}/{s}", .{ u.github, u.tag_prefix, c.version, name });
}

/// What apps read: `updater.Manifest` of the plugin, signed.
pub const Manifest = struct {
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
    signature: []const u8,
    notes: []const u8,
    date: []const u8,
    size: u64,
};

/// Signs the update of `target` (the executable `exe`, which the updater
/// plugin puts in place of the installed one) and writes it to `dir` with
/// its manifest, which it returns with it; nothing without a key, after a
/// warning.
pub fn writeUpdate(ctx: Ctx, c: Config, dir: []const u8, target: []const u8, exe: []const u8) ![]const []const u8 {
    if (c.updates == null) return &.{};
    const kp = try signingKey(ctx, c) orelse {
        if (!ctx.quiet) ctx.warn("not signing an update: set {s} or updates.private_key", .{key_env});
        return &.{};
    };
    const notes = try notesOf(ctx, c);
    const bytes = try fsx.read(ctx, exe);
    const ext: []const u8 = if (std.mem.startsWith(u8, target, "windows-")) ".exe" else "";
    const name = try ctx.fmt("{s}-{s}-{s}{s}", .{ try config.slug(ctx.gpa, c.executable, '-'), c.version, target, ext });
    const payload = try ctx.join(&.{ dir, name });
    try fsx.writeExecutable(ctx.io, payload, bytes);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    const m: Manifest = .{
        .version = c.version,
        // Beside the manifest on a server of `url`, relative: the app's
        // manifest URL decides, so builds (dev, production) can check
        // directories of their own.
        .url = if (c.updates.?.github.len == 0) name else try fileUrl(ctx, c, name, false),
        .sha256 = &std.fmt.bytesToHex(digest, .lower),
        .signature = try sign(ctx.gpa, kp, digest),
        .notes = notes,
        .date = try rfc3339(ctx, fsx.epoch(ctx)),
        .size = bytes.len,
    };
    const json = try std.json.Stringify.valueAlloc(ctx.gpa, m, .{ .whitespace = .indent_2 });
    const manifest = try ctx.join(&.{ dir, try manifestName(ctx, target) });
    try fsx.write(ctx.io, manifest, try ctx.fmt("{s}\n", .{json}));
    ctx.log("Signed the update of {s}; apps check {s}", .{ target, try fileUrl(ctx, c, try manifestName(ctx, target), true) });
    return ctx.gpa.dupe([]const u8, &.{ payload, manifest });
}

/// "2026-10-19T08:30:00Z".
pub fn rfc3339(ctx: Ctx, secs: u64) ![]u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return ctx.fmt("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
}

/// `myzig keygen`: writes myzig-update.key (the secret) and
/// myzig-update.pub to `out` (default `<config>/myzig/update-keys`).
pub fn keygen(ctx: Ctx, out_dir: []const u8, force: bool) !void {
    const dir = if (out_dir.len > 0) out_dir else try ctx.join(&.{ try configDir(ctx), "myzig", "update-keys" });
    const secret = try ctx.join(&.{ dir, "myzig-update.key" });
    const public = try ctx.join(&.{ dir, "myzig-update.pub" });
    if (!force and (fsx.exists(ctx.io, secret) or fsx.exists(ctx.io, public)))
        return fail(ctx, "{s} already holds keys; pass --force to replace them", .{dir});
    const kp = Ed25519.KeyPair.generate(ctx.io);
    const pub_text = try encodeKey(ctx.gpa, &kp.public_key.toBytes());
    try fsx.write(ctx.io, secret, try ctx.fmt("{s}\n", .{try encodeKey(ctx.gpa, &kp.secret_key.toBytes())}));
    try fsx.write(ctx.io, public, try ctx.fmt("{s}\n", .{pub_text}));
    ctx.log("Wrote {s} (secret) and {s}", .{ secret, public });
    if (!ctx.quiet) fsx.out(ctx.io, "Add to myzig.zon:\n\n    .updates = .{{\n        .public_key = \"{s}\",\n        .github = \"owner/name\",\n    }},\n", .{pub_text});
}

test {
    _ = @import("updates_test.zig");
}
