//! inputlatency measures how long input takes to show on screen in native
//! UI: from when an event arrives to when the frame showing it reaches
//! the display, on macOS and Windows (see README.md). It shows a window and
//! types, scrolls and drags in it: run it in a desktop session, and leave
//! the mouse and keyboard alone meanwhile.
//!
//! Each run is a process of its own (`--run=MODE`), which prints its
//! figures; the parent prints each run's and the median of the runs'. A
//! run keeps the state the compositor settles in, which changes from run
//! to run, so compare medians of several runs, alternating builds.
const std = @import("std");
const builtin = @import("builtin");
const figures = @import("figures.zig");
const Figures = figures.Figures;
const options = @import("options.zig");
const Options = options.Options;
const plan = @import("plan.zig");

const measure = switch (builtin.os.tag) {
    .macos => @import("measure_mac.zig").measure,
    .windows => @import("measure_windows.zig").measure,
    else => @import("measure_other.zig").measure,
};

const usage =
    \\usage: inputlatency [--mode=type,scroll,drag,anim,heavy] [--runs=6] [--events=300]
    \\                    [--warmup=30] [--x=X --y=Y] [--boxes=30] [--seed=1]
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const all = try init.minimal.args.toSlice(arena);
    const o = Options.parse(all[@min(1, all.len)..]) catch |e| {
        std.debug.print("inputlatency: {t}\n{s}", .{ e, usage });
        std.process.exit(2);
    };
    if (o.help) return std.debug.print("{s}", .{usage});
    var buf: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const w = &out.interface;
    if (o.run != null) {
        const f = measure(init, o) catch |e| {
            std.debug.print("inputlatency: {t}\n", .{e});
            std.process.exit(1);
        };
        try f.write(w);
        return w.flush();
    }
    const self = try std.process.executablePathAlloc(init.io, arena);
    var modes = std.mem.splitScalar(u8, o.modes, ',');
    while (modes.next()) |name| {
        const mode = std.meta.stringToEnum(plan.Mode, name).?;
        var runs: std.ArrayList(Figures) = .empty;
        for (0..o.runs) |i| {
            const args = try o.childArgs(arena, mode, i);
            const argv = try arena.alloc([]const u8, args.len + 1);
            argv[0] = self;
            @memcpy(argv[1..], args);
            const r = try std.process.run(arena, init.io, .{ .argv = argv });
            if (!r.term.success()) {
                std.debug.print("inputlatency: {s} run {d} failed: {s}\n", .{ name, i + 1, r.stderr });
                std.process.exit(1);
            }
            const f = Figures.parse(r.stdout) catch |e| {
                std.debug.print("inputlatency: {s} run {d}: {t}\n", .{ name, i + 1, e });
                std.process.exit(1);
            };
            try w.print("{s:<6} run {d}: {f}\n", .{ name, i + 1, f });
            try w.flush();
            try runs.append(arena, f);
        }
        const scratch = try arena.alloc(f64, runs.items.len);
        try w.print("{s:<6} median of {d} runs: {f}\n", .{ name, runs.items.len, Figures.medianOf(runs.items, scratch) });
        try w.flush();
    }
}

test {
    _ = figures;
    _ = options;
    _ = plan;
    _ = @import("record.zig");
    _ = @import("probe.zig");
}
