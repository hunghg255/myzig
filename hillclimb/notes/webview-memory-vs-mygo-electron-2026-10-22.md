# WebView2 memory: myzig, mygo and Electron, 2026-10-22

The question: a myzig app with a page shows six WebView2 processes in Task
Manager (Windows 10), where an older build's screenshot (0.1.5, Windows 11)
showed the app alone at about 2 MB. Is it a regression?

No. myzig 0.1.5 and 0.1.7 start the same processes, and so do mygo and
every WebView2 app: they are the runtime's own (browser, GPU, network and
storage services, renderer, crash handler). Task Manager groups them under
the app or lists them apart as "Microsoft Edge WebView2" under background
processes depending on the Windows build and the runtime; the 2 MB was the
app's executable alone.

Windows 10 Pro 19045, Intel Core i5-1145G7, 32 GB. WebView2 Runtime
155.0.4283.62, Zig 0.17.0 ReleaseSmall, Go 1.27.2 (`-s -w`), Electron
38.8.6. No window was shown. Private bytes (private commit) of the whole
process tree, console hosts excluded; shared DLL pages and GPU memory are
outside the totals.

## 0.1.5 against 0.1.7

`hello` (its embedded frontend), headless, one sample each after 6 s:

| process (MiB) | 0.1.5 | 0.1.7 |
|---|---:|---:|
| hello.exe | 3.6 | 3.8 |
| browser | 33.4 | 32.3 |
| GPU | 66.3 | 51.8 |
| network | 11.1 | 11.7 |
| storage | 7.5 | 7.4 |
| renderer | 26.2 | 25.8 |
| crashpad | 2.4 | 2.4 |

The difference is 0.1.7's low memory target for hidden pages
([windows-webview-memory-2026-10-22.md](windows-webview-memory-2026-10-22.md)).

## myzig, mygo and Electron on about:blank

`hillclimb/webview-memory/measure.ps1 -Runs 5`, apps taking turns, the
median of five. mygo at 9c05b11.

| process (MiB) | myzig | mygo | Electron |
|---|---:|---:|---:|
| app | 3.7 | 47.4 | 36.3 |
| browser | 29.8 | 30.4 | (in app) |
| GPU | 51.8 | 50.9 | 77.1 |
| renderer | 19.4 | 23.5 | 22.6 |
| network | 11.5 | 11.2 | 13.1 |
| storage | 7.3 | 7.3 | (in browser) |
| crashpad | 2.4 | 2.4 | - |
| **total** | **127.2** | **173.7** | **149.0** |
| processes | 7 | 7 | 4 |

A second run of five, with myzig built to keep the normal memory target
while hidden (`page_memory.levelFor` returning `.normal`, the controller
kept visible), as a shown window would: myzig 130.7, mygo 173.7, Electron
152.3. On `about:blank` the hidden-page target saves little; with hello's
frontend it saved about 15 MiB.

On disk: myzig's hello.exe 1.2 MiB, mygo's 6.8 MiB, Electron's `dist`
324 MiB. The WebView2 runtime is the system's, shared by every app.

## Chromium flags

`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`, myzig hello (frontend, headless),
one sample each:

| flags | processes | total (MiB) |
|---|---:|---:|
| none | 7 | 131 |
| `--in-process-gpu` | 6 | 120 |
| `--enable-features=NetworkServiceInProcess2` | 6 | 128 |
| `--disable-gpu` | 7 | 93 |
| `--in-process-gpu --enable-features=NetworkServiceInProcess2 --disable-breakpad` | 5 | 110 |
| `--disable-gpu --in-process-gpu --enable-features=NetworkServiceInProcess2` | 5 | 80 |

(Totals exclude conhost; the earlier tables in the session included it.)
`--disable-features=StorageServiceOutOfProcess` and `--disable-breakpad`
changed nothing: storage and crashpad stay. `--disable-gpu` rasterizes on
the CPU (fine for forms and tables, costly for animation, long scrolling
lists, canvas and WebGL); the in-process flags trade isolation (a crash in
the GPU or network code takes the browser process down) and are Chromium
internals that a runtime update may drop.
