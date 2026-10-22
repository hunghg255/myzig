//! Real-runtime checks, independent of the policy's cached applied level.
const builtin = @import("builtin");

/// Exercise the real setter and read its value back from ICoreWebView2_19.
/// Other backends and older WebView2 versions skip this Windows-only probe.
pub fn target(window: anytype, normal: bool) !?i32 {
    if (comptime builtin.os.tag != .windows) return null;
    const page = window.page orelse return error.NoPage;
    if (page.memory_target.unsupported) return null;
    if (window.isVisible()) return error.VisibleTestWindow;
    page.memory_target.apply(page.webview, if (normal) .normal else .low);
    if (comptime @hasField(@TypeOf(page.*), "visibility")) {
        page.visibility.apply(page.controller, normal);
        const ctl = page.controller orelse return error.NoController;
        const table: *const [*]const *const anyopaque = @ptrCast(@alignCast(ctl));
        const GetVisible = *const fn (*anyopaque, *i32) callconv(.winapi) i32;
        const get: GetVisible = @ptrCast(table.*[3]);
        var actual: i32 = -1;
        if (get(ctl, &actual) < 0) return error.ReadVisibilityFailed;
        if (actual != @as(i32, @intFromBool(normal))) return error.WrongVisibility;
    }
    const obj = page.webview orelse return error.NoWebView;
    const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
    const iid: Guid = .{
        .a = 0x6921f954,
        .b = 0x79b0,
        .c = 0x437f,
        .d = .{ 0xa9, 0x97, 0xc8, 0x58, 0x11, 0x89, 0x7c, 0x68 },
    };
    const Query = *const fn (*anyopaque, *const Guid, *?*anyopaque) callconv(.winapi) i32;
    const Get = *const fn (*anyopaque, *i32) callconv(.winapi) i32;
    const Release = *const fn (*anyopaque) callconv(.winapi) u32;
    const table: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    const query: Query = @ptrCast(table.*[0]);
    var newer: ?*anyopaque = null;
    if (query(obj, &iid, &newer) < 0) return error.QueryFailed;
    const ptr = newer orelse return error.NullInterface;
    const methods: *const [*]const *const anyopaque = @ptrCast(@alignCast(ptr));
    const release: Release = @ptrCast(methods.*[2]);
    defer _ = release(ptr);
    const get: Get = @ptrCast(methods.*[119]);
    var level: i32 = -1;
    if (get(ptr, &level) < 0) return error.ReadFailed;
    if (level != @as(i32, if (normal) 0 else 1)) return error.WrongMemoryTarget;
    return level;
}
