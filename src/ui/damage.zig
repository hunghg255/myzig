//! Drawing only what changed, after mygo's `scene.Differ`: a frame that
//! changes little of a window (a caret blinking, a spinner turning, a
//! button under the pointer) redraws only the pixels that may differ from
//! the last frame, over the rest kept as it was, in every renderer whose
//! target keeps what was drawn (the CPU renderer's pixels, a GtkGLArea's
//! framebuffer, a WebGL canvas kept between frames, a flip sequential swap
//! chain, a CAMetalLayer's drawables by their age).
//!
//! `Differ` compares a frame's instances with the last frame's from both
//! ends: where they differ, the pixels each instance drew last and draws
//! now are damaged. Instances are compared with the rows they read (a
//! transform's, a gradient's, an effect's), wherever those rows are, and
//! pictures count as changed when the image atlas did; a frame of another
//! size, scale or background, or after the glyph atlas was emptied, draws
//! whole. Effects and blurred layers read what is under them: an area to
//! draw that meets one grows by all it reads (`grow`), so that it reads
//! none of what the last frame drew. Past half the frame, drawing it
//! whole costs about the same, and it is drawn whole.
//!
//! Drawn in part, every pixel is what drawing the frame whole gives, byte
//! for byte: tests draw random frames changing frame after frame both ways
//! (`tests_damage.zig`, and each GPU renderer's tests).
const std = @import("std");
const gpu = @import("gpu.zig");
const types = @import("types.zig");
const xf = @import("raster_xf.zig");
const raster_fx = @import("raster_fx.zig");
const backdrop = @import("backdrop.zig");
const effect = @import("effect.zig");
const raster = @import("raster.zig");

/// Pixels x0, y0, x1, y1.
pub const Box = [4]i32;

/// The most rectangles damage is kept in, apart from each other.
pub const max_rects = 8;

/// How far, in pixels, a renderer may draw beyond an instance's bounds as
/// the CPU renderer finds them: the GPUs' quads, at whole pixels. Three
/// more under a transform.
const reach = 2;

/// `MYZIG_PARTIAL=0` draws every frame whole, for measurements that compare.
pub fn enabled() bool {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return true;
    const v = std.c.getenv("MYZIG_PARTIAL") orelse return true;
    return v[0] != '0';
}

/// A frame, and what its pixels depend on besides its instances.
pub const Frame = struct {
    /// As painted: the instances, then their rows (`gpu.Frame`).
    instances: []const gpu.Instance,
    width: u32,
    height: u32,
    scale: f32,
    clear: types.Color,
    /// The glyph atlas's state (`atlasKey`): emptied, its glyphs may be
    /// others.
    atlas: u64 = 0,
    /// The image atlas's generation: pictures changed when it did.
    images: u64 = 0,
};

/// The glyph atlas's size and how often it was emptied.
pub fn atlasKey(a: anytype) u64 {
    return @as(u64, a.size) << 32 | a.resets;
}

pub fn empty(b: Box) bool {
    return b[2] <= b[0] or b[3] <= b[1];
}

pub fn unite(a: Box, b: Box) Box {
    if (empty(a)) return b;
    if (empty(b)) return a;
    return .{ @min(a[0], b[0]), @min(a[1], b[1]), @max(a[2], b[2]), @max(a[3], b[3]) };
}

pub fn intersect(a: Box, b: Box) Box {
    return .{ @max(a[0], b[0]), @max(a[1], b[1]), @min(a[2], b[2]), @min(a[3], b[3]) };
}

pub fn overlaps(a: Box, b: Box) bool {
    return !empty(a) and !empty(b) and a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3];
}

fn within(a: Box, b: Box) bool {
    return a[0] >= b[0] and a[1] >= b[1] and a[2] <= b[2] and a[3] <= b[3];
}

pub fn area(b: Box) u64 {
    if (empty(b)) return 0;
    return @as(u64, @intCast(b[2] - b[0])) * @as(u64, @intCast(b[3] - b[1]));
}

fn usize4(b: [4]usize) Box {
    return .{ @intCast(b[0]), @intCast(b[1]), @intCast(b[2]), @intCast(b[3]) };
}

fn outset(b: Box, d: i32, w: u32, h: u32) Box {
    return .{ @max(b[0] - d, 0), @max(b[1] - d, 0), @min(b[2] + d, @as(i32, @intCast(w))), @min(b[3] + d, @as(i32, @intCast(h))) };
}

