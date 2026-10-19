//! Programs in pseudo-terminals: one's output read straight from the
//! pseudo-terminal, and a terminal running a command whose output shows
//! on its screen. Waiting is on the output (`waitOutput`), never on time.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const terminal = @import("terminal");

const echo: []const []const u8 = if (builtin.os.tag == .windows) &.{ "cmd", "/c", "echo hi" } else &.{ "sh", "-c", "echo hi" };

test "a program's output comes through the pseudo-terminal" {
    // ConPTY may need conpty.dll's library lookup: libghostty-vt is not used.
    var p = try terminal.pty.Pty.start(testing.allocator, testing.io, .{ .argv = echo, .cols = 80, .rows = 24 });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const Waiter = struct {
        fn run(pty: *terminal.pty.Pty, code: *u32) void {
            code.* = pty.wait();
            // ConPTY closes its output once the console closes.
            pty.hangUp();
        }
    };
    var code: u32 = 99;
    const waiter = try std.Thread.spawn(.{}, Waiter.run, .{ &p, &code });
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = p.read(&buf);
        if (n == 0) break;
        try out.appendSlice(testing.allocator, buf[0..n]);
    }
    waiter.join();
    p.deinit();
    try testing.expectEqual(@as(u32, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.items, "hi") != null);
}

test "a terminal shows its program's output and its exit" {
    terminal.library.load(testing.allocator, testing.io) catch |err| switch (err) {
        error.GhosttyMissing => return error.SkipZigTest,
        else => return err,
    };
    const t = try terminal.Terminal.create(testing.allocator, testing.io, .{ .command = echo });
    defer t.destroy();
    // The first size starts the program, as a view's first frame does.
    t.resize(60, 10, 8, 16);
    var seen: u64 = 0;
    while (t.exitCode() == null) seen = t.waitOutput(seen);
    try testing.expectEqual(@as(?i32, 0), t.exitCode());
    const text = t.text(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "hi") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[Process exited]") != null);
}

test "a program that is missing shows why" {
    terminal.library.load(testing.allocator, testing.io) catch |err| switch (err) {
        error.GhosttyMissing => return error.SkipZigTest,
        else => return err,
    };
    const t = try terminal.Terminal.create(testing.allocator, testing.io, .{ .command = &.{"myzig-no-such-program"} });
    defer t.destroy();
    t.start();
    try testing.expectEqual(@as(?i32, -1), t.exitCode());
    const text = t.text(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "ProgramNotFound") != null);
}
