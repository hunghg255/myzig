//! Platforms the tool does not measure on yet (Linux: GTK would need its
//! events synthesized into the window and the probe read back from the
//! X server or the compositor, which Wayland does not let an app do).
const std = @import("std");
const Options = @import("options.zig").Options;
const Figures = @import("figures.zig").Figures;

pub fn measure(_: std.process.Init, _: Options) !Figures {
    return error.Unsupported;
}
