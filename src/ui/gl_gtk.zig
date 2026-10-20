//! Native UI's frames on the GPU on Linux: the surface's widget is a
//! GtkGLArea (GTK 3.16 and later) whose context the OpenGL renderer
//! (`gl.zig`) draws into in its render signal, at the frame clock's pace
//! (vsync), at the area's size. Where GL is unavailable the surface keeps a
//! GtkDrawingArea and cairo (`linux/surface.zig`); where the area has no
//! context it draws with cairo as one; where the renderer fails, the
//! frames drawn on the CPU are shown through the area's framebuffer.
//!
//! `MYZIG_GPU=0` keeps frames on the CPU, `MYZIG_GPU=1` draws them with
//! OpenGL even where it would draw on the CPU itself (Mesa's llvmpipe,
//! which is slower than myzig's CPU renderer, on machines without a GPU).
const std = @import("std");
const gl = @import("gl.zig");
const raster = @import("raster.zig");
const types = @import("types.zig");
const text_mod = @import("text.zig");
const damage = @import("damage.zig");

const Widget = anyopaque;

const Api = struct {
    gtk_gl_area_new: *const fn () callconv(.c) *Widget,
    gtk_gl_area_set_required_version: *const fn (area: *Widget, major: c_int, minor: c_int) callconv(.c) void,
    gtk_gl_area_set_has_alpha: *const fn (area: *Widget, alpha: c_int) callconv(.c) void,
    gtk_gl_area_get_error: *const fn (area: *Widget) callconv(.c) ?*anyopaque,
    gtk_gl_area_make_current: *const fn (area: *Widget) callconv(.c) void,
    gtk_widget_get_realized: *const fn (w: *Widget) callconv(.c) c_int,
    g_signal_handlers_disconnect_matched: *const fn (instance: *anyopaque, mask: c_uint, id: c_uint, detail: u32, closure: ?*anyopaque, func: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_uint,
};

var api: Api = undefined;
var state: enum { unknown, loaded, missing } = .unknown;

fn load() bool {
    if (state == .unknown) state = blk: {
        const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .GLOBAL = true }) orelse break :blk .missing;
        inline for (@typeInfo(Api).@"struct".field_names) |name| {
            @field(api, name) = @ptrCast(@alignCast(std.c.dlsym(lib, name) orelse break :blk .missing));
        }
        break :blk .loaded;
    };
    return state == .loaded;
}

/// A GtkGLArea asking for OpenGL 3.3, for a surface that draws with the
/// GPU; null when frames stay on the CPU (no GtkGLArea, `MYZIG_GPU=0`, or
/// no GPU to draw on).
pub fn newArea() ?*Widget {
    if (!wanted() or !load()) return null;
    const area = api.gtk_gl_area_new();
    api.gtk_gl_area_set_required_version(area, 3, 3);
    // Its buffer keeps alpha: frames are opaque, but a blurred layer is
    // drawn on its cleared, transparent area before it goes over what was
    // there (`gl_fx.zig`).
    api.gtk_gl_area_set_has_alpha(area, 1);
    return area;
}

/// Whether the GtkGLArea has its context (once realized): it draws in its
/// render signal then, and with cairo otherwise.
pub fn hasContext(area: *Widget) bool {
    return api.gtk_gl_area_get_error(area) == null;
}

/// Disconnects the handlers of `instance` that were given `data`: a
/// surface freed before its widget goes.
pub fn disconnect(instance: *anyopaque, data: *anyopaque) void {
    if (load()) _ = api.g_signal_handlers_disconnect_matched(instance, 1 << 4, 0, 0, null, null, data);
}

fn wanted() bool {
    if (std.c.getenv("MYZIG_GPU")) |v| {
        if (v[0] == '0') return false;
        if (v[0] == '1') return true;
    }
    return gpuDevice();
}

/// DRM drivers that only show what the CPU drew (virtual machines', servers').
const display_only = [_][]const u8{ "simpledrm", "simple-framebuffer", "bochs", "bochs-drm", "cirrus", "cirrus-qemu", "vboxvideo", "hyperv_drm", "ast", "mgag200", "udl", "vkms" };

