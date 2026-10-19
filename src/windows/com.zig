//! COM without headers: methods called through an object's vtable, by
//! index, and the handler objects WebView2 takes for its events and
//! completions (IUnknown and one Invoke).
const std = @import("std");

pub const HRESULT = i32;
pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));

pub const GUID = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,

    /// "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", at compile time.
    pub fn parse(comptime s: []const u8) GUID {
        @setEvalBranchQuota(10_000);
        const hex = struct {
            fn f(comptime t: []const u8) u64 {
                return std.fmt.parseInt(u64, t, 16) catch @compileError("bad GUID " ++ s);
            }
        }.f;
        return comptime blk: {
            var d: [8]u8 = undefined;
            d[0] = @intCast(hex(s[19..21]));
            d[1] = @intCast(hex(s[21..23]));
            for (0..6) |i| d[2 + i] = @intCast(hex(s[24 + i * 2 ..][0..2]));
            break :blk .{ .a = @intCast(hex(s[0..8])), .b = @intCast(hex(s[9..13])), .c = @intCast(hex(s[14..18])), .d = d };
        };
    }

    pub fn eql(x: GUID, y: GUID) bool {
        return std.mem.eql(u8, std.mem.asBytes(&x), std.mem.asBytes(&y));
    }
};

pub const Object = *anyopaque;

pub fn failed(hr: HRESULT) bool {
    return hr < 0;
}

/// Calls method `index` of `obj` with `args` after the object itself.
pub fn call(obj: Object, index: usize, args: anytype) HRESULT {
    return callAs(HRESULT, obj, index, args);
}

pub fn callAs(comptime R: type, obj: Object, index: usize, args: anytype) R {
    const info = @typeInfo(@TypeOf(args)).@"struct";
    const params = comptime blk: {
        var p: [info.field_types.len + 1]type = undefined;
        p[0] = Object;
        for (info.field_types, 0..) |t, i| p[i + 1] = t;
        break :blk p;
    };
    const F = @Fn(&params, &@splat(.{}), R, .{ .@"callconv" = .winapi });
    const vtbl: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    const f: *const F = @ptrCast(@alignCast(vtbl.*[index]));
    return @call(.auto, f, .{obj} ++ args);
}

pub fn addRef(obj: ?Object) void {
    if (obj) |o| _ = callAs(u32, o, 1, .{});
}

pub fn release(obj: ?Object) void {
    if (obj) |o| _ = callAs(u32, o, 2, .{});
}

/// `obj`'s implementation of `iid`, or null.
pub fn query(obj: Object, iid: *const GUID) ?Object {
    var out: ?Object = null;
    if (failed(call(obj, 0, .{ iid, &out }))) return null;
    return out;
}

extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;
extern "ole32" fn CoTaskMemAlloc(n: usize) callconv(.winapi) ?*anyopaque;
pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) HRESULT;

/// A string COM allocated, as UTF-8 in `gpa`; the COM string is freed.
pub fn takeString(gpa: std.mem.Allocator, p: ?[*:0]u16) ![]u8 {
    const s = p orelse return gpa.dupe(u8, "");
    defer CoTaskMemFree(s);
    return std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(s));
}

/// A NUL-terminated UTF-16 copy of `s`.
pub fn wide(gpa: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(gpa, s);
}

/// A COM string (CoTaskMemAlloc) of `s`, which its receiver frees.
pub fn coString(s: []const u8) ?[*:0]u16 {
    var buf: [1024]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, s[0..@min(s.len, 512)]) catch return null;
    const p: [*]u16 = @ptrCast(@alignCast(CoTaskMemAlloc((n + 1) * 2) orelse return null));
    @memcpy(p[0..n], buf[0..n]);
    p[n] = 0;
    return p[0..n :0];
}

const iid_unknown = GUID.parse("00000000-0000-0000-c000-000000000046");
// Interfaces a handler must not claim: callers would marshal through it.
const iid_marshal = GUID.parse("00000003-0000-0000-c000-000000000046");
const iid_agile = GUID.parse("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90");
const iid_no_marshal = GUID.parse("ecc8691b-c1db-4dc0-855e-65f6c551af49");

