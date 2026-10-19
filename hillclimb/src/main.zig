//! myzig's hill-climb: a terminal app that renders benchmark scenes
//! offscreen with myzig and with mygo, frame after frame, and compares
//! their CPU and GPU costs with each other and with earlier runs. No
//! window opens, nothing takes focus. Where there is no Metal (Linux,
//! Windows) both frameworks' CPU renderers draw the frames instead, and
//! their time takes the place of encoding (`render CPU`); GPU is empty.
//!
//!   zig build run                          all scenes, myzig and mygo
//!   zig build run -- --label "glyph atlas" name this run in the history
//!   zig build run -- --scene text --frames 600 --only myzig
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const scenes = @import("scenes.zig");
const report = @import("report.zig");
const mygo = @import("mygo.zig");
const clock = @import("clock.zig");

pub const width = 900;
pub const height = 640;
pub const scale = 2;
const warmup = 30;

pub const Result = struct {
    fw: []const u8,
    scene: []const u8,
    frames: usize,
    /// Median CPU time of building, laying out and painting a frame.
    frame_ms: f64,
    frame_p95: f64,
    /// Median CPU time of encoding it for the GPU.
    encode_ms: f64,
    /// Median GPU time of drawing it.
    gpu_ms: f64,
    /// The process's CPU time (user + system) per frame, all included.
    cpu_ms: f64,
    /// What the GPU draws: myzig's instances, mygo's scene operations.
    ops: usize,
    /// myzig's phases of a frame (medians); mygo reports none.
    build_ms: f64 = 0,
    layout_ms: f64 = 0,
    paint_ms: f64 = 0,
    /// With --hash, where the CPU renderer draws: every frame's pixels
    /// hashed together, to tell that a change to it drew the same.
    pixels_hash: u64 = 0,
};

const Options = struct {
    frames: usize = 300,
    /// Runs of each scene; the one with the lowest median frame is kept,
    /// the others being the same work disturbed by the rest of the system.
    repeat: usize = 3,
    only: ?[]const u8 = null,
    scenes: []const scenes.Scene = std.enums.values(scenes.Scene),
    label: []const u8 = "",
    hash: bool = false,
    /// The CPU renderer draws every frame whole, rather than only what
    /// changed since the last (`ui.damage`), to compare the two.
    whole: bool = false,
    /// On Windows, Direct3D 11 draws the frames (into a texture kept
    /// across frames), timed by the GPU, rather than the CPU renderer.
    gpu: bool = false,
};

/// Drawing only what changed, and Direct3D 11, once `ui` exports them.
const has_damage = @hasDecl(ui, "damage");
const has_d3d11 = has_damage and @import("builtin").os.tag == .windows and @hasDecl(ui, "d3d11");

fn medianOf(xs: []f64) f64 {
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    return xs[xs.len / 2];
}

fn p95Of(xs: []f64) f64 {
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    return xs[xs.len * 95 / 100];
}

