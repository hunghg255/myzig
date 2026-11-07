# Native UI performance

Views are immediate mode: the view runs on every frame and builds the
whole tree again. That is cheap for two reasons:

- A frame is only built when something happens: input, a resize, an
  animation, a request from outside the view.
- What is expensive is kept across frames:

| What | How it is kept |
|---|---|
| **Layout** | each text box's text, width and last two wraps, by its id (`layout_cache.zig`, after mygo's layout cache) |
| **Text layouts** | cached by string and style; glyphs rasterized once into the glyph atlas |
| **Pictures** | decoded once and packed into the image atlas |
| **The frame's memory** | an arena reset each frame |
| **Control animations** | values kept by widget id |
| **Drawing** | one instanced draw call a frame on the GPU (see [Rendering](rendering.md)) |

**Layout**

- A box whose text is as it was, as most are, asks the text system
  nothing. One whose text changed allocates nothing.
- Within a frame, a box measured again at the same width is as it was.
  Deep trees are measured once, not once per level around them.
- Every 60 frames, entries unused for more than two frames are discarded.
  The sweep drains all expired entries, so continuous scrolling builds no
  backlog. If scratch allocation fails, it still removes a small batch.

**Text layouts**

- Printable ASCII has an exact fast path on macOS (`shaper.zig`, tested
  to match CoreText's shaping).
- A font is kept for each size text is shown at. Past 256 of them, a
  frame lets them all go and starts over, rasterizing its glyphs again.
  That happens with sizes that change every frame, as a zoom slider
  gives.

**Pictures**

- The image atlas starts at 512 pixels a side and doubles as pictures
  need, up to 2048.
- Where the GPU draws (Metal, Direct3D 11), pictures go straight to its
  texture. No copy of the atlas stays in memory.

**The frame's memory.** Strings made with `c.print` and `c.alloc()` cost
a bump of a pointer.

**Control animations.** Every 120 frames, values unused for more than 120
frames are discarded in one sweep. Scrolling past buttons does not pile
up old hover and press states. If scratch allocation fails, the sweep
still removes a small batch.

## Writing fast views

- Show long collections with a virtual [list](lists.md) (`ui.list`, after
  GPUI's `uniform_list`), a table or a grid view. They build only the
  rows in view, so 100 000 rows cost what 30 do.
- Keep ids stable with `ui.key` or `c.keyed` for items of a collection.
  Their state (hover, focus, animations) then follows them.
- Set `c.changed` only when an interaction changed state. Each one builds
  the frame again (`FrameStats.passes`).
- Ask for pointer moves (`c.wants_moves`) and the wheel (`c.wants_wheel`)
  only in views that follow them, as a graph does. Without them, moving
  the pointer over a still view builds frames only when what is under it
  changes.
- Do work outside the view. The view reads the state; it does not compute
  it. Work from other threads reaches the main thread through the event
  loop and asks for a frame.

## Out of sight

While nothing of a window shows, myzig draws no frames for it. Browsers
do the same for pages out of sight, and Apple asks it of Mac apps.

- "Out of sight" means, on macOS: hidden, minimized, on another Space, or
  entirely covered by other windows. In a browser: a tab in the
  background.
- The view does not run, drawings are not painted, and the frames an
  animation or a timer asks for wait.
- As soon as some of the window shows, it draws once, with everything
  that changed meanwhile. Until then the screen shows its last frame, for
  about a refresh.
- A frame still builds after input, such as keys typed into a key window
  another app's window covers. It also builds for assistive technology,
  and for a snapshot (`--myzig-snapshot`), so that it shows the window as
  it is now.
- Windows and Linux do not tell myzig when a window is out of sight.
  There it draws as it always did.

What this means for motion:

- **What myzig animates goes on from where the time puts it.** Springs,
  curves on their way, loops, keyframes and timelines run on `c.time`,
  the clock, not on a count of frames. Ones running when the window went
  out of sight are further along, or done, when it shows.
- **A target that changed out of sight animates when the window shows.**
  The view first sees the new target then. The value moves to it from
  where it was, as a CSS transition does for a change made in a hidden
  tab.
- **Compute your own motion from the time, not from frames.** A start
  time taken in the first frame that draws, or a count of frames, starts
  over when the window shows. It plays what happened meanwhile as if it
  just began.

Take the time from when the state changed, in the code that changes it.
Then the view shows a change made out of sight as done:

```zig
/// Eases from one value to the next over 400 ms, by the clock.
const Counter = struct {
    from: f32 = 0,
    to: f32 = 0,
    changed: f64 = 0, // ui.clock.now() when it changed

    const ease = 0.4;

    fn at(n: Counter, t: f64) f32 {
        const p: f32 = @floatCast(@min((t - n.changed) / ease, 1));
        return n.from + (n.to - n.from) * ui.motion.Easing.at(.ease_out, p);
    }
};

// Where the count changes, outside the view:
const now = ui.clock.now();
app.count = .{ .from = app.count.at(now), .to = @floatFromInt(n), .changed = now };
win.redraw();

// In the view:
const value = app.count.at(c.time);
if (c.time - app.count.changed < Counter.ease) c.animationFrame();
```

- **Keep work out of the view.** Polling, saving, or starting jobs from
  the view, from a timer it asks for, or from a drawing waits while the
  window is out of sight. Run such work from the app: a thread, or a
  timer of the app (`myzig.App.after`). Show what it does by asking the
  window for a frame (`redraw`).

## Measuring

`c.stats` (`ui.FrameStats`) holds the last frame's costs: build, layout
and paint in milliseconds, the passes, the boxes and the instances. The
[inspector](inspector.md) graphs them for the last 60 frames.

The benchmarks are hill-climbed. [`hillclimb/`](../../hillclimb/README.md)
is a terminal app, built on myzig as a library. It renders the same
scenes through myzig's frames and through mygo's, without a window, and
records every run in `hillclimb/history.jsonl`:

```sh
cd hillclimb
zig build run                                  # every scene, myzig and mygo
zig build run -- --label "what changed"        # name the run in history.jsonl
zig build run -- --scene text,list --only myzig --frames 600 --repeat 5
zig build run -- --only myzig --hash           # and hash the CPU renderer's pixels
```

- Each scene runs 30 frames of warm-up, then 300 measured, three times.
- The run with the lowest median frame is kept. It is compared with mygo,
  with myzig's previous run and with its best.
- Changes within 5% are noise.

Performance work is done this way:

- Run before and after, keep changes that climb, and label runs.
- Never trade correctness for speed. Fast paths come with tests proving
  they match the slow path. `--hash` proves a faster CPU renderer draws
  the same pixels.

The scenes:

- **boxes**: 600 rounded, shadowed boxes moving and changing color.
- **text**: 300 labels whose numbers change every frame.
- **scroll**: a plain column of 1000 rows, clipped, moving every frame.
- **list**: a virtualized list of 100 000 rows, scrolled every frame.
- **dashboard**: 12 cards of text, a large number and a progress bar.

## Results

On an Apple M3 Ultra, with the frames drawn by each framework's offscreen
Metal renderer. Medians per frame in milliseconds, lower is better:

| scene | frame CPU myzig | frame CPU mygo | GPU myzig | GPU mygo |
|---|---:|---:|---:|---:|
| boxes (600 shadowed boxes) | 0.061 | 0.301 | 0.140 | 1.616 |
| text (300 changing labels) | 0.108 | 0.418 | 0.065 | 0.056 |
| scroll (1000-row column) | 0.315 | 2.076 | 0.055 | 0.122 |
| list (100 000-row virtual list) | 0.060 | 0.367 | 0.046 | 0.045 |
| dashboard (12 cards) | 0.015 | 0.087 | 0.098 | 0.295 |

On Windows, an Intel Core i5-1145G7 with 8 threads. Both frameworks' CPU
renderers draw every frame whole into memory, on several cores. Zig
0.17.0 against mygo 9c05b11
([the runs](../../hillclimb/notes/windows-results-2026-10-20.md)):

| scene | frame CPU myzig | frame CPU mygo | render myzig | render mygo | process CPU myzig | process CPU mygo |
|---|---:|---:|---:|---:|---:|---:|
| boxes | 0.094 | 0.646 | 5.6 | 17.2 | 37.3 | 125.4 |
| text | 0.276 | 0.993 | 0.8 | 2.5 | 4.8 | 20.3 |
| scroll | 0.658 | 4.094 | 0.7 | 0.9 | 5.8 | 7.4 |
| list | 0.065 | 0.731 | 0.5 | 1.1 | 3.9 | 8.9 |
| dashboard | 0.054 | 0.179 | 4.3 | 6.7 | 27.7 | 34.2 |
| layout | 0.166 | 0.473 | 1.4 | 2.6 | 8.8 | 12.9 |

Measurements of real windows (time to first frame, memory, idle CPU) are
in [hillclimb/notes/windowed-results-2026-10-17.md](../../hillclimb/notes/windowed-results-2026-10-17.md).
Idle, a myzig window uses no CPU at all.

## Size

A release binary of the counter is about 0.7 MB (`ReleaseSmall`; 1.14 MB
`ReleaseFast` on Windows), against 9 to 12 MB for mygo's. What an app
does not use is not linked:

- i18n's date data only into apps that format dates;
- myzig's own translations only into apps that ship those languages;
- the [inspector](inspector.md) only into debug builds.

See [the architecture guide](../architecture-testing.md) on binary size.

Timings depend on the machine, the renderer and what else runs. Recheck
small differences. Compare a run only with earlier runs of the same
platform (`history.jsonl` records each run's `os`).
