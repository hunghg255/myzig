//! The terminal report: one table per run, myzig against mygo, and
//! myzig against its own earlier runs (history.jsonl), so each change is
//! kept only if it climbs.
const std = @import("std");
const builtin = @import("builtin");
const main = @import("main.zig");
const clock = @import("clock.zig");
pub const Profile = @import("profile.zig").Profile;

/// Where the run ran: runs compare only with runs of the same platform.
const platform = @tagName(builtin.os.tag);
const metal = builtin.os.tag == .macos;

const history_path = "history.jsonl";

const Entry = struct {
    time: u64,
    label: []const u8 = "",
    /// Runs from before platforms were recorded ran on macOS.
    os: []const u8 = "macos",
    /// Unknown in older entries: keep those, but do not auto-compare them.
    profile: ?Profile = null,
    results: []const main.Result,
};

const green = "\x1b[32m";
const red = "\x1b[31m";
const dim = "\x1b[2m";
const bold = "\x1b[1m";
const reset = "\x1b[0m";

pub fn header(frames: usize) void {
    std.debug.print("\n{s}myzig hill-climb{s} {s}· {d} frames after {d} of warm-up · {d}×{d} at {d}x · offscreen, no window · {s}, {s}{s}\n\n", .{
        bold, reset, dim, frames, 30, main.width, main.height, main.scale, platform, if (metal) "Metal" else "CPU renderers", reset,
    });
}

/// A transient progress line, rewritten in place.
pub fn status(text: []const u8) void {
    std.debug.print("\r\x1b[2K{s}{s}{s}", .{ dim, text, reset });
}

pub fn loadHistory(init: std.process.Init, current: Profile) ![]const Entry {
    const arena = init.arena.allocator();
    const data = std.Io.Dir.cwd().readFileAlloc(init.io, history_path, arena, .limited(64 << 20)) catch return &.{};
    var list: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r").len == 0) continue;
        const e = std.json.parseFromSliceLeaky(Entry, arena, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
        if (!std.mem.eql(u8, e.os, platform)) continue;
        const previous = e.profile orelse continue;
        if (current.matches(previous)) try list.append(arena, e);
    }
    return list.items;
}

pub fn appendHistory(
    init: std.process.Init,
    label: []const u8,
    results: []const main.Result,
    profile: Profile,
) !void {
    const gpa = init.gpa;
    const cwd = std.Io.Dir.cwd();
    const old = cwd.readFileAlloc(init.io, history_path, gpa, .limited(64 << 20)) catch try gpa.dupe(u8, "");
    defer gpa.free(old);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.writeAll(old);
    const entry: Entry = .{
        .time = clock.unixSeconds(),
        .label = label,
        .os = platform,
        .profile = profile,
        .results = results,
    };
    try std.json.Stringify.value(entry, .{}, &aw.writer);
    try aw.writer.writeByte('\n');
    try cwd.writeFile(init.io, .{ .sub_path = history_path, .data = aw.written() });
}

fn find(results: []const main.Result, fw: []const u8, scene: []const u8) ?main.Result {
    for (results) |r| if (std.mem.eql(u8, r.fw, fw) and std.mem.eql(u8, r.scene, scene)) return r;
    return null;
}

const Metric = struct { name: []const u8, get: *const fn (main.Result) f64, unit: []const u8 };

const metrics = [_]Metric{
    .{ .name = "frame CPU (median)", .get = struct {
        fn f(r: main.Result) f64 {
            return r.frame_ms;
        }
    }.f, .unit = "ms" },
    .{ .name = "frame CPU (p95)", .get = struct {
        fn f(r: main.Result) f64 {
            return r.frame_p95;
        }
    }.f, .unit = "ms" },
    .{ .name = "  build", .get = struct {
        fn f(r: main.Result) f64 {
            return r.build_ms;
        }
    }.f, .unit = "ms" },
    .{ .name = "  layout", .get = struct {
        fn f(r: main.Result) f64 {
            return r.layout_ms;
        }
    }.f, .unit = "ms" },
    .{ .name = "  paint", .get = struct {
        fn f(r: main.Result) f64 {
            return r.paint_ms;
        }
    }.f, .unit = "ms" },
    .{ .name = if (metal) "encode CPU" else "render CPU", .get = struct {
        fn f(r: main.Result) f64 {
            return r.encode_ms;
        }
    }.f, .unit = "ms" },
    .{ .name = "GPU", .get = struct {
        fn f(r: main.Result) f64 {
            return r.gpu_ms;
        }
    }.f, .unit = "ms" },
    .{ .name = "process CPU / frame", .get = struct {
        fn f(r: main.Result) f64 {
            return r.cpu_ms;
        }
    }.f, .unit = "ms" },
    .{ .name = "draw items", .get = struct {
        fn f(r: main.Result) f64 {
            return @floatFromInt(r.ops);
        }
    }.f, .unit = "" },
};

