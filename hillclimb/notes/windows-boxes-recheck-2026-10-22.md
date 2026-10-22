# Windows boxes regression recheck, 2026-10-22

The earlier 13-14% CPU-render slowdown is not reproduced by this recheck.
No renderer algorithm was changed. Keep the existing OOM cleanup and GPU
ABI assertions. A separate benchmark reporting bug was fixed: automatic
delta columns now exclude runs with incompatible or unknown profiles.

This does not establish the cause of the historical slowdown. In
particular, the previous skill report used explicitly matched labels;
its old measurements cannot be explained away by the automatic-column bug.

## Method and results

Windows, Zig 0.17.0, ReleaseFast, CPU rendering, 900x640 at 2x, offscreen.
Only myzig was measured. All processes ran sequentially; no build ran
concurrently with timing. Exact old before/after executables from the
skill task were reused. The current executable was saved before changing
benchmark reporting. Draw-item counts stay at 1,201 for boxes.

The first 300-frame/three-repeat recheck used old-before/old-after/
old-after/old-before order. Render CPU was 9.4003/8.7879/8.7556/8.6945 ms;
the current executable then measured 8.6831 ms. These reproduce neither
the old slowdown nor a dependable speedup. The larger follow-up below
compares old-before with current in before/current/current/before order.
Each executable still selects the repeat with lowest median frame CPU,
as the benchmark has always done; that selection policy was not changed.

| mode | measured frames | repeats | before frame CPU (ms) | current | before render CPU (ms) | current | render change |
|---|---:|---:|---:|---:|---:|---:|---:|
| damaged | 600 | 5 | 0.1793 | 0.1973 | 9.1677 | 9.0362 | -1.4% |
| whole | 300 | 3 | 0.1662 | 0.1578 | 8.8443 | 8.7240 | -1.4% |

Entries are medians of two launches, not pooled frame samples. Frame CPU
still varies between launches (the long comparison's first pair is
slower, while its second pair is nearly equal); no frame-CPU improvement
is claimed. The render medians are within the repository's +/-5% noise
threshold. The result is "historical slowdown not reproduced", not
"renderer made faster" or proof that all timing variation is harmless.

## Reporting fix

History previously filtered only OS, allowing automatic comparisons across
whole/damaged, CPU/GPU, hashing, frame/repeat counts and build modes.
New entries include a profile with those options, partial-rendering
environment setting and output dimensions. Both delta columns filter by
that profile. Legacy entries remain intact for manual investigation;
their unknown modes exclude them from automatic comparisons.

- Four benchmark tests pass, including JSON metadata round-trip,
  incompatible profile rejection and allocation-failure cleanup.
- CLI integration used three-frame runs: damaged-first, whole,
  damaged-second, hash. Only damaged-second compared with damaged-first;
  whole/hash selected no incompatible prior run.

## Pixel verification

All eight scenes were checked with 30 measured frames and one repeat,
old-before versus the final reporting executable, damaged and whole.
All four hashes must agree for each scene. Hashing ran separately from
the timing comparisons above.

| scene | matching hash |
|---|---|
| boxes | `d59d8f0e922f2927` |
| text | `1c0b9f03c3295c7a` |
| scroll | `6f04769e5105955c` |
| list | `0f54ac5ca629d16d` |
| dashboard | `b46eadb3bf3ae4cd` |
| layout | `6c2e2ea1fd357108` |
| caret | `e477feb513efe279` |
| spinner | `f58fc572951eb98b` |

Only benchmark history/reporting/tests and documentation changed. Core
renderer code and application binaries were not rebuilt or modified for
this reporting fix. Benchmark tests, CLI comparisons, pixel checks,
formatting and the repository line limit were checked.

The reporting patch itself was checked in before/after/after/before
order (300 frames, three repeats): render median 9.1803 -> 9.2429 ms
(+0.7%, within timing noise).

[Raw runs and executable hashes](windows-boxes-recheck-2026-10-22.jsonl).
