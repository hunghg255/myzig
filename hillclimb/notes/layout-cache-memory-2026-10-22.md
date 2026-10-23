# Layout cache eviction, Windows, 2026-10-22

Keep the change: a cache sweep collects every expired entry before
removing it. Previously it removed at most 256 entries every 60 frames,
less than even the normal list scene introduces (two texts per row,
three new rows per frame). The backlog grew for as long as new rows
arrived. The sweep interval and two-frame grace period are unchanged;
live texts retain their buffers. The frame arena supplies larger scratch
lists, with the original stack batch as a fallback if allocation fails.

## Retained allocations

Windows, Zig 0.17.0, ReleaseFast, baseline commit `8c0b69b`. The
[probe](layout-cache-probe.zig) builds 6,000 frames of a 100,000-row
virtual list, scrolling three rows per frame, with two labels per row.
The view has 132 nodes at each sample, 900x640 points at 2x. It does not
rasterize or create a window.

`std.testing.FailingAllocator` with no failures configured counts the
Tester's successful allocations, frees, resizes and remaps. Live bytes
are allocated minus freed bytes. This includes all allocations through
the Tester's allocator, not just the layout cache. It excludes native
API allocations, allocator overhead, GPU memory and process working set.
Every run checks that the tracked allocations are freed on teardown.

Saved before/after executables ran sequentially in before/after/after/
before order. No build ran during measurement. Both runs of each version
gave the same allocation counts:

| At frame 6,000 | Before | After |
|---|---:|---:|
| Cache entries | 10,450 | 76 |
| Cache table capacity | 16,384 | 1,024 |
| Live requested bytes | 5,245,731 | 702,008 |
| Maximum live bytes sampled at frame boundaries | 5,284,531 | 756,506 |

Live requested memory fell 86.6% in this workload, about 4.33 MiB saved.
This is not an 86.6% reduction in an application's total RAM. After the
change the cache contained 76 entries at every 600-frame sample; entries
still accumulate between sweeps. The table retains its peak capacity,
so this does not promise to release capacity after a one-off large view.

The probe's median frame time averaged 0.09765 ms before and 0.08145 ms
after across the two launches (-16.6%). Timings from this small custom
view are separate from the standard hill-climb results below.
[Raw probe samples](layout-cache-memory-2026-10-22.json).

To reproduce on Windows, create a temporary build-options file containing
`pub const portable = false; pub const inspector = false;`, then run from
the repository root (quote `-M...` arguments in PowerShell):

```sh
zig run -O ReleaseFast -lc --dep myzig \
  -Mroot=hillclimb/notes/layout-cache-probe.zig \
  -O ReleaseFast --dep build_options -Mmyzig=src/myzig.zig \
  -Mbuild_options=/path/to/build_options.zig
```

## Standard hill climb

CPU rendering, 30 warm-up frames, 600 measured frames, three repeats;
the repeat with the lowest median frame time is kept. Saved executables
ran in before/after/after/before order. Entries below are averages of
the two launch medians, not pooled frame samples. Only labels
`cache-pair-{before,after}-{a,b}-2026-10-22` in
[history](../history.jsonl) supply these comparisons; the earlier
`cache-before-a-2026-10-22` run is excluded.

| Scene | Frame CPU before (ms) | After | Change | Render before (ms) | After |
|---|---:|---:|---:|---:|---:|
| list | 0.11120 | 0.10255 | -7.8% | 0.62730 | 0.61240 |
| scroll | 1.02425 | 1.02370 | -0.1% | 0.78430 | 0.78155 |
| layout | 0.16245 | 0.15710 | -3.3% | 0.85165 | 0.86700 |
| text | 0.40750 | 0.39615 | -2.8% | 0.98835 | 0.99590 |

List frame p95 was 0.16975 -> 0.15695 ms (-7.5%). Other scene and render
differences are within the repository's +/-5% noise threshold; no general
rendering speedup is claimed.

## Correctness and size

The new scrolling regression failed against the old code because stale
entries remained after a sweep, then passed with the fix. It compares
every node's rectangle with caching disabled and checks that live text
and wrap buffers survive multiple sweeps. A second regression checks
that a failed scratch allocation still evicts old entries safely.

Pixel checks use 90 measured frames after 30 warm-up frames, crossing a
sweep. Each hash agrees in all four runs: before/after, damaged/whole.

| Scene | Matching hash |
|---|---|
| list | `b1a6bdc3035baebe` |
| scroll | `813e5b3e61235a31` |
| layout | `262d17275aa1abfd` |
| text | `4ff5f8391e20f75a` |

ReleaseSmall Windows executable sizes, rebuilt before/after:

| App | Before (bytes) | After (bytes) | Delta |
|---|---:|---:|---:|
| counter | 1,149,952 | 1,149,952 | 0 |
| hello | 1,258,496 | 1,259,008 | +512 (+0.04%) |

Validation:

- `zig build test lines -j1 --summary all`: 21/21 steps succeeded,
  770 tests passed, 24 skipped, including the scratch-allocation failure
  regression and layout comparisons with caching disabled.
- `zig build size web test-web -Doptimize=ReleaseSmall -j1 --summary all`:
  23/23 steps succeeded. Counter, gallery and gestures passed headless
  Node checks of their WebAssembly builds.
- Formatting and the 600-line check passed. No macOS/Linux runtime tests
  were performed for this shared-code change.
