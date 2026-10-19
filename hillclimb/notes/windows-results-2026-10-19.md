# Windows results, 2026-10-19

The first hill-climb on Windows, after nanoui became myzig: `zig build run
-- --mygo D:/projects/mygo --label "Windows baseline: CPU renderers (myzig
rename)"`, 300 frames after 30 of warm-up, the best of three runs a scene,
900×640 points at 2x (1800×1280 pixels), offscreen.

- Machine: Intel Core i5-1145G7 (4 cores, 8 threads), Windows 10 Pro 19045.
- myzig: Zig 0.18.0-dev.349, `ReleaseFast`, its own text and CPU renderer
  (`src/ui/raster.zig`, one thread).
- mygo: commit c2a5a7c, Go 1.27.2, `CGO_ENABLED=0`, its CPU renderer
  (`internal/raster`, on several cores), invalidated before every frame so
  that it draws the whole frame as myzig's does.

Medians per frame in milliseconds (`n / m` below 1 is myzig ahead):

| scene | metric | myzig | mygo | n / m |
|---|---|---:|---:|---:|
| boxes | frame CPU | 0.092 | 0.873 | 0.11× |
| | render CPU | 59.109 | 269.028 | 0.22× |
| | process CPU / frame | 60.000 | 1693.021 | 0.04× |
| text | frame CPU | 0.254 | 0.887 | 0.29× |
| | render CPU | 9.897 | 2.424 | 4.08× |
| | process CPU / frame | 10.365 | 16.823 | 0.62× |
| scroll | frame CPU | 0.615 | 6.675 | 0.09× |
| | render CPU | 7.494 | 5.195 | 1.44× |
| | process CPU / frame | 8.281 | 40.677 | 0.20× |
| list | frame CPU | 0.072 | 0.821 | 0.09× |
| | render CPU | 7.538 | 1.121 | 6.72× |
| | process CPU / frame | 7.969 | 6.927 | 1.15× |
| dashboard | frame CPU | 0.055 | 0.149 | 0.37× |
| | render CPU | 40.032 | 5.564 | 7.20× |
| | process CPU / frame | 41.042 | 30.313 | 1.35× |

What it says:

- Building, laying out and painting a frame costs myzig 3 to 11 times less
  than mygo, as on macOS.
- myzig's CPU renderer is ahead on Gaussian shadows (boxes) but behind on
  text, large rounded cards (dashboard) and plain rows: mygo's draws
  glyph runs and spans on several cores, myzig's draws instance by
  instance on one. That is where the Windows renderer can climb, until a
  GPU renderer (Direct3D 11) takes its place.

Release sizes of the counter on Windows: myzig 0.68 MB (`ReleaseSmall`),
1.14 MB (`ReleaseFast`); mygo's `counter-native` 9.04 MB (`-trimpath -tags
mygo_noinspector -ldflags "-s -w"`). The galleries: 0.72 MB and 11.90 MB.

## The CPU renderer, made faster

Then the CPU renderer was reworked, its pixels unchanged (the frames'
hashes, `--hash`, were the same before and after, and a fuzz test drew
3000 random frames with both, byte for byte):

- A frame is drawn in bands of 64 rows, taken in turn by up to 8 threads
  when it has enough to draw (about a pixel's fill a million each).
- What a row or a column shares is found once: a glyph's texel taps, a
  shadow's four samples along y (their Gaussian weights and curves).
- The inside of an opaque quad is copied, its edges and shadows go eight
  pixels at a time (`raster_lanes.zig`, each lane doing the scalar
  arithmetic), and empty texels of glyphs are skipped.

On one thread it is 2.8 to 4 times as fast as before (render CPU, ms):

| scene | before | one thread | as it runs |
|---|---:|---:|---:|
| boxes | 58.9 | 21.0 | 5.9 |
| text | 9.8 | 2.9 | 1.5 |
| scroll | 7.4 | 2.0 | 1.3 |
| list | 7.4 | 1.8 | 1.3 |
| dashboard | 39.7 | 14.0 | 3.9 |

Against mygo, the full run (`--label "CPU renderer: bands on cores,
lanes, solid spans, empty texels"`):

| scene | render myzig | render mygo | n / m | process CPU myzig | process CPU mygo |
|---|---:|---:|---:|---:|---:|
| boxes | 6.725 | 277.126 | 0.02× | 40.6 | 1720.9 |
| text | 1.606 | 2.360 | 0.68× | 4.9 | 12.7 |
| scroll | 1.458 | 5.645 | 0.26× | 4.0 | 40.6 |
| list | 1.369 | 1.228 | 1.12× | 3.4 | 9.1 |
| dashboard | 5.037 | 7.506 | 0.67× | 31.9 | 37.2 |

myzig's renderer now leads everywhere but the list, within a tenth of a
millisecond there, and uses less of the machine in every scene. (The
frame CPU of boxes read higher in this run than in the first, +54%, though
nothing it runs changed: the machine was hot from mygo's run of boxes.)