const none: Box = .{ 0, 0, 0, 0 };

/// The pixels instance `i` of a `w` × `h` frame may change, whichever
/// renderer draws it.
pub fn boundsOf(i: *const gpu.Instance, rows: []const [4]f32, w: u32, h: u32, scale: f32) Box {
    const kind = gpu.kindOf(i.kind);
    if (kind == gpu.Kind.trailer) return none;
    if (gpu.isMarker(i.kind) and i.kind < 16) {
        const a = raster_fx.area(w, h, i.rect, i.clip, scale) orelse return none;
        return outset(usize4(a), reach, w, h);
    }
    if (xf.general(i)) {
        const b = xf.bounds(w, h, i, rows, scale) orelse return none;
        return outset(usize4(b), if (i.kind >= 16) reach + 3 else reach, w, h);
    }
    const blur: f32 = if (kind == gpu.Kind.shadow) i.border_width * 3 else 0;
    const x0 = @max(i.rect[0] - blur, i.clip[0]);
    const y0 = @max(i.rect[1] - blur, i.clip[1]);
    const x1 = @min(i.rect[0] + i.rect[2] + blur, i.clip[2]);
    const y1 = @min(i.rect[1] + i.rect[3] + blur, i.clip[3]);
    if (x1 <= x0 or y1 <= y0) return none;
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const b: Box = .{
        @intFromFloat(std.math.clamp(@floor(x0 * scale), 0, fw)),
        @intFromFloat(std.math.clamp(@floor(y0 * scale), 0, fh)),
        @intFromFloat(std.math.clamp(@ceil(x1 * scale), 0, fw)),
        @intFromFloat(std.math.clamp(@ceil(y1 * scale), 0, fh)),
    };
    if (empty(b)) return none;
    return outset(b, reach, w, h);
}

/// How many rows from `at` the instance of kind `kind` reads: a gradient's
/// (its stops), an effect's.
fn blockOf(kind: f32, rows: []const [4]f32, at: usize) ?usize {
    if (kind == gpu.Kind.effect) return effect.rows_per_effect;
    if (kind == gpu.Kind.gradient) {
        if (at >= rows.len) return null;
        return 2 + 2 * @as(usize, @intFromFloat(@max(rows[at][1], 0)));
    }
    return 0;
}

fn sameRows(ra: []const [4]f32, a: usize, rb: []const [4]f32, b: usize, n: usize) bool {
    if (a + n > ra.len or b + n > rb.len) return false;
    return std.mem.eql(u8, std.mem.sliceAsBytes(ra[a..][0..n]), std.mem.sliceAsBytes(rb[b..][0..n]));
}

/// Whether instance `a` (reading rows `ra`) draws what `b` (reading `rb`)
/// does, its pictures unchanged unless `pictures_changed`.
pub fn same(a: *const gpu.Instance, ra: []const [4]f32, b: *const gpu.Instance, rb: []const [4]f32, pictures_changed: bool) bool {
    var x = a.*;
    var y = b.*;
    const kind = gpu.kindOf(x.kind);
    if (kind != gpu.kindOf(y.kind)) return false;
    const ta = gpu.transformOf(x.kind);
    const tb = gpu.transformOf(y.kind);
    if ((ta == null) != (tb == null)) return false;
    if (ta) |t| if (!sameRows(ra, t, rb, tb.?, gpu.transform_rows)) return false;
    x.kind = kind;
    y.kind = kind;
    if (kind == gpu.Kind.gradient or kind == gpu.Kind.effect) {
        const sa: usize = @intFromFloat(@max(x.uv[0], 0));
        const sb: usize = @intFromFloat(@max(y.uv[0], 0));
        const n = blockOf(kind, ra, sa) orelse return false;
        if (n != (blockOf(kind, rb, sb) orelse return false) or !sameRows(ra, sa, rb, sb, n)) return false;
        x.uv[0] = 0;
        y.uv[0] = 0;
    }
    if (kind == gpu.Kind.image and pictures_changed) return false;
    return std.mem.eql(u8, std.mem.asBytes(&x), std.mem.asBytes(&y));
}

