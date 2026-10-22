# Loading

The 29 loading.dev indicators from mygo's `examples/loading` and
`plugins/loading`, commit `6725e0d4ef2970dc41ba151f5c2d5bd909cbe278`.
This native UI gallery uses the reusable [loading plugin](../../plugins/loading).
Its drawing code and public indicator clocks live in that package.

```sh
zig build run-loading
zig build build-loading -Doptimize=ReleaseSmall -j1
zig build test-loading -j1
```

Choose size (16/24/32/48 DIPs), theme color, rotation easing and round/flat
stroke caps. Pause holds the current animation time and resumes from it.
The desktop's reduced-motion setting draws each indicator at rest and
stops requesting animation frames. The scrollable gallery adapts its
number of columns to the window width; controls occupy two rows.
Each indicator is exposed to accessibility as an indeterminate progress
indicator with its own name.

The plugin's `drawing.zig` implements CSS timing and canvas primitives;
its `indicators.zig` and `indicators_extra.zig` draw the designs. Timings,
keyframes and proportions follow upstream. Comet and Orbit approximate
their conic fades with 128 sectors; Flip projects a sampled rounded
outline because canvas transforms are affine. Pixel identity with mygo's
renderer is not claimed. Ripple, Wave and Blocks use the upstream
gallery's default direction, origin and sweep; the public plugin also
exposes those options and a duration in seconds.

Tests use `ui.Tester`, simulated time and offscreen pixels. They cover all
29 names and heights, option propagation, changing pixels for every
animation, stable reduced-motion poses, color, caps, easing, pause and
resume. The plugin tests also compare duration-dependent phases and verify
independent clocks across repeated builds of the same frame.
They never show a window or drive system input.

The indicators' original MIT license is kept in [NOTICE.md](NOTICE.md).
