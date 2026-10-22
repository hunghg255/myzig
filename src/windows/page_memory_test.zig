//! Memory-target transitions use a COM fake; no window or profile is opened.
const std = @import("std");
const com = @import("com.zig");
const memory = @import("page_memory.zig");
const t = std.testing;

const Fake = extern struct {
    vtbl: *const Vtbl = &methods,
    refs: u32 = 1,
    queries: u32 = 0,
    writes: u32 = 0,
    level: i32 = 0,
    supported: bool = true,
    fail_write: bool = false,

    const Vtbl = extern struct {
        query: *const fn (com.Object, *const com.GUID, *?com.Object) callconv(.winapi) com.HRESULT,
        add_ref: *const fn (com.Object) callconv(.winapi) u32,
        release: *const fn (com.Object) callconv(.winapi) u32,
        unused: [116]?*const anyopaque = @splat(null),
        get: *const fn (com.Object, *i32) callconv(.winapi) com.HRESULT,
        put: *const fn (com.Object, i32) callconv(.winapi) com.HRESULT,
    };
    const methods: Vtbl = .{ .query = query, .add_ref = addRef, .release = release, .get = get, .put = put };

    fn of(obj: com.Object) *Fake {
        return @ptrCast(@alignCast(obj));
    }
    fn query(obj: com.Object, iid: *const com.GUID, out: *?com.Object) callconv(.winapi) com.HRESULT {
        const f = of(obj);
        f.queries += 1;
        out.* = null;
        if (!f.supported or !std.meta.eql(iid.*, memory.iid)) return com.E_NOINTERFACE;
        f.refs += 1;
        out.* = obj;
        return com.S_OK;
    }
    fn addRef(obj: com.Object) callconv(.winapi) u32 {
        const f = of(obj);
        f.refs += 1;
        return f.refs;
    }
    fn release(obj: com.Object) callconv(.winapi) u32 {
        const f = of(obj);
        f.refs -= 1;
        return f.refs;
    }
    fn get(obj: com.Object, out: *i32) callconv(.winapi) com.HRESULT {
        out.* = of(obj).level;
        return com.S_OK;
    }
    fn put(obj: com.Object, level: i32) callconv(.winapi) com.HRESULT {
        const f = of(obj);
        f.writes += 1;
        if (f.fail_write) return com.E_FAIL;
        f.level = level;
        return com.S_OK;
    }
};

comptime {
    std.debug.assert(@offsetOf(Fake.Vtbl, "get") == 119 * @sizeOf(usize));
    std.debug.assert(@offsetOf(Fake.Vtbl, "put") == 120 * @sizeOf(usize));
}

test "memory target follows the host and embedded view and restores even during loading" {
    const Embed = struct { shown: bool = false };
    const Visibility = struct {
        requested: ?bool = null,
        pub fn apply(self: *@This(), _: ?com.Object, visible: bool) void {
            self.requested = visible;
        }
    };
    const Page = struct {
        controller: ?com.Object = null,
        visibility: Visibility = .{},
        webview: ?com.Object,
        embed: ?*Embed = null,
        dom_ready: bool = false,
        memory_target: memory.State = .{},
    };
    var primary: Fake = .{};
    var embedded: Fake = .{};
    var placement: Embed = .{};
    var page: Page = .{ .webview = &primary };
    var child: Page = .{ .webview = &embedded, .embed = &placement };
    var children = [_]*Page{&child};
    const window = .{ .page = @as(?*Page, &page), .web_views = .{ .items = children[0..] } };
    memory.windowChanged(&window, false, false);
    try t.expectEqual(false, page.visibility.requested.?);
    try t.expectEqual(@as(?bool, null), child.visibility.requested);
    try t.expectEqual(@as(u32, 0), primary.writes);
    try t.expectEqual(@as(u32, 0), embedded.writes);
    page.dom_ready = true;
    child.dom_ready = true;
    memory.windowChanged(&window, false, false);
    try t.expectEqual(@as(i32, 1), primary.level);
    try t.expectEqual(@as(i32, 1), embedded.level);
    page.dom_ready = false;
    memory.windowChanged(&window, true, false);
    try t.expectEqual(true, page.visibility.requested.?);
    try t.expectEqual(@as(i32, 0), primary.level);
    try t.expectEqual(@as(i32, 1), embedded.level);
    placement.shown = true;
    memory.windowChanged(&window, true, false);
    try t.expectEqual(@as(i32, 0), embedded.level);
    page.dom_ready = true;
    memory.windowChanged(&window, true, true);
    try t.expectEqual(false, page.visibility.requested.?);
    try t.expectEqual(@as(i32, 1), primary.level);
    try t.expectEqual(@as(i32, 1), embedded.level);
}

test "memory target restores normal, skips duplicate writes and releases COM references" {
    var fake: Fake = .{};
    var state: memory.State = .{};
    state.apply(&fake, .low);
    state.apply(&fake, .low);
    try t.expectEqual(@as(u32, 1), fake.writes);
    try t.expectEqual(@as(u32, 1), fake.queries);
    try t.expectEqual(@as(i32, 1), fake.level);
    state.apply(&fake, .normal);
    try t.expectEqual(@as(i32, 0), fake.level);
    try t.expectEqual(memory.Level.normal, state.applied.?);
    state.apply(&fake, .low);
    try t.expectEqual(@as(u32, 3), fake.writes);
    try t.expectEqual(@as(u32, 1), fake.refs);
}

test "old WebView2 runtimes skip memory targets without retrying QueryInterface" {
    var fake: Fake = .{ .supported = false };
    var state: memory.State = .{};
    state.apply(&fake, .low);
    state.apply(&fake, .normal);
    try t.expect(state.unsupported);
    try t.expectEqual(@as(u32, 1), fake.queries);
    try t.expectEqual(@as(u32, 0), fake.writes);
    try t.expectEqual(@as(u32, 1), fake.refs);
}

test "memory target retries absent webviews and failed writes without a false applied state" {
    var fake: Fake = .{ .fail_write = true };
    var state: memory.State = .{};
    state.apply(null, .low);
    try t.expect(!state.unsupported);
    state.apply(&fake, .low);
    try t.expectEqual(@as(?memory.Level, null), state.applied);
    try t.expectEqual(@as(u32, 1), fake.refs);
    fake.fail_write = false;
    state.apply(&fake, .low);
    try t.expectEqual(memory.Level.low, state.applied.?);
    try t.expectEqual(@as(u32, 2), fake.writes);
    try t.expectEqual(@as(u32, 1), fake.refs);
}
