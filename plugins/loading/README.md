# Loading

29 native loading.dev indicators for myzig, with no JavaScript or runtime
service. Add this package as a dependency and import its `loading` module.
Keep one `Indicator` in app state for each displayed indicator:

```zig
const loading = @import("loading");

// In app state:
busy: loading.Indicator = .{},

// In the view:
_ = s.busy.show(c, .ring, .{ .size = 24, .label = "Saving" });
```

See [the documentation](../../docs/plugins/loading.md) and the
[gallery](../../examples/loading). Run `zig build test -j1` in this directory;
`zig build check -Dtarget=x86_64-linux-gnu -j1` compiles without running.

Tests cover all designs' pixels, duration-dependent phases, independent
instance clocks, repeated view builds, pause/resume and reduced motion.
`zig build test-loading -j1` from the repository also runs the gallery tests.

The designs follow loading.dev (MIT): see [NOTICE.md](NOTICE.md).
