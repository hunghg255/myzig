# Scrolling and pinching

`Div.handleInput(state, callback)` lets a chart, canvas or other element
handle scrolling and touchpad zoom itself.

```zig
fn input(s: *State, e: ui.InputEvent) bool {
    switch (e.kind) {
        .zoom => s.zoom *= e.scale,
        .scroll => s.pan += e.dx,
    }
    return true;
}

// In the view:
const plot = ui.div(c).size(400, 240).handleInput(s, input);
defer plot.end();
// Draw the chart here.
```

- The callback runs on the main thread before the next view build.
- It returns whether it took the event.
- Keep the state pointer valid while the element is shown.

| `ui.InputEvent` | |
|---|---|
| `kind` | `.scroll` or `.zoom` |
| `x`, `y` | the pointer, relative to the element and its transform |
| `dx`, `dy` | scroll in points, positive right and down |
| `precise` | touchpad rather than wheel notches, where the platform tells them apart |
| `scale` | zoom factor: 2 is twice as large |
| `ctrl`, `shift`, `cmd` | the modifiers held |

**Behavior**

- Input goes to the innermost visible handler under the pointer.
- Returning false offers it to a parent handler, then to normal
  scrolling.
- A handled scroll does not scroll the box around it. A pinch never does.
- Scale factors that are not finite, not positive, or 1 are ignored.

**Platforms**

- **macOS**: magnification events.
- **Linux**: GTK 3 recognizes touchpad pinches where the desktop supplies
  them, notably Wayland.
- **Windows**: fractional wheel deltas with Ctrl are precision touchpad
  zoom. Whole wheel notches with Ctrl stay scrolling.
- **Windows**: `WM_MOUSEHWHEEL` goes to `dx` (positive right), also with
  Ctrl held. Horizontal scrolling never becomes a pinch.
- **Browsers**: Ctrl with pixel wheel deltas is a pinch, as browsers
  report it. Ctrl-wheel devices that send pixel deltas count too.
- **Browsers**: the default zoom is prevented only when the view handles
  the event.

**Testing**

- `t.pinch(x, y, scale)` returns whether a handler took it.
- `t.scroll(x, y, dy)` and `t.wheel(x, y, dy)` go through handlers too.
  Their `dy` is positive up; `InputEvent` gets it positive down.
- `zig build test-web -j1` checks pinch and horizontal and vertical pan
  in the WebAssembly build under Node, without a browser window.

See [the gestures example](../../examples/gestures/main.zig).

<details>
<summary>Real browser wheel events</summary>

Pass `-Dweb-browser="/path/to/chrome-or-edge"` to `zig build test-web` to
also test real DOM `WheelEvent`s in a headless browser:

- pixel, line and page deltas;
- Ctrl-pinch;
- cancellation only for handled events.

It shows no window and synthesizes no system input.

</details>
