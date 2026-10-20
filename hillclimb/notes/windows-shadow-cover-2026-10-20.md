# A shadow under its opaque box, 2026-10-20

`zig build run -Doptimize=ReleaseFast -- --only myzig --scene
boxes,dashboard,text --repeat 5`, before and after in turn, twice, on
Windows (Intel Core i5-1145G7), drawing damaged regions as a window does.

A box's shadow is drawn just before the box. Where the box is an opaque
quad, its fill is copied over whatever is under it (`Inner`), so the
shadow's pixels there were computed (eight `erf` a pixel) and never seen.
The CPU renderer now leaves them (`raster_fill.zig`'s `Cover`), the
pixels unchanged (`--hash`, every scene; and a test drawing each pair with
and without it).

Render CPU per frame, median ms:

| scene | before (1) | after (1) | before (2) | after (2) |
|---|---:|---:|---:|---:|
| boxes | 8.433 | 7.633 | 8.683 | 8.867 |
| dashboard | 3.937 | 2.706 | 4.179 | 2.696 |
| text | 0.984 | 0.922 | 1.132 | 0.953 |

`dashboard` (large cards, wide shadows) is a third faster, process CPU
about 30% less. `boxes` (24-point boxes, 4-point blur) has little inside
its boxes to leave and is within the noise; the machine was noisy that
day (the same `boxes` ran 6.0 ms in the morning). Apps grew 0.5 KB
(`counter`) and 1 KB (`hello`), `ReleaseSmall`.
