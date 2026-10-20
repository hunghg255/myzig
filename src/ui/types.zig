//! Geometry, colors and styles of native UI. Units are points.
const std = @import("std");

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Size = struct {
    w: f32 = 0,
    h: f32 = 0,
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(r: Rect, p: Point) bool {
        return p.x >= r.x and p.y >= r.y and p.x < r.x + r.w and p.y < r.y + r.h;
    }

    pub fn inset(r: Rect, e: Edges) Rect {
        return .{ .x = r.x + e.left, .y = r.y + e.top, .w = @max(0, r.w - e.left - e.right), .h = @max(0, r.h - e.top - e.bottom) };
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }

    pub const infinite: Rect = .{ .x = -1e6, .y = -1e6, .w = 2e6, .h = 2e6 };
};

pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    /// `0xRRGGBB` or, with `alpha`, any opacity.
    pub fn hex(v: u24) Color {
        return .{
            .r = @as(f32, @floatFromInt((v >> 16) & 0xff)) / 255,
            .g = @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255,
            .b = @as(f32, @floatFromInt(v & 0xff)) / 255,
        };
    }

    pub fn alpha(c: Color, a: f32) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a * a };
    }

    pub fn mix(a: Color, b: Color, t: f32) Color {
        return .{
            .r = a.r + (b.r - a.r) * t,
            .g = a.g + (b.g - a.g) * t,
            .b = a.b + (b.b - a.b) * t,
            .a = a.a + (b.a - a.a) * t,
        };
    }

    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };
    pub const black: Color = .{};
    pub const transparent: Color = .{ .a = 0 };
};

pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn all(v: f32) Edges {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    pub fn xy(x: f32, y: f32) Edges {
        return .{ .top = y, .right = x, .bottom = y, .left = x };
    }

    pub fn horizontal(e: Edges) f32 {
        return e.left + e.right;
    }

    pub fn vertical(e: Edges) f32 {
        return e.top + e.bottom;
    }
};

/// The length of a box along one axis.
pub const Length = union(enum) {
    /// As large as its content.
    auto,
    /// Exactly this many points.
    px: f32,
    /// All the room its parent gives it.
    fill,
};

pub const Direction = enum { row, column };
/// Where children go across their parent's direction. `baseline` lines up
/// the first lines of text of a row's children, as a large price beside
/// its small unit (`layout_baseline.zig`): a child without text lines up
/// its bottom; across a column it is `start`.
pub const Align = enum { start, center, end, stretch, baseline };
pub const Justify = enum { start, center, end, space_between };
pub const Weight = enum { regular, medium, semibold, bold };

/// A box's transform (`Style.transform`): see `transform.zig`.
pub const Affine = @import("transform.zig").Affine;

/// A color of a gradient and its place along it, from 0 to 1, as CSS's
/// color stops: the first color shows before the first stop, the last
/// after the last, and two stops at one place make a sharp edge.
pub const Stop = struct {
    color: Color,
    at: f32,
};

/// Colors blended across a box (`Style.gradient`), over its background,
/// within its rounded corners, as CSS's linear-, radial- and
/// conic-gradient(): at most `Gradient.max_stops` stops, in order.
pub const Gradient = struct {
    kind: Kind = .linear,
    stops: []const Stop,
    /// Linear: the direction, in degrees clockwise from upward (180 goes
    /// from top to bottom, 90 from left to right).
    angle: f32 = 180,
    /// Conic: where the turn starts, in degrees clockwise from upward
    /// (CSS's "from").
    start: f32 = 0,
    /// Radial and conic: the center, in fractions of the box.
    center: Point = .{ .x = 0.5, .y = 0.5 },
    /// Radial: the radius of the last stop, in points; null reaches the
    /// farthest corner, as CSS's.
    radius: ?f32 = null,
    /// Mixes the colors in Oklab, whose midpoints keep their lightness,
    /// rather than in sRGB (CSS's "in oklab").
    oklab: bool = false,

    pub const Kind = enum { linear, radial, conic };
    pub const max_stops = 16;
};

/// A backdrop effect (`Style.effect`): see `effect.zig`.
pub const Effect = @import("effect.zig").Effect;

/// The curve of a box's rounded corners (`Style.corners`).
pub const Corners = enum {
    /// Quarter circles of the radius.
    circular,
    /// Core Animation's continuous curve ("squircle"): it leaves the edges
    /// farther from the corner (1.53 times the radius) and bends gradually.
    continuous,

    /// An instance's radius for corners of `radius` in this style:
    /// negative for continuous ones (`gpu.Instance.radius`).
    pub fn signed(k: Corners, radius: f32) f32 {
        return if (k == .continuous) -radius else radius;
    }
};

pub const Shadow = struct {
    color: Color = .{ .a = 0.18 },
    blur: f32 = 12,
    y: f32 = 4,
};

