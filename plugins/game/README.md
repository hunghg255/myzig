# game

What games need beyond what apps do, after mygo's
[game plugin](../../../mygo/docs/plugins/game.md), opt-in and kept out of
myzig's ui: a game loop in fixed steps with its input, a camera, pixel-
perfect scaling (module `game`), and gamepads in one standard layout
(module `gamepad`, which needs no ui).

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
        const x = f.px + (f.x - f.px) * alpha; // between its last two steps
        game.fill(c, .{ .x = x, .y = 40, .w = 16, .h = 16 }, .hex(0x4caf50));
    }
};

const State = struct {
    farm: Farm = .{},
    runner: game.Runner = .{},
    fn build(s: *State, c: *ui.Context) void {
        game.view(c, &s.farm, &s.runner); // fills its parent
    }
};
```

- Steps are fixed, 60 a second (`pub const rate = 30;` in the game for
  another), whatever the display's rate; after a pause they catch up a
  quarter of a second at most. `draw` runs every frame with `alpha`, how
  far the frame is into the next step. A frame that builds its view twice
  steps once.
- `game.fill` and `game.rounded` draw boxes positioned in the view (0, 0 at
  its corner), clipped to it.
- `Input`: `down`, `pressed`, `released` by key position (`.w` is W's
  place), the pointer (`pointer`, `over`, `pointerDown/Pressed/Released`),
  `wheel`, `size`, `focused`. Keys with Command or Control are left to the
  menus. `releaseAll` lets go of everything.
- **Held keys:** myzig's ui reports key presses (typed characters and
  navigation keys), not releases, so the view turns them into taps, down
  for one step. Real held keys need key-down/up events in myzig's ui (see
  "Not yet"); until then `runner.input.keyDown/keyUp` take them from
  wherever an app gets them (and tests use them).

## The camera

```zig
const cam: game.Camera = .{ .x = player.x, .y = player.y, .zoom = 3 };
if (cam.rect(view, c.scale, tile_rect)) |r| game.fill(c, r, color); // null when out of view
const w = cam.toWorld(view, c.scale, px, py); // the pointer, in the world
const seen = cam.visible(view, c.scale); // the world's part in view, for culling
```

It looks at the world's `x, y` at the middle of the view, `zoom` times as
large, turned `rotation` degrees (boxes are axis-aligned: turned, `rect`
is the rect around). Unturned, the world moves by whole pixels of the
screen. `transform` gives the affine transform; `integerFit(w, h, r)` the
largest whole multiple of a logical size that fits, letterboxed.

## Gamepads

```zig
const gamepad = @import("gamepad");

var pads: gamepad.Pads = .{};
defer pads.deinit();
pads.update(now_seconds); // once a frame: reads them, looks for new ones once a second
for (pads.list()) |p| {
    const x, const y = p.state.leftStick(); // -1..1, right and down, radial dead zone 0.15
    if (p.state.justPressed(last, .south)) jump(); // pressed: a quarter of the way
}
```

Buttons by place, as the W3C's standard layout: `south east west north`,
`left_shoulder right_shoulder left_trigger right_trigger` (0 to 1),
`back start left_stick right_stick`, `up down left right`, `guide`; axes
`left_x left_y right_x right_y`.

| platform | from |
|---|---|
| Windows | XInput (xinput1_4, loaded with LoadLibrary; Guide through `XInputGetStateEx`, ordinal 100) |
| Linux | evdev, `/dev/input/event*` with gamepad buttons, read without blocking; Xbox X and Y in place |
| macOS | none yet |

## Not yet

- Held keys in native UI: myzig's ui needs key-down and key-up events
  (with physical key codes) for `game.view` to report keys held.
- macOS gamepads (GameController.framework through the Objective-C
  runtime), and browsers.
- Bitmaps and canvases (mygo's `ImageRegion`, `ui.Canvas`): myzig's ui has
  images but not parts of them nor offscreen canvases; games draw boxes.
- mygo's examples (mayoi, farm).

## Example and tests

`example/` is a little game: walk to the coins with D/A, the arrows or a
gamepad, the camera following. `zig build run` shows it.

```sh
zig build test       # loop, input, camera and pads; the view in a ui.Tester; the example rendered offscreen
zig build snapshot   # the example's first frame as a PNG (--myzig-snapshot), no window
zig build check -Dtarget=x86_64-linux-gnu
```

The view's tests advance the Tester's clock, never the wall's: 60 frames
are 60 steps (30 for a game of rate 30).
