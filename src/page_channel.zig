//! The channels of one page: typed streams between Zig and the page,
//! opened by either side, each closed by either. Values from Zig wait in
//! the page until it takes them; while it has more than a window of
//! bytes yet to take, sending fails with `error.ChannelFull` and the
//! channel's drain listener hears when it took enough. The wire:
//!
//!   Zig → page   {"t":"chan","c":ID,"p":VALUE[,"a":1]}   a value (a: acknowledge it)
//!                {"t":"chan","c":ID,"end":true}          Zig closed it
//!                {"t":"chan-open","c":ID,"n":NAME}       Zig opened it (IDs < 0)
//!                {"t":"chan-ack","c":ID,"n":SEQ}         Zig took the page's values up to SEQ
//!   page → Zig   {"t":"chan-msg","c":ID,"v":"JSON","n":SEQ[,"a":1]}
//!                {"t":"chan-ack","c":ID,"n":SEQ}  {"t":"chan-close","c":ID}
//!
//! Channels the page makes (IDs > 0) are passed to bound methods, which
//! take them as `myzig.Channel(T)` parameters.
const std = @import("std");

/// Bytes of values that may wait in the page; acknowledgments are asked
/// every half window.
pub const window_bytes: u64 = 1 << 20;

pub const CloseReason = enum {
    /// Zig closed it.
    zig,
    /// The page closed it.
    page,
    /// The page navigated away or closed.
    lost,
};

pub const Receiver = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, id: i64, json: []const u8) void,
};

pub const Notifier = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, id: i64, reason: CloseReason) void,
};

/// What a channel's listeners get back: the window, the document and the
/// listener's pointer. Kept by the page until its document goes.
pub const Handle = struct {
    app: *anyopaque,
    window: *anyopaque,
    /// The page of the channel (a window's, or a web view's).
    page: *anyopaque,
    generation: u32,
    ptr: *anyopaque,
};

pub const Entry = struct {
    id: i64,
    // Zig → page, in bytes: sent, taken as far as the page said, and sent
    // when an acknowledgment was last asked for, by sequence number.
    seq: u64 = 0,
    sent: u64 = 0,
    taken: u64 = 0,
    asked: u64 = 0,
    asks: std.ArrayList([2]u64) = .empty,
    /// A send failed for the window: tell `on_drain` once there is room.
    full: bool = false,
    on_message: ?Receiver = null,
    on_close: ?Notifier = null,
    on_drain: ?Notifier = null,
};

pub const Registry = struct {
    entries: std.ArrayList(*Entry) = .empty,
    next_id: i64 = -1,

    pub fn deinit(r: *Registry, gpa: std.mem.Allocator, reason: CloseReason) void {
        r.closeAll(gpa, reason);
        r.entries.deinit(gpa);
    }

    pub fn get(r: *Registry, id: i64) ?*Entry {
        for (r.entries.items) |e| if (e.id == id) return e;
        return null;
    }

    /// The channel `id`, made if the page just passed it to a call.
    pub fn ensure(r: *Registry, gpa: std.mem.Allocator, id: i64) !*Entry {
        if (r.get(id)) |e| return e;
        const e = try gpa.create(Entry);
        errdefer gpa.destroy(e);
        e.* = .{ .id = id };
        try r.entries.append(gpa, e);
        return e;
    }

    /// A channel Zig opens: its id, and the message telling the page.
    pub fn open(r: *Registry, gpa: std.mem.Allocator, name: []const u8) !struct { *Entry, []u8 } {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try aw.writer.print("{{\"t\":\"chan-open\",\"c\":{d},\"n\":", .{r.next_id});
        try std.json.Stringify.encodeJsonString(name, .{}, &aw.writer);
        try aw.writer.writeByte('}');
        const msg = try aw.toOwnedSlice();
        errdefer gpa.free(msg);
        const e = try r.ensure(gpa, r.next_id);
        r.next_id -= 1;
        return .{ e, msg };
    }

    /// The message carrying `json` on `e`, or why it cannot be sent.
    pub fn encodeValue(r: *Registry, gpa: std.mem.Allocator, e: *Entry, json: []const u8) error{ ChannelFull, OutOfMemory }![]u8 {
        _ = r;
        if (e.sent - e.taken >= window_bytes) {
            e.full = true;
            return error.ChannelFull;
        }
        const ask = e.sent + json.len - e.asked >= window_bytes / 2;
        const msg = try gpa.print("{{\"t\":\"chan\",\"c\":{d},{s}\"p\":{s}}}", .{ e.id, if (ask) "\"a\":1," else "", json });
        errdefer gpa.free(msg);
        if (ask) try e.asks.append(gpa, .{ e.seq + 1, e.sent + msg.len });
        e.seq += 1;
        e.sent += msg.len;
        if (ask) e.asked = e.sent;
        return msg;
    }

    /// The page took `e`'s values up to `seq`.
    pub fn ack(r: *Registry, id: i64, seq: u64) void {
        const e = r.get(id) orelse return;
        while (e.asks.items.len > 0 and e.asks.items[0][0] <= seq) e.taken = e.asks.orderedRemove(0)[1];
        if (e.full and e.sent - e.taken < window_bytes) {
            e.full = false;
            if (e.on_drain) |d| d.func(d.ctx, id, .zig);
        }
    }

    /// A value from the page; the acknowledgment to send back, if it asked.
    pub fn received(r: *Registry, gpa: std.mem.Allocator, id: i64, json: []const u8, seq: u64, ask: bool) ?[]u8 {
        const e = r.get(id) orelse return null;
        if (e.on_message) |m| m.func(m.ctx, id, json);
        if (!ask) return null;
        return gpa.print("{{\"t\":\"chan-ack\",\"c\":{d},\"n\":{d}}}", .{ id, seq }) catch null;
    }

    /// Closes `id`; returns the message telling the page when Zig closed it.
    pub fn close(r: *Registry, gpa: std.mem.Allocator, id: i64, reason: CloseReason) ?[]u8 {
        for (r.entries.items, 0..) |e, i| if (e.id == id) {
            _ = r.entries.swapRemove(i);
            const cb = e.on_close;
            e.asks.deinit(gpa);
            gpa.destroy(e);
            if (cb) |c| c.func(c.ctx, id, reason);
            if (reason != .zig) return null;
            return gpa.print("{{\"t\":\"chan\",\"c\":{d},\"end\":true}}", .{id}) catch null;
        };
        return null;
    }

    pub fn closeAll(r: *Registry, gpa: std.mem.Allocator, reason: CloseReason) void {
        while (r.entries.items.len > 0) {
            const id = r.entries.items[r.entries.items.len - 1].id;
            if (r.close(gpa, id, reason)) |m| gpa.free(m);
        }
    }
};