/// Whether the machine has a device OpenGL draws on: NVIDIA's, or a render
/// node of a DRM driver with 3D. Elsewhere Mesa draws on the CPU, slower
/// than myzig does.
fn gpuDevice() bool {
    if (std.c.access("/dev/nvidia0", 0) == 0) return true;
    var path: [64]u8 = undefined;
    for (128..136) |n| {
        const p = std.fmt.bufPrint(&path, "/sys/class/drm/renderD{d}/device/driver\x00", .{n}) catch continue;
        var link: [256]u8 = undefined;
        const len = std.c.readlink(@ptrCast(p.ptr), &link, link.len);
        if (len <= 0) continue;
        const driver = std.fs.path.basenamePosix(link[0..@intCast(len)]);
        for (display_only) |d| {
            if (std.mem.eql(u8, d, driver)) break;
        } else return true;
    }
    // WSL's GPU, when Mesa is told to draw on it.
    if (std.c.access("/dev/dxg", 0) == 0) if (std.c.getenv("GALLIUM_DRIVER")) |g| return std.mem.eql(u8, std.mem.span(g), "d3d12");
    return false;
}

/// What a surface keeps for drawing in its GtkGLArea: the renderer of the
/// area's context, made with the first frame.
pub const Gpu = struct {
    renderer: ?gl.Renderer = null,
    /// The renderer could not be made, or failed: frames come from the CPU.
    failed: bool = false,
    presenter: gl.Presenter = .{},
    /// Frames draw only what changed since the last (`damage.zig`): GTK
    /// keeps the area's framebuffer from render to render, but makes its
    /// buffers anew, holding nothing defined, whenever it allocates the
    /// area, at the same size too (`invalidate`). `held` tells that the
    /// framebuffer holds the last frame drawn.
    differ: ?damage.Differ = null,
    held: bool = false,

    /// The area was allocated: the next frame draws whole.
    pub fn invalidate(self: *Gpu) void {
        self.held = false;
    }

    /// Draws a frame into the area's framebuffer (bound by GTK for its
    /// render signal), `w` × `h` pixels; false when the renderer can't, and
    /// the caller shows the frame drawn on the CPU (`present`).
    pub fn render(self: *Gpu, gpa: std.mem.Allocator, text: *text_mod.TextSystem, instances: []const gl.Instance, scale: f32, w: u32, h: u32, clear: types.Color) bool {
        if (self.failed) return false;
        if (self.renderer == null) {
            self.renderer = gl.Renderer.init(gpa) catch |e| {
                std.log.info("myzig: no OpenGL renderer ({s}): frames are drawn on the CPU", .{@errorName(e)});
                self.failed = true;
                return false;
            };
        }
        const r = &self.renderer.?;
        r.syncAtlas(text.atlas.mask(), text.atlas.generation, text.atlas.takeDirty());
        r.syncImages(&text.images);
        if (self.differ == null) self.differ = .init(gpa);
        const d = &self.differ.?;
        const f: damage.Frame = .{ .instances = instances, .width = w, .height = h, .scale = scale, .clear = clear, .atlas = damage.atlasKey(&text.atlas), .images = text.images.generation };
        var part: ?damage.Box = null;
        if (damage.enabled()) {
            const since = d.diff(f);
            if (self.held) if (d.planOne(f, since)) |p| {
                // The framebuffer holds the frame already.
                if (damage.empty(p)) return true;
                part = p;
            };
        }
        self.held = false;
        r.drawPart(instances, scale, w, h, clear, part) catch |e| {
            std.log.warn("myzig: OpenGL failed ({s}): frames are drawn on the CPU", .{@errorName(e)});
            r.deinit();
            self.renderer = null;
            self.failed = true;
            return false;
        };
        d.remember(f);
        self.held = true;
        return true;
    }

    /// Shows `pixels` (BGRA, `w` × `h`, drawn on the CPU) in the area.
    pub fn present(self: *Gpu, gpa: std.mem.Allocator, pixels: []const u8, w: u32, h: u32) void {
        self.presenter.present(gpa, pixels, w, h) catch |e| {
            std.log.warn("myzig: OpenGL cannot show frames ({s})", .{@errorName(e)});
        };
    }

    /// Frees what the area's context holds, with it current: when the area
    /// is unrealized (its context goes) or the surface is freed. A context
    /// made again later gets a renderer again.
    pub fn release(self: *Gpu, gpa: std.mem.Allocator, area: *Widget) void {
        if (load() and api.gtk_widget_get_realized(area) != 0 and hasContext(area)) {
            api.gtk_gl_area_make_current(area);
            if (self.renderer) |*r| r.deinit();
            self.presenter.deinit(gpa);
        } else {
            gpa.free(self.presenter.rgba);
        }
        if (self.differ) |*d| d.deinit();
        self.* = .{};
    }
};
