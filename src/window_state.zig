//! Where windows were: each key's frame and maximized state, kept in
//! `window-state.txt` in the app's data directory (a line a key:
//! "key<TAB>x y width height maximized"), loaded with the first window
//! that has a key and written when such a window closes. Windows reach it
//! through `key` (`.state = myzig.windowState("main")`), so apps that
//! remember none don't link it.
const std = @import("std");
const builtin = @import("builtin");
const window_types = @import("window_types.zig");

pub const State = window_types.WindowState;

pub const Store = struct {
    gpa: std.mem.Allocator,
    map: std.StringArrayHashMapUnmanaged(State) = .empty,
    /// The file, or null to keep states in memory (tests).
    path: ?[]u8 = null,

    pub fn deinit(s: *Store) void {
        for (s.map.keys()) |k| s.gpa.free(k);
        s.map.deinit(s.gpa);
        if (s.path) |p| s.gpa.free(p);
    }

    pub fn get(s: *Store, key_: []const u8) ?State {
        return s.map.get(key_);
    }

    pub fn put(s: *Store, key_: []const u8, state: State) !void {
        if (s.map.getPtr(key_)) |p| {
            p.* = state;
            return;
        }
        const k = try s.gpa.dupe(u8, key_);
        errdefer s.gpa.free(k);
        try s.map.put(s.gpa, k, state);
    }

    /// Reads states, a line each; lines not understood are skipped (and
    /// a text of nothing else is `error.BadStates`).
    pub fn parse(s: *Store, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var read: usize = 0;
        var bad: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const tab = std.mem.lastIndexOfScalar(u8, line, '\t') orelse {
                bad += 1;
                continue;
            };
            var nums = std.mem.tokenizeScalar(u8, line[tab + 1 ..], ' ');
            var v: [5]f64 = undefined;
            var n: usize = 0;
            while (nums.next()) |t| : (n += 1) {
                if (n == v.len) break;
                v[n] = std.fmt.parseFloat(f64, t) catch break;
            }
            if (n < 4) {
                bad += 1;
                continue;
            }
            try s.put(line[0..tab], .{ .x = v[0], .y = v[1], .width = v[2], .height = v[3], .maximized = n > 4 and v[4] != 0 });
            read += 1;
        }
        if (read == 0 and bad > 0) return error.BadStates;
    }

    pub fn format(s: *Store, gpa: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        for (s.map.keys(), s.map.values()) |k, v| try aw.writer.print("{s}\t{d} {d} {d} {d} {d}\n", .{ k, v.x, v.y, v.width, v.height, @intFromBool(v.maximized) });
        return aw.toOwnedSlice();
    }

    pub fn load(s: *Store, io: std.Io) void {
        const p = s.path orelse return;
        const data = std.Io.Dir.cwd().readFileAlloc(io, p, s.gpa, .limited(1 << 20)) catch return;
        defer s.gpa.free(data);
        s.parse(data) catch {};
    }

    pub fn save(s: *Store, io: std.Io) void {
        const p = s.path orelse return;
        const text = s.format(s.gpa) catch return;
        defer s.gpa.free(text);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = text }) catch {};
    }
};

const desktop = switch (builtin.os.tag) {
    .macos => @import("desktop.zig"),
    .linux => @import("linux/desktop.zig"),
    .windows => @import("windows/desktop.zig"),
    .wasi => @import("web/desktop.zig"),
    else => struct {},
};

/// The process's store (one app a process), made and loaded on first use.
var store: ?*Store = null;
/// Tests keep states in memory.
var in_memory = false;

fn storeOf(gpa: std.mem.Allocator, io: std.Io, app_name: []const u8) ?*Store {
    if (store) |s| return s;
    const s = gpa.create(Store) catch return null;
    s.* = .{ .gpa = gpa };
    if (!in_memory) {
        if (desktop.path(gpa, .data, app_name)) |dir| {
            defer gpa.free(dir);
            s.path = std.fs.path.join(gpa, &.{ dir, "window-state.txt" }) catch null;
        } else |_| {}
    }
    s.load(io);
    store = s;
    window_types.free_states = free;
    return s;
}

fn free() void {
    const s = store orelse return;
    const gpa = s.gpa;
    s.deinit();
    gpa.destroy(s);
    store = null;
    window_types.free_states = null;
}

fn load(gpa: std.mem.Allocator, io: std.Io, app_name: []const u8, k: []const u8) ?State {
    const s = storeOf(gpa, io, app_name) orelse return null;
    return s.get(k);
}

fn save(gpa: std.mem.Allocator, io: std.Io, app_name: []const u8, k: []const u8, state: State) void {
    const s = storeOf(gpa, io, app_name) orelse return;
    s.put(k, state) catch return;
    s.save(io);
}

/// A window's key in the remembered states: `.state = myzig.windowState("main")`.
pub fn key(k: []const u8) window_types.StateKey {
    return .{ .key = k, .load = load, .save = save };
}

test "window states written and read back" {
    const gpa = std.testing.allocator;
    var s: Store = .{ .gpa = gpa };
    defer s.deinit();
    try s.put("main", .{ .x = 10, .y = 20, .width = 800, .height = 600 });
    try s.put("prefs", .{ .x = -5, .y = 0, .width = 400.5, .height = 300, .maximized = true });
    try s.put("main", .{ .x = 11, .y = 20, .width = 800, .height = 600 });
    const text = try s.format(gpa);
    defer gpa.free(text);
    var t: Store = .{ .gpa = gpa };
    defer t.deinit();
    try t.parse(text);
    try std.testing.expectEqual(@as(f64, 11), t.get("main").?.x);
    try std.testing.expect(t.get("prefs").?.maximized);
    try std.testing.expectEqual(@as(f64, 400.5), t.get("prefs").?.width);
    try std.testing.expect(t.get("other") == null);
    try std.testing.expectError(error.BadStates, t.parse("not states"));
    try t.parse("a key\t1 2 3 4\nbroken\n");
    try std.testing.expectEqual(@as(f64, 4), t.get("a key").?.height);
    try std.testing.expect(!t.get("a key").?.maximized);
}

test "a window's options take its remembered frame" {
    in_memory = true;
    defer in_memory = false;
    const FakeApp = struct { gpa: std.mem.Allocator, io: std.Io, options: struct { name: []const u8 } };
    const app: FakeApp = .{ .gpa = std.testing.allocator, .io = std.testing.io, .options = .{ .name = "t" } };
    defer if (window_types.free_states) |f| f();
    const Opts = struct { state: ?window_types.StateKey = null, x: ?f64 = null, y: ?f64 = null, width: f64 = 800, height: f64 = 600 };
    const none = window_types.restore(&app, Opts{ .state = key("main") });
    try std.testing.expect(none[0].x == null);
    key("main").put(&app, .{ .x = 5, .y = 6, .width = 700, .height = 500, .maximized = true });
    const got = window_types.restore(&app, Opts{ .state = key("main") });
    try std.testing.expectEqual(@as(?f64, 5), got[0].x);
    try std.testing.expectEqual(@as(f64, 500), got[0].height);
    try std.testing.expect(got[1]);
    try std.testing.expect(window_types.restore(&app, Opts{})[0].x == null);
    key("tiny").put(&app, .{ .x = 0, .y = 0, .width = 10, .height = 10 });
    try std.testing.expect(window_types.restore(&app, Opts{ .state = key("tiny") })[0].x == null);
}
