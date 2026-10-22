# Windows inactive WebView2 memory, 2026-10-22

WebView2 pages request `MemoryUsageTargetLevel.Low` while their host
window is hidden/minimized, or their embedded native-UI view is clipped
out. Showing/restoring them requests `Normal`. Scripts, timers, IPC and
network connections continue; this does not suspend or reload pages.
Requests are cached, so ordinary resizes do not repeat COM writes.
Unsupported older runtimes quietly keep their existing behavior.

The ICoreWebView2_19 GUID and vtable slots were checked against the
official Microsoft.Web.WebView2 1.0.1823.32 SDK: get at 119, put at 120.
See [Microsoft's API reference](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2_19).

## Measurement

Windows 10 build 19045, Intel Core i5-1145G7 (4 cores / 8 threads),
Zig 0.17.0, ReleaseSmall. Saved before/after executables were run in
before/after then after/before order. Each launch had fresh TEMP and
LOCALAPPDATA directories. All windows remained hidden; no screen or
input automation was used, and no build ran concurrently with sampling.

Each launch supplied three process-counter samples, at two-second
intervals after the page's ready message. Tables combine the two
launches (six samples per version/case). Only the root Zig process and
its WebView2 processes are counted; console helpers are excluded.
The blank case ran hello with MYZIG_DEV_URL=about:blank; the frontend
case loaded hello's embedded HTML/CSS/JS. A JavaScript timer closed
each web case normally, confirming timers continued in low mode.

Private working set is resident private RAM. Private bytes are private
commit and may include paged-out memory. Shared DLL pages and GPU VRAM
are outside these totals. Low is a best-effort memory target, not a cap.

| case | private WS before (MiB) | after | change | private commit before (MiB) | after |
|---|---:|---:|---:|---:|---:|
| counter-hidden | 1.98 | 2.03 | +2.7% | 2.59 | 2.64 |
| webview-blank | 72.82 | 66.35 | -8.9% | 129.95 | 132.59 |
| webview-hello | 95.81 | 85.52 | -10.7% | 157.43 | 150.66 |

Individual launch medians, to show repeatability:

| pair | case | private WS before (MiB) | after |
|---|---|---:|---:|
| 1 | webview-blank | 72.96 | 67.10 |
| 1 | webview-hello | 96.91 | 86.61 |
| 2 | webview-blank | 72.78 | 66.14 |
| 2 | webview-hello | 95.48 | 84.48 |

The benefit is lower resident RAM for inactive pages. Private commit
does not fall by the same amount. These measurements do not establish
lower memory use for visible pages or a general frame-rate improvement.
Foreground first-paint/restore latency was not measured: the tests never
show a window. Normal-target restoration and subsequent IPC were checked
against the real WebView2 runtime while the host remained hidden.

## Profile isolation

Headless WebView2 profiles now use the run's temporary cache directory.
Normal launches retain `%LOCALAPPDATA%\<name>\WebView2`. Overflow
fails page creation instead of falling back to the working directory.
The pages and embedded-page test steps pass a no-op eval flag so they
also activate the existing headless temporary-directory mechanism.

## Size and validation

| app | ReleaseSmall before (bytes) | after | delta |
|---|---:|---:|---:|
| hello.exe | 1,254,912 | 1,256,960 | +2,048 |
| counter.exe | 1,147,904 | 1,148,416 | +512 |

- `zig build test test-pages lines -j1 --summary all`: 744 tests passed,
  24 skipped; hello, pages and embedded-webview integration checks passed.
- COM fakes verify normal/low transitions, duplicate-write suppression,
  balanced references, absent/old interfaces and retry after failures.
- A profile test verifies temporary isolation even with LOCALAPPDATA set
  and verifies failure for an undersized path buffer.
- A subsequent targeted run passed all four memory-target tests, including
  host visibility, embedded clipping and restoration during navigation.

## Native controls

ReleaseFast hillclimb controls used 300 frames and three repeats, with
labels `webview-memory-before-native-2026-10-22` and
`webview-memory-after-native-2026-10-22` in `history.jsonl`.

| scene | frame CPU before (ms) | after | render CPU before (ms) | after |
|---|---:|---:|---:|---:|
| list | 0.0657 | 0.0617 | 0.4490 | 0.4025 |
| dashboard | 0.0336 | 0.0339 | 1.7690 | 1.7688 |

These controls do not exercise WebView2 and establish no WebView speedup.
The earlier `boxes` CPU-rendering regression remains unresolved; this
change targets inactive WebView2 resident memory only.

## Recovery probe

Run `zig build test-page-memory -Doptimize=ReleaseSmall -j1 --summary all`
on Windows. Four fresh headless profiles ran sequentially in Normal,
restore, restore, Normal order. Distinct run identities preserve separate
logs in `zig-out/memory-probe/`, and the runs are not cached.

Each run first reloaded once to check policy reinstallation, then ran ten
cycles. The restore case requested Low; the control stayed Normal. Fetch
and IPC were checked, followed by two seconds without fetch or IPC before
timing the Normal request and its reply, then the first ping. The request
also reads the real ICoreWebView2_19 getter, not only our cached state.
Twenty subsequent pings checked steady IPC. Every cycle verified the
same DOM node, document time origin and an 8 MiB touched JS buffer.

All 40 cycles passed: 20 control and 20 restore. Each mode supplied 20
transition/first-ping samples and 400 subsequent ping samples. Timings
use `performance.now()` (about 0.1 ms resolution here); p95 is nearest
rank. Four separate log hashes are recorded with the
[raw samples](windows-webview-recovery-2026-10-22.jsonl).

| measurement (ms) | Normal median | p95 | restore median | p95 |
|---|---:|---:|---:|---:|
| Normal request + runtime readback | 1.30 | 1.40 | 1.25 | 1.50 |
| First subsequent ping | 0.80 | 1.10 | 0.85 | 1.40 |
| Both requests combined | 2.10 | 2.40 | 2.30 | 2.80 |
| Subsequent warm ping | 0.30 | 1.00 | 0.30 | 1.00 |

Maximum combined latency was 2.60 ms
for Normal and 3.10 ms for restore.
The observed combined median increased by 0.20 ms and p95 by 0.40 ms.
These are descriptive samples, not evidence of statistical significance
or a general foreground performance guarantee.
The runtime reported `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36 Edg/155.0.0.0`.

This short-idle test checks IPC recovery and state retention with the host
hidden. It does not measure visible first paint, animation, GPU uploads,
long-idle disk paging, or recovery under system memory pressure. It also
does not establish reduced RAM for a visible window. AGENTS.md prohibits
showing windows, so no foreground repaint claim is made. The earlier
inactive-RAM measurements remain the evidence for memory savings.
