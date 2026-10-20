//! Pictures the UI shows (`ui.image`): decoded once from the bytes the app
//! gives (ImageIO on macOS, myzig's PNG decoder elsewhere), scaled to at
//! most `max_side` pixels, and packed into one BGRA atlas the renderers
//! sample (premultiplied). Made small on the first picture, it doubles
//! when one doesn't fit, up to `size`; when full, emptied and packed again,
//! and the frame painted again.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const png_decode = @import("png_decode.zig");

const portable = build_options.portable or builtin.os.tag != .macos;
const imageio = if (portable) void else @import("image.zig");

/// The atlas's side at most.
pub const size: u32 = 2048;
/// Its side when the first picture comes.
const initial_side: u32 = 512;
/// The longest side a picture keeps.
pub const max_side: u32 = 1024;
const pad: u32 = 1;

pub const Entry = struct {
    uv: [4]f32,
    /// The picture's own size in pixels (before scaling down).
    width: u32,
    height: u32,
};

/// A picture decoded and scaled down, kept so packing it again is a copy.
pub const Decoded = struct {
    /// Its own size in pixels.
    width: u32,
    height: u32,
    /// The scaled pixels, `w` × `h`.
    w: u32,
    h: u32,
    bgra: []u8,
};

/// Decoded pictures kept at most (the oldest go first).
const max_kept_bytes = 64 * 1024 * 1024;

/// Where packed pictures go instead of `pixels`: the GPU's texture, so no
/// copy of the atlas is kept in memory (a window on Metal or Direct3D 11).
/// `upload` writes `w` × `h` pixels at (`x`, `y`) of a texture `side` ×
/// `side`, made anew and cleared when `side` changes.
pub const Sink = struct {
    ctx: *anyopaque,
    upload: *const fn (ctx: *anyopaque, side: u32, x: u32, y: u32, w: u32, h: u32, bgra: []const u8) void,
};

