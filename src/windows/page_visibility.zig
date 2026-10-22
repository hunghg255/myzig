//! Main-page controller visibility, independent of the host HWND's flag.
const com = @import("com.zig");

pub const State = struct {
    applied: ?bool = null,

    pub fn apply(self: *State, controller: ?com.Object, visible: bool) void {
        const obj = controller orelse return;
        if (self.applied) |previous| if (previous == visible) return;
        if (!com.failed(com.call(obj, 4, .{@as(i32, @intFromBool(visible))}))) {
            self.applied = visible;
        }
    }
};

test "controller visibility retries failures, tolerates absent controllers and skips duplicates" {
    const t = @import("std").testing;
    const Fake = extern struct {
        table: *const Table = &methods,
        writes: u32 = 0,
        visible: i32 = 1,
        fail: bool = false,

        const Table = extern struct {
            unused: [4]?*const anyopaque = @splat(null),
            put: *const fn (com.Object, i32) callconv(.winapi) i32,
        };
        const methods: Table = .{ .put = put };

        fn put(obj: com.Object, visible: i32) callconv(.winapi) i32 {
            const self: *@This() = @ptrCast(@alignCast(obj));
            self.writes += 1;
            if (self.fail) return com.E_FAIL;
            self.visible = visible;
            return com.S_OK;
        }
    };
    var fake: Fake = .{};
    var state: State = .{};
    state.apply(null, false);
    try t.expectEqual(@as(?bool, null), state.applied);
    fake.fail = true;
    state.apply(&fake, false);
    try t.expectEqual(@as(?bool, null), state.applied);
    fake.fail = false;
    state.apply(&fake, false);
    state.apply(&fake, false);
    try t.expectEqual(@as(u32, 2), fake.writes);
    try t.expectEqual(@as(i32, 0), fake.visible);
    state.apply(&fake, true);
    try t.expectEqual(@as(i32, 1), fake.visible);
}
