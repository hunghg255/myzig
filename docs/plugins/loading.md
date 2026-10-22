# Loading

The `loading` package provides 29 loading.dev indicators for native UI on
macOS, Linux, Windows and browsers. It uses myzig's canvas; there is no
service to bind or JavaScript dependency.

## Setup

Add `.loading = .{ .path = "path/to/myzig/plugins/loading" }` to your
`build.zig.zon` dependencies. In `build.zig`, use the same myzig dependency
and target options as the rest of your app:

```zig
const loading = b.dependency("loading", .{
    .target = target, .optimize = optimize,
}).module("loading");
exe.root_module.addImport("loading", loading);
```

Keep a separate `loading.Indicator` in app state for each instance. Call
`show` once per instance per view build; it returns a node index that can
also be passed to `c.interact` or styled through `c.node`.

Each instance has its own elapsed clock. Pausing one does not pause another,
and rebuilding the view several times in the same frame adds no extra time.
Doubling `duration` takes twice as long to reach the same animation phase.

```zig
const loading = @import("loading");

const State = struct {
    saving: loading.Indicator = .{},

    fn view(s: *State, c: *ui.Context) void {
        _ = s.saving.show(c, .ring, .{
            .size = 32, .color = c.theme.accent, .label = "Saving",
        });
    }
};
```

## Designs and options

`Kind` contains `arc`, `atom`, `blocks`, `bouncing_dots`, `cascade`,
`circular_dots`, `classic`, `classic_v2`, `clock`, `comet`, `compass`,
`dual`, `eclipse`, `flip`, `gather`, `leap`, `linear_dots`, `loading`,
`morph`, `orbit`, `pulse`, `radar`, `ring`, `ripple`, `slide`, `snake`,
`swirl`, `trace` and `wave`, in the same order as `loading.names`.

| Option | Meaning |
| --- | --- |
| `size` | Height in points, default 20; width follows the design's aspect ratio. Must be finite and positive. |
| `color` | Defaults to the theme's text color. |
| `duration` | Optional seconds per cycle; finite and positive. Defaults to each design's own timing. |
| `paused` | Holds elapsed time; resuming continues from there. |
| `easing` | `.linear`, `.ease_in_out` or `.stacked` for rotating designs. |
| `cap` | `.round` or `.flat` for stroked designs. |
| `sweep` | Blocks: `.diagonal`, `.rows` or `.columns`. |
| `direction` | Ripple: `.out` or `.in`. |
| `origin` | Wave: `.center` or `.bottom`. |
| `label` | Accessible name; defaults to the design's name. |

Desktop reduced motion draws a stable resting pose and requests no ongoing
animation frames. An indicator clipped out of view stops requesting frames;
visibility is known from the previous paint. Each is exposed as an
indeterminate progress indicator. Canvas masks may be rasterized again as
shapes animate; this port does not promise pixel identity or the same
rendering cost as mygo's optimized plugin.

The [gallery](../../examples/loading/README.md) uses this package. Run
`zig build test-loading -j1` from the repository, or `zig build test -j1`
inside `plugins/loading`, for offscreen pixel, clock and accessibility tests.
These tests compare rendered phases at different durations and check
independent clocks, repeated builds, pause/resume and offscreen behavior.
