//! The user's choices about updates, kept as `updater.json` in the app's
//! data directory: whether to check by itself, whether to install without
//! asking, the version skipped, and when it last checked.
const std = @import("std");
const Io = std.Io;

pub const Prefs = struct {
    automaticChecks: bool = true,
    automaticDownloads: bool = false,
    /// Background checks do not offer it again (the next one, they do).
    skippedVersion: ?[]const u8 = null,
    /// Seconds since 1970; 0 for never.
    lastCheck: i64 = 0,

    /// Reads `path`; defaults when it is missing or unreadable.
    pub fn load(io: Io, arena: std.mem.Allocator, path: []const u8) Prefs {
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 10)) catch return .{};
        return std.json.parseFromSliceLeaky(Prefs, arena, bytes, .{ .ignore_unknown_fields = true }) catch .{};
    }

    /// Writes `path` (its directory must exist), replacing it whole.
    pub fn save(p: Prefs, io: Io, path: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        try std.json.Stringify.value(p, .{ .whitespace = .indent_2 }, &w);
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
        const cwd = Io.Dir.cwd();
        try cwd.writeFile(io, .{ .sub_path = tmp, .data = w.buffered() });
        try cwd.rename(tmp, cwd, path, io);
    }

    /// Whether a background check is due at `now` (seconds), every `interval`.
    pub fn due(p: Prefs, now: i64, interval: i64) bool {
        return p.automaticChecks and now - p.lastCheck >= interval;
    }

    /// Whether a background check is due at `now`: the first since launch
    /// is (`checked_since_launch` false), whenever the last one was, so a
    /// version out since the app last ran shows when it opens again; then
    /// every `interval`. Never when the user turned checks off.
    pub fn dueAt(p: Prefs, now: i64, interval: i64, checked_since_launch: bool) bool {
        if (!p.automaticChecks) return false;
        return !checked_since_launch or p.due(now, interval);
    }

    /// Whether a background check offers `version`.
    pub fn offers(p: Prefs, version: []const u8) bool {
        const skipped = p.skippedVersion orelse return true;
        return !std.mem.eql(u8, skipped, version);
    }
};

test "prefs round-trip through the file, and defaults when it is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}{c}updater.json", .{ dir_buf[0..n], std.fs.path.sep });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const none = Prefs.load(std.testing.io, arena.allocator(), path);
    try std.testing.expect(none.automaticChecks and !none.automaticDownloads and none.skippedVersion == null);
    try (Prefs{ .automaticDownloads = true, .skippedVersion = "2.0.0", .lastCheck = 1000 }).save(std.testing.io, path);
    const back = Prefs.load(std.testing.io, arena.allocator(), path);
    try std.testing.expect(back.automaticDownloads);
    try std.testing.expectEqualStrings("2.0.0", back.skippedVersion.?);
    try std.testing.expect(!back.offers("2.0.0") and back.offers("2.0.1"));
    try std.testing.expect(!back.due(1000 + 3600, 86400) and back.due(1000 + 86400, 86400));
}

test "a check soon after every launch, then once an interval" {
    // The last launch checked an hour ago; a version came out since.
    const p: Prefs = .{ .lastCheck = 1000 };
    try std.testing.expect(p.dueAt(1000 + 3600, 86400, false));
    // Then an interval after it, not at once again.
    try std.testing.expect(!p.dueAt(1000 + 3600, 86400, true));
    try std.testing.expect(p.dueAt(1000 + 86400, 86400, true));
    // Not when the user turned them off.
    try std.testing.expect(!(Prefs{ .automaticChecks = false }).dueAt(0, 86400, false));
}
