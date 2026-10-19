//! What games need beyond what apps do, after mygo's game plugin, opt-in
//! and kept out of myzig's ui: a game loop in fixed steps with its input
//! (`view`), a camera, and pixel-perfect scaling. Gamepads are the module
//! `gamepad` of this package (src/gamepad), which needs no ui.
//!
//!     fn build(s: *State, c: *ui.Context) void { game.view(c, &s.world, &s.runner); }
const std = @import("std");
const loop = @import("loop.zig");
const view_mod = @import("view.zig");
const camera = @import("camera.zig");

pub const Clock = loop.Clock;
pub const Input = loop.Input;
pub const Key = loop.Key;
pub const default_rate = loop.default_rate;

pub const Runner = view_mod.Runner;
pub const view = view_mod.view;
pub const fill = view_mod.fill;
pub const rounded = view_mod.rounded;

pub const Camera = camera.Camera;
pub const Transform = camera.Transform;
pub const integerFit = camera.integerFit;

test {
    _ = loop;
    _ = camera;
    _ = view_mod;
}
