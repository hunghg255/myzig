# hillclimb

A terminal app, built on myzig as a library, that measures myzig against
[mygo](https://github.com/egoist/mygo) **without opening a window**: each
scene is built, laid out and painted frame after frame, then drawn by the
GPU into an offscreen texture, as a window's frames would be.

```sh
cd hillclimb
zig build run                                  # every scene, myzig and mygo
zig build run -- --label "what changed"        # name the run in history.jsonl
zig build run -- --scene text,list --only myzig --frames 600 --repeat 5
zig build run -- --mygo D:/projects/mygo       # clone mygo from a local checkout
zig build run -- --only myzig --hash           # and hash the CPU renderer's pixels
zig build run -- --only myzig --whole          # draw every frame whole, to compare
zig build run -- --only myzig --gpu            # Windows: Direct3D 11, timed by the GPU
```

On macOS the frames are drawn by Metal. On Windows and Linux both
frameworks' CPU renderers draw each frame into memory, so `render CPU`
takes the place of `encode CPU` and `GPU`, and mygo's renderer may use
several cores (`process CPU / frame` counts them all). myzig's draws only
what changed since the last frame, as a window's (`ui.damage`; `--whole`
draws every frame whole), mygo's every frame whole. On Windows, `--gpu`
has Direct3D 11 draw myzig's frames into a texture kept across frames, as
a window's swap chain, with the GPU's time from timestamp queries
(`render CPU` is then the time to encode them). Runs compare only with earlier runs of the same platform
(`history.jsonl` records each run's `os`). `--mygo` matters only for the
first run: delete `.mygo` to clone again. `--hash` prints, per scene, a
hash of every frame the CPU renderer drew: a change that makes it faster
must leave them as they were (with the same `--frames`).

Each scene runs 30 frames of warm-up, then 300 measured, three times; the
run with the lowest median frame is kept. The table shows, per scene:

| metric | what |
|---|---|
| frame CPU | building the view, layout, paint (median, p95), and myzig's three phases |
| encode CPU | uploading and encoding the frame for the GPU |
| GPU | the command buffer's GPU time (its timestamps) |
| process CPU / frame | the process's user + system time over the run, per frame |
| draw items | myzig's instances, mygo's scene operations |

and compares myzig with mygo (`n / m`), with myzig's previous run (`Δ
last`) and with its best (`Δ best`). Changes within ±5% are noise.

## Scenes

- **boxes**: 600 rounded, shadowed boxes moving and changing color.
- **text**: 300 labels whose numbers change every frame.
- **scroll**: a plain column of 1000 rows, clipped, moving every frame.
- **list**: a virtualized list of 100 000 rows, scrolled every frame.
- **dashboard**: 12 cards of text, a large number and a progress bar.
- **layout**: two columns of 10 cards of wrapping text and tags, one
  counter changing each frame: what layout keeps of what did not change.
- **caret**, **spinner** (myzig's only): a page of 108 cards that stays
  as it is but for a caret blinking or a small box turning: what drawing
  only what changed saves.

## mygo's twin

`mygo/` holds the files the tool copies into a clone of mygo (`.mygo`,
cloned on first run): a test running the same scenes through mygo's own
frames, a helper exposing mygo's offscreen Metal renderer, and per
platform the renderer they draw with (Metal on macOS, mygo's CPU renderer
elsewhere) and the clocks, all built only with the `myzig_hillclimb` tag,
so mygo's code is unchanged. Go 1.27
is fetched by `GOTOOLCHAIN=auto` if missing.

## Climbing

Change myzig, run, keep the change if the numbers climb, label it:
`history.jsonl` records every run. Shadows count GPU time honestly: both
draw Gaussian shadows (myzig's after GPUI's shader).
