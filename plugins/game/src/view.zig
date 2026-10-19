//! A game in an element of native UI: each frame, the steps due run with
//! the player's input, then the game draws, in boxes placed in the view.
//!
//!     const Farm = struct {
//!         pub fn update(f: *Farm, in: *game.Input) void { if (in.down(.d)) f.x += 2; }
//!         pub fn draw(f: *Farm, c: *ui.Context, size: ui.Size, alpha: f32) void {
//!             game.fill(c, .{ .x = f.x, .y = 40, .w = 16, .h = 16 }, .hex(0x4caf50));
//!         }
//!     };
//!     fn view(s: *State, c: *ui.Context) void { game.view(c, &s.farm, &s.runner); }
const std = @import("std");
const ui = @import("myzig").ui;
const loop = @import("loop.zig");
const UiKey = @typeInfo(@FieldType(@FieldType(ui.Context, "input"), "key")).optional.child;

/// What a game view keeps between frames: its clock and its input.
pub const Runner = struct {
    clock: loop.Clock = .{},
    input: loop.Input = .{},
    /// Steps run so far.
    steps: u64 = 0,
    /// The frame that last ran steps: a frame may build its view twice.
    frame: ?u64 = null,
    /// Keys came going down and up (`Context.wants_keys`): typed keys are
    /// no longer taken as taps.
    edges: bool = false,
};

/// Runs `game` (with `update(*G, *game.Input)` and `draw(*G, *ui.Context,
/// ui.Size, alpha: f32)`, and an optional `pub const rate`) in a box that
/// fills its parent. Its draws are positioned in the box (0, 0 at its
/// corner) and clipped to it.
pub fn view(c: *ui.Context, game: anytype, runner: *Runner) void {
    const G = @typeInfo(@TypeOf(game)).pointer.child;
    if (@hasDecl(G, "rate")) runner.clock.rate = G.rate;
    const box = c.open(.{ .width = .fill, .height = .fill, .grow = 1, .clip = true }, "myzig-game");
    const it = c.interact(box, .{ .focusable = true });
    const rect = it.rect orelse ui.Rect{};
    // Keys going down and up, from the next event on.
    c.wants_keys = true;
    if (runner.frame != c.frame) {
        runner.frame = c.frame;
        feed(c, runner, rect, it.hovered);
        const n = runner.clock.advance(c.dt);
        for (0..n) |_| {
            game.update(&runner.input);
            runner.input.endStep();
            runner.steps += 1;
        }
    }
    game.draw(c, .{ .w = rect.w, .h = rect.h }, runner.clock.alpha());
    c.end();
    // Steps run on frames: ask for the next one.
    c.animationFrame();
}

/// This frame's input, from the context: keys going down and up (until
/// the first comes, typed and navigation keys as taps), the pointer and
/// the wheel.
fn feed(c: *ui.Context, runner: *Runner, rect: ui.Rect, hovered: bool) void {
    const i = &c.input;
    const in = &runner.input;
    in.size = .{ rect.w, rect.h };
    in.pointer = .{ i.mouse.x - rect.x, i.mouse.y - rect.y };
    in.over = hovered;
    if (i.pressed) in.button(0, true);
    if (i.released) in.button(0, false);
    in.wheel[0] += i.scroll.x;
    in.wheel[1] += i.scroll.y;
    if (i.key_down) |code| if (edgeKey(code)) |k| {
        runner.edges = true;
        in.keyDown(k);
    };
    if (i.key_up) |code| if (edgeKey(code)) |k| {
        runner.edges = true;
        in.keyUp(k);
    };
    if (runner.edges) return;
    // Keys with Command, Control or Alt are the menus'.
    if (i.cmd or i.ctrl) return;
    for (i.chars) |ch| if (loop.Key.fromChar(ch)) |k| in.tap(k);
    if (i.key) |k| if (navKey(k)) |gk| in.tap(gk);
}

/// A key's code as the ui gives its edges (`Input.key_down`).
fn edgeKey(code: u21) ?loop.Key {
    const S = ui.Shortcut;
    return switch (code) {
        S.up => .up,
        S.down => .down,
        S.left => .left,
        S.right => .right,
        S.enter => .enter,
        S.escape => .escape,
        S.tab => .tab,
        0x08 => .backspace,
        0xF710 => .shift,
        0xF711 => .ctrl,
        0xF712 => .alt,
        else => if (code < 128) loop.Key.fromChar(@intCast(code)) else null,
    };
}

fn navKey(k: UiKey) ?loop.Key {
    return switch (k) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
        .enter => .enter,
        .escape => .escape,
        .tab => .tab,
        .backspace => .backspace,
        else => null,
    };
}

/// Draws a filled rectangle at `r` in the game's box.
pub fn fill(c: *ui.Context, r: ui.Rect, color: ui.Color) void {
    _ = c.leaf(.{
        .absolute = true,
        .offset = .{ .x = r.x, .y = r.y },
        .width = .{ .px = r.w },
        .height = .{ .px = r.h },
        .background = color,
    }, .none, null);
}

/// Draws a rounded rectangle (a ball, a coin) at `r`.
pub fn rounded(c: *ui.Context, r: ui.Rect, color: ui.Color, radius: f32) void {
    _ = c.leaf(.{
        .absolute = true,
        .offset = .{ .x = r.x, .y = r.y },
        .width = .{ .px = r.w },
        .height = .{ .px = r.h },
        .background = color,
        .radius = radius,
    }, .none, null);
}
