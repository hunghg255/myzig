//! The WebGL 2 renderer's shaders (`webgl.zig`): `gl.glsl`, which the
//! OpenGL renderer draws with too, in GLSL ES 3.0. Each pixel is what the
//! CPU renderer (`raster.zig`) finds for it, by the same arithmetic (see
//! `gl.glsl`); GL's window coordinates start at the bottom, so rows are
//! counted from the top as the CPU renderer counts them.

const source = @import("shader_min.zig").minify(@embedFile("gl.glsl"));

/// The vertex shader: attributes 0 to 5 are `gpu.Instance`'s six vec4s,
/// one per instance; four vertices a quad, as a triangle strip.
pub const vertex = "#version 300 es\n#define VERTEX 1\n" ++ source;

pub const fragment = "#version 300 es\n#define FRAGMENT 1\n" ++ source;
