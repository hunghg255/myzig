//! The boxes of a frame's tree and what they show: text, an icon, a
//! picture (re-exported by `context.zig`).
const types = @import("types.zig");
const text = @import("text.zig");

pub const none = @import("std").math.maxInt(u32);

pub const Content = union(enum) {
    none,
    text: Text,
    icon: Icon,
    image: Image,

    /// A picture: its key in the image atlas, and its bytes for the first
    /// time it is drawn.
    pub const Image = struct {
        key: u64,
        bytes: []const u8,
        opacity: f32 = 1,
        /// The part of the picture shown (a sprite of a sheet), in its
        /// own pixels: x, y, w, h; all of it when null.
        source: ?[4]f32 = null,
        /// Sampled from the nearest texel (pixel art) rather than smoothed.
        pixelated: bool = false,
    };

    pub const Icon = struct {
        /// An SF Symbol's name.
        name: []const u8,
        size: f32,
        weight: types.Weight,
        color: types.Color,
    };

    pub const Text = struct {
        str: []const u8,
        style: types.TextStyle,
        color: types.Color,
        lines: []const text.Line = &.{},
        /// Colored byte ranges, sorted; the rest is drawn in `color`.
        spans: []const types.Span = &.{},
    };
};

pub const Node = struct {
    id: u64,
    parent: u32 = none,
    first_child: u32 = none,
    last_child: u32 = none,
    next: u32 = none,
    child_count: u32 = 0,
    style: types.Style,
    content: Content = .none,
    interactive: bool = false,
    input_handler: ?*@import("gesture.zig").Handler = null,
    maximize_button: bool = false,
    /// Holds wrapping text: may shrink below its measured width in a row.
    flexible: bool = false,
    measured: types.Size = .{},
    /// Its size before its minimum and maximum: its flex base size.
    base: types.Size = .{},
    /// The width `measured` was measured at, in layout pass `pass`
    /// (`Context.layout_pass`): measured again at it, it is as it was.
    measured_at: f32 = -1,
    pass: u32 = 0,
    rect: types.Rect = .{},
};
