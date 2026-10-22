# Windows Zig skill adoption, 2026-10-22

Zig 0.17.0, Windows 10 build 19045, Intel Core i5-1145G7
(4 cores, 8 logical processors). These are myzig's CPU renderer runs;
neither mygo nor GPU timings were measured in this comparison.

## Changes

- Use `Allocator.print` in shared IPC/page code and the benchmark, and
  `std.lang.Optimize` in the benchmark build.
- Assert the shared GPU instance's 96-byte layout and every field offset
  at compile time, for all backends.
- Clean up partially allocated phase timing buffers with `errdefer`.
  The regression test reproduced a 56-byte leak when the second of
  three seven-sample allocations failed; all allocation-failure paths
  now pass `checkAllAllocationFailures`.
- Add `zig build size` for counter/hello size checks, a benchmark test
  step, and README guidance on applying the three local Zig skills.

The existing outline/input/context changes were present in the working
tree and were not edited by this work. This is an API and safety change,
not a renderer optimization.

## Method

`ReleaseFast`, 900x640 points at 2x (1800x1280 pixels), offscreen:
30 warm-up frames, 300 measured frames, three repeats per scene; the
repeat with the lowest median frame CPU is kept, as in the normal
hillclimb. Timings below are milliseconds per frame; lower is better.
Damaged runs draw only changed regions; whole runs use `--whole`.
The order was before/after for damaged, then after/before for whole.
Hash checks ran separately with 30 measured frames and one repeat, so
hashing is excluded from the timing tables.

Only `skills-verified-{before,after}-{damaged,whole}-2026-10-22`
entries in [history.jsonl](../history.jsonl) supply timing data here.
The corresponding `skills-verified-*-hash-*` entries supply hashes.
Earlier `skills-before-*`, `skills-after-*` and `skills-control-*`
trial runs were removed from the history: some direct runs used an
older installed executable. `zig build run` runs the cache artifact, so both exact
cache executables were saved and used for all verified runs. To use
`zig-out/bin/hillclimb` directly, install it with `zig build` first.
The terminal's automatic delta columns also mix modes; use these
explicitly matched labels instead.

## Changed regions

| scene | frame before | frame after | render before | render after | render delta |
|---|---:|---:|---:|---:|---:|
| boxes | 0.1090 | 0.1447 | 6.0578 | 8.1180 | +34.0% |
| text | 0.3222 | 0.3275 | 0.8725 | 0.8690 | -0.4% |
| scroll | 0.8500 | 0.8255 | 0.6960 | 0.6482 | -6.9% |
| list | 0.0810 | 0.0907 | 0.5289 | 0.6662 | +26.0% |
| dashboard | 0.0581 | 0.0462 | 2.6546 | 2.2660 | -14.6% |
| layout | 0.1470 | 0.1199 | 0.7767 | 0.6380 | -17.9% |
| caret | 0.0902 | 0.0914 | 0.0761 | 0.0775 | +1.8% |
| spinner | 0.0929 | 0.0919 | 0.1963 | 0.1915 | -2.4% |

## Whole frames

| scene | frame before | frame after | render before | render after | render delta |
|---|---:|---:|---:|---:|---:|
| boxes | 0.1471 | 0.1410 | 8.6650 | 7.5254 | -13.2% |
| text | 0.3371 | 0.3131 | 0.9873 | 0.8327 | -15.7% |
| scroll | 0.8323 | 0.8000 | 0.6443 | 0.6154 | -4.5% |
| list | 0.0752 | 0.0733 | 0.4971 | 0.4973 | +0.0% |
| dashboard | 0.0609 | 0.0587 | 3.2607 | 3.1927 | -2.1% |
| layout | 0.1935 | 0.1899 | 1.5088 | 1.4329 | -5.0% |
| caret | 0.1559 | 0.1501 | 5.6943 | 5.4108 | -5.0% |
| spinner | 0.1518 | 0.1671 | 5.5443 | 6.0747 | +9.6% |

