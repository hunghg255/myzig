//! The tool's command line.
//!
//!     inputlatency [--mode=type,scroll,drag,anim] [--runs=6] [--events=300]
//!                  [--warmup=30] [--x=X --y=Y] [--boxes=30] [--seed=N]
//!
//! `--run=MODE` makes the process one run of the mode, printing its
//! figures: the parent starts one such process a run.
const std = @import("std");
const plan = @import("plan.zig");

pub const Options = struct {
    /// The modes the runs do, separated by commas.
    modes: []const u8 = "type,scroll,drag,anim",
    runs: usize = 6,
    /// Events measured in a run, after the warmup (refreshes for anim and heavy).
    events: usize = 300,
    warmup: usize = 30,
    /// Where the window opens, in screen points; centered when null.
    x: ?f64 = null,
    y: ?f64 = null,
    /// How many boxes heavy draws.
    boxes: usize = 30,
    /// The plans' pauses come from it: run `i` of a mode takes `seed + i`.
    seed: u64 = 1,
    /// This process is one run of this mode.
    run: ?plan.Mode = null,
    /// For `run`: its mode, as `run` has it.
    mode: plan.Mode = .type,
    help: bool = false,

    pub fn parse(args: []const []const u8) !Options {
        var o: Options = .{};
        for (args) |a| {
            if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
                o.help = true;
            } else if (value(a, "--mode=")) |v| {
                o.modes = v;
                var it = std.mem.splitScalar(u8, v, ',');
                while (it.next()) |m| _ = std.meta.stringToEnum(plan.Mode, m) orelse return error.UnknownMode;
            } else if (value(a, "--runs=")) |v| {
                o.runs = try std.fmt.parseInt(usize, v, 10);
            } else if (value(a, "--events=")) |v| {
                o.events = try std.fmt.parseInt(usize, v, 10);
            } else if (value(a, "--warmup=")) |v| {
                o.warmup = try std.fmt.parseInt(usize, v, 10);
            } else if (value(a, "--x=")) |v| {
                o.x = try std.fmt.parseFloat(f64, v);
            } else if (value(a, "--y=")) |v| {
                o.y = try std.fmt.parseFloat(f64, v);
            } else if (value(a, "--boxes=")) |v| {
                o.boxes = try std.fmt.parseInt(usize, v, 10);
            } else if (value(a, "--seed=")) |v| {
                o.seed = try std.fmt.parseInt(u64, v, 10);
            } else if (value(a, "--run=")) |v| {
                o.run = std.meta.stringToEnum(plan.Mode, v) orelse return error.UnknownMode;
                o.mode = o.run.?;
            } else if (std.mem.startsWith(u8, a, "--myzig-")) {
                // myzig's own (the child's --myzig-hidden).
            } else return error.UnknownFlag;
        }
        return o;
    }

    fn value(arg: []const u8, comptime flag: []const u8) ?[]const u8 {
        return if (std.mem.startsWith(u8, arg, flag)) arg[flag.len..] else null;
    }

    /// The arguments of the process of run `i` of `mode`, after the
    /// program, allocated with `a`.
    pub fn childArgs(o: Options, a: std.mem.Allocator, mode: plan.Mode, i: usize) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        try out.append(a, try std.fmt.allocPrint(a, "--run={t}", .{mode}));
        try out.append(a, try std.fmt.allocPrint(a, "--events={d}", .{o.events}));
        try out.append(a, try std.fmt.allocPrint(a, "--warmup={d}", .{o.warmup}));
        try out.append(a, try std.fmt.allocPrint(a, "--boxes={d}", .{o.boxes}));
        try out.append(a, try std.fmt.allocPrint(a, "--seed={d}", .{o.seed + i}));
        if (o.x) |x| try out.append(a, try std.fmt.allocPrint(a, "--x={d}", .{x}));
        if (o.y) |y| try out.append(a, try std.fmt.allocPrint(a, "--y={d}", .{y}));
        // macOS: the app starts without activating (myzig's hidden runs);
        // the tool shows its window itself, without taking the front.
        try out.append(a, "--myzig-hidden");
        return out.items;
    }
};

test "flags, and a run's own command line reading back" {
    const o = try Options.parse(&.{ "--mode=type,anim", "--runs=3", "--events=50", "--x=10", "--seed=9" });
    try std.testing.expectEqualStrings("type,anim", o.modes);
    try std.testing.expectEqual(@as(usize, 3), o.runs);
    try std.testing.expectEqual(@as(?f64, 10), o.x);
    try std.testing.expect(o.run == null);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const child = try Options.parse(try o.childArgs(arena.allocator(), .anim, 2));
    try std.testing.expectEqual(plan.Mode.anim, child.run.?);
    try std.testing.expectEqual(@as(usize, 50), child.events);
    try std.testing.expectEqual(@as(u64, 11), child.seed);
    try std.testing.expectEqual(@as(?f64, 10), child.x);
    try std.testing.expectEqual(@as(?f64, null), child.y);
    try std.testing.expectError(error.UnknownMode, Options.parse(&.{"--mode=type,typo"}));
    try std.testing.expectError(error.UnknownFlag, Options.parse(&.{"--frames=3"}));
}
