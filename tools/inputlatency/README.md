# inputlatency

Measures how long input takes to show on screen in myzig's native UI: from
when an event arrives to when the frame showing it reaches the display,
after mygo's `internal/inputlatency`. macOS and Windows; on Linux it builds
and reports `Unsupported`.

The tool **shows a window and synthesizes input into it**: run it yourself,
in a desktop session, and leave the mouse and keyboard alone while it runs
(a few minutes for the default runs). Agents and CI never run it; they
build it and run its tests.

```sh
cd tools/inputlatency
zig build test                      # statistics, plans, recorder, probe: no window
zig build run                       # every mode, 6 runs each, optimized
zig build run -- --mode=type,anim --runs=8 --events=300
zig build run -- --mode=heavy --boxes=60
zig build -Dtarget=x86_64-windows-gnu   # to copy to a Windows machine
```

Flags: `--mode` (`type`, `scroll`, `drag`, `anim`, `heavy`, separated by
commas), `--runs`, `--events` (measured per run, after `--warmup`;
refreshes for `anim` and `heavy`), `--x`/`--y` (where the window opens),
`--boxes` (for `heavy`), `--seed` (the pauses between events: run `i` takes
`seed + i`).

## What a run does

Each run is a process of its own (`--run=MODE --myzig-hidden`), with an
800×600 window of native UI shown without taking the keyboard or the
front:

- `type`: a key into a text area every 60 to 140 ms (each frame after a pause);
- `scroll`: a list of a million rows scrolled as a trackpad does, gestures
  of 60 events one every 4 to 12 ms;
- `drag`: a box pressed, dragged 60 times by 3 points (30 right, 30 back),
  released;
- `anim`: a box crossing the window every second, no input;
- `heavy`: boxes casting wide shadows (30, `--boxes`), keeping the GPU busy.

An event arrives when it is posted to the main thread, so the time the main
thread was busy counts. The plans are `src/plan.zig`.

## Reading the figures

Each run prints the latency's mean and percentiles in milliseconds, and the
means of what it is made of: waiting for the main thread (queue), handling
the event (handle), from then to the frame's present (to present: waiting
for the display link's tick, building and painting, waiting for a
drawable), and from the present to the screen (to screen: the GPU, the
compositor, the display). And of the frames: how long the main thread
waited for drawables a frame and how often over 4 ms (macOS); what share of
the refreshes showed a new frame (all of them for `anim`, but for frames
not drawn in time); what share of the frames presented never showed on
their own, replaced by the next. The summary is each figure's median over
the runs: a run keeps the state the compositor settles in, which changes
from run to run, so compare medians of several runs, alternating builds.

## How it measures

**macOS** (as mygo's tool): the app is an accessory, its window ordered in
front without activating; App Nap is held off. Events go through the
window as AppKit's (`sendEvent:`, `scrollWheel:` with a trackpad's
continuous events). The tool swizzles the presents (the command buffer's
`presentDrawable:`, the drawable's `present`) to give each frame the events
handled before it, and adds a presented handler to each drawable: its
`presentedTime` is when the frame reached the screen (0: never, replaced).
It swizzles `-[CAMetalLayer nextDrawable]` for the main thread's waits
(myzig fetches drawables off the main thread, so they are rare).

**Windows**: the window shows with `SW_SHOWNOACTIVATE`, topmost so that
nothing covers it. Input is posted into the tool's own window (`WM_CHAR`,
`WM_MOUSEWHEEL` with a touchpad's small deltas, `WM_LBUTTONDOWN`,
`WM_MOUSEMOVE`, `WM_LBUTTONUP`) through a subclass of myzig's window
procedure that notes when handling began and ended; `SendInput` is not
used, since it types into whatever window is in front. Each frame shows the
number of the last event (or animation frame) in a probe square in the top
left corner (`src/probe.zig`); a thread reads that one pixel out of each
desktop image the compositor presents (DXGI desktop duplication,
`src/dup_windows.zig`), whose present time is when the frame reached the
screen. Frames present within the window procedure that drew them, or once
the swap chain has room, so "to present" is 0 and "to screen" counts from
the end of handling.

## Files

| file | |
|---|---|
| `src/main.zig` | the runs: one process each, their figures, the medians |
| `src/options.zig` | the command line, and a run's |
| `src/plan.zig` | what a run injects and when |
| `src/record.zig` | events, frames, samples; the figures of a run |
| `src/figures.zig` | the figures' line between processes, medians, percentiles |
| `src/view.zig` | the window by mode |
| `src/probe.zig` | the probe's colors and numbers (Windows) |
| `src/measure_mac.zig`, `measure_windows.zig`, `dup_windows.zig`, `measure_other.zig` | the platforms |
