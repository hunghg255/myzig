//! The Metal renderer: one pipeline, one instanced draw per frame, into a
//! CAMetalLayer the native view hosts.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const types = @import("types.zig");

const shader_source = @import("shader_min.zig").minify(@embedFile("shader.metal"));

const gpu = @import("gpu.zig");
const fx_mod = @import("metal_fx.zig");
const damage = @import("damage.zig");
const present_mod = @import("metal_present.zig");
pub const Instance = gpu.Instance;
pub const Kind = gpu.Kind;
pub const color4 = gpu.color4;
pub const clip4 = gpu.clip4;
pub const Pixels = gpu.Pixels;

pub const Renderer = struct {
    /// The image atlas on the GPU, copied when its generation changes.
    images_texture: ?objc.Object = null,
    images_side: u32 = 0,
    images_generation: u64 = std.math.maxInt(u64),
    device: objc.Object,
    queue: objc.Object,
    pipeline: objc.Object,
    layer: objc.Object,
    live_resize: bool = false,
    /// Instances go into one of three buffers, reused once the GPU is done
    /// with the frame that last used it.
    buffers: [frames_in_flight]?objc.Object = @splat(null),
    capacities: [frames_in_flight]usize = @splat(0),
    next_buffer: usize = 0,
    in_flight: objc.dispatch_semaphore_t,
    /// Pixels a point, as last resized (or a target was made).
    scale: f32 = 2,
    /// The layer's drawables are only drawn into until a frame has effects
    /// or blurred layers, whose passes copy from them.
    framebuffer_only: bool = true,
    /// The passes of effects and blurred layers, made when first needed.
    fx: fx_mod.Passes = .{},
    /// Frames draw only what changed since their drawable was drawn
    /// (`damage.zig`): Core Animation hands the layer's drawables out in
    /// turn, each holding the frame drawn into it last; `ages` keeps, by
    /// the drawable's texture (retained, so that no other takes its
    /// address), what changed since.
    differ: damage.Differ = .init(std.heap.page_allocator),
    ages: damage.Ages = .{},
    /// A frame's instances with its large shadows with continuous corners
    /// cut into pieces (`gpu_corners.zig`).
    pieces: std.ArrayList(Instance) = .empty,
    /// Fetches the next frame's drawable off the main thread after each
    /// frame presented as soon as drawn (`metal_present.zig`), made on
    /// the first; `wake` (the surface's) draws a frame that waited for it.
    present: ?*present_mod.Presenter = null,
    wake: ?present_mod.Wake = null,

    pub fn init() !Renderer {
        const pool = objc.Pool.push();
        defer pool.pop();
        const device = cf.MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;
        errdefer objc.release(device);
        const queue = objc.msg(objc.Object, device, "newCommandQueue", .{});
        errdefer objc.release(queue);

        var err: ?objc.Object = null;
        const library = objc.msg(?objc.Object, device, "newLibraryWithSource:options:error:", .{
            objc.nsString(shader_source), @as(?objc.Object, null), &err,
        }) orelse {
            const desc = objc.msg(objc.Object, err.?, "localizedDescription", .{});
            std.log.err("myzig: shader: {s}", .{objc.fromNSString(desc)});
            return error.ShaderCompile;
        };
        defer objc.release(library);
        const vs = objc.msg(objc.Object, library, "newFunctionWithName:", .{objc.nsString("vs")});
        defer objc.release(vs);
        const fs = objc.msg(objc.Object, library, "newFunctionWithName:", .{objc.nsString("fs")});
        defer objc.release(fs);

        const desc = objc.new("MTLRenderPipelineDescriptor");
        defer objc.release(desc);
        objc.msg(void, desc, "setVertexFunction:", .{vs});
        objc.msg(void, desc, "setFragmentFunction:", .{fs});
        const attachments = objc.msg(objc.Object, desc, "colorAttachments", .{});
        const ca = objc.msg(objc.Object, attachments, "objectAtIndexedSubscript:", .{@as(objc.NSUInteger, 0)});
        objc.msg(void, ca, "setPixelFormat:", .{pixel_format});
        objc.msg(void, ca, "setBlendingEnabled:", .{objc.YES});
        // Premultiplied alpha: one, one minus source alpha.
        objc.msg(void, ca, "setSourceRGBBlendFactor:", .{@as(objc.NSUInteger, 1)});
        objc.msg(void, ca, "setSourceAlphaBlendFactor:", .{@as(objc.NSUInteger, 1)});
        objc.msg(void, ca, "setDestinationRGBBlendFactor:", .{@as(objc.NSUInteger, 5)});
        objc.msg(void, ca, "setDestinationAlphaBlendFactor:", .{@as(objc.NSUInteger, 5)});
        const pipeline = objc.msg(?objc.Object, device, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err }) orelse
            return error.PipelineCreate;

        const layer = objc.new("CAMetalLayer");
        objc.msg(void, layer, "setDevice:", .{device});
        objc.msg(void, layer, "setPixelFormat:", .{pixel_format});
        objc.msg(void, layer, "setFramebufferOnly:", .{objc.YES});
        // Two drawables: a frame takes the GPU well under a millisecond, and
        // frames are drawn on demand, so a third would only hold memory
        // (a window-sized buffer, 13 MB for a large window).
        objc.msg(void, layer, "setMaximumDrawableCount:", .{@as(objc.NSUInteger, 2)});
        objc.msg(void, layer, "setOpaque:", .{objc.YES});
        // Colors are sRGB, as in CSS: tag them so the display matches them.
        if (cf.CGColorSpaceCreateWithName(cf.kCGColorSpaceSRGB)) |srgb| {
            defer cf.CGColorSpaceRelease(srgb);
            objc.msg(void, layer, "setColorspace:", .{srgb});
        }
        return .{ .device = device, .queue = queue, .pipeline = pipeline, .layer = layer, .in_flight = objc.dispatch_semaphore_create(frames_in_flight) };
    }

    /// Puts a packed picture straight into the GPU's image atlas (the
    /// `Images.Sink` of a window): no copy of the atlas stays in memory.
    pub fn uploadImage(ctx: *anyopaque, side: u32, x: u32, y: u32, w: u32, h: u32, bgra: []const u8) void {
        const self: *Renderer = @ptrCast(@alignCast(ctx));
        const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
        if (side != self.images_side) {
            self.imagesTexture(side);
            // Cleared, as the atlas in memory starts.
            const zero = std.heap.page_allocator.alloc(u8, @as(usize, side) * side * 4) catch return;
            defer std.heap.page_allocator.free(zero);
            @memset(zero, 0);
            objc.msg(void, self.images_texture.?, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
                Region{ .x = 0, .y = 0, .z = 0, .w = side, .h = side, .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, zero.ptr), @as(objc.NSUInteger, side) * 4,
            });
        }
        if (w == 0 or h == 0) return;
        objc.msg(void, self.images_texture.?, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            Region{ .x = x, .y = y, .z = 0, .w = w, .h = h, .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, bgra.ptr), @as(objc.NSUInteger, w) * 4,
        });
    }

    /// The image atlas made anew, `side` on a side.
    fn imagesTexture(self: *Renderer, side: u32) void {
        if (self.images_texture) |t| objc.release(t);
        const n: objc.NSUInteger = side;
        const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ pixel_format, n, n, objc.NO });
        self.images_texture = objc.msg(objc.Object, self.device, "newTextureWithDescriptor:", .{desc});
        self.images_side = side;
    }

    /// Brings the GPU's copy of the image atlas up to date (made on the
    /// first picture).
    pub fn syncImages(self: *Renderer, im: *Images) void {
        if (im.pixels.len == 0 or im.generation == self.images_generation) return;
        const side: objc.NSUInteger = im.side;
        const new = self.images_texture == null or self.images_side != im.side;
        if (new) self.imagesTexture(im.side);
        const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
        // Only the rows that changed, unless the texture is new.
        const rows: [2]u32 = if (new) .{ 0, im.side } else im.dirty orelse .{ 0, 0 };
        if (rows[1] > rows[0]) objc.msg(void, self.images_texture.?, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            Region{ .x = 0, .y = rows[0], .z = 0, .w = side, .h = rows[1] - rows[0], .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, im.pixels.ptr + @as(usize, rows[0]) * side * 4), side * 4,
        });
        im.dirty = null;
        self.images_generation = im.generation;
    }

    pub fn deinit(self: *Renderer) void {
        if (self.present) |p| p.destroy();
        self.forgetDrawables();
        self.differ.deinit();
        self.pieces.deinit(std.heap.page_allocator);
        self.fx.deinit();
        if (self.images_texture) |t| objc.release(t);
        // Wait for the frames in flight: their handlers signal this renderer.
        for (0..frames_in_flight) |_| _ = objc.dispatch_semaphore_wait(self.in_flight, objc.DISPATCH_TIME_FOREVER);
        for (0..frames_in_flight) |_| _ = objc.dispatch_semaphore_signal(self.in_flight);
        objc.dispatch_release(self.in_flight);
        for (self.buffers) |b| if (b) |buf| objc.release(buf);
        objc.release(self.layer);
        objc.release(self.pipeline);
        objc.release(self.queue);
        objc.release(self.device);
    }

    /// Lets go of the drawables' textures `ages` tracks: the next frames
    /// draw whole.
    fn forgetDrawables(self: *Renderer) void {
        for (self.ages.bufs[0..self.ages.n]) |b| objc.release(@as(objc.Object, @ptrFromInt(b.id)));
        self.ages.reset();
    }

    pub fn resize(self: *Renderer, size: types.Size, scale: f32) void {
        // Drawables of another size are new ones.
        self.settleDrawables();
        self.forgetDrawables();
        self.scale = scale;
        objc.msg(void, self.layer, "setContentsScale:", .{@as(f64, scale)});
        objc.msg(void, self.layer, "setDrawableSize:", .{objc.CGSize{
            .width = @max(1, @round(size.w * scale)),
            .height = @max(1, @round(size.h * scale)),
        }});
    }

    /// Draws `instances` over `clear` into the window, sized `size` points,
    /// whole.
    pub fn draw(self: *Renderer, instances: []const Instance, atlas: objc.Object, size: types.Size, clear: types.Color) void {
        self.differ.invalidate();
        self.drawFrame(instances, atlas, size, clear, 0, 0);
    }

    /// Draws `instances` as `draw` does, only where the frame changed
    /// since the drawable given was drawn; a frame like the last one
    /// draws nothing and takes no drawable. `atlas_key` and `images` are
    /// the atlases' states (`damage.Frame`).
    pub fn drawFrame(self: *Renderer, all: []const Instance, atlas: objc.Object, size: types.Size, clear: types.Color, atlas_key: u64, images: u64) void {
        const instances = self.cut(all, self.scale);
        const pool = objc.Pool.push();
        defer pool.pop();
        const f: damage.Frame = .{
            .instances = instances,
            .width = @intFromFloat(@max(1, @round(size.w * self.scale))),
            .height = @intFromFloat(@max(1, @round(size.h * self.scale))),
            .scale = self.scale,
            .clear = clear,
            .atlas = atlas_key,
            .images = images,
        };
        const since = if (damage.enabled()) self.differ.diff(f) else null;
        if (since) |s| if (s.len == 0 and self.ages.n > 0) return;
        if (self.waitsForDrawable()) return;
        if (self.framebuffer_only and hasMarkers(instances)) {
            self.settleDrawables();
            objc.msg(void, self.layer, "setFramebufferOnly:", .{objc.NO});
            self.framebuffer_only = false;
            self.forgetDrawables();
        }
        _ = objc.dispatch_semaphore_wait(self.in_flight, objc.DISPATCH_TIME_FOREVER);
        const drawable = self.nextDrawable(f) orelse {
            _ = objc.dispatch_semaphore_signal(self.in_flight);
            self.differ.invalidate();
            return;
        };
        const texture = objc.msg(objc.Object, drawable, "texture", .{});
        const part = self.partOf(f, since, texture);
        const buffer = self.upload(instances, if (part) |p| damage.clearQuad(p, self.scale, clear) else null);
        const cmd = self.encode(texture, buffer, instances, atlas, size, self.scale, clear, part);
        self.differ.remember(f);
        var done = objc.Block(Renderer, &.{objc.Object}).init(self, frameDone);
        objc.msg(void, cmd, "addCompletedHandler:", .{@as(*anyopaque, @ptrCast(&done))});
        if (self.live_resize) {
            // In the layer's transaction: a resizing window never shows a
            // stretched or misplaced frame.
            objc.msg(void, cmd, "commit", .{});
            objc.msg(void, cmd, "waitUntilScheduled", .{});
            objc.msg(void, drawable, "present", .{});
        } else {
            objc.msg(void, cmd, "presentDrawable:", .{drawable});
            objc.msg(void, cmd, "commit", .{});
            // The next frame's drawable, while this one shows.
            self.prefetch();
        }
    }

    /// Has the main thread draw a frame that waited for its drawable
    /// (`wake`, on the main thread). Without one, frames wait for their
    /// drawable on the main thread.
    pub fn setWake(self: *Renderer, wake: present_mod.Wake) void {
        self.wake = wake;
        if (self.present) |p| p.wake = wake;
    }

    /// Whether a frame can take a drawable at once; otherwise `wake` runs
    /// once the one being fetched came: frames paced by the display wait
    /// for it rather than being built ahead.
    pub fn ready(self: *Renderer) bool {
        return !self.waitsForDrawable();
    }

    /// A drawable is being fetched (not for the transaction's frames):
    /// the frame is drawn once it came, through `wake`.
    fn waitsForDrawable(self: *Renderer) bool {
        if (self.live_resize or self.wake == null) return false;
        const p = self.present orelse return false;
        return p.waitFor();
    }

    /// The drawable of `f`: the one fetched after the last frame, if it
    /// has the layer's size, else the layer's next, waited for here.
    fn nextDrawable(self: *Renderer, f: damage.Frame) ?objc.Object {
        if (self.present) |p| {
            if (self.live_resize) {
                // Presented with the transaction: its own drawable.
                p.drain();
            } else if (p.take()) |ptr| {
                const d: objc.Object = @ptrCast(ptr);
                const tex = objc.msg(objc.Object, d, "texture", .{});
                const fits = objc.msg(objc.NSUInteger, tex, "width", .{}) == f.width and objc.msg(objc.NSUInteger, tex, "height", .{}) == f.height;
                objc.autorelease(d);
                if (fits) return d;
            }
        }
        return objc.msg(?objc.Object, self.layer, "nextDrawable", .{});
    }

    /// Starts fetching the next frame's drawable.
    fn prefetch(self: *Renderer) void {
        if (self.present == null) {
            const p = present_mod.create(@ptrCast(self.layer)) catch return;
            p.wake = self.wake;
            self.present = p;
        }
        self.present.?.start();
    }

    /// Waits for a drawable being fetched and lets it go: before the
    /// layer changes.
    fn settleDrawables(self: *Renderer) void {
        if (self.present) |p| p.drain();
    }

    fn frameDone(self: *Renderer, _: objc.Object) void {
        _ = objc.dispatch_semaphore_signal(self.in_flight);
    }

    /// The part of frame `f` to draw into the drawable's `texture`: what
    /// changed since the texture was drawn, grown by what effects read;
    /// null to draw it whole (a drawable not seen yet, too much changed).
    fn partOf(self: *Renderer, f: damage.Frame, since: ?*damage.Rects, texture: objc.Object) ?damage.Box {
        const id = @intFromPtr(texture);
        const known = self.ages.has(id);
        self.ages.add(if (since) |s| s.total() else null);
        var forgot: ?usize = null;
        const age = self.ages.take(id, &forgot);
        if (forgot) |old| objc.release(@as(objc.Object, @ptrFromInt(old)));
        if (!known) _ = objc.retain(texture);
        var rects: damage.Rects = .{};
        const changed = age orelse return null;
        if (since == null) return null;
        rects.items[0] = changed;
        rects.len = 1;
        const p = self.differ.planOne(f, &rects) orelse return null;
        // Nothing changed since this drawable was drawn: it presents as it
        // is, a pixel drawn again.
        return if (damage.empty(p)) .{ 0, 0, 1, 1 } else p;
    }

    /// Copies `instances`, and `extra` after them, into the next buffer of
    /// the ring, grown as needed.
    fn upload(self: *Renderer, instances: []const Instance, extra: ?Instance) ?objc.Object {
        if (instances.len == 0 and extra == null) return null;
        const i = self.next_buffer;
        self.next_buffer = (i + 1) % frames_in_flight;
        const bytes = std.mem.sliceAsBytes(instances);
        const need = bytes.len + @as(usize, if (extra != null) @sizeOf(Instance) else 0);
        if (self.capacities[i] < need) {
            if (self.buffers[i]) |old| objc.release(old);
            const cap = @max(need * 3 / 2, 64 * 1024);
            self.buffers[i] = objc.msg(objc.Object, self.device, "newBufferWithLength:options:", .{ @as(objc.NSUInteger, cap), @as(objc.NSUInteger, 0) });
            self.capacities[i] = cap;
        }
        const buf = self.buffers[i].?;
        const dst: [*]u8 = @ptrCast(objc.msg(*anyopaque, buf, "contents", .{}));
        @memcpy(dst[0..bytes.len], bytes);
        if (extra) |e| @memcpy(dst[bytes.len..][0..@sizeOf(Instance)], std.mem.asBytes(&e));
        return buf;
    }

    pub fn setLiveResize(self: *Renderer, on: bool) void {
        self.settleDrawables();
        self.live_resize = on;
        objc.msg(void, self.layer, "setPresentsWithTransaction:", .{on});
    }

    /// A render target of `size` points at `scale`, kept by the caller
    /// across frames (release it): for benchmarks drawing without a window.
    pub fn newTarget(self: *Renderer, size: types.Size, scale: f32) objc.Object {
        self.scale = scale;
        const w: usize = @intFromFloat(@max(1, @round(size.w * scale)));
        const h: usize = @intFromFloat(@max(1, @round(size.h * scale)));
        const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            pixel_format, w, h, objc.NO,
        });
        objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1 | 4)}); // shader read, render target
        objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 2)}); // private: GPU only, as a drawable
        return objc.msg(objc.Object, self.device, "newTextureWithDescriptor:", .{desc});
    }

    pub const Timing = struct {
        /// CPU time to upload the instances and encode the frame.
        encode_ms: f64,
        /// GPU time of the frame, from the command buffer's timestamps.
        gpu_ms: f64,
    };

    /// Draws a frame into `target` as a window's frame is drawn (the ring
    /// of instance buffers, one command buffer), waits for it, and times it.
    pub fn drawTimed(self: *Renderer, target: objc.Object, all: []const Instance, atlas: objc.Object, size: types.Size, clear: types.Color) Timing {
        const instances = self.cut(all, self.scale);
        const pool = objc.Pool.push();
        defer pool.pop();
        _ = objc.dispatch_semaphore_wait(self.in_flight, objc.DISPATCH_TIME_FOREVER);
        defer _ = objc.dispatch_semaphore_signal(self.in_flight);
        const t0 = cf.CACurrentMediaTime();
        const buffer = self.upload(instances, null);
        const cmd = self.encode(target, buffer, instances, atlas, size, self.scale, clear, null);
        objc.msg(void, cmd, "commit", .{});
        const t1 = cf.CACurrentMediaTime();
        objc.msg(void, cmd, "waitUntilCompleted", .{});
        const gpu_s = objc.msg(f64, cmd, "GPUEndTime", .{}) - objc.msg(f64, cmd, "GPUStartTime", .{});
        return .{ .encode_ms = (t1 - t0) * 1000, .gpu_ms = gpu_s * 1000 };
    }

    /// Draws into a new offscreen texture and returns its BGRA pixels,
    /// premultiplied, `width * 4` bytes per row: frames without a window.
    pub fn drawOffscreen(self: *Renderer, gpa: std.mem.Allocator, all: []const Instance, atlas: objc.Object, size: types.Size, scale: f32, clear: types.Color) !Pixels {
        const instances = self.cut(all, scale);
        const pool = objc.Pool.push();
        defer pool.pop();
        const w: usize = @intFromFloat(@max(1, @round(size.w * scale)));
        const h: usize = @intFromFloat(@max(1, @round(size.h * scale)));
        const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            pixel_format, w, h, objc.NO,
        });
        objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1 | 4)}); // shader read, render target
        objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 0)}); // shared
        const texture = objc.msg(objc.Object, self.device, "newTextureWithDescriptor:", .{desc});
        defer objc.release(texture);
        const src = std.mem.sliceAsBytes(instances);
        const buffer: ?objc.Object = if (instances.len == 0) null else objc.msg(objc.Object, self.device, "newBufferWithBytes:length:options:", .{
            @as(*const anyopaque, src.ptr), @as(objc.NSUInteger, src.len), @as(objc.NSUInteger, 0),
        });
        defer if (buffer) |b| objc.release(b);
        const cmd = self.encode(texture, buffer, instances, atlas, size, scale, clear, null);
        objc.msg(void, cmd, "commit", .{});
        objc.msg(void, cmd, "waitUntilCompleted", .{});
        const bytes = try gpa.alloc(u8, w * h * 4);
        const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
        objc.msg(void, texture, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{
            @as(*anyopaque, bytes.ptr), w * 4, Region{ .x = 0, .y = 0, .z = 0, .w = w, .h = h, .d = 1 }, @as(objc.NSUInteger, 0),
        });
        return .{ .bytes = bytes, .width = w, .height = h };
    }

    /// The frame's instances with its large shadows with continuous
    /// corners cut into pieces (`gpu_corners.zig`).
    fn cut(self: *Renderer, all: []const Instance, scale: f32) []const Instance {
        return @import("gpu_corners.zig").split(std.heap.page_allocator, all, scale, &self.pieces);
    }

    /// Draws a frame into `texture`, in parts around the marks of effects
    /// and layers, which `metal_fx.zig` draws between them. Drawn in
    /// `part`, the passes load what the texture holds, are scissored to
    /// the part, cleared there first by an opaque quad of the frame's color
    /// (`damage.clearQuad`, after the instances in the buffer), and draw
    /// only the effects and layers in it.
    fn encode(self: *Renderer, texture: objc.Object, instance_buffer: ?objc.Object, instances: []const Instance, atlas: objc.Object, size: types.Size, scale: f32, clear: types.Color, part: ?damage.Box) objc.Object {
        const fr = gpu.Frame.of(instances);
        const cmd = objc.msg(objc.Object, self.queue, "commandBuffer", .{});
        var enc = beginPass(cmd, texture, if (part == null) clear else null);
        if (instance_buffer) |buffer| if (fr.instances.len > 0 or part != null) {
            const frame: [4]f32 = .{ size.w, size.h, scale, 0 };
            const rows_at: objc.NSUInteger = if (fr.rows.len > 0) fr.first_row_instance * @sizeOf(Instance) else 0;
            self.bind(enc, buffer, &frame, rows_at, atlas);
            setScissor(enc, part);
            if (part != null) drawRange(enc, instances.len, instances.len + 1);
            var markers: damage.Markers = .{ .part = part };
            const f: fx_mod.Frame = .{
                .cmd = cmd,
                .target = texture,
                .w = @intCast(objc.msg(objc.NSUInteger, texture, "width", .{})),
                .h = @intCast(objc.msg(objc.NSUInteger, texture, "height", .{})),
                .scale = scale,
            };
            var start: usize = 0;
            for (fr.instances, 0..) |*i, k| {
                if (!gpu.isMarker(i.kind)) continue;
                drawRange(enc, start, k);
                start = k + 1;
                if (!markers.draws(i, f.w, f.h, scale)) continue;
                objc.msg(void, enc, "endEncoding", .{});
                self.fx.apply(self.device, f, i, fr.rows);
                enc = beginPass(cmd, texture, null);
                self.bind(enc, buffer, &frame, rows_at, atlas);
                setScissor(enc, part);
            }
            drawRange(enc, start, fr.instances.len);
        };
        objc.msg(void, enc, "endEncoding", .{});
        self.fx.endFrame();
        return cmd;
    }

    fn bind(self: *Renderer, enc: objc.Object, buffer: objc.Object, frame: *const [4]f32, rows_at: objc.NSUInteger, atlas: objc.Object) void {
        objc.msg(void, enc, "setRenderPipelineState:", .{self.pipeline});
        objc.msg(void, enc, "setVertexBuffer:offset:atIndex:", .{ buffer, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 0) });
        objc.msg(void, enc, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, frame), @as(objc.NSUInteger, 16), @as(objc.NSUInteger, 1) });
        objc.msg(void, enc, "setVertexBuffer:offset:atIndex:", .{ buffer, rows_at, @as(objc.NSUInteger, 2) });
        objc.msg(void, enc, "setFragmentBuffer:offset:atIndex:", .{ buffer, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 0) });
        objc.msg(void, enc, "setFragmentBytes:length:atIndex:", .{ @as(*const anyopaque, frame), @as(objc.NSUInteger, 16), @as(objc.NSUInteger, 1) });
        objc.msg(void, enc, "setFragmentBuffer:offset:atIndex:", .{ buffer, rows_at, @as(objc.NSUInteger, 2) });
        objc.msg(void, enc, "setFragmentTexture:atIndex:", .{ atlas, @as(objc.NSUInteger, 0) });
        // Pictures, when there are any; else the atlas stands in (unread).
        objc.msg(void, enc, "setFragmentTexture:atIndex:", .{ self.images_texture orelse atlas, @as(objc.NSUInteger, 1) });
    }
};