/// Adds `b` to the rectangles of `list`, merged with one it nearly
/// touches; past `max_rects`, they become one.
fn addRect(list: *Rects, b: Box) void {
    if (empty(b)) return;
    for (list.slice()) |*d| {
        if (overlaps(.{ d[0] - 8, d[1] - 8, d[2] + 8, d[3] + 8 }, b)) {
            d.* = unite(d.*, b);
            return;
        }
    }
    if (list.len == max_rects) {
        var u = b;
        for (list.slice()) |d| u = unite(u, d);
        list.len = 1;
        list.items[0] = u;
        return;
    }
    list.items[list.len] = b;
    list.len += 1;
}

/// A few rectangles of damage.
pub const Rects = struct {
    items: [max_rects]Box = undefined,
    len: usize = 0,

    pub fn slice(r: *Rects) []Box {
        return r.items[0..r.len];
    }

    pub fn total(r: *const Rects) Box {
        var u = none;
        for (r.items[0..r.len]) |d| u = unite(u, d);
        return u;
    }
};

pub const Differ = struct {
    gpa: std.mem.Allocator,
    /// The last frame is remembered to compare the next with.
    valid: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    scale: f32 = 0,
    clear: types.Color = .{},
    atlas: u64 = 0,
    images: u64 = 0,
    /// The last frame's instances drawn and its rows.
    instances: std.ArrayList(gpu.Instance) = .empty,
    rows: std.ArrayList([4]f32) = .empty,
    /// Where each instance of the last frame drew; `next`, of the frame
    /// `diff` was given.
    bounds: std.ArrayList(Box) = .empty,
    next: std.ArrayList(Box) = .empty,
    damage: Rects = .{},

    pub fn init(gpa: std.mem.Allocator) Differ {
        return .{ .gpa = gpa };
    }

    pub fn deinit(d: *Differ) void {
        d.instances.deinit(d.gpa);
        d.rows.deinit(d.gpa);
        d.bounds.deinit(d.gpa);
        d.next.deinit(d.gpa);
        d.* = .{ .gpa = d.gpa };
    }

    /// The next frame draws whole.
    pub fn invalidate(d: *Differ) void {
        d.valid = false;
    }

    /// Where `f` differs from the last frame remembered, or null when it
    /// may differ everywhere. Empty: nothing changed.
    pub fn diff(d: *Differ, f: Frame) ?*Rects {
        const fr = gpu.Frame.of(f.instances);
        d.next.resize(d.gpa, fr.instances.len) catch {
            d.valid = false;
            return null;
        };
        for (fr.instances, d.next.items) |*i, *b| b.* = boundsOf(i, fr.rows, f.width, f.height, f.scale);
        if (!d.valid or f.width != d.width or f.height != d.height or f.scale != d.scale or f.atlas != d.atlas or
            !std.meta.eql(f.clear, d.clear)) return null;
        const changed = f.images != d.images;
        const old = d.instances.items;
        const new = fr.instances;
        const n = old.len;
        const m = new.len;
        var pre: usize = 0;
        while (pre < n and pre < m and same(&old[pre], d.rows.items, &new[pre], fr.rows, changed)) pre += 1;
        var suf: usize = 0;
        while (suf < n - pre and suf < m - pre and same(&old[n - 1 - suf], d.rows.items, &new[m - 1 - suf], fr.rows, changed)) suf += 1;
        d.damage = .{};
        if (n == m) {
            for (pre..n - suf) |k| if (!same(&old[k], d.rows.items, &new[k], fr.rows, changed)) {
                addRect(&d.damage, d.bounds.items[k]);
                addRect(&d.damage, d.next.items[k]);
            };
        } else {
            for (d.bounds.items[pre .. n - suf]) |b| addRect(&d.damage, b);
            for (d.next.items[pre .. m - suf]) |b| addRect(&d.damage, b);
        }
        return &d.damage;
    }

    /// Keeps what `diff` needs of `f`, which it was given last and which
    /// was drawn, to compare the next frame with.
    pub fn remember(d: *Differ, f: Frame) void {
        const fr = gpu.Frame.of(f.instances);
        d.instances.clearRetainingCapacity();
        d.rows.clearRetainingCapacity();
        d.instances.appendSlice(d.gpa, fr.instances) catch return d.invalidate();
        d.rows.appendSlice(d.gpa, fr.rows) catch return d.invalidate();
        std.mem.swap(std.ArrayList(Box), &d.bounds, &d.next);
        d.valid = d.bounds.items.len == fr.instances.len;
        d.width = f.width;
        d.height = f.height;
        d.scale = f.scale;
        d.clear = f.clear;
        d.atlas = f.atlas;
        d.images = f.images;
    }

    /// What `f` must draw, given what changed in the target since it was
    /// drawn (`since`, from `diff`, or null for unknown), as rectangles
    /// apart from each other (the CPU draws each), or null for the whole
    /// frame. Empty: nothing.
    pub fn plan(d: *Differ, f: Frame, since: ?*Rects) ?*Rects {
        const r = since orelse return null;
        if (r.len == 0) return r;
        grow(f, d.next.items, r);
        var total: u64 = 0;
        for (r.slice()) |b| total += area(b);
        if (2 * total >= @as(u64, f.width) * f.height) return null;
        return r;
    }

    /// `plan` as one rectangle, for a GPU renderer's scissor; null for the
    /// whole frame, an empty box for nothing.
    pub fn planOne(d: *Differ, f: Frame, since: ?*Rects) ?Box {
        const r = since orelse return null;
        if (r.len == 0) return none;
        // Grown until one box holds all that it meets reads.
        var b = r.total();
        while (true) {
            r.items[0] = b;
            r.len = 1;
            grow(f, d.next.items, r);
            const t = r.total();
            if (std.mem.eql(i32, &t, &b)) break;
            b = t;
        }
        if (2 * area(b) >= @as(u64, f.width) * f.height) return null;
        return b;
    }
};

