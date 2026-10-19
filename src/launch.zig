//! What a launch hands the app, the same on every platform: the URLs of
//! its schemes and the files of its types among the command line's
//! arguments (Windows and Linux start apps with them), and the message a
//! later instance sends the first one.
const std = @import("std");
const builtin = @import("builtin");

/// Whether `s` is a URL scheme: a letter, then letters, digits, "+", "-", ".".
pub fn isUrlScheme(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s, 0..) |c, i| {
        if (std.ascii.isAlphabetic(c)) continue;
        if (i == 0) return false;
        if (!std.ascii.isDigit(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return true;
}

/// The URL `arg` is when its scheme is one of `schemes`, else null.
pub fn urlOf(arg: []const u8, schemes: []const []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, arg, ':') orelse return null;
    const scheme = arg[0..colon];
    // A single letter is a Windows drive, as in C:\.
    if (scheme.len < 2 or !isUrlScheme(scheme)) return null;
    for (schemes) |s| if (std.ascii.eqlIgnoreCase(s, scheme)) return arg;
    return null;
}

/// The path of the file `arg` names when its extension is one of
/// `extensions` (file: URLs too), absolute against `cwd`; null otherwise.
/// It is not checked to exist. Caller frees it.
pub fn fileOf(gpa: std.mem.Allocator, arg: []const u8, cwd: []const u8, extensions: []const []const u8) !?[]u8 {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(gpa);
    var p = arg;
    if (std.ascii.startsWithIgnoreCase(arg, "file://")) {
        var rest = arg["file://".len..];
        // file://host/path: only the local host.
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        rest = rest[slash..];
        try percentDecode(gpa, &decoded, rest);
        p = decoded.items;
        // file:///C:/x on Windows.
        if (p.len >= 3 and p[0] == '/' and p[2] == ':') p = p[1..];
    }
    const ext = std.fs.path.extension(p);
    if (ext.len < 2) return null;
    var known = false;
    for (extensions) |e| {
        const want = if (e.len > 0 and e[0] == '.') e[1..] else e;
        if (std.ascii.eqlIgnoreCase(want, ext[1..])) known = true;
    }
    if (!known) return null;
    if (isAbsolute(p)) return try gpa.dupe(u8, p);
    return try std.fs.path.join(gpa, &.{ cwd, p });
}

fn isAbsolute(p: []const u8) bool {
    if (p.len > 0 and (p[0] == '/' or p[0] == '\\')) return true;
    return p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/');
}

fn percentDecode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                try out.append(gpa, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(gpa, s[i]);
    }
}

/// Whether `arg` is one of myzig's own flags (`--myzig-...`), which apps never see.
pub fn isOwnFlag(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "--myzig-");
}

/// The name of the app's single instance lock: "myzig-" and a hash of its
/// id, short enough for a Unix socket's path.
pub fn instanceName(buf: *[24]u8, id: []const u8) []const u8 {
    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &sum, .{});
    const hex = std.fmt.bytesToHex(sum[0..8], .lower);
    @memcpy(buf[0..6], "myzig-");
    @memcpy(buf[6..22], &hex);
    return buf[0..22];
}

/// A later instance's message: its working directory and arguments, each
/// followed by a NUL.
pub fn encodeMessage(gpa: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, cwd);
    try out.append(gpa, 0);
    for (args) |a| {
        if (isOwnFlag(a)) continue;
        try out.appendSlice(gpa, a);
        try out.append(gpa, 0);
    }
    return out.toOwnedSlice(gpa);
}

pub const Message = struct {
    working_dir: []const u8,
    /// Slices of the message's bytes.
    args: [][]const u8,

    pub fn deinit(m: Message, gpa: std.mem.Allocator) void {
        gpa.free(m.args);
    }
};

/// Decodes `bytes` (an `encodeMessage`), whose slices it returns.
pub fn decodeMessage(gpa: std.mem.Allocator, bytes: []const u8) !Message {
    var it = std.mem.splitScalar(u8, bytes, 0);
    const cwd = it.next() orelse return error.BadMessage;
    if (std.mem.indexOfScalar(u8, bytes, 0) == null) return error.BadMessage;
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(gpa);
    while (it.next()) |a| {
        // The terminator of the last argument leaves an empty piece.
        if (it.index == null and a.len == 0) break;
        try args.append(gpa, a);
    }
    return .{ .working_dir = cwd, .args = try args.toOwnedSlice(gpa) };
}

test "URL schemes" {
    try std.testing.expect(isUrlScheme("myapp"));
    try std.testing.expect(isUrlScheme("x-my.app+1"));
    try std.testing.expect(!isUrlScheme("1app"));
    try std.testing.expect(!isUrlScheme("my app"));
    try std.testing.expect(!isUrlScheme(""));
    const schemes: []const []const u8 = &.{"MyApp"};
    try std.testing.expectEqualStrings("myapp://open?note=1", urlOf("myapp://open?note=1", schemes).?);
    try std.testing.expect(urlOf("other://x", schemes) == null);
    try std.testing.expect(urlOf("C:\\x\\myapp.md", schemes) == null);
    try std.testing.expect(urlOf("--flag", schemes) == null);
}

test "files of the app's types among the arguments" {
    const gpa = std.testing.allocator;
    const exts: []const []const u8 = &.{ "md", ".txt" };
    const a = (try fileOf(gpa, "notes/a.MD", "/home/u", exts)).?;
    defer gpa.free(a);
    try std.testing.expectEqualStrings("/home/u" ++ std.fs.path.sep_str ++ "notes/a.MD", a);
    const b = (try fileOf(gpa, "/tmp/b.txt", "/home/u", exts)).?;
    defer gpa.free(b);
    try std.testing.expectEqualStrings("/tmp/b.txt", b);
    const c = (try fileOf(gpa, "file:///tmp/my%20notes.md", "/", exts)).?;
    defer gpa.free(c);
    try std.testing.expectEqualStrings("/tmp/my notes.md", c);
    const d = (try fileOf(gpa, "file:///C:/Users/a.md", "/", exts)).?;
    defer gpa.free(d);
    try std.testing.expectEqualStrings("C:/Users/a.md", d);
    const e = (try fileOf(gpa, "C:\\x\\e.md", "D:\\", exts)).?;
    defer gpa.free(e);
    try std.testing.expectEqualStrings("C:\\x\\e.md", e);
    try std.testing.expect((try fileOf(gpa, "a.png", "/", exts)) == null);
    try std.testing.expect((try fileOf(gpa, "README", "/", exts)) == null);
}

test "a later instance's message" {
    const gpa = std.testing.allocator;
    const bytes = try encodeMessage(gpa, "/home/u", &.{ "a.md", "--myzig-hidden", "", "myapp://x" });
    defer gpa.free(bytes);
    const m = try decodeMessage(gpa, bytes);
    defer m.deinit(gpa);
    try std.testing.expectEqualStrings("/home/u", m.working_dir);
    try std.testing.expectEqual(@as(usize, 3), m.args.len);
    try std.testing.expectEqualStrings("a.md", m.args[0]);
    try std.testing.expectEqualStrings("", m.args[1]);
    try std.testing.expectEqualStrings("myapp://x", m.args[2]);
    try std.testing.expectError(error.BadMessage, decodeMessage(gpa, "no terminator"));
    var buf: [24]u8 = undefined;
    const n = instanceName(&buf, "com.example.notes");
    try std.testing.expectEqual(@as(usize, 22), n.len);
    try std.testing.expect(std.mem.startsWith(u8, n, "myzig-"));
    var buf2: [24]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, n, instanceName(&buf2, "com.example.other")));
}
