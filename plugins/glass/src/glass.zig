//! Liquid Glass for myzig's native UI, after mygo's glass plugin: what is
//! under a pane shows through it, frosted, bent near its edges as through
//! the rim of a lens, toned so that what is on it reads, and lit along its
//! hairline rim; and a plain backdrop blur. A pane is a backdrop effect of
//! myzig's renderers (`shader.zig`): every renderer draws it, the CPU
//! renderer with `pixels.zig` (mygo's CPU twin), the GPUs with
//! `glass.hlsl`, `glass.glsl` and `glass.metal`.
const std = @import("std");

pub const material = @import("material.zig");
pub const pixels = @import("pixels.zig");
pub const shader = @import("shader.zig");
const pane_mod = @import("pane.zig");

pub const Style = material.Style;
pub const Material = material.Material;
pub const Image = pixels.Image;
pub const Glass = pane_mod.Glass;
pub const Kind = pane_mod.Kind;
pub const pane = pane_mod.pane;
pub const paneOf = pane_mod.paneOf;

test {
    _ = material;
    _ = pixels;
    _ = pane_mod;
    _ = shader;
}