fn pct(now: f64, then: f64) f64 {
    return if (then == 0) 0 else (now - then) / then * 100;
}

fn signed(buf: []u8, d: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d:.1}%", .{ if (d < 0) "-" else "+", @abs(d) }) catch "?";
}

/// Changes within ±5% are noise on a machine doing other work.
fn deltaColor(d: f64) []const u8 {
    return if (d < -5) green else if (d > 5) red else dim;
}

pub fn table(results: []const main.Result, history: []const Entry) void {
    const last: ?Entry = if (history.len > 0) history[history.len - 1] else null;
    std.debug.print("{s}{s:<10} {s:<20} {s:>9} {s:>9} {s:>9} {s:>8} {s:>8}{s}\n", .{ bold, "scene", "metric", "myzig", "mygo", "n / m", "Δ last", "Δ best", reset });
    var scenes_seen: [8][]const u8 = undefined;
    var n_scenes: usize = 0;
    for (results) |r| {
        var seen = false;
        for (scenes_seen[0..n_scenes]) |s| if (std.mem.eql(u8, s, r.scene)) {
            seen = true;
        };
        if (seen or n_scenes == scenes_seen.len) continue;
        scenes_seen[n_scenes] = r.scene;
        n_scenes += 1;
    }
    for (scenes_seen[0..n_scenes]) |scene| {
        const n = find(results, "myzig", scene);
        const m = find(results, "mygo", scene);
        for (metrics, 0..) |metric, mi| {
            // Without Metal nothing is timed on a GPU, but Direct3D (--gpu).
            if (!metal and std.mem.eql(u8, metric.name, "GPU") and (n == null or n.?.gpu_ms == 0)) continue;
            std.debug.print("{s:<10} {s:<20} ", .{ if (mi == 0) scene else "", metric.name });
            if (n) |nr| std.debug.print("{d:>9.3} ", .{metric.get(nr)}) else std.debug.print("{s:>9} ", .{"—"});
            if (m != null and metric.get(m.?) > 0) std.debug.print("{d:>9.3} ", .{metric.get(m.?)}) else std.debug.print("{s:>9} ", .{"—"});
            if (n != null and m != null and metric.get(m.?) > 0) {
                const ratio = metric.get(n.?) / metric.get(m.?);
                const col = if (ratio < 0.95) green else if (ratio > 1.05) red else dim;
                std.debug.print("{s}{d:>8.2}×{s} ", .{ col, ratio, reset });
            } else std.debug.print("{s:>9} ", .{""});
            if (n) |nr| {
                const v = metric.get(nr);
                if (last) |l| if (find(l.results, "myzig", scene)) |lr| {
                    const d = pct(v, metric.get(lr));
                    var b: [16]u8 = undefined;
                    std.debug.print("{s}{s:>8}{s} ", .{ deltaColor(d), signed(&b, d), reset });
                } else std.debug.print("{s:>8} ", .{""});
                var best: ?f64 = null;
                for (history) |e| if (find(e.results, "myzig", scene)) |hr| {
                    const hv = metric.get(hr);
                    // Runs from before a metric existed recorded 0.
                    if (hv > 0) best = if (best) |b| @min(b, hv) else hv;
                };
                if (best) |b| {
                    const d = pct(v, b);
                    var buf: [16]u8 = undefined;
                    std.debug.print("{s}{s:>8}{s}", .{ deltaColor(d), signed(&buf, d), reset });
                }
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("\n", .{});
    }
    if (last) |l| std.debug.print("{s}Δ against the previous run{s}{s}{s}, and the best of {d} runs.{s}\n", .{
        dim, if (l.label.len > 0) " (" else "", l.label, if (l.label.len > 0) ")" else "", history.len, reset,
    });
}
