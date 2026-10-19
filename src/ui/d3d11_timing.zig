//! Frames of the Direct3D 11 renderer timed, for benchmarks (the hill
//! climb's, `hillclimb/`): the CPU time of encoding a frame into a target
//! kept across frames, whole or only what changed (`damage.zig`), and the
//! GPU's time drawing it, by timestamp queries around it.
const std = @import("std");
const d3d = @import("d3d11_api.zig");
const gpu = @import("gpu.zig");
const types = @import("types.zig");
const damage = @import("damage.zig");
const Renderer = @import("d3d11.zig").Renderer;

const query_timestamp = 2;
const query_disjoint = 3;
const QueryDesc = extern struct { query: u32, misc: u32 = 0 };
const Disjoint = extern struct { frequency: u64, disjoint: i32 };

pub const Timing = struct {
    /// CPU time to upload the instances and encode the frame.
    encode_ms: f64,
    /// GPU time of the frame (0 when the GPU would not tell).
    gpu_ms: f64,
    /// How much of the frame was drawn.
    drawn: Renderer.Drawn,
};

/// Draws frames into a target as a window does, each only where it changed
/// since the last (unless `whole`), timing them.
pub const Timer = struct {
    target: Renderer.Target,
    differ: damage.Differ,
    queries: [3]?d3d.Object = .{ null, null, null },

    pub fn init(r: *Renderer, gpa: std.mem.Allocator, w: u32, h: u32) !Timer {
        var t: Timer = .{ .target = try r.newTarget(w, h), .differ = .init(gpa) };
        const descs = [3]QueryDesc{ .{ .query = query_disjoint }, .{ .query = query_timestamp }, .{ .query = query_timestamp } };
        for (&descs, &t.queries) |*desc, *q| {
            if (d3d.failed(d3d.call(r.device, d3d.dev.create_query, .{ desc, q }))) q.* = null;
        }
        return t;
    }

    pub fn deinit(t: *Timer, r: *Renderer) void {
        for (t.queries) |q| d3d.release(q);
        r.freeTarget(t.target);
        t.differ.deinit();
    }

    pub fn draw(t: *Timer, r: *Renderer, f: damage.Frame, whole: bool) !Timing {
        const c = r.context;
        const now = @import("clock.zig").now;
        const t0 = now();
        var part: ?damage.Box = null;
        const since = t.differ.diff(f);
        if (!whole) if (t.differ.planOne(f, since)) |p| {
            if (damage.empty(p)) {
                t.differ.remember(f);
                return .{ .encode_ms = 0, .gpu_ms = 0, .drawn = .nothing };
            }
            part = p;
        };
        const timed = t.queries[0] != null and t.queries[1] != null and t.queries[2] != null;
        if (timed) {
            d3d.callAs(void, c, d3d.ctx.begin, .{t.queries[0].?});
            d3d.callAs(void, c, d3d.ctx.end, .{t.queries[1].?});
        }
        try r.drawTarget(t.target, f.instances, f.scale, f.clear, part);
        t.differ.remember(f);
        if (timed) {
            d3d.callAs(void, c, d3d.ctx.end, .{t.queries[2].?});
            d3d.callAs(void, c, d3d.ctx.end, .{t.queries[0].?});
        }
        d3d.callAs(void, c, d3d.ctx.flush, .{});
        const encode_ms = (now() - t0) * 1000;
        const drawn: Renderer.Drawn = if (part != null) .part else .whole;
        if (!timed) return .{ .encode_ms = encode_ms, .gpu_ms = 0, .drawn = drawn };
        // Waits for the GPU: the queries' data comes once it is done.
        var dj: Disjoint = undefined;
        while (d3d.call(c, d3d.ctx.get_data, .{ t.queries[0].?, &dj, @as(u32, @sizeOf(Disjoint)), @as(u32, 0) }) == 1) {}
        var a: u64 = 0;
        var b: u64 = 0;
        while (d3d.call(c, d3d.ctx.get_data, .{ t.queries[1].?, &a, @as(u32, 8), @as(u32, 0) }) == 1) {}
        while (d3d.call(c, d3d.ctx.get_data, .{ t.queries[2].?, &b, @as(u32, 8), @as(u32, 0) }) == 1) {}
        const gpu_ms = if (dj.disjoint != 0 or dj.frequency == 0 or b < a) 0 else @as(f64, @floatFromInt(b - a)) * 1000 / @as(f64, @floatFromInt(dj.frequency));
        return .{ .encode_ms = encode_ms, .gpu_ms = gpu_ms, .drawn = drawn };
    }
};