/// A render pass into `texture`: cleared to `clear`, or loading what is there.
fn beginPass(cmd: objc.Object, texture: objc.Object, clear: ?types.Color) objc.Object {
    const pass = objc.msg(objc.Object, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
    const ca = objc.msg(objc.Object, objc.msg(objc.Object, pass, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(objc.NSUInteger, 0)});
    objc.msg(void, ca, "setTexture:", .{texture});
    objc.msg(void, ca, "setLoadAction:", .{@as(objc.NSUInteger, if (clear != null) 2 else 1)}); // clear, or load
    objc.msg(void, ca, "setStoreAction:", .{@as(objc.NSUInteger, 1)}); // store
    if (clear) |c| {
        const ClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };
        objc.msg(void, ca, "setClearColor:", .{ClearColor{ .r = c.r, .g = c.g, .b = c.b, .a = 1 }});
    }
    return objc.msg(objc.Object, cmd, "renderCommandEncoderWithDescriptor:", .{pass});
}

/// Keeps the encoder's drawing to `part`, when the frame draws in part.
fn setScissor(enc: objc.Object, part: ?damage.Box) void {
    const p = part orelse return;
    const ScissorRect = extern struct { x: objc.NSUInteger, y: objc.NSUInteger, w: objc.NSUInteger, h: objc.NSUInteger };
    objc.msg(void, enc, "setScissorRect:", .{ScissorRect{ .x = @intCast(p[0]), .y = @intCast(p[1]), .w = @intCast(p[2] - p[0]), .h = @intCast(p[3] - p[1]) }});
}

/// Instances [from, to), four vertices each, as a triangle strip.
fn drawRange(enc: objc.Object, from: usize, to: usize) void {
    if (to <= from) return;
    objc.msg(void, enc, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", .{
        @as(objc.NSUInteger, 4), @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 4), @as(objc.NSUInteger, to - from), @as(objc.NSUInteger, from),
    });
}

fn hasMarkers(instances: []const Instance) bool {
    for (gpu.Frame.of(instances).instances) |i| if (gpu.isMarker(i.kind)) return true;
    return false;
}

const pixel_format: objc.NSUInteger = 80; // BGRA8Unorm
const Images = @import("images.zig").Images;
const frames_in_flight = 2;