/// Runs `scene` with myzig: the view, layout and paint of a frame as a
/// window runs them, then the Metal renderer drawing it into a texture (the
/// CPU renderer into memory where there is no Metal, or Direct3D 11 with
/// `--gpu`).
fn runMyzig(gpa: std.mem.Allocator, scene: scenes.Scene, frames: usize, hash: bool, whole: bool, use_gpu: bool) !Result {
    var state: scenes.State = .{ .scene = scene };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, scenes.State.view), .{ .width = width, .height = height, .scale = scale });
    defer t.deinit();
    t.dt = 1.0 / 120.0;
    const has_metal = @TypeOf(t.renderer) != void;
    const target = if (has_metal) t.renderer.newTarget(t.size, t.scale) else {};
    defer if (has_metal) myzig.objc.release(target);
    const px = t.pixelSize();
    const pixels = try gpa.alloc(u8, if (has_metal) 0 else px[0] * px[1] * 4);
    defer gpa.free(pixels);
    // As a window's frames on the CPU: only what changed, unless --whole.
    var differ = if (has_damage) ui.damage.Differ.init(gpa) else {};
    defer if (has_damage) differ.deinit();
    var d3d: if (has_d3d11) ?ui.d3d11.Renderer else ?void = if (has_d3d11 and use_gpu) ui.d3d11.Renderer.init(gpa) catch null else null;
    defer if (has_d3d11) if (d3d) |*r| r.deinit();
    var timer: if (has_d3d11) ?ui.d3d11.Timer else ?void = null;
    if (has_d3d11) if (d3d) |*r| {
        timer = try ui.d3d11.Timer.init(r, gpa, @intCast(px[0]), @intCast(px[1]));
    };
    defer if (has_d3d11) if (timer) |*tm| tm.deinit(&d3d.?);

    const frame_ms = try gpa.alloc(f64, frames);
    defer gpa.free(frame_ms);
    const encode_ms = try gpa.alloc(f64, frames);
    defer gpa.free(encode_ms);
    const gpu_ms = try gpa.alloc(f64, frames);
    defer gpa.free(gpu_ms);
    var phases: [3][]f64 = undefined;
    for (&phases) |*ph| ph.* = try gpa.alloc(f64, frames);
    defer for (phases) |ph| gpa.free(ph);
    var cpu0: f64 = 0;
    var pixels_hash: u64 = 0;
    for (0..warmup + frames) |i| {
        if (i == warmup) cpu0 = clock.cpuSeconds();
        state.frame = i;
        state.time = @as(f32, @floatFromInt(i)) / 120;
        t.time = state.time;
        const t0 = clock.now();
        t.frame();
        const ft = (clock.now() - t0) * 1000;
        const timing: struct { encode_ms: f64, gpu_ms: f64 } = if (has_metal) blk: {
            const tm = t.renderer.drawTimed(target, t.instances.items, t.text.texture(), t.size, t.theme.background);
            break :blk .{ .encode_ms = tm.encode_ms, .gpu_ms = tm.gpu_ms };
        } else if (has_d3d11 and timer != null) blk: {
            const r = &d3d.?;
            r.syncAtlas(t.text.atlas.mask(), t.text.atlas.generation);
            r.syncImages(&t.text.images);
            const f: ui.damage.Frame = .{ .instances = t.instances.items, .width = @intCast(px[0]), .height = @intCast(px[1]), .scale = t.scale, .clear = t.theme.background, .atlas = ui.damage.atlasKey(&t.text.atlas), .images = t.text.images.generation };
            const tm = try timer.?.draw(r, f, whole);
            break :blk .{ .encode_ms = tm.encode_ms, .gpu_ms = tm.gpu_ms };
        } else blk: {
            const r0 = clock.now();
            if (has_damage) {
                const out: ui.damage.Pixels = .{ .bytes = pixels, .width = px[0], .height = px[1] };
                const f: ui.damage.Frame = .{ .instances = t.instances.items, .width = @intCast(px[0]), .height = @intCast(px[1]), .scale = t.scale, .clear = t.theme.background, .atlas = ui.damage.atlasKey(&t.text.atlas), .images = t.text.images.generation };
                _ = ui.damage.drawCpu(&differ, out, f, t.text.atlas.mask(), t.text.images.pictures(), whole);
            } else t.rasterize(pixels);
            const ms = (clock.now() - r0) * 1000;
            if (hash) pixels_hash = std.hash.Wyhash.hash(pixels_hash, pixels);
            break :blk .{ .encode_ms = ms, .gpu_ms = 0 };
        };
        if (i >= warmup) {
            frame_ms[i - warmup] = ft;
            encode_ms[i - warmup] = timing.encode_ms;
            gpu_ms[i - warmup] = timing.gpu_ms;
            phases[0][i - warmup] = t.ctx.stats.build_ms;
            phases[1][i - warmup] = t.ctx.stats.layout_ms;
            phases[2][i - warmup] = t.ctx.stats.paint_ms;
        }
    }
    const cpu = (clock.cpuSeconds() - cpu0) * 1000 / @as(f64, @floatFromInt(frames));
    return .{
        .fw = "myzig",
        .scene = @tagName(scene),
        .frames = frames,
        .frame_ms = medianOf(frame_ms),
        .frame_p95 = p95Of(frame_ms),
        .encode_ms = medianOf(encode_ms),
        .gpu_ms = medianOf(gpu_ms),
        .cpu_ms = cpu,
        .ops = t.instances.items.len,
        .build_ms = medianOf(phases[0]),
        .layout_ms = medianOf(phases[1]),
        .paint_ms = medianOf(phases[2]),
        .pixels_hash = pixels_hash,
    };
}

