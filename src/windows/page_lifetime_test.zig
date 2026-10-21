const std = @import("std");
const ipc = @import("../ipc.zig");
const Channel = @import("../channel.zig").Channel;
const Fixture = @import("page_test_support.zig").Fixture;
const t = std.testing;
const types = @import("../page_types.zig");
const Window = @import("window.zig").Window;

test "page regression: malformed call IDs do not dispatch or reply" {
    const Probe = struct {
        pub const myzig_name = "Regression";
        calls: usize = 0,
        pub fn ping(p: *@This()) u32 {
            p.calls += 1;
            return 7;
        }
    };
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const page = try f.open(.{});
    page.url_next = try t.allocator.dupe(u8, "myzig://localhost/");
    var probe: Probe = .{};
    try f.app.bind(&probe);
    for ([_][]const u8{ "-1", "1e100", "1.5", "9007199254740992", "null", "{}" }) |id| {
        const msg = try std.fmt.allocPrint(t.allocator, "{{\"t\":\"call\",\"id\":{s},\"m\":\"Regression.ping\"}}", .{id});
        defer t.allocator.free(msg);
        ipc.handleMessage(page.window, page, msg);
        try t.expectEqual(@as(usize, 0), page.outbox.items.len);
        try t.expectEqual(@as(usize, 0), probe.calls);
    }
    ipc.handleMessage(page.window, page, "{\"t\":\"call\",\"m\":\"Regression.ping\"}");
    try t.expectEqual(@as(usize, 0), probe.calls);
    try t.expectEqual(@as(usize, 0), page.outbox.items.len);
    ipc.handleMessage(page.window, page, "{\"t\":\"call\",\"id\":42,\"m\":\"Regression.ping\"}");
    try t.expectEqualStrings("{\"t\":\"reply\",\"id\":42,\"ok\":true,\"v\":7}", page.outbox.items);
    try t.expectEqual(@as(usize, 1), probe.calls);
}

test "page regression: malformed eval IDs leave the callback pending" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const page = try f.open(.{});
    const Probe = struct {
        fn result(ctx: ?*anyopaque, _: @import("../page_types.zig").EvalResult) void {
            const calls: *usize = @ptrCast(@alignCast(ctx));
            calls.* += 1;
        }
    };
    var calls: usize = 0;
    const script = try page.core.evalScript("1", .{ .ctx = &calls, .func = Probe.result });
    defer t.allocator.free(script);
    for ([_][]const u8{ "-1", "1e100", "1.5", "9007199254740992", "null", "{}" }) |id| {
        const msg = try std.fmt.allocPrint(t.allocator, "{{\"t\":\"eval\",\"id\":{s},\"k\":\"0123456789abcdef\",\"ok\":true,\"v\":\"1\"}}", .{id});
        defer t.allocator.free(msg);
        ipc.handleMessage(page.window, page, msg);
        try t.expectEqual(@as(usize, 0), calls);
    }
    ipc.handleMessage(page.window, page, "{\"t\":\"eval\",\"id\":1,\"k\":\"0123456789abcdef\",\"ok\":true,\"v\":\"1\"}");
    try t.expectEqual(@as(usize, 1), calls);
}

test "page regression: retained channels are closed after their window is freed" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const page = try f.open(.{});
    const channel = try Channel(u32).fromArg(page.window, .{ .integer = 1 });
    try t.expect(channel.isOpen());
    const opened = try Channel(u32).open(page.window, "numbers");
    const Probe = struct {
        retained: ?Channel(u32) = null,
        fn closed(p: *@This(), ch: Channel(u32), reason: @import("../channel.zig").CloseReason) void {
            std.debug.assert(reason == .lost);
            p.retained = ch;
        }
    };
    var probe: Probe = .{};
    channel.onClose(&probe, Probe.closed);
    page.window.close();
    for ([_]Channel(u32){ channel, opened, probe.retained.? }) |ch| {
        try t.expect(!ch.isOpen());
        try t.expectError(error.ChannelClosed, ch.send(1));
        ch.close();
    }
}