/// A COM object with one method besides IUnknown, `Invoke(a, b)`, as
/// WebView2's handlers are: it calls `func(ctx, a, b)`. It holds one
/// reference when made; COM's last release frees it.
pub const Handler = extern struct {
    vtbl: *const Vtbl,
    refs: std.atomic.Value(u32),
    ctx: ?*anyopaque,
    /// A `Func` (extern structs keep no Zig function pointers).
    func: *const anyopaque,

    pub const Func = *const fn (ctx: ?*anyopaque, a: usize, b: usize) void;

    const Vtbl = extern struct {
        query: *const fn (*Handler, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        add_ref: *const fn (*Handler) callconv(.winapi) u32,
        release: *const fn (*Handler) callconv(.winapi) u32,
        invoke: *const fn (*Handler, usize, usize) callconv(.winapi) HRESULT,
    };

    const shared_vtbl: Vtbl = .{ .query = queryImpl, .add_ref = addRefImpl, .release = releaseImpl, .invoke = invokeImpl };

    pub fn create(ctx: ?*anyopaque, func: Func) !*Handler {
        const h = try std.heap.page_allocator.create(Handler);
        h.* = .{ .vtbl = &shared_vtbl, .refs = .init(1), .ctx = ctx, .func = @ptrCast(func) };
        return h;
    }

    pub fn object(h: *Handler) Object {
        return @ptrCast(h);
    }

    fn queryImpl(h: *Handler, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (iid.eql(iid_marshal) or iid.eql(iid_agile) or iid.eql(iid_no_marshal)) {
            out.* = null;
            return E_NOINTERFACE;
        }
        out.* = h;
        _ = addRefImpl(h);
        return S_OK;
    }

    fn addRefImpl(h: *Handler) callconv(.winapi) u32 {
        return h.refs.fetchAdd(1, .monotonic) + 1;
    }

    fn releaseImpl(h: *Handler) callconv(.winapi) u32 {
        const left = h.refs.fetchSub(1, .acq_rel) - 1;
        if (left == 0) std.heap.page_allocator.destroy(h);
        return left;
    }

    fn invokeImpl(h: *Handler, a: usize, b: usize) callconv(.winapi) HRESULT {
        const f: Func = @ptrCast(@alignCast(h.func));
        f(h.ctx, a, b);
        return S_OK;
    }
};

/// Passes a new handler to `start`, which takes its own reference if it
/// keeps it; ours is dropped.
pub fn withHandler(ctx: ?*anyopaque, func: *const fn (?*anyopaque, usize, usize) void, start: anytype, args: anytype) HRESULT {
    const h = Handler.create(ctx, func) catch return E_FAIL;
    defer _ = Handler.releaseImpl(h);
    return @call(.auto, start, args ++ .{h.object()});
}

test "GUIDs parse as their bytes" {
    const g = GUID.parse("c979903e-d4ca-4228-92eb-47ee3fa96eab");
    try std.testing.expectEqual(@as(u32, 0xc979903e), g.a);
    try std.testing.expectEqual(@as(u16, 0xd4ca), g.b);
    try std.testing.expectEqual(@as(u16, 0x4228), g.c);
    try std.testing.expectEqualSlices(u8, &.{ 0x92, 0xeb, 0x47, 0xee, 0x3f, 0xa9, 0x6e, 0xab }, &g.d);
    try std.testing.expect(!g.eql(iid_unknown));
}

test "a handler calls its function and frees itself on the last release" {
    const S = struct {
        var got: [2]usize = .{ 0, 0 };
        fn f(_: ?*anyopaque, a: usize, b: usize) void {
            got = .{ a, b };
        }
    };
    const h = try Handler.create(null, S.f);
    const o = h.object();
    addRef(o);
    try std.testing.expectEqual(S_OK, call(o, 3, .{ @as(usize, 7), @as(usize, 9) }));
    try std.testing.expectEqual([2]usize{ 7, 9 }, S.got);
    var out: ?*anyopaque = null;
    try std.testing.expectEqual(E_NOINTERFACE, call(o, 0, .{ &iid_marshal, &out }));
    release(o);
    release(o);
}