pub const Images = struct {
    gpa: std.mem.Allocator,
    /// Every picture decoded, by key (null: it can't be).
    decoded: std.AutoArrayHashMapUnmanaged(u64, ?Decoded) = .empty,
    kept_bytes: usize = 0,
    /// Rows of `pixels` changed since the GPU's copy was made.
    dirty: ?[2]u32 = null,
    sink: ?Sink = null,
    /// The atlas's side now: 0 until a picture comes.
    side: u32 = 0,
    /// BGRA, `side` × `side`; empty until a picture comes, or with a sink.
    pixels: []u8 = &.{},
    entries: std.AutoHashMapUnmanaged(u64, ?Entry) = .empty,
    shelf_x: u32 = 0,
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,
    /// Changes whenever the pixels do, for the GPU's copy.
    generation: u64 = 0,
    /// Emptied during a frame: its earlier pictures must be painted again.
    reset_during_frame: bool = false,

    pub fn deinit(im: *Images) void {
        if (im.pixels.len > 0) im.gpa.free(im.pixels);
        im.entries.deinit(im.gpa);
        for (im.decoded.values()) |d| if (d) |x| im.gpa.free(x.bgra);
        im.decoded.deinit(im.gpa);
    }

    /// The picture `k` decoded (from `bytes` the first time), or null.
    /// Sizing a picture needs only this: it is packed when drawn.
    pub fn info(im: *Images, k: u64, bytes: []const u8) ?Decoded {
        if (im.decoded.get(k)) |d| return d;
        const d = load(im.gpa, bytes) catch null;
        if (d) |x| im.kept_bytes += x.bgra.len;
        im.decoded.put(im.gpa, k, d) catch {
            if (d) |x| im.gpa.free(x.bgra);
            return null;
        };
        im.evict(k);
        return d;
    }

    /// Over budget: the oldest go (not `keep`); they decode again if they
    /// are drawn again.
    fn evict(im: *Images, keep: u64) void {
        var i: usize = 0;
        while (im.kept_bytes > max_kept_bytes and i + 1 < im.decoded.count()) {
            const old = im.decoded.keys()[i];
            if (old == keep or im.decoded.values()[i] == null) {
                i += 1;
                continue;
            }
            im.remove(old);
        }
    }

    /// Keeps `d` as the picture `k`, as if decoded from bytes: pictures
    /// the app draws itself (canvases). Its pixels (`im.gpa`'s) are now
    /// the atlas's.
    pub fn put(im: *Images, k: u64, d: Decoded) void {
        im.remove(k);
        im.decoded.put(im.gpa, k, d) catch {
            im.gpa.free(d.bgra);
            return;
        };
        im.kept_bytes += d.bgra.len;
        im.evict(k);
    }

    /// Lets the picture `k` go: its pixels now, its room in the atlas when
    /// the atlas is next emptied.
    pub fn remove(im: *Images, k: u64) void {
        if (im.decoded.fetchOrderedRemove(k)) |kv| if (kv.value) |d| {
            im.kept_bytes -= d.bgra.len;
            im.gpa.free(d.bgra);
        };
        _ = im.entries.remove(k);
    }

    /// Gives the picture `k` the pixels of `d`: in place in the atlas when
    /// it is there at the same size, so a picture that changes every frame
    /// keeps its room rather than taking more; packed anew otherwise.
    pub fn replace(im: *Images, k: u64, d: Decoded) void {
        const e = (im.entries.get(k) orelse null) orelse return im.put(k, d);
        const old = (im.decoded.get(k) orelse null) orelse return im.put(k, d);
        if (old.w != d.w or old.h != d.h) return im.put(k, d);
        const at = im.place(e);
        im.write(at, d);
        im.generation +%= 1;
        im.dirty = if (im.dirty) |r| .{ @min(r[0], at[1]), @max(r[1], at[1] + d.h) } else .{ at[1], at[1] + d.h };
        im.gpa.free(old.bgra);
        im.decoded.putAssumeCapacity(k, d);
    }

    /// The atlas as the CPU renderer reads it.
    pub fn pictures(im: *const Images) @import("raster.zig").Pictures {
        return .{ .pixels = im.pixels, .size = if (im.pixels.len > 0) im.side else 0 };
    }

    /// Sends the pictures to `sk` from now on, and lets the copy in memory
    /// go: each is written to it where it is, so frames painted already
    /// find them there.
    pub fn useSink(im: *Images, sk: Sink) void {
        im.sink = sk;
        im.rewrite();
        if (im.pixels.len > 0) im.gpa.free(im.pixels);
        im.pixels = &.{};
        im.dirty = null;
        im.generation +%= 1;
    }

    /// Keeps the pictures in memory again, as when the GPU is gone: each
    /// written where it was.
    pub fn useCpu(im: *Images) void {
        if (im.sink == null) return;
        im.sink = null;
        if (im.side == 0) return;
        im.generation +%= 1;
        im.pixels = im.gpa.alloc(u8, im.side * im.side * 4) catch {
            // Packed again as they are drawn.
            im.empty();
            im.side = 0;
            return;
        };
        @memset(im.pixels, 0);
        im.rewrite();
        im.dirty = .{ 0, im.side };
    }

    /// Where the picture `e` is in the atlas, in pixels.
    fn place(im: *const Images, e: Entry) [2]u32 {
        const s: f32 = @floatFromInt(im.side);
        return .{ @intFromFloat(@round(e.uv[0] * s)), @intFromFloat(@round(e.uv[1] * s)) };
    }

    /// Writes `d`'s pixels at `at`: to the sink, or into `pixels`.
    fn write(im: *Images, at: [2]u32, d: Decoded) void {
        if (im.sink) |sk| return sk.upload(sk.ctx, im.side, at[0], at[1], d.w, d.h, d.bgra);
        for (0..d.h) |row| {
            @memcpy(im.pixels[((at[1] + row) * im.side + at[0]) * 4 ..][0 .. d.w * 4], d.bgra[row * d.w * 4 ..][0 .. d.w * 4]);
        }
    }

    /// Writes every picture packed where it is.
    fn rewrite(im: *Images) void {
        var it = im.entries.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.* orelse continue;
            const d = (im.decoded.get(kv.key_ptr.*) orelse continue) orelse continue;
            im.write(im.place(e), d);
        }
    }

    /// Doubles the atlas until `w` × `h` fits or it is as large as it gets,
    /// keeping the pictures where they are (their `uv` scaled, which a
    /// power of two keeps exact): whether it fits now.
    fn grow(im: *Images, w: u32, h: u32) !bool {
        var side = im.side;
        while (side < size and !im.fitsIn(side, w, h)) side *= 2;
        if (side == im.side) return false;
        if (im.sink == null) {
            const px = try im.gpa.alloc(u8, side * side * 4);
            @memset(px, 0);
            for (0..im.side) |row| @memcpy(px[row * side * 4 ..][0 .. im.side * 4], im.pixels[row * im.side * 4 ..][0 .. im.side * 4]);
            im.gpa.free(im.pixels);
            im.pixels = px;
        }
        const k = @as(f32, @floatFromInt(im.side)) / @as(f32, @floatFromInt(side));
        im.side = side;
        var it = im.entries.valueIterator();
        while (it.next()) |v| if (v.*) |*e| {
            for (&e.uv) |*c| c.* *= k;
        };
        // The sink's texture is made anew at the new side.
        if (im.sink != null) im.rewrite();
        im.generation +%= 1;
        im.dirty = .{ 0, side };
        // Pictures painted this frame have their old `uv`.
        im.reset_during_frame = true;
        return im.fitsIn(side, w, h);
    }

    pub fn key(name: []const u8) u64 {
        return std.hash.Wyhash.hash(0x1a9e, name);
    }

    /// The picture `k` in the atlas, packing it (decoding `bytes` the
    /// first time) when it is not there; null if it can't be decoded.
    pub fn get(im: *Images, k: u64, bytes: []const u8) ?Entry {
        if (im.entries.get(k)) |e| return e;
        const d = im.info(k, bytes) orelse return null;
        const e = im.pack(d) catch return null;
        im.entries.put(im.gpa, k, e) catch {};
        return e;
    }

    fn pack(im: *Images, d: Decoded) !Entry {
        if (im.side == 0) im.side = initial_side;
        if (im.pixels.len == 0 and im.sink == null) {
            im.pixels = try im.gpa.alloc(u8, im.side * im.side * 4);
            @memset(im.pixels, 0);
        }
        if (!im.fitsIn(im.side, d.w, d.h) and !try im.grow(d.w, d.h)) {
            im.empty();
            im.reset_during_frame = true;
        }
        if (im.shelf_x > 0 and im.shelf_x + d.w + pad > im.side) {
            im.shelf_y += im.shelf_h + pad;
            im.shelf_x = 0;
            im.shelf_h = 0;
        }
        const x = im.shelf_x;
        const y = im.shelf_y;
        im.write(.{ x, y }, d);
        im.shelf_x += d.w + pad;
        im.shelf_h = @max(im.shelf_h, d.h);
        im.generation +%= 1;
        im.dirty = if (im.dirty) |r| .{ @min(r[0], y), @max(r[1], y + d.h) } else .{ y, y + d.h };
        const s: f32 = @floatFromInt(im.side);
        return .{
            .uv = .{ @as(f32, @floatFromInt(x)) / s, @as(f32, @floatFromInt(y)) / s, @as(f32, @floatFromInt(x + d.w)) / s, @as(f32, @floatFromInt(y + d.h)) / s },
            .width = d.width,
            .height = d.height,
        };
    }

    /// Whether `w` × `h` fits after the pictures packed, in an atlas `side`
    /// on a side.
    fn fitsIn(im: *const Images, side: u32, w: u32, h: u32) bool {
        if (w > side) return false;
        if (im.shelf_x == 0 or im.shelf_x + w + pad <= side) return im.shelf_y + @max(im.shelf_h, h) <= side;
        return im.shelf_y + im.shelf_h + pad + h <= side;
    }

    fn empty(im: *Images) void {
        im.entries.clearRetainingCapacity();
        im.shelf_x = 0;
        im.shelf_y = 0;
        im.shelf_h = 0;
    }
};