test "page regression: channel close callback may close its window" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const page = try f.open(.{});
    const ch = try Channel(u32).fromArg(page.window, .{ .integer = 1 });
    const Probe = struct {
        fn closed(_: *u8, channel: Channel(u32), _: @import("../channel.zig").CloseReason) void {
            channel.window.close();
        }
    };
    var p: u8 = 0;
    ch.onClose(&p, Probe.closed);
    ch.close();
    try t.expectEqual(@as(usize, 0), f.app.windows.items.len);
}

test "page regression: channel close callback may navigate without sending to the new document" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const page = try f.open(.{});
    const ch = try Channel(u32).fromArg(page.window, .{ .integer = 1 });
    const Probe = struct {
        fn closed(_: *u8, channel: Channel(u32), _: @import("../channel.zig").CloseReason) void {
            channel.page.navigated();
        }
    };
    var p: u8 = 0;
    ch.onClose(&p, Probe.closed);
    ch.close();
    try t.expectEqual(@as(u32, 1), page.core.generation);
    try t.expectEqual(@as(usize, 0), page.held.items.len);
    try t.expectEqual(@as(usize, 0), page.outbox.items.len);
}

test "page regression: failed eval callback may close its window during navigation" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const page = try f.open(.{});
    const Probe = struct {
        closed: usize = 0,
        results: usize = 0,
        fn result(ctx: ?*anyopaque, _: types.EvalResult) void {
            const win: *Window = @ptrCast(@alignCast(ctx));
            win.close();
        }
        fn other(ctx: ?*anyopaque, r: types.EvalResult) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            std.debug.assert(r == .err and std.mem.eql(u8, r.err, "the page navigated"));
            p.results += 1;
        }
        fn channelClosed(p: *@This(), ch: Channel(u32), reason: @import("../channel.zig").CloseReason) void {
            std.debug.assert(reason == .lost and !ch.isOpen());
            p.closed += 1;
        }
    };
    var probe: Probe = .{};
    const ch = try Channel(u32).fromArg(page.window, .{ .integer = 1 });
    ch.onClose(&probe, Probe.channelClosed);
    const script = try page.core.evalScript("new Promise(() => {})", .{ .ctx = page.window, .func = Probe.result });
    defer t.allocator.free(script);
    const another = try page.core.evalScript("1", .{ .ctx = &probe, .func = Probe.other });
    defer t.allocator.free(another);
    page.navigated();
    try t.expectEqual(@as(usize, 0), f.app.windows.items.len);
    try t.expectEqual(@as(usize, 1), probe.results);
    try t.expectEqual(@as(usize, 1), probe.closed);
}

test "page regression: download listener may close its window" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const Probe = struct {
        fn event(_: *u8, win: *Window, e: types.PageEvent) void {
            if (e == .download_started) win.close();
        }
    };
    var p: u8 = 0;
    const page = try f.open(.{ .on_event = .of(&p, Probe.event) });
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    const path = page.core.startDownload(t.io, dir, "app://localhost/file", "file.txt");
    if (path) |value| t.allocator.free(value);
    try t.expectEqual(@as(usize, 0), f.app.windows.items.len);
}

test "page regression: deferred download response after page close" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const Probe = struct {
        request: ?*types.SchemeRequest = null,
        fn serve(ctx: ?*anyopaque, req: *types.SchemeRequest) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            p.request = req;
        }
    };
    for ([_]u16{ 200, 404 }) |status| {
        var p: Probe = .{};
        const page = try f.open(.{ .schemes = &.{.{ .name = "app", .handler = .{ .ctx = &p, .func = Probe.serve } }} });
        @import("page_scheme.zig").download(page, "app://localhost/deferred", "file.txt");
        try t.expectEqual(@as(usize, 1), page.ops.items.len);
        page.window.close();
        p.request.?.respond(status, &.{}, "late response");
        try t.expectEqual(@as(usize, 0), f.app.windows.items.len);
    }
}
