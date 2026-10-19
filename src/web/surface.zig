//! Native UI in a browser: a canvas that shows frames WebGL 2 draws
//! (`ui/webgl.zig`), or, where the browser has none, the very same pixels
//! the CPU renderer draws (a 2D canvas shows them), at the device pixel
//! ratio. The host's events (`exports.zig`) feed it the pointer, the wheel,
//! keys and an input method's text; frames are built on input and drawn
//! in the browser's next animation frame, again while something animates.
//! Idle, nothing runs: no frame is asked for.
const std = @import("std");
const js = @import("js.zig");
const ui = @import("../ui/ui.zig");
const types = @import("../ui/types.zig");
const gpu = @import("../ui/gpu.zig");
const webgl = @import("../ui/webgl.zig");
const damage = @import("../ui/damage.zig");
const text = @import("../ui/text.zig");
const frame_mod = @import("../ui/frame.zig");
const ctx_mod = @import("../ui/context.zig");
const clock = @import("../ui/clock.zig");
const Theme = @import("../ui/theme.zig").Theme;
const Context = ctx_mod.Context;
const Window = @import("window.zig").Window;

pub const Surface = struct {
    gpa: std.mem.Allocator,
    window: *Window,
    text: text.TextSystem,
    ctx: Context,
    view: ui.View,
    instances: std.ArrayList(gpu.Instance) = .empty,
    /// WebGL 2 on the canvas, made with the first frame shown; null where
    /// the browser has none, and frames are drawn on the CPU.
    gl: ?webgl.Renderer = null,
    gl_tried: bool = false,
    pixels: []u8 = &.{},
    pixel_w: usize = 0,
    pixel_h: usize = 0,
    /// What changed since the pixels were drawn on the CPU (`damage.zig`).
    cpu_damage: ?damage.Differ = null,
    /// Instances changed since they were drawn.
    stale: bool = true,
    /// A frame is to be built in the next animation frame (requested from
    /// outside the view, animating, or a hot box that changed).
    wanted: bool = false,
    /// An animation frame is asked for and has not run yet.
    frame_asked: bool = false,
    size: types.Size = .{},
    scale: f32 = 1,
    last_frame_time: f64 = 0,
    start_time: f64,
    /// A frame asked for later (`Context.frame_in`) is pending.
    later: bool = false,
    theme_override: ?Theme = null,
    cursor: ctx_mod.Cursor = .arrow,
    focused: bool = false,
    /// The text area's place, as last sent to the host.
    area: [4]f32 = .{ -1, -1, -1, -1 },
    area_focused: bool = false,

    pub fn create(window: *Window, view: ui.View, theme_override: ?Theme) !*Surface {
        const gpa = window.app.gpa;
        const self = try gpa.create(Surface);
        self.* = .{ .gpa = gpa, .window = window, .text = .init(gpa), .ctx = undefined, .view = view, .theme_override = theme_override, .start_time = clock.now() };
        self.ctx = .init(gpa, &self.text);
        return self;
    }

    pub fn destroy(self: *Surface) void {
        if (self.cpu_damage) |*d| d.deinit();
        if (self.gl) |*g| g.differ.deinit();
        self.instances.deinit(self.gpa);
        self.gpa.free(self.pixels);
        self.ctx.deinit();
        self.text.deinit();
        self.gpa.destroy(self);
    }

    fn id(self: *Surface) u32 {
        return self.window.id();
    }

    fn theme(self: *Surface) Theme {
        if (self.theme_override) |t| return t;
        return if (self.window.app.dark) Theme.dark_theme else Theme.light;
    }

    /// Builds, lays out and paints a frame; the next animation frame draws it.
    pub fn frame(self: *Surface) void {
        if (self.size.w <= 0 or self.size.h <= 0) return;
        const c = &self.ctx;
        const now = clock.now();
        const dt: f32 = if (self.last_frame_time > 0) @floatCast(@min(now - self.last_frame_time, 0.1)) else 1.0 / 60.0;
        self.last_frame_time = now;
        const r = frame_mod.run(c, self.view, &self.text, &self.instances, self.size, self.scale, self.theme(), dt, now - self.start_time);
        self.stale = true;
        self.updateCursor();
        self.updateTextArea();
        self.wanted = c.animating or r.hot_changed;
        self.ask();
        // Something changes now and then: one frame, that much later.
        if (!self.wanted and !self.later) if (c.frame_in) |s| {
            self.later = true;
            self.window.app.later(@max(1, s * 1000), self);
        };
        if (!c.animating) self.last_frame_time = 0;
    }

    /// The timer of `Context.frame_in` ran.
    pub fn onLater(self: *Surface) void {
        self.later = false;
        self.frame();
    }

    fn ask(self: *Surface) void {
        if (self.frame_asked) return;
        self.frame_asked = true;
        js.request_frame(self.id());
    }

    /// A frame soon, for changes from outside the view.
    pub fn requestFrame(self: *Surface) void {
        self.wanted = true;
        self.ask();
    }

    /// The browser's animation frame: builds the frame wanted, draws what
    /// changed. True when another one is wanted (an animation runs).
    pub fn animationFrame(self: *Surface) bool {
        self.frame_asked = false;
        if (self.wanted) self.frame();
        if (self.stale) self.render();
        return self.frame_asked;
    }

    fn pixelSize(self: *Surface) [2]usize {
        return .{ @intFromFloat(@max(1, @round(self.size.w * self.scale))), @intFromFloat(@max(1, @round(self.size.h * self.scale))) };
    }

    fn glRenderer(self: *Surface) ?*webgl.Renderer {
        if (!self.gl_tried) {
            self.gl_tried = true;
            self.gl = webgl.Renderer.init(self.id()) catch null;
            if (self.gl == null) std.log.info("myzig: no WebGL 2: frames are drawn on the CPU", .{});
        }
        return if (self.gl) |*g| g else null;
    }

    /// The WebGL context was lost and restored: its textures are gone.
    pub fn contextRestored(self: *Surface) void {
        if (self.gl) |*g| g.reset();
        self.stale = true;
        self.ask();
    }

    fn frameOf(self: *Surface, px: [2]usize) damage.Frame {
        return .{
            .instances = self.instances.items,
            .width = @intCast(px[0]),
            .height = @intCast(px[1]),
            .scale = self.scale,
            .clear = self.ctx.theme.background,
            .atlas = damage.atlasKey(&self.text.atlas),
            .images = self.text.images.generation,
        };
    }

    /// Draws the frame's instances to the canvas: only what changed.
    pub fn render(self: *Surface) void {
        if (self.size.w <= 0 or self.size.h <= 0) return;
        const px = self.pixelSize();
        self.stale = false;
        if (self.glRenderer()) |g| {
            g.syncAtlas(self.text.atlas.mask(), self.text.atlas.generation);
            g.syncImages(&self.text.images);
            _ = g.render(self.frameOf(px));
            return;
        }
        const pixels = self.cpuPixels() orelse return;
        js.blit(self.id(), pixels.ptr, @intCast(self.pixel_w), @intCast(self.pixel_h));
    }

    /// The frame drawn on the CPU, as `raster.zig` draws it (and as WebGL
    /// should): the fallback, and what tests compare WebGL's pixels with.
    pub fn cpuPixels(self: *Surface) ?[]u8 {
        const px = self.pixelSize();
        if (px[0] != self.pixel_w or px[1] != self.pixel_h) {
            const bytes = self.gpa.alloc(u8, px[0] * px[1] * 4) catch return null;
            self.gpa.free(self.pixels);
            self.pixels = bytes;
            self.pixel_w = px[0];
            self.pixel_h = px[1];
            if (self.cpu_damage) |*d| d.invalidate();
        }
        if (self.cpu_damage == null) self.cpu_damage = .init(self.gpa);
        const d = &self.cpu_damage.?;
        const out: gpu.Pixels = .{ .bytes = self.pixels, .width = self.pixel_w, .height = self.pixel_h };
        const f = self.frameOf(px);
        _ = damage.drawCpu(d, out, f, self.text.atlas.mask(), self.text.images.pictures(), false);
        return self.pixels;
    }

    pub fn resize(self: *Surface, w: f32, h: f32, scale: f32) void {
        if (w == self.size.w and h == self.size.h and scale == self.scale) return;
        self.size = .{ .w = w, .h = h };
        if (scale != self.scale) {
            self.scale = scale;
            self.text.setScale(scale);
        }
        self.frame();
    }

    fn updateCursor(self: *Surface) void {
        const want = self.ctx.cursor orelse if (self.ctx.cursor_text) ctx_mod.Cursor.text else if (self.ctx.cursor_hand) ctx_mod.Cursor.hand else ctx_mod.Cursor.arrow;
        if (want == self.cursor) return;
        self.cursor = want;
        js.set_cursor(self.id(), @intFromEnum(want));
    }

    /// Moves the host's text area to the caret, where an input method
    /// shows its candidates.
    fn updateTextArea(self: *Surface) void {
        const f = self.ctx.focused_text;
        const r: types.Rect = if (f) |t| t.caret_rect else .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const area: [4]f32 = .{ r.x, r.y, r.w, r.h };
        if (std.mem.eql(f32, &area, &self.area) and self.area_focused == (f != null)) return;
        self.area = area;
        self.area_focused = f != null;
        js.text_area(self.id(), r.x, r.y, r.w, r.h, f != null);
    }
};
