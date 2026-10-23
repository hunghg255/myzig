# Animation cache eviction, Windows, 2026-10-22

Keep the change: the control animation cache drains all expired entries
at each sweep, instead of at most 64. A virtual list with one button per
row, scrolling three rows per frame, adds about 720 values per 120-frame
sweep (hover and press for each button). The previous batch could not
keep up. The sweep interval and 120-frame grace period are unchanged.

Keys are collected before removals so the map's iterator stays valid.
Up to 64 entries use stack scratch; larger caches use the frame arena.
If that allocation fails, the original stack batch still makes progress.
After removals, an in-place rehash clears tombstones without allocating.
It runs at frame end, after consumers have finished using value pointers.

The rehash matters: an initial full-sweep version without it retained
the same small allocation count but doubled the custom probe's median
frame time (about 0.045 to 0.093 ms). Repeated insertions and deletions
filled the small table with tombstones, slowing lookups for new ids.
The final version below includes the rehash.

## Retained allocations

Windows, Zig 0.17.0, ReleaseFast. The baseline is commit `8c0b69b` plus
the preceding [layout-cache fix](layout-cache-memory-2026-10-22.md).
The [probe](animation-cache-probe.zig) builds 6,000 frames of a 100,000-row
virtual list, scrolling three rows per frame, with a label and button in
each row. The view has 104 nodes at the samples, 900x640 points at 2x.
It does not create a window or rasterize.

`std.testing.FailingAllocator`, with no failures configured, counts all
allocations through the Tester's allocator. Live requested bytes are
allocated minus freed bytes; native API allocations, allocator overhead,
GPU memory and process working set are excluded. Teardown checks that
all tracked allocations have been freed.

Saved executables ran sequentially in before/after/after/before order,
with no build running during measurement. Each pair gave identical
allocation counts. [Raw samples](animation-cache-memory-2026-10-22.json).

| After 6,000 scrolling frames | Before | After |
|---|---:|---:|
| Animation entries | 32,900 | 770 |
| Expired entries | 32,136 | 6 |
| Table capacity | 65,536 | 2,048 |
| Live requested bytes | 2,219,043 | 669,337 |

Live requested memory fell 69.8%, saving 1,549,706 bytes (1.48 MiB) in
this workload, not 69.8% of an application's total RAM. The final cache
had 770 entries at every 600-frame sample. The Tester runs one initial
frame: each sample is one frame after a sweep, so six entries have
expired since it. The regression checks that none remain immediately
after a sweep. Recent offscreen entries retain the original grace period.

After hiding the list and running another 1,200 empty frames, the old
cache still held 32,260 expired entries; the final cache held none.
Live requested bytes were 2,206,998 versus 657,292. Table capacity and
frame scratch remain allocated for reuse; this does not shrink a table
after an arbitrary one-off large view.

Custom probe medians were 0.0463/0.0452 ms before and 0.0441/0.0450 ms
after. Their averages, 0.04575 and 0.04455 ms, differ by only 2.6%, within
the repository's 5% noise threshold. No general CPU speedup is claimed.

To reproduce, create a temporary build-options file containing
`pub const portable = false; pub const inspector = false;`, then run
from the repository root (quote `-M...` arguments in PowerShell):

```sh
zig run -O ReleaseFast -lc --dep myzig \
  -Mroot=hillclimb/notes/animation-cache-probe.zig \
  -O ReleaseFast --dep build_options -Mmyzig=src/myzig.zig \
  -Mbuild_options=/path/to/build_options.zig
```

## Correctness and size

The scrolling regression fails on the old code because expired entries
remain after a sweep. The final regressions check full sweeps, continuous
motion across sweeps, the exact 120-frame grace boundary, removal after
the view disappears, and progress with failed scratch allocation.

ReleaseSmall Windows executable sizes, rebuilt before and after:

| App | Before (bytes) | After | Delta |
|---|---:|---:|---:|
| counter | 1,149,952 | 1,150,464 | +512 |
| hello | 1,259,008 | 1,259,520 | +512 |

Validation:

- `zig build test lines -j1 --summary all`: 21/21 steps succeeded;
  773 tests passed, 24 skipped.
- `zig build size web test-web -Doptimize=ReleaseSmall -j1 --summary all`:
  23/23 steps succeeded. Counter, gallery and gestures passed their
  headless WebAssembly checks under Node.
- No macOS/Linux runtime tests were performed for this shared-code change.

## Standard hill climb

CPU rendering, 30 warm-up frames, 600 measured frames, three repeats;
the repeat with the lowest median frame time is kept. Saved executables
ran sequentially before/after/after/before. These are averages of the two
launch medians, not pooled samples. Only the four labels
`animation-pair-{before,after}-{a,b}-2026-10-22` in
[history](../history.jsonl) supply this comparison; the earlier
`animation-before-a-2026-10-22` run is not included.

| Scene | Frame CPU before (ms) | After | Change | Render before (ms) | After |
|---|---:|---:|---:|---:|---:|
| list | 0.10485 | 0.10340 | -1.4% | 0.61495 | 0.63095 |
| layout | 0.13470 | 0.13245 | -1.7% | 0.73040 | 0.71320 |
| dashboard | 0.06455 | 0.06435 | -0.3% | 2.70600 | 2.71805 |

Frame and render medians stay within the 5% noise threshold. These
standard scenes do not exercise the scrolling-button backlog; the
custom probe above establishes the memory improvement. Process CPU and
p95 readings were more variable across launches, so no general speedup
is claimed. The change is retained for bounded cache growth.
