//! An OpenGL context without a window, for tests: EGL on Mesa's
//! surfaceless platform (llvmpipe draws without a GPU or a display), else
//! EGL's default display, current on the calling thread without a surface.
//! The renderer draws into framebuffers of its own there (`drawOffscreen`).
const std = @import("std");

const Display = ?*anyopaque;
const Context = ?*anyopaque;
const Config = ?*anyopaque;

const Egl = struct {
    eglGetProcAddress: *const fn (name: [*:0]const u8) callconv(.c) ?*anyopaque,
    eglGetDisplay: *const fn (native: ?*anyopaque) callconv(.c) Display,
    eglInitialize: *const fn (d: Display, major: ?*i32, minor: ?*i32) callconv(.c) u32,
    eglBindAPI: *const fn (api: u32) callconv(.c) u32,
    eglChooseConfig: *const fn (d: Display, attribs: [*]const i32, configs: *Config, size: i32, n: *i32) callconv(.c) u32,
    eglCreateContext: *const fn (d: Display, config: Config, share: Context, attribs: [*]const i32) callconv(.c) Context,
    eglMakeCurrent: *const fn (d: Display, draw: ?*anyopaque, read: ?*anyopaque, ctx: Context) callconv(.c) u32,
    eglDestroyContext: *const fn (d: Display, ctx: Context) callconv(.c) u32,
    eglTerminate: *const fn (d: Display) callconv(.c) u32,
};

const platform_surfaceless = 0x31DD; // EGL_PLATFORM_SURFACELESS_MESA
const none = 0x3038;
const renderable_type = 0x3040;
const opengl_bit = 0x0008;
const opengl_es3_bit = 0x0040;
const surface_type = 0x3033;
const pbuffer_bit = 0x0001;
const opengl_api = 0x30A2;
const opengl_es_api = 0x30A0;
const context_major = 0x3098;
const context_minor = 0x30FB;
const context_profile = 0x30FD;
const core_profile_bit = 0x1;

pub const Offscreen = struct {
    egl: Egl,
    display: Display,
    context: Context,

    /// An OpenGL 3.3 core context, or with `es` an OpenGL ES 3.0 one,
    /// current on this thread; an error when there is no EGL or no such
    /// context (the test is skipped then).
    pub fn init(es: bool) !Offscreen {
        const lib = std.c.dlopen("libEGL.so.1", .{ .NOW = true, .GLOBAL = true }) orelse return error.NoEGL;
        var egl: Egl = undefined;
        inline for (@typeInfo(Egl).@"struct".field_names) |name| {
            @field(egl, name) = @ptrCast(@alignCast(std.c.dlsym(lib, name) orelse return error.NoEGL));
        }
        const GetPlatformDisplay = *const fn (platform: u32, native: ?*anyopaque, attribs: ?[*]const isize) callconv(.c) Display;
        var display: Display = null;
        if (egl.eglGetProcAddress("eglGetPlatformDisplay")) |p| {
            display = @as(GetPlatformDisplay, @ptrCast(@alignCast(p)))(platform_surfaceless, null, null);
        }
        if (display == null or egl.eglInitialize(display, null, null) == 0) {
            display = egl.eglGetDisplay(null);
            if (display == null or egl.eglInitialize(display, null, null) == 0) return error.NoDisplay;
        }
        errdefer _ = egl.eglTerminate(display);
        _ = egl.eglBindAPI(if (es) opengl_es_api else opengl_api);
        const config_attribs = [_]i32{ renderable_type, if (es) opengl_es3_bit else opengl_bit, surface_type, pbuffer_bit, none };
        var config: Config = null;
        var n: i32 = 0;
        if (egl.eglChooseConfig(display, &config_attribs, &config, 1, &n) == 0 or n == 0) return error.NoConfig;
        const gl_attribs = [_]i32{ context_major, 3, context_minor, 3, context_profile, core_profile_bit, none };
        const es_attribs = [_]i32{ context_major, 3, context_minor, 0, none };
        const context = egl.eglCreateContext(display, config, null, if (es) &es_attribs else &gl_attribs) orelse return error.NoContext;
        errdefer _ = egl.eglDestroyContext(display, context);
        if (egl.eglMakeCurrent(display, null, null, context) == 0) return error.NoSurfaceless;
        return .{ .egl = egl, .display = display, .context = context };
    }

    pub fn deinit(o: *Offscreen) void {
        _ = o.egl.eglMakeCurrent(o.display, null, null, null);
        _ = o.egl.eglDestroyContext(o.display, o.context);
        _ = o.egl.eglTerminate(o.display);
    }
};