const Raw = struct { width: u32, height: u32, bgra: []u8 };

/// Decodes and scales a picture to keep.
fn load(gpa: std.mem.Allocator, bytes: []const u8) !Decoded {
    if (!portable) {
        const f = try imageio.decodeFit(gpa, bytes, max_side);
        return .{ .width = f.width, .height = f.height, .w = f.w, .h = f.h, .bgra = f.bgra };
    }
    const d = try decode(gpa, bytes);
    const scaled = fit(gpa, d.bgra, d.width, d.height) catch |e| {
        gpa.free(d.bgra);
        return e;
    };
    if (scaled.bgra.ptr != d.bgra.ptr) gpa.free(d.bgra);
    return .{ .width = d.width, .height = d.height, .w = scaled.w, .h = scaled.h, .bgra = scaled.bgra };
}

fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Raw {
    if (!portable) {
        const d = try imageio.decode(gpa, bytes);
        return .{ .width = d.width, .height = d.height, .bgra = d.bgra };
    }
    const d = png_decode.decode(gpa, bytes) catch |err| {
        // On Windows, what the system decodes: JPEG, GIF, BMP, WebP...
        if (builtin.os.tag == .windows and !build_options.portable) {
            const w = @import("../windows/wic.zig").decode(gpa, bytes) catch return err;
            return .{ .width = w.width, .height = w.height, .bgra = w.bgra };
        }
        return err;
    };
    return .{ .width = d.width, .height = d.height, .bgra = d.bgra };
}

