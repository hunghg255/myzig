//! Compare only runs with the same recorded workload and rendering mode.
const std = @import("std");

pub const Profile = struct {
    frames: usize,
    repeat: usize,
    whole: bool = false,
    gpu: bool = false,
    hash: bool = false,
    partial: bool = true,
    optimize: []const u8,
    width: u32,
    height: u32,
    scale: f32,

    pub fn matches(a: Profile, b: Profile) bool {
        return a.frames == b.frames and a.repeat == b.repeat and
            a.whole == b.whole and a.gpu == b.gpu and a.hash == b.hash and a.partial == b.partial and
            a.width == b.width and a.height == b.height and a.scale == b.scale and
            std.mem.eql(u8, a.optimize, b.optimize);
    }
};

test "history metadata parsed from JSON matches equivalent live run options" {
    const t = std.testing;
    const current: Profile = .{
        .frames = 300,
        .repeat = 3,
        .optimize = "fast",
        .width = 900,
        .height = 640,
        .scale = 2,
    };
    const parsed = try std.json.parseFromSlice(Profile, t.allocator,
        \\{"frames":300,"repeat":3,"whole":false,"gpu":false,"hash":false,
        \\"optimize":"fast","width":900,"height":640,"scale":2}
    , .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try t.expect(current.matches(parsed.value));
    const whole = try std.json.parseFromSlice(Profile, t.allocator,
        \\{"frames":300,"repeat":3,"whole":true,"optimize":"fast",
        \\"width":900,"height":640,"scale":2}
    , .{});
    defer whole.deinit();
    try t.expect(!current.matches(whole.value));
}

test "GPU, hash, sample count and optimization change history comparability" {
    const t = std.testing;
    const current: Profile = .{
        .frames = 300,
        .repeat = 3,
        .optimize = "fast",
        .width = 900,
        .height = 640,
        .scale = 2,
    };
    var other = current;
    other.gpu = true;
    try t.expect(!current.matches(other));
    other = current;
    other.hash = true;
    try t.expect(!current.matches(other));
    other = current;
    other.frames = 30;
    try t.expect(!current.matches(other));
    other = current;
    other.repeat = 5;
    try t.expect(!current.matches(other));
    other = current;
    other.optimize = "small";
    try t.expect(!current.matches(other));
    other = current;
    other.partial = false;
    try t.expect(!current.matches(other));
}
