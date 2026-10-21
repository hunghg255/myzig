//! Service policy checks through the real worker and main-thread queue.
const std = @import("std");
const myzig = @import("myzig");
const fetch = @import("fetch");
const Api = @import("api").Server;
const t = std.testing;

test "service checks redirect policy on the main thread before the next request" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var api: Api = undefined;
    try api.start(t.io);
    defer api.stop();
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var app: myzig.App = .{ .gpa = t.allocator, .io = t.io, .environ = &env, .options = .{ .name = "fetch-policy-test" } };
    defer app.windows.deinit(t.allocator);
    var win: myzig.Window = .{ .app = &app };
    try app.windows.append(t.allocator, &win);
    const Policy = struct {
        calls: usize = 0,
        follow: bool,
        thread: std.Thread.Id,
        fn allow(ctx: ?*anyopaque, req: *const fetch.Request) bool {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            std.debug.assert(p.thread == std.Thread.getCurrentId());
            p.calls += 1;
            return p.follow or std.mem.endsWith(u8, req.url, "/redirect");
        }
    };
    for ([_]bool{ false, true }) |follow| {
        const before = api.requests.load(.monotonic);
        var policy: Policy = .{ .follow = follow, .thread = std.Thread.getCurrentId() };
        var service = try fetch.Service.init(t.allocator, t.io, .{ .allow = Policy.allow, .allow_ctx = &policy });
        defer service.deinit();
        var call: myzig.Call = .{ .arena = t.allocator, .window = &win };
        var buf: [128]u8 = undefined;
        try service.start(&call, .{ .id = "redirect", .url = api.url(&buf, "/redirect") });
        var turns: usize = 0;
        while (service.tasks.items.len > 0 and turns < 10000) : (turns += 1) myzig.runFor(0.001);
        try t.expectEqual(@as(usize, 0), service.tasks.items.len);
        try t.expectEqual(@as(usize, 2), policy.calls);
        try t.expectEqual(before + @as(u32, if (follow) 2 else 1), api.requests.load(.monotonic));
    }
}

test "cross-origin redirect policy can refuse or abort before connecting" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var api: Api = undefined;
    try api.start(t.io);
    defer api.stop();
    var target: Api = undefined;
    try target.start(t.io);
    defer target.stop();
    var target_buf: [128]u8 = undefined;
    api.redirect_target = target.url(&target_buf, "/hello");
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var app: myzig.App = .{ .gpa = t.allocator, .io = t.io, .environ = &env, .options = .{ .name = "fetch-policy-test" } };
    defer app.windows.deinit(t.allocator);
    var win: myzig.Window = .{ .app = &app };
    try app.windows.append(t.allocator, &win);
    var call: myzig.Call = .{ .arena = t.allocator, .window = &win };
    const Policy = struct {
        svc: *fetch.Service = undefined,
        call: *myzig.Call,
        abort: bool,
        calls: usize = 0,
        fn allow(ctx: ?*anyopaque, req: *const fetch.Request) bool {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            p.calls += 1;
            if (std.mem.endsWith(u8, req.url, "/external-redirect")) return true;
            if (p.abort) p.svc.abort(p.call, "external");
            return p.abort;
        }
    };
    for ([_]bool{ false, true }) |abort| {
        var policy: Policy = .{ .call = &call, .abort = abort };
        var service = try fetch.Service.init(t.allocator, t.io, .{ .allow = Policy.allow, .allow_ctx = &policy });
        defer service.deinit();
        policy.svc = &service;
        var buf: [128]u8 = undefined;
        try service.start(&call, .{ .id = "external", .url = api.url(&buf, "/external-redirect") });
        var turns: usize = 0;
        while (service.tasks.items.len > 0 and turns < 10000) : (turns += 1) myzig.runFor(0.001);
        try t.expectEqual(@as(usize, 0), service.tasks.items.len);
        try t.expectEqual(@as(usize, 2), policy.calls);
        try t.expectEqual(@as(u32, 0), target.requests.load(.monotonic));
    }
    try t.expectEqual(@as(u32, 2), api.requests.load(.monotonic));
}