const Scaled = struct { w: u32, h: u32, bgra: []u8 };

/// The picture within `max_side`, averaging the pixels each new one covers.
fn fit(gpa: std.mem.Allocator, bgra: []u8, w: u32, h: u32) !Scaled {
    const longest = @max(w, h);
    if (longest <= max_side) return .{ .w = w, .h = h, .bgra = bgra };
    const nw = @max(1, w * max_side / longest);
    const nh = @max(1, h * max_side / longest);
    const out = try gpa.alloc(u8, nw * nh * 4);
    for (0..nh) |y| {
        const sy0 = y * h / nh;
        const sy1 = @max(sy0 + 1, (y + 1) * h / nh);
        for (0..nw) |x| {
            const sx0 = x * w / nw;
            const sx1 = @max(sx0 + 1, (x + 1) * w / nw);
            var acc: [4]u32 = .{ 0, 0, 0, 0 };
            for (sy0..sy1) |sy| for (sx0..sx1) |sx| {
                const p = bgra[(sy * w + sx) * 4 ..][0..4];
                for (0..4) |k| acc[k] += p[k];
            };
            const n: u32 = @intCast((sy1 - sy0) * (sx1 - sx0));
            for (0..4) |k| out[(y * nw + x) * 4 + k] = @intCast(acc[k] / n);
        }
    }
    return .{ .w = nw, .h = nh, .bgra = out };
}

test "pictures drawn by the app are kept, replaced in place, and let go" {
    const gpa = std.testing.allocator;
    var im: Images = .{ .gpa = gpa };
    defer im.deinit();
    const px = struct {
        fn f(g: std.mem.Allocator, v: u8) !Decoded {
            const b = try g.alloc(u8, 3 * 2 * 4);
            @memset(b, v);
            return .{ .width = 3, .height = 2, .w = 3, .h = 2, .bgra = b };
        }
    }.f;
    im.put(7, try px(gpa, 10));
    const e = im.get(7, "").?;
    const p = im.place(e);
    const at = (@as(usize, p[1]) * im.side + p[0]) * 4;
    try std.testing.expectEqual(@as(u8, 10), im.pixels[at]);
    const shelf = im.shelf_x;
    // The same size: the same room, new pixels.
    im.replace(7, try px(gpa, 99));
    try std.testing.expectEqual(shelf, im.shelf_x);
    try std.testing.expectEqual(@as(u8, 99), im.pixels[at]);
    try std.testing.expectEqualDeep(e, im.get(7, "").?);
    im.remove(7);
    try std.testing.expect(im.get(7, "") == null);
    try std.testing.expectEqual(@as(usize, 0), im.kept_bytes);
}

test "pictures pack, scale down and come back by key" {
    const gpa = std.testing.allocator;
    var im: Images = .{ .gpa = gpa };
    defer im.deinit();
    // A 2×1 PNG, red then half-transparent blue.
    var px = [_]u8{ 0, 0, 255, 255, 128, 0, 0, 128 };
    const bytes = try @import("png.zig").encode(gpa, .{ .bytes = &px, .width = 2, .height = 1 });
    defer gpa.free(bytes);
    const e = im.get(Images.key("a.png"), bytes).?;
    try std.testing.expectEqual(@as(u32, 2), e.width);
    try std.testing.expectEqualSlices(u8, &px, im.pixels[0..8]);
    const gen = im.generation;
    _ = im.get(Images.key("a.png"), bytes);
    try std.testing.expectEqual(gen, im.generation);
    try std.testing.expect(im.get(Images.key("bad"), "not an image") == null);
    // Too big: averaged down to the longest side.
    const big = try gpa.alloc(u8, 2048 * 2 * 4);
    defer gpa.free(big);
    @memset(big, 200);
    const s = try fit(gpa, big, 2048, 2);
    defer gpa.free(s.bgra);
    try std.testing.expectEqual(@as(u32, 1024), s.w);
    try std.testing.expectEqual(@as(u32, 1), s.h);
    try std.testing.expectEqual(@as(u8, 200), s.bgra[0]);
}

