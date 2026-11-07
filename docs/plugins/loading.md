# Loading

The `loading` package draws 29 loading.dev indicators in native UI on
macOS, Linux, Windows and browsers. It uses myzig's canvas: no service to
bind, no JavaScript dependency.

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

Keep one `loading.Indicator` in app state for each instance:

- Call `show` once per instance per view build.
- It returns a node index. Pass it to `c.interact` or style it through
  `c.node`.
- Each instance has its own clock. Pausing one does not pause another.
- Building the view several times in one frame adds no time.
- Doubling `duration` takes twice as long to reach the same phase.

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

**Behavior**

- With reduced motion on the desktop, it draws a still pose and asks for
  no animation frames.
- Clipped out of view, it stops asking for frames. Visibility comes from
  the previous paint.
- Screen readers get an indeterminate progress indicator.

The [gallery](../../examples/loading/README.md) uses this package.

<details>
<summary>Tests and differences from mygo</summary>

Run `zig build test-loading -j1` from the repository, or
`zig build test -j1` inside `plugins/loading`. The offscreen tests check
pixels, clocks and accessibility:

- rendered phases at different durations;
- independent clocks and repeated builds;
- pause/resume and offscreen behavior.

Canvas masks may be rasterized again as shapes animate. This port does
not promise the same pixels or rendering cost as mygo's optimized plugin.

</details>