/// The style of a box, in the manner of CSS flexbox.
pub const Style = struct {
    direction: Direction = .column,
    gap: f32 = 0,
    padding: Edges = .{},
    width: Length = .auto,
    height: Length = .auto,
    min_width: f32 = 0,
    min_height: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    /// At most this tall: a scrolling box is as tall as its content up to
    /// here, then scrolls (a chat's answer, a popover's list).
    max_height: f32 = std.math.inf(f32),
    /// Share of the free room along the parent's main axis.
    grow: f32 = 0,
    align_items: Align = .start,
    justify: Justify = .start,
    background: ?Color = null,
    border: ?Color = null,
    border_width: f32 = 1,
    radius: f32 = 0,
    /// How its corners curve: as circles (CSS's), or continuous, as macOS
    /// and iOS curve theirs (`raster_corner.zig`): its background, border,
    /// shadow, picture, gradient and what it clips, by every renderer.
    corners: Corners = .circular,
    shadow: ?Shadow = null,
    /// Children are clipped to the box and scroll along it: a column
    /// vertically, a row sideways (the wheel scrolls it too).
    scroll: bool = false,
    /// Overall opacity of the box and its content.
    opacity: f32 = 1,
    /// Moves the box after layout, without moving its siblings.
    offset: Point = .{},
    /// Moves, scales, turns or slants the box and its children as drawn,
    /// after layout (its place stays), about `transform_origin`; the
    /// pointer follows it. See `transform.zig`.
    transform: ?Affine = null,
    /// The point transforms act about, in fractions of the box: its
    /// center by default, (0, 0) its top left.
    transform_origin: Point = .{ .x = 0.5, .y = 0.5 },
    /// Colors blended across the box, over its background: kept until the
    /// frame is drawn (a constant, the app's memory or the frame's).
    gradient: ?*const Gradient = null,
    /// Blurs the box and its children as drawn, by this standard
    /// deviation in points (CSS's filter: blur()).
    blur: f32 = 0,
    /// Draws the box from what is under it (frosted glass), under its
    /// background and children: see `effect.zig`.
    effect: ?*const Effect = null,
    /// Out of the flow: placed at its parent's content origin (plus
    /// `offset`), at its own size, over or under its siblings.
    absolute: bool = false,
    /// Children are clipped to the box.
    clip: bool = false,
    /// A scrolling box that stays at its end as its content grows, while
    /// it was at its end: logs, chats, terminals.
    follow_end: bool = false,
    /// Following its end, it glides there as its content grows, as the
    /// animation says (`ui.FollowGlide.of(.smooth)`), rather than showing
    /// the end at once: what is added comes up from below
    /// (`follow_glide.zig`).
    follow_glide: ?*const @import("follow_glide.zig").FollowGlide = null,
    /// Its texts (and its children's) can be selected with the pointer and
    /// copied, as a terminal's or a page's (`selection.zig`).
    selectable: bool = false,
    /// A control (a button, a toggle): its texts do not select, even in a
    /// selectable box, so the pointer is a hand all over it.
    control: bool = false,
    /// A row lining up the first lines of its children's text as a form's
    /// field does: its label with its control's text, or with the middle
    /// of a control without text (a switch) that comes first.
    baselines: bool = false,
};

/// Bytes [start, end) of a text drawn their own way: a color (ANSI
/// output, syntax), and for rich text a weight, italics, the monospaced
/// font (inline code), a background, an underline or a line through.
pub const Span = struct {
    start: u32,
    end: u32,
    color: ?Color = null,
    weight: ?Weight = null,
    italic: bool = false,
    mono: bool = false,
    background: ?Color = null,
    underline: bool = false,
    strike: bool = false,

    /// Whether it changes the font, so the text is shaped with its runs.
    pub fn styled(s: Span) bool {
        return s.weight != null or s.italic or s.mono;
    }
};

pub const TextStyle = struct {
    size: f32 = 14,
    weight: Weight = .regular,
    color: ?Color = null,
    /// Break lines to fit the width the parent gives.
    wrap: bool = false,
    mono: bool = false,
    italic: bool = false,
    /// Line height as a multiple of the font's (1.5 for airy prose).
    leading: f32 = 1,
    /// A family of its own instead of the theme's (`font` or `mono_font`).
    family: ?[]const u8 = null,
    /// OpenType features, by commas: "calt=0,ss01", "-liga", "+zero".
    /// DirectWrite and HarfBuzz apply them.
    features: []const u8 = "",
    /// A weight from 100 to 900 in place of `weight`'s, 0 for `weight`.
    weight_value: u16 = 0,
};

test "rect" {
    const r: Rect = .{ .x = 10, .y = 10, .w = 100, .h = 50 };
    try std.testing.expect(r.contains(.{ .x = 20, .y = 20 }));
    try std.testing.expect(!r.contains(.{ .x = 120, .y = 20 }));
    const i = r.intersect(.{ .x = 50, .y = 0, .w = 100, .h = 30 });
    try std.testing.expectEqual(@as(f32, 60), i.w);
    try std.testing.expectEqual(@as(f32, 20), i.h);
}
