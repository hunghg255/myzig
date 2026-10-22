# Benchmarks

What a myzig app costs next to [mygo](https://github.com/egoist/mygo),
which myzig is a port of, and [Electron](https://www.electronjs.org).
Native UI's frame times against mygo are the hill climb's
([hillclimb/README.md](../hillclimb/README.md)); binary sizes are in
[Testing, size and features](architecture-testing.md).

## Memory of a page window on Windows

One window on `about:blank`, the memory of the app's whole process tree
(the app and every WebView2 or Chromium process it started), private
bytes, the median of five runs:

| process (MiB) | myzig 0.1.7 | mygo | Electron 38 |
|---|---:|---:|---:|
| the app | 3.7 | 47.4 | 36.3 |
| browser (WebView2 Manager) | 29.8 | 30.4 | in the app |
| GPU | 51.8 | 50.9 | 77.1 |
| renderer (the page) | 19.4 | 23.5 | 22.6 |
| network service | 11.5 | 11.2 | 13.1 |
| storage service | 7.3 | 7.3 | in the browser |
| crash handler | 2.4 | 2.4 | none |
| **total** | **127.2** | **173.7** | **149.0** |
| processes | 7 | 7 | 4 |

| on disk | myzig | mygo | Electron |
|---|---:|---:|---:|
| what the app ships | 1.2 MiB (`hello.exe`) | 6.8 MiB | 324 MiB (its own Chromium) |

Windows 10 19045, Core i5-1145G7, WebView2 Runtime 155, myzig ReleaseSmall,
mygo at 9c05b11 built with Go 1.27 (`-s -w`). The windows were hidden; a
hidden myzig page asks WebView2 for its low memory target
([Pages](pages.md)), which on `about:blank` saves little: with the normal
target, as a shown window has, myzig's total was 130.7 MiB.

What it says:

- **Most of the memory is the browser engine's**, and it is the same
  engine for myzig and mygo: their WebView2 processes are within a few
  MiB of each other. Electron runs its own Chromium, with fewer processes
  (its main process is also the browser, and storage runs there) but a
  larger GPU process.
- **myzig's own part is about 4 MiB**: the executable, its allocations and
  the system DLLs it maps. mygo's Go runtime is about 47 MiB, Electron's
  main process (Node and the browser) about 36 MiB.
- A real page adds to the renderer and the GPU process what its DOM,
  scripts and images need, in every framework alike.

### Why Task Manager shows several processes

WebView2 is Chromium, and Chromium splits its work over processes so that
a crash or a compromised page stays in its own:

| in Task Manager | what it does |
|---|---|
| WebView2 Manager | the browser process: it starts and supervises the others |
| WebView2 GPU Process | compositing and drawing with the GPU |
| WebView2 Utility: Network Service | every network request |
| WebView2 Utility: Storage Service | localStorage, IndexedDB, the cache |
| WebView2: *page title* | the renderer: the page's DOM and JavaScript |

Every WebView2 app has them; myzig adds none. Some Windows builds and
runtime versions list them under the app, others apart, as "Microsoft Edge
WebView2" among the background processes, where the app then looks like a
few MiB. To compare builds, add the app and all its `msedgewebview2.exe`
processes in the Details tab, or run the script below, which follows the
process tree.

### Using less

Chromium takes flags from `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`, set
before the app starts. Measured with the hello example's frontend (one run
each, so a few MiB either way):

| flags | processes | total (MiB) |
|---|---:|---:|
| none | 7 | 131 |
| `--in-process-gpu` | 6 | 120 |
| `--disable-gpu` | 7 | 93 |
| `--disable-gpu --in-process-gpu --enable-features=NetworkServiceInProcess2` | 5 | 80 |

`--disable-gpu` draws the page on the CPU: fine for forms and tables,
slower for animation, long scrolling lists, canvas and WebGL. The
in-process flags merge the GPU or network work into the browser process,
so a crash there takes the page down, and they are Chromium internals a
runtime update may drop. The browser, renderer, storage service and crash
handler always run.

### Measuring it again

[hillclimb/webview-memory](../hillclimb/webview-memory/README.md) has the
three apps and `measure.ps1`, which runs them in turn without showing a
window and prints the table above. The dated results, with myzig 0.1.5
against 0.1.7, are in
[hillclimb/notes](../hillclimb/notes/webview-memory-vs-mygo-electron-2026-10-22.md).
