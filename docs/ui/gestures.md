# Scrolling and pinching

Use `Div.handleInput(state, callback)` for a chart, canvas or other element
that handles scrolling or touchpad zoom. The callback runs on the main
thread before the next view build and returns whether it took the event.
Keep the state pointer valid while the element is displayed.

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

`InputEvent.kind` is `.scroll` or `.zoom`. `x` and `y` are pointer coordinates
relative to the element, including its transform. Scroll `dx`/`dy` are
points, positive right/down; `precise` distinguishes touchpad input from
wheel notches where the platform reports that distinction. `scale` is a
multiplicative zoom factor: 2 means twice as large. `ctrl`, `shift` and
`cmd` carry the current modifiers.

Input goes to the innermost visible handler under the pointer. Returning
false offers it to a parent handler, then to normal scrolling. A handled
scroll does not scroll the containing box. A pinch never scrolls it.
Invalid scale factors (nonfinite, nonpositive or 1) are ignored.

macOS uses magnification events. GTK 3 recognizes touchpad pinches where
the desktop supplies them, notably Wayland. Windows interprets fractional
wheel deltas with Ctrl as precision touchpad zoom; whole wheel notches
remain scrolling with Ctrl. Browsers use Ctrl plus pixel wheel deltas for
pinches, as browsers report them; this also includes Ctrl-wheel devices
that emit pixel deltas. The browser's default zoom is prevented only when
the view handles the event.

In headless tests, `t.pinch(x, y, scale)` returns whether a handler took it.
`t.scroll(x, y, dy)` and `t.wheel(x, y, dy)` also route through handlers;
these Tester's existing methods use positive-up `dy`, converted to
positive-down in `InputEvent`.

See [the gestures example](../../examples/gestures/main.zig). `zig build
test-web -j1` also checks pinch and horizontal/vertical pan in its WebAssembly
build under Node, without opening a browser window.

Windows also routes `WM_MOUSEHWHEEL` to the handler's `dx` (positive right),
including when Ctrl is held; horizontal scrolling does not become a pinch.

Pass `-Dweb-browser="/path/to/chrome-or-edge"` to `zig build test-web`
to additionally exercise real DOM `WheelEvent`s in a headless browser:
pixel, line and page deltas, Ctrl-pinch, and cancellation only for handled
events. This starts no visible window and synthesizes no system input.
