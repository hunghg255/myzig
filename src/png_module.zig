//! PNG decoding alone, for tools built beside myzig (the CLI's icons): a
//! module rooted here, in src/, so the files `png_decode.zig` reaches
//! resolve their imports.
pub const decode = @import("ui/png_decode.zig").decode;