/// The pixels a marker reads: an effect its backdrop, a layer its area.
fn readsOf(i: *const gpu.Instance, rows: []const [4]f32, w: u32, h: u32, scale: f32) ?Box {
    if (i.kind >= 16) return null;
    if (i.kind == gpu.Kind.layer or i.kind == gpu.Kind.layer_end) {
        return usize4(raster_fx.area(w, h, i.rect, i.clip, scale) orelse return null);
    }
    if (i.kind != gpu.Kind.effect) return null;
    const row: usize = @intFromFloat(@max(i.uv[0], 0));
    if (row + effect.rows_per_effect > rows.len) return null;
    const s = scale;
    const b = backdrop.Backdrop.of(.{ i.rect[0] * s, i.rect[1] * s, i.rect[2] * s, i.rect[3] * s }, rows[row][0] * s, w, h);
    const a = raster_fx.area(w, h, i.rect, i.clip, scale) orelse return null;
    return unite(usize4(.{ b.x0, b.y0, b.x1, b.y1 }), usize4(a));
}

/// Grows the rectangles `r` by all an effect or a layer reads that one of
/// them meets, until each reads all of it or none, merging those that
/// overlap: within a rectangle drawn, it then reads none of what the last
/// frame drew (`bounds`: where each instance draws).
pub fn grow(f: Frame, bounds: []const Box, r: *Rects) void {
    const fr = gpu.Frame.of(f.instances);
    var changed = true;
    while (changed) {
        changed = false;
        for (fr.instances, 0..) |*i, k| {
            if (!gpu.isMarker(i.kind)) continue;
            var need = readsOf(i, fr.rows, f.width, f.height, f.scale) orelse continue;
            if (k < bounds.len) need = unite(need, bounds[k]);
            for (r.slice()) |b| if (overlaps(b, need) and !within(need, b)) {
                addRect(r, need);
                changed = true;
                break;
            };
        }
        var a: usize = 0;
        while (a < r.len) : (a += 1) {
            var b = a + 1;
            while (b < r.len) {
                if (overlaps(r.items[a], r.items[b])) {
                    r.items[a] = unite(r.items[a], r.items[b]);
                    r.items[b] = r.items[r.len - 1];
                    r.len -= 1;
                    changed = true;
                    b = a + 1;
                } else b += 1;
            }
        }
    }
}