test "the atlas starts small, and grows keeping its pictures where they are" {
    const gpa = std.testing.allocator;
    var im: Images = .{ .gpa = gpa };
    defer im.deinit();
    const px = struct {
        fn f(g: std.mem.Allocator, w: u32, h: u32, v: u8) !Decoded {
            const b = try g.alloc(u8, w * h * 4);
            @memset(b, v);
            return .{ .width = w, .height = h, .w = w, .h = h, .bgra = b };
        }
    }.f;
    im.put(1, try px(gpa, 40, 30, 7));
    const small = im.get(1, "").?;
    try std.testing.expectEqual(initial_side, im.side);
    try std.testing.expectEqual(@as(usize, initial_side * initial_side * 4), im.pixels.len);
    const before = im.place(small);
    // Too wide for the atlas as it is: it doubles, then doubles again.
    im.put(2, try px(gpa, 1500, 20, 9));
    const wide = im.get(2, "").?;
    try std.testing.expectEqual(@as(u32, 2048), im.side);
    try std.testing.expect(im.reset_during_frame);
    const moved = im.get(1, "").?;
    try std.testing.expectEqual(before, im.place(moved));
    // Its `uv` as packing it at this side would give, to the bit.
    try std.testing.expectEqual(@as(f32, @floatFromInt(before[0])) / 2048, moved.uv[0]);
    try std.testing.expectEqual(@as(u8, 7), im.pixels[(@as(usize, before[1]) * im.side + before[0]) * 4]);
    const w = im.place(wide);
    try std.testing.expectEqual(@as(u8, 9), im.pixels[(@as(usize, w[1]) * im.side + w[0]) * 4]);
}

test "pictures go to a sink and come back to memory where they were" {
    const gpa = std.testing.allocator;
    // A texture in memory, as a GPU's would be.
    const Texture = struct {
        side: u32 = 0,
        px: []u8 = &.{},
        g: std.mem.Allocator,
        fn upload(ctx: *anyopaque, side: u32, x: u32, y: u32, w: u32, h: u32, bgra: []const u8) void {
            const t: *@This() = @ptrCast(@alignCast(ctx));
            if (t.side != side) {
                t.g.free(t.px);
                t.px = t.g.alloc(u8, side * side * 4) catch unreachable;
                @memset(t.px, 0);
                t.side = side;
            }
            for (0..h) |row| @memcpy(t.px[((y + row) * side + x) * 4 ..][0 .. w * 4], bgra[row * w * 4 ..][0 .. w * 4]);
        }
    };
    var tex: Texture = .{ .g = gpa };
    defer gpa.free(tex.px);
    var im: Images = .{ .gpa = gpa };
    defer im.deinit();
    var prng: std.Random.DefaultPrng = .init(0x1a6e);
    const rnd = prng.random();
    const sink: Sink = .{ .ctx = &tex, .upload = Texture.upload };
    for (0..40) |k| {
        const w = rnd.intRangeAtMost(u32, 1, 300);
        const h = rnd.intRangeAtMost(u32, 1, 200);
        const b = try gpa.alloc(u8, w * h * 4);
        rnd.bytes(b);
        im.put(k, .{ .width = w, .height = h, .w = w, .h = h, .bgra = b });
        _ = im.get(k, "");
        // Now and then the GPU comes, or goes.
        if (k == 10 or k == 30) im.useSink(sink);
        if (k == 20) im.useCpu();
    }
    try std.testing.expectEqual(@as(usize, 0), im.pixels.len);
    try std.testing.expectEqual(im.side, tex.side);
    im.useCpu();
    try std.testing.expectEqualSlices(u8, tex.px, im.pixels);
}
