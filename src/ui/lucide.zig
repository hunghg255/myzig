//! Lucide's icons (lucide.dev, v0.460.0, ISC: `lucide/LICENSE`), shipped
//! with myzig: line drawings on a 24-unit grid in `currentColor`.
//!
//! - `svg("trash-2")` is any of them by Lucide's name, at compile time: an
//!   app carries only those it names. Draw one with `ui.svg` (`.crisp`), or
//!   hand it to myzig by name (`ui.app_icons`).
//! - `symbol("trash")` is the one myzig's widgets draw for an SF Symbol's
//!   name, where there are no SF Symbols (Linux, Windows): in place of the
//!   line icons of `icons.zig`, which remain for names not here.
const std = @import("std");

pub const version = "0.460.0";

/// Lucide's icon `name` ("trash-2", "git-branch"), its SVG document.
pub fn svg(comptime name: []const u8) []const u8 {
    return @embedFile("lucide/icons/" ++ name ++ ".svg");
}

/// `svg(name)` filled with `currentColor`, for the SF Symbols that are
/// solid shapes ("star.fill").
fn solid(comptime name: []const u8) []const u8 {
    @setEvalBranchQuota(100_000);
    const s = svg(name);
    const at = std.mem.indexOf(u8, s, "fill=\"none\"") orelse @compileError("no fill to set in " ++ name);
    return s[0..at] ++ "fill=\"currentColor\"" ++ s[at + "fill=\"none\"".len ..];
}

const Pair = struct { []const u8, []const u8 };

/// The SF Symbols myzig's widgets and apps name, and Lucide's icon for each.
const symbols = [_]Pair{
    .{ "checkmark", svg("check") },
    .{ "xmark", svg("x") },
    .{ "plus", svg("plus") },
    .{ "chevron.down", svg("chevron-down") },
    .{ "chevron.up", svg("chevron-up") },
    .{ "chevron.right", svg("chevron-right") },
    .{ "chevron.left", svg("chevron-left") },
    .{ "chevron.up.chevron.down", svg("chevrons-up-down") },
    .{ "arrow.right", svg("arrow-right") },
    .{ "arrow.up", svg("arrow-up") },
    .{ "arrow.clockwise", svg("rotate-cw") },
    .{ "magnifyingglass", svg("search") },
    .{ "circle", svg("circle") },
    .{ "circle.dotted", svg("circle-dashed") },
    .{ "checkmark.circle.fill", svg("circle-check") },
    .{ "stop.circle", svg("circle-stop") },
    .{ "play.fill", solid("play") },
    .{ "pause.fill", solid("pause") },
    .{ "star.fill", solid("star") },
    .{ "sparkles", svg("sparkles") },
    .{ "wand.and.stars", svg("wand-sparkles") },
    .{ "person.fill", svg("user") },
    .{ "photo", svg("image") },
    .{ "doc", svg("file") },
    .{ "doc.text", svg("file-text") },
    .{ "doc.richtext", svg("file-text") },
    .{ "doc.on.doc", svg("copy") },
    .{ "chevron.left.forwardslash.chevron.right", svg("code-xml") },
    .{ "code", svg("code") },
    .{ "folder", svg("folder") },
    .{ "trash", svg("trash-2") },
    .{ "pencil", svg("pencil") },
    .{ "square.and.pencil", svg("square-pen") },
    .{ "paperclip", svg("paperclip") },
    .{ "globe", svg("globe") },
    .{ "network", svg("network") },
    .{ "terminal", svg("terminal") },
    .{ "terminal.fill", svg("square-terminal") },
    .{ "command", svg("command") },
    .{ "cpu", svg("cpu") },
    .{ "brain", svg("brain") },
    .{ "memorychip", svg("memory-stick") },
    .{ "cube", svg("box") },
    .{ "internaldrive", svg("hard-drive") },
    .{ "desktopcomputer", svg("monitor") },
    .{ "wrench.and.screwdriver", svg("wrench") },
    .{ "waveform.path.ecg", svg("activity") },
    .{ "gauge.with.dots.needle.33percent", svg("gauge") },
    .{ "flame", svg("flame") },
    .{ "exclamationmark.triangle", svg("triangle-alert") },
    .{ "exclamationmark.triangle.fill", svg("triangle-alert") },
    .{ "exclamationmark.circle.fill", svg("circle-alert") },
    .{ "questionmark.circle", svg("circle-help") },
    .{ "info.circle", svg("info") },
    .{ "info.circle.fill", svg("info") },
    .{ "xmark.octagon", svg("octagon-x") },
    .{ "ellipsis.circle", svg("circle-ellipsis") },
    .{ "hand.raised", svg("hand") },
    .{ "list.bullet", svg("list") },
    .{ "checklist", svg("list-checks") },
    .{ "sun.max", svg("sun") },
    .{ "moon", svg("moon") },
    .{ "circle.lefthalf.filled", svg("contrast") },
    .{ "chart.bar.xaxis", svg("chart-column") },
    .{ "equal.square", svg("square-equal") },
    .{ "plus.square", svg("square-plus") },
    .{ "xmark.square", svg("square-x") },
    .{ "arrow.right.square", svg("square-arrow-right") },
    .{ "square.grid.2x2", svg("layout-grid") },
    .{ "square.grid.3x3", svg("grid-3x3") },
    .{ "rectangle.split.2x1", svg("columns-2") },
    .{ "rectangle.split.1x2", svg("rows-2") },
    .{ "rectangle.on.rectangle", svg("copy") },
    .{ "arrow.up.left.and.arrow.down.right", svg("maximize-2") },
    .{ "arrow.triangle.branch", svg("git-branch") },
    .{ "slider.horizontal.3", svg("sliders-horizontal") },
    .{ "text.cursor", svg("text-cursor") },
    .{ "textformat", svg("type") },
    .{ "clear", svg("delete") },
};

/// Lucide's icon for the SF Symbol `name`, if there is one.
pub fn symbol(name: []const u8) ?[]const u8 {
    for (symbols) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
    return null;
}

test "Lucide's icons by their names and by SF Symbols'" {
    try std.testing.expect(std.mem.indexOf(u8, svg("trash-2"), "<svg") != null);
    try std.testing.expect(symbol("checkmark") != null and symbol("no.such.symbol") == null);
    try std.testing.expect(std.mem.indexOf(u8, symbol("star.fill").?, "fill=\"currentColor\"") != null);
    // Every SF Symbol myzig's own line icons draw has a Lucide one.
    for (@import("icons.zig").all) |i| try std.testing.expect(symbol(i.name) != null);
}