fn better(a: ?Result, b: Result) Result {
    return if (a) |x| (if (x.frame_ms <= b.frame_ms) x else b) else b;
}

fn parseArgs(init: std.process.Init) !Options {
    const arena = init.arena.allocator();
    var o: Options = .{};
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--repeat")) {
            o.repeat = @max(1, try std.fmt.parseInt(usize, next, 10));
            i += 1;
        } else if (std.mem.eql(u8, a, "--frames")) {
            o.frames = try std.fmt.parseInt(usize, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--only")) {
            o.only = next;
            i += 1;
        } else if (std.mem.eql(u8, a, "--hash")) {
            o.hash = true;
        } else if (std.mem.eql(u8, a, "--whole")) {
            o.whole = true;
        } else if (std.mem.eql(u8, a, "--gpu")) {
            o.gpu = true;
        } else if (std.mem.eql(u8, a, "--mygo")) {
            mygo.url = next;
            i += 1;
        } else if (std.mem.eql(u8, a, "--label")) {
            o.label = next;
            i += 1;
        } else if (std.mem.eql(u8, a, "--scene")) {
            var list: std.ArrayList(scenes.Scene) = .empty;
            var it = std.mem.splitScalar(u8, next, ',');
            while (it.next()) |name| try list.append(arena, std.meta.stringToEnum(scenes.Scene, name) orelse return error.UnknownScene);
            o.scenes = list.items;
            i += 1;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("usage: hillclimb [--scene boxes,text,scroll,list,dashboard,layout,caret,spinner] [--frames N] [--only myzig|mygo] [--label NAME] [--mygo REPO] [--hash] [--whole] [--gpu]\n", .{});
            std.process.exit(0);
        } else return error.UnknownArgument;
    }
    return o;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const opts = try parseArgs(init);
    const want = struct {
        fn f(o: Options, fw: []const u8) bool {
            return o.only == null or std.mem.eql(u8, o.only.?, fw);
        }
    }.f;

    report.header(opts.frames);
    var results: std.ArrayList(Result) = .empty;
    var mygo_error: ?anyerror = null;
    if (want(opts, "mygo")) {
        report.status("building mygo's twin (go test -c)…");
        mygo.build(init) catch |err| {
            report.status("");
            mygo_error = err;
            std.debug.print("mygo skipped: {s}\n", .{@errorName(err)});
        };
    }
    for (opts.scenes) |scene| {
        var n_best: ?Result = null;
        var m_best: ?Result = null;
        for (0..opts.repeat) |rep| {
            if (want(opts, "myzig")) {
                report.status(try std.fmt.allocPrint(arena, "myzig · {s} · run {d}/{d}…", .{ @tagName(scene), rep + 1, opts.repeat }));
                n_best = better(n_best, try runMyzig(gpa, scene, opts.frames, opts.hash, opts.whole, opts.gpu));
            }
            if (want(opts, "mygo") and mygo.ready and scene.inMygo()) {
                report.status(try std.fmt.allocPrint(arena, "mygo · {s} · run {d}/{d}…", .{ @tagName(scene), rep + 1, opts.repeat }));
                if (mygo.run(init, scene, opts.frames)) |r| {
                    m_best = better(m_best, r);
                } else |err| std.debug.print("mygo {s}: {s}\n", .{ @tagName(scene), @errorName(err) });
            }
        }
        if (n_best) |r| try results.append(arena, r);
        if (m_best) |r| try results.append(arena, r);
    }
    report.status("");
    const history = report.loadHistory(init) catch &.{};
    report.table(results.items, history);
    if (opts.hash) for (results.items) |r| if (r.pixels_hash != 0) std.debug.print("pixels {s:<10} {x:0>16}\n", .{ r.scene, r.pixels_hash });
    if (mygo_error) |err| std.debug.print("\x1b[31mmygo's twin did not build ({s}): its columns are empty.\x1b[0m\n", .{@errorName(err)});
    try report.appendHistory(init, opts.label, results.items);
}