## Targeted timing controls

The largest damaged-mode changes were checked again with only boxes
and list: 300 measured frames, three repeats, in before A / after A /
after B / before B order, using the same saved executables.

| run | scene | frame CPU | render CPU |
|---|---|---:|---:|
| before A | boxes | 0.2504 | 8.7910 |
| before A | list | 0.1500 | 0.7571 |
| after A | boxes | 0.2497 | 9.9807 |
| after A | list | 0.1562 | 0.8163 |
| after B | boxes | 0.2506 | 10.8927 |
| after B | list | 0.1549 | 0.7599 |
| before B | boxes | 0.2462 | 9.5261 |
| before B | list | 0.1575 | 0.7667 |

Boxes render CPU is 13.5% and 14.3% slower in these two control pairs;
list is +7.8% and -0.9%. Frame CPU stays within 5% in both scenes.
The boxes result remains an unresolved timing regression in this
benchmark comparison; it is not dismissed as ordinary +/-5% noise.

Follow-up: the [longer paired recheck](windows-boxes-recheck-2026-10-22.md)
did not reproduce this render slowdown. The historical observations above
remain unchanged; the follow-up does not establish their cause. It also
fixes automatic history comparisons between incompatible modes, a separate
reporting issue rather than a proven explanation of these matched runs.

There is no consistent speedup across scenes and modes. Several changes
exceed the usual +/-5% noise threshold, in both directions; this run
does not establish a performance improvement or rule out a regression.
The change is retained for the demonstrated OOM cleanup and ABI checks,
not as a performance win.

## Pixels and binary size

All eight pixel hashes match before/after, and damaged/whole, with the
same frame count. Draw-item counts in matched timing runs also agree.

| scene | hash (all four checks) |
|---|---|
| boxes | `d59d8f0e922f2927` |
| text | `1c0b9f03c3295c7a` |
| scroll | `6f04769e5105955c` |
| list | `0f54ac5ca629d16d` |
| dashboard | `b46eadb3bf3ae4cd` |
| layout | `6c2e2ea1fd357108` |
| caret | `e477feb513efe279` |
| spinner | `f58fc572951eb98b` |

`ReleaseSmall` native Windows executables, measured before/after:

| app | before (bytes) | after (bytes) | delta |
|---|---:|---:|---:|
| counter.exe | 1,147,904 | 1,147,904 | +0 |
| hello.exe | 1,254,912 | 1,254,912 | +0 |

Rebuild sizes with `zig build size -Doptimize=ReleaseSmall -j1` at the
repository root. Benchmark commands from `hillclimb/`:

```sh
zig build run -Doptimize=ReleaseFast -j1 -- --only myzig --frames 300 --repeat 3 --label "change-damaged"
zig build run -Doptimize=ReleaseFast -j1 -- --only myzig --frames 300 --repeat 3 --whole --label "change-whole"
zig build run -Doptimize=ReleaseFast -j1 -- --only myzig --frames 30 --repeat 1 --hash --label "change-hash-damaged"
zig build run -Doptimize=ReleaseFast -j1 -- --only myzig --frames 30 --repeat 1 --hash --whole --label "change-hash-whole"
```

## Validation

- Native Windows framework/examples: 739 tests passed, 24 skipped
  (`zig build test -j1 --summary all`).
- Benchmark timing-buffer OOM test: passed, after first reproducing
  the original partial-allocation leak.
- Counter/gallery browser builds and headless Node checks: passed
  (`zig build web test-web -j1 --summary all`).
- Shared GPU layout type-checked for x86_64 Linux and aarch64 macOS
  with `zig build-obj`, a repository-root wrapper and build_options;
  these were compile-only checks, not full backend/runtime tests.
- Before the core edit all 24 examples built in ReleaseSmall; after
  the edit the size step rebuilt counter and hello successfully.
