# Windows WebView2 experiments, 2026-10-22

Keep controller visibility synchronization for primary page windows.
Hidden/minimized hosts request IsVisible=false; showing/restoring them
requests true. Writes are deduplicated; failed writes can retry. Embedded
views retain their existing layout-driven visibility contract. The
previous Low-memory target remains in place.

Revert the 4 KiB call-local UTF-16 scratch buffer: faster isolated small
conversions did not produce a dependable end-to-end IPC improvement.
Page.execute again uses its original allocated UTF-16 conversion. There
is no retained scratch buffer or thread-local allocation.

## Inactive RAM

ReleaseSmall, Windows, Zig 0.17.0. Saved executables ran sequentially in
before/visibility/visibility/before order with fresh TEMP and LOCALAPPDATA
per launch. Both versions already include the prior Low-memory policy.
Three samples per launch were taken at two-second intervals after the
page-ready message; each table median combines six samples per version.
No build or other benchmark ran concurrently with sampling. The app and
its WebView2 descendants are counted, excluding console helpers. Private
working set is resident private RAM; private commit includes paged-out
memory. Shared DLL pages and GPU VRAM are outside these totals.

| case | private WS before (MiB) | after | change | private commit before (MiB) | after |
|---|---:|---:|---:|---:|---:|
| counter-hidden | 1.99 | 1.93 | -2.7% | 2.59 | 2.54 |
| webview-blank | 66.30 | 64.33 | -3.0% | 131.03 | 131.93 |
| webview-hello | 84.81 | 68.60 | -19.1% | 153.45 | 136.13 |

Individual hello launch medians, before -> after (MiB):

- Pair 1: 84.52 -> 68.73.
- Pair 2: 85.06 -> 68.48.

The repeated hello reduction is the reason for keeping visibility
synchronization. The small counter differences are not a claimed native
memory improvement. This does not establish lower RAM for a shown window.

## IPC experiments

The probe runs batches of eight concurrent echo calls, validates every
reply, warms up five batches, then measures five blocks per case. The
table shows block medians; lower is better. Small ASCII uses 1,600 calls
per block, Unicode 800, and a 64 KiB payload 160.

The scratch experiment used four launches per version, ordered
before/scratch/scratch/before twice, giving 20 blocks per version/case.
The visibility experiment then used fresh before/visibility/visibility/
before launches, giving ten blocks per version/case. Earlier unpaired
visibility checks are excluded from the comparison.

| case | heap control (ms) | scratch (ms) | scratch change | fresh visibility control (ms) | visibility (ms) |
|---|---:|---:|---:|---:|---:|
| ascii-small | 111.15 | 114.30 | +2.8% | 104.80 | 105.10 |
| unicode | 125.75 | 146.90 | +16.8% | 113.10 | 111.05 |
| large | 445.85 | 432.75 | -2.9% | 399.95 | 362.80 |

There is launch-to-launch timing noise. Scratch showed no convincing
overall gain, including a worse Unicode median, so it was rejected.
Visibility's fresh small/Unicode results are close to their controls;
no general IPC speedup is claimed. All payload validations passed.

## Recovery and timer tradeoff

`zig build test-page-memory -Doptimize=ReleaseSmall -j1 --summary all`
passed four fresh-profile launches: Normal, restore, restore, Normal.
All 40 cycles passed (20 control, 20 restore), including an initial reload,
real COM memory-target/controller-visibility readback, fetch, IPC, and
retention of the DOM node, document identity and an 8 MiB touched JS array.
Each mode also supplied 400 subsequent ping samples.

The idle timer requests two seconds, but can be delivered later when
rendering is hidden. Timing covers the Normal request, real runtime
readback and first subsequent ping. The host HWND remains hidden.

| measurement (ms) | Normal median | p95 | restore median | p95 |
|---|---:|---:|---:|---:|
| Normal request + first ping | 1.10 | 1.70 | 4.15 | 6.50 |
| Subsequent warm ping | 0.30 | 0.60 | 0.30 | 0.50 |

Maximum combined restore latency was 8.50 ms.
In a separate hello probe, five requested 2,000 ms timers had median
actual delays of 2002.2 ms before and
3000.3 ms after visibility synchronization.
Timers still run, but background cadence can change. This is a material
tradeoff of disabling rendering, consistent with Microsoft's
[IsVisible documentation](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2controller#get_isvisible).

These tests measure hidden-host IPC recovery, not visible first paint,
animation smoothness or GPU presentation. Long-idle recovery and system
memory pressure were not measured. AGENTS.md prohibits showing windows;
no foreground repaint claim is made.

## Size and validation

| app | ReleaseSmall before (bytes) | kept version | delta |
|---|---:|---:|---:|
| counter | 1,148,416 | 1,148,928 | +512 |
| hello | 1,256,960 | 1,256,960 | +0 |

Reusable IPC check: `zig build test-page-ipc -Doptimize=ReleaseSmall -j1`.
`zig build build-pages -Doptimize=ReleaseSmall -j1` installs the page
probe for external process-counter measurements.

Full validation: `zig build test test-pages test-page-ipc lines -j1 --summary all`.
26/26 build steps succeeded; 745 tests passed, 24 skipped. Hello, pages,
embedded-webview and batched IPC integration checks all passed. Controller
fakes cover duplicate writes, missing controllers and retry after failures;
the host-policy test checks hide/minimize/restore, including during load.

## Native controls

ReleaseFast, list/dashboard, 300 frames, three repeats. Four adjacent
runs used before/after/after/before order; each table entry is the median
of two launches. This replaces the initial, nonadjacent pair, whose
variation was not reproduced by the paired control. Labels in
[history](../history.jsonl):

- `webview-experiments-before-native-pair-a-2026-10-22`.
- `webview-experiments-after-native-pair-a-2026-10-22`.
- `webview-experiments-after-native-pair-b-2026-10-22`.
- `webview-experiments-before-native-pair-b-2026-10-22`.

| scene | frame CPU before (ms) | after | render CPU before (ms) | after |
|---|---:|---:|---:|---:|
| list | 0.1157 | 0.1157 | 0.6418 | 0.6628 |
| dashboard | 0.0746 | 0.0734 | 2.8779 | 2.8645 |

These controls do not exercise WebView2; no native speedup is claimed.

[Raw measurement samples and executable hashes](windows-webview-experiments-2026-10-22.jsonl).