const testing = std.testing;

test "memory regression: failed channel open leaves no entry or consumed id" {
    for (0..3) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        var r: Registry = .{};
        defer r.deinit(gpa, .lost);
        if (r.open(gpa, "stream")) |result| {
            gpa.free(result[1]);
            return error.ExpectedAllocationFailure;
        } else |_| {}
        try testing.expectEqual(@as(usize, 0), r.entries.items.len);
        try testing.expectEqual(@as(i64, -1), r.next_id);
    }
}

test "memory regression: failed ACK tracking leaves send counters unchanged" {
    const json = try testing.allocator.alloc(u8, window_bytes / 2);
    defer testing.allocator.free(json);
    @memset(json, '0');
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    const gpa = failing.allocator();
    var r: Registry = .{};
    defer r.deinit(testing.allocator, .lost);
    const e = try r.ensure(testing.allocator, 1);
    const result = r.encodeValue(gpa, e, json);
    if (result) |msg| {
        gpa.free(msg);
        return error.ExpectedAllocationFailure;
    } else |err| try testing.expectEqual(error.OutOfMemory, err);
    try testing.expectEqual(@as(u64, 0), e.seq);
    try testing.expectEqual(@as(u64, 0), e.sent);
    try testing.expectEqual(@as(u64, 0), e.asked);
    try testing.expectEqual(@as(usize, 0), e.asks.items.len);
}

test "values wait for the page's acknowledgments" {
    const gpa = testing.allocator;
    var r: Registry = .{};
    defer r.deinit(gpa, .lost);
    const S = struct {
        var drained: u32 = 0;
        var closed: ?CloseReason = null;
        fn drain(_: ?*anyopaque, _: i64, _: CloseReason) void {
            drained += 1;
        }
        fn close(_: ?*anyopaque, _: i64, why: CloseReason) void {
            closed = why;
        }
    };
    const e = try r.ensure(gpa, 3);
    e.on_drain = .{ .ctx = null, .func = S.drain };
    e.on_close = .{ .ctx = null, .func = S.close };
    const big = try gpa.alloc(u8, 200 * 1024);
    defer gpa.free(big);
    @memset(big, '1');
    var sent: u32 = 0;
    var asked: u64 = 0;
    while (true) {
        const m = r.encodeValue(gpa, e, big) catch |err| {
            try testing.expectEqual(error.ChannelFull, err);
            break;
        };
        defer gpa.free(m);
        if (std.mem.indexOf(u8, m[0..40], "\"a\":1") != null) asked = e.seq;
        sent += 1;
    }
    try testing.expect(sent >= 5 and sent <= 6);
    try testing.expect(asked > 0);
    r.ack(3, asked);
    try testing.expectEqual(@as(u32, 1), S.drained);
    gpa.free(try r.encodeValue(gpa, e, "2")); // room again
    gpa.free(try r.encodeValue(gpa, e, "3"));
    const end = r.close(gpa, 3, .zig).?;
    defer gpa.free(end);
    try testing.expectEqualStrings("{\"t\":\"chan\",\"c\":3,\"end\":true}", end);
    try testing.expectEqual(CloseReason.zig, S.closed.?);
    try testing.expect(r.get(3) == null);
}

test "opening, receiving and losing channels" {
    const gpa = testing.allocator;
    var r: Registry = .{};
    defer r.deinit(gpa, .lost);
    const S = struct {
        var last: [16]u8 = undefined;
        var len: usize = 0;
        var lost: u32 = 0;
        fn got(_: ?*anyopaque, _: i64, json: []const u8) void {
            @memcpy(last[0..json.len], json);
            len = json.len;
        }
        fn close(_: ?*anyopaque, _: i64, why: CloseReason) void {
            if (why == .lost) lost += 1;
        }
    };
    const opened = try r.open(gpa, "logs");
    defer gpa.free(opened[1]);
    try testing.expectEqualStrings("{\"t\":\"chan-open\",\"c\":-1,\"n\":\"logs\"}", opened[1]);
    opened[0].on_message = .{ .ctx = null, .func = S.got };
    opened[0].on_close = .{ .ctx = null, .func = S.close };
    try testing.expect(r.received(gpa, -1, "\"hi\"", 1, false) == null);
    try testing.expectEqualStrings("\"hi\"", S.last[0..S.len]);
    const ack = r.received(gpa, -1, "2", 2, true).?;
    defer gpa.free(ack);
    try testing.expectEqualStrings("{\"t\":\"chan-ack\",\"c\":-1,\"n\":2}", ack);
    _ = try r.ensure(gpa, 1);
    r.closeAll(gpa, .lost);
    try testing.expectEqual(@as(u32, 1), S.lost);
    try testing.expectEqual(@as(usize, 0), r.entries.items.len);
}
