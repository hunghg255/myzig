# game

What games need beyond what apps do, opt-in and kept out of myzig's `ui`:
a game loop in fixed steps with its input, a camera, pixel-perfect scaling
(module `game`), and gamepads in one standard layout (module `gamepad`,
which needs no ui).

The package is `plugins/game`. `examples/farm` is a game built on it, a
package of its own (`cd examples/farm && zig build run`); its
`build.zig.zon` shows how an app depends on the plugin:

```zig
.dependencies = .{
    .myzig = .{ .path = "../.." },
    .myzig_game = .{ .path = "../../plugins/game" },
},
```

```zig
const plugin = b.dependency("myzig_game", .{ .target = target, .optimize = optimize });
// imports: .{ .name = "game", .module = plugin.module("game") }, .{ .name = "gamepad", .module = plugin.module("gamepad") }
```

## The game loop

```zig
const game = @import("game");

const Farm = struct {
    x: f32 = 0,
    px: f32 = 0, // where it was a step before

    pub fn update(f: *Farm, in: *game.Input) void {
        f.px = f.x;
        if (in.down(.d) or in.down(.right)) f.x += 2;
        if (in.pressed(.space)) f.jump();
    }

    pub fn draw(f: *Farm, c: *ui.Context, size: ui.Size, alpha: f32) void {
        _ = size;
        const x = f.px + (f.x - f.px) * alpha; // between its last two steps
        game.fill(c, .{ .x = x, .y = 40, .w = 16, .h = 16 }, .hex(0x4caf50));
    }

    fn jump(f: *Farm) void {
        _ = f;
    }
};

const State = struct {
    farm: Farm = .{},
    runner: game.Runner = .{},

    fn view(s: *State, c: *ui.Context) void {
        game.view(c, &s.farm, &s.runner); // fills its parent
    }
};
```

`game.view(c, &g, &runner)` runs a game, any struct with
`update(*G, *game.Input)` and `draw(*G, *ui.Context, ui.Size, alpha: f32)`,
in a focusable box that fills its parent, clipped to it:

- Steps are fixed, 60 a second (`game.default_rate`; `pub const rate = 30;`
  in the game for another), whatever the display's rate. After a pause they
  catch up a quarter of a second at most. A frame that builds its view
  twice steps once.
- `draw` runs every frame with `alpha`, how far the frame is into the next
  step, to draw between the last two steps.
- The view asks for the next frame (`c.animationFrame()`): a game draws
  continuously while it is shown.
- `game.fill(c, rect, color)` and `game.rounded(c, rect, color, radius)`
  draw boxes positioned in the view (0, 0 at its corner).
- The `Runner` keeps the clock, the input and the count of `steps`.

### Input

`game.Input` holds what the step sees:

- keys by position (`game.Key`: `.w` is W's place, and `.up`, `.space`,
  `.shift`...): `down(k)`, `pressed(k)`, `released(k)`;
- the pointer: `pointer` (in the view), `over`, `pointerDown(b)`,
  `pointerPressed(b)`, `pointerReleased(b)`; `wheel`; the view's `size`;
  `focused`;
- `releaseAll()` lets go of everything (when the window loses focus).

The view sets `c.wants_keys`, so keys come going down and up where the
platform reports them (Windows, Linux and browsers do). Until the first
such edge comes, typed characters and navigation keys arrive as taps, down
for one step. Keys with Command or Control are left to the menus.
`runner.input.keyDown(k)` and `keyUp(k)` feed keys from elsewhere (tests
use them).

## The camera

```zig
const cam: game.Camera = .{ .x = player.x, .y = player.y, .zoom = 3 };
if (cam.rect(view_rect, c.scale, tile_rect)) |r| game.fill(c, r, color); // null when out of view
const world = cam.toWorld(view_rect, c.scale, px, py); // the pointer, in the world
const seen = cam.visible(view_rect, c.scale); // the world's part in view, for culling
```

A `Camera` looks at the world's `x, y` in the middle of the view, `zoom`
times as large, turned `rotation` degrees clockwise (boxes stay
axis-aligned: turned, `rect` is the rect around). Unturned, the world moves
by whole pixels of the screen, so tiles drawn at whole units keep their
edges on pixels. `transform` gives the affine `game.Transform` (`apply`,
`invert`), `toScreen` the other way from `toWorld`, and
`game.integerFit(w, h, view_rect)` the largest whole multiple of a logical
size that fits, letterboxed, with its scale.

## Gamepads

```zig
const gamepad = @import("gamepad");

var pads: gamepad.Pads = .{};
defer pads.deinit();
var last: gamepad.State = .{};

// once a frame: reads the pads, and looks for new ones once a second
pads.update(now_seconds);
for (pads.list()) |p| {
    const x, const y = p.state.leftStick(); // -1..1, right and down, radial dead zone 0.15
    if (p.state.justPressed(last, .south)) jump(); // pressed: a quarter of the way
    last = p.state;
}
```

- Buttons by place, as the W3C's standard layout (`gamepad.Button`):
  `south east west north`, `left_shoulder right_shoulder left_trigger
  right_trigger` (0 to 1), `back start left_stick right_stick`,
  `up down left right`, `guide`.
- Axes (`gamepad.Axis`): `left_x left_y right_x right_y`.
- `State`: `value(b)`, `pressed(b)`, `justPressed(last, b)`,
  `justReleased(last, b)`, `axis(a)`, `leftStick()`, `rightStick()`.
- A `Pad` has an `id` (unique while the app runs: plugged in again, a pad
  is a new one), its `name`, `state` and `connected`. Up to 8.

| platform | from |
|---|---|
| Windows | XInput (`xinput1_4`, loaded with LoadLibrary; Guide through `XInputGetStateEx`, ordinal 100) |
| Linux | evdev, `/dev/input/event*` with gamepad buttons, read without blocking |
| macOS, browsers | none yet (no pads are listed) |

## Not yet

- macOS gamepads (GameController.framework through the Objective-C
  runtime), and browsers' Gamepad API.
- Parts of images and offscreen canvases (mygo's `ImageRegion`): games
  draw boxes, [canvases](../ui/drawing.md) and `ui.image`.

## Example and tests

`example/` is a little game: walk to the coins with D and A, the arrows or
a gamepad, the camera following. `zig build run` shows it.

```sh
cd plugins/game
zig build test       # loop, input, camera and pads; the view in a ui.Tester; the example rendered offscreen
zig build snapshot   # the example's first frame as a PNG (--myzig-snapshot), no window
zig build check -Dtarget=x86_64-linux-gnu
```

The view's tests advance the Tester's clock, never the wall's: 60 frames
are 60 steps (30 for a game of rate 30).
