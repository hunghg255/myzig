# Windows results, 2026-10-20

`zig build run -Doptimize=ReleaseFast -- --whole`, Zig 0.17.0, against
mygo 9c05b11 (Go, `CGO_ENABLED=0`), both drawing every frame whole on
their CPU renderers: 300 frames after 30 of warm-up, the best of three
runs a scene, 900×640 points at 2x (1800×1280 pixels), offscreen. Intel
Core i5-1145G7 (4 cores, 8 threads), Windows 10 Pro 19045.

Before, myzig's CPU renderer was slower than mygo's in `scroll` and `list`.
About half its time there was the clear, a 9 MB `memset` on one core,
which the window's opaque background quad then wrote over again, and the
threads it started for each frame cost about what a small frame does.
Two changes, the pixels unchanged (`--hash`, damaged and whole, every
scene):

- The clear leaves the pixels the first instance sets to its fill
  whatever is under them, when it is an opaque quad whose corners nothing
  clips (`Frame.clearRows`, `raster_fill.zig`).
- Bands are drawn by threads started once, which wait for the next frame
  on a futex (`raster_pool.zig`), so a frame is worth sharing from 2¹⁸
  pixels' work a core instead of 2²⁰.

Medians per frame in milliseconds (`n / m` below 1 is myzig ahead):

| scene | render CPU before | after | mygo | n / m | process CPU after | mygo |
|---|---:|---:|---:|---:|---:|---:|
| boxes | 6.243 | 5.611 | 17.165 | 0.33× | 37.3 | 125.4 |
| text | 1.807 | 0.804 | 2.522 | 0.32× | 4.8 | 20.3 |
| scroll | 1.539 | 0.661 | 0.900 | 0.73× | 5.8 | 7.4 |
| list | 1.539 | 0.473 | 1.056 | 0.45× | 3.9 | 8.9 |
| dashboard | 4.921 | 4.346 | 6.740 | 0.64× | 27.7 | 34.2 |
| layout | 2.197 | 1.409 | 2.587 | 0.54× | 8.8 | 12.9 |

Frame CPU (build, layout, paint) is unchanged, 0.09–0.35× mygo's. More
cores draw a frame now, so process CPU grew where frames are small
(scroll 3.3 → 5.8, list 3.0 → 3.9) and is still below mygo's. Apps grew
1.5 KB (`counter`, `hello`, `ReleaseSmall`).
