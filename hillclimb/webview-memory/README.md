# webview-memory

The memory of one hidden window on `about:blank` in myzig, mygo and
Electron, on Windows: each app's process tree (the app and every
WebView2 or Chromium child), private bytes, the median of several runs.
Results and what they mean are in
[docs/benchmarks.md](../../docs/benchmarks.md); dated runs in
[notes/](../notes/).

No window is shown: myzig runs headless (`--myzig-eval`), mygo with
`Hidden: true`, Electron with `show: false`. Each app quits on its own
after nine seconds; `measure.ps1` stops one that does not.

Build the three apps first (one heavy build at a time):

```sh
zig build -Doptimize=ReleaseSmall                       # myzig: zig-out/bin/hello.exe
cd hillclimb/webview-memory/mygo-blank
go build -ldflags "-s -w -H windowsgui" -o mygo-blank.exe .   # mygo, from hillclimb/.mygo
cd ../electron-blank && npm install                     # Electron 38.8.6
```

`hillclimb/.mygo` is the clone `zig build run` in `hillclimb` makes;
`mygo-blank/go.mod` points there. Then:

```sh
powershell -ExecutionPolicy Bypass -File hillclimb/webview-memory/measure.ps1 -Runs 5
```

It prints a Markdown table: one row per kind of process, one column per
app. `-Myzig <exe>` measures another myzig build (a saved one, to compare
before and after a change); `-Settle <s>` waits longer before sampling.

Chromium flags apply to all three through the environment, without
changing them:

```sh
set WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--disable-gpu
```

(WebView2 reads it; Electron does not, it takes `app.commandLine`
switches.)