/// While a frame draws in part, which effects and layers it draws: those
/// whose pixels meet the part (all they read is in it then); the others,
/// outside, are left as they are.
pub const Markers = struct {
    part: ?Box,
    /// Whether each layer open was skipped, innermost lowest.
    skipped: u64 = 0,

    pub fn draws(m: *Markers, i: *const gpu.Instance, w: u32, h: u32, scale: f32) bool {
        const part = m.part orelse return true;
        if (i.kind == gpu.Kind.layer_end) {
            const skip = m.skipped & 1 != 0;
            m.skipped >>= 1;
            return !skip;
        }
        const meets = if (raster_fx.area(w, h, i.rect, i.clip, scale)) |a| overlaps(usize4(a), part) else false;
        if (i.kind == gpu.Kind.layer) m.skipped = m.skipped << 1 | @intFromBool(!meets);
        return meets or i.kind >= 16;
    }
};

/// An opaque quad of the frame's color over `part`, which a GPU renderer
/// draws first, scissored to it, in place of clearing: the same pixels.
pub fn clearQuad(part: Box, scale: f32, clear: types.Color) gpu.Instance {
    const inv = 1 / scale;
    return .{
        .rect = .{ @as(f32, @floatFromInt(part[0] - 4)) * inv, @as(f32, @floatFromInt(part[1] - 4)) * inv, @as(f32, @floatFromInt(part[2] - part[0] + 8)) * inv, @as(f32, @floatFromInt(part[3] - part[1] + 8)) * inv },
        .color = .{ clear.r, clear.g, clear.b, 1 },
    };
}

/// What changed in a window's frames since each buffer of its swap chain
/// was drawn, by the buffer's identity (a CAMetalLayer's drawable's
/// texture): a buffer handed out again holds the frame drawn into it some
/// frames ago, as EGL's buffer age tells.
pub const Ages = struct {
    pub const max = 4;
    const Age = struct { id: usize = 0, changed: Box = none, whole: bool = false, used: u64 = 0 };
    bufs: [max]Age = @splat(.{}),
    n: usize = 0,
    frame: u64 = 0,

    /// Notes a frame drawn, which changed `changed` of the last (null:
    /// everything).
    pub fn add(a: *Ages, changed: ?Box) void {
        a.frame += 1;
        for (a.bufs[0..a.n]) |*b| {
            if (changed) |c| b.changed = unite(b.changed, c) else b.whole = true;
        }
    }

    /// What changed since buffer `id` was drawn, which the frame now draws
    /// into, or null when unknown (a buffer not seen). `forgot` is set to
    /// a buffer no longer tracked, which a caller holding it lets go.
    pub fn take(a: *Ages, id: usize, forgot: *?usize) ?Box {
        forgot.* = null;
        for (a.bufs[0..a.n]) |*b| if (b.id == id) {
            const c = b.changed;
            const whole = b.whole;
            b.* = .{ .id = id, .used = a.frame };
            return if (whole) null else c;
        };
        var k = a.n;
        if (a.n == max) {
            k = 0;
            for (a.bufs, 0..) |b, j| if (b.used < a.bufs[k].used) {
                k = j;
            };
            forgot.* = a.bufs[k].id;
        } else a.n += 1;
        a.bufs[k] = .{ .id = id, .used = a.frame };
        return null;
    }

    pub fn has(a: *const Ages, id: usize) bool {
        for (a.bufs[0..a.n]) |b| if (b.id == id) return true;
        return false;
    }

    /// Forgets every buffer (the caller lets go of those it holds).
    pub fn reset(a: *Ages) void {
        a.* = .{ .frame = a.frame };
    }
};

pub const Pixels = gpu.Pixels;

/// Draws frame `f` on the CPU into `out`, which holds the last frame `d`
/// remembered (or anything, when `d` forgot it): only where it changed,
/// in rectangles apart from each other, unless `whole`. Returns them (null:
/// drawn whole; empty: nothing changed).
pub fn drawCpu(d: *Differ, out: Pixels, f: Frame, mask: raster.Mask, pictures: raster.Pictures, whole: bool) ?*Rects {
    const since = if (!whole and enabled()) d.diff(f) else blk: {
        _ = d.diff(f);
        break :blk null;
    };
    const plan = d.plan(f, since);
    if (plan) |rects| {
        for (rects.slice()) |p| raster.drawPart(out, f.instances, mask, pictures, f.scale, f.clear, .{ @intCast(p[0]), @intCast(p[1]), @intCast(p[2]), @intCast(p[3]) });
    } else raster.draw(out, f.instances, mask, pictures, f.scale, f.clear);
    d.remember(f);
    return plan;
}
