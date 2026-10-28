# updater

Updates: check a manifest, download the new executable verifying its
SHA-256 and its signature, and put it in place of the running one (it runs
at the next launch, or now with `relaunch`), with the user's preferences; a
service for an update banner or window in a page; and the update window
that Mac users know from Sparkle, in native UI, on every platform.

The package is `plugins/updater` (module `updater`); it depends on
[mainthread](mainthread.md). See [Plugins](../plugins.md) for adding it to
an app, and [Updates](../updates.md) to sign and publish updates with
`myzig build`.

## The manifest

Each platform (and architecture) has its own manifest, a JSON file served
over HTTPS, which `myzig build` writes:

```json
{ "version": "2.0.0", "url": "app-2.0.0", "sha256": "<64 hex digits>", "signature": "<base64>", "notes": "Markdown", "date": "2026-10-19T08:00:00Z", "size": 1234567 }
```

- `url` is absolute or relative to the manifest's URL.
- Versions are semantic (`1.2.3`, `v1.2.3`, `2.0.0-beta.1`); only a newer
  one is an update (`updater.isNewer`).
- `signature` is the Ed25519 signature of the SHA-256, in base64, by the
  key of [`myzig keygen`](../cli.md#myzig-keygen). An updater given the
  public key (`public_key`) refuses a manifest without one, and a download
  it does not sign.
- `notes`, `date` and `size` are optional; a download larger than `size`,
  or than `max_size` (1 GiB), fails.
- Publish the executable first and the manifest last, so that an app never
  sees a manifest whose file is not there yet (`myzig build --upload` does).

## From Zig

```zig
const updater = @import("updater");

var client: std.http.Client = .{ .allocator = gpa, .io = io };
defer client.deinit();
var u: updater.Updater = .{ .gpa = gpa, .io = io, .client = &client, .manifest_url = url, .current = "1.4.2", .public_key = key };
u.cleanup(); // at startup: removes what the last update left
if (try u.check(arena)) |update| { // update.version, .notes, .size
    const staged = try u.download(arena, update, null); // <exe>.update, checksum and signature verified (removed if not)
    try u.install(staged);
    try u.relaunch(&.{}); // optional: start the new version, then quit
}
```

- `download` takes an optional `updater.Progress` (`ctx`, and
  `func(ctx, done, total)`, with `total` null when the server didn't say).
- `install` replaces the executable (`exe_path`, the running one when
  null). Windows lets a running executable be renamed (`MoveFileExW`;
  `Io.Dir.rename` refuses it) but not replaced, so
  it moves aside to `<exe>.old` first (and back if moving the new one in
  fails), which `cleanup` removes at the next start; on macOS and Linux the
  rename replaces it at once. The running app goes on as it was.
- Without `public_key`, the manifest's SHA-256 is the trust: serve it over
  HTTPS.
- Errors: `error.BadManifest`, `BadVersion`, `HttpStatus`,
  `ChecksumMismatch`, `TooLarge`, `SizeMismatch`, `Unsigned`,
  `BadSignature`, `BadPublicKey`, and the network's.
- `updater.Prefs` keeps the user's choices in `updater.json`:
  `automaticChecks` (on), `automaticDownloads` (off), `skippedVersion`,
  `lastCheck`; `Prefs.load`, `save`, `due(now, interval)`,
  `dueAt(now, interval, checked_since_launch)` and `offers(version)`.

## The service

```zig
var service: updater.Service = try .init(gpa, app, .{ .manifest_url = url, .current = version, .public_key = key });
defer service.deinit();
service.startBackgroundChecks(10_000); // in 10 s, then once a day, if the user lets it
```

Background checks run 10 seconds after launch, whenever the last check
was, then once a day while the app runs, so a version that came out since
the app last ran shows when it opens again. They don't offer a skipped
version (but the next one), and with automatic downloads they install
without asking. Checks and downloads run on a task of the app's `Io`;
their states reach the main thread ([mainthread](mainthread.md)), every
page, and native code following the service (`service.listener`, an
`updater.Listener`: the update window).

`updater.ServiceOptions`:

| field | default | |
|---|---|---|
| `manifest_url` | required | |
| `current` | required | the running version |
| `public_key` | null | the contents of `myzig-update.pub`: only updates it signs install |
| `exe_path` | null | the executable to replace; the running one |
| `prefs_dir` | null | where `updater.json` lives; the app's data directory |
| `interval_s` | 1 day | seconds between background checks |

## The update window

`updater.Window` is mygo's update window in native UI, so it needs no
webview, in apps of native UI and of pages alike. When a new version is
out, it shows its release notes (Markdown, with links that open in the
browser) and offers **Install Update**, **Remind Me Later** and **Skip
This Version**, with "Automatically download and install updates in the
future"; installing shows the download with a progress bar, then offers to
relaunch. Escape and Enter answer with the window's cancel and default
buttons.

```zig
var window: updater.Window = undefined;
window.init(&service, .{}); // follows the service; .language, .width, .height
defer window.deinit();
```

A "Check for Updates…" item of the app's menu, labeled
`updater.menuItemLabel("")` (in the language the app shows), calls
`window.checkForUpdates()`: it checks as the user asked, so the window
shows at once and says when the app is up to date or the check failed; it
shows updates the user skipped too. While a check is under way, calling it
again brings its window to the front. `updater.WindowView` is the
window's view alone, which a `ui.Tester` drives.

### Languages

The window speaks the user's language when the plugin has it: English,
Chinese (Simplified and Traditional), Dutch, French, German, Italian,
Japanese, Korean, Polish, Portuguese (Brazil), Russian, Spanish, Turkish
and Ukrainian, with their locales' decimal marks ("1,5 MB"); other
languages get English. Its texts are a catalog of `src/locales/*.json`,
checked at compile time ([Languages](../i18n.md)); `updater.Texts` says
them.

A window speaks the language the app shows (`i18n.locale()`, or
`WindowOptions.language`) when its check begins, and keeps it while it is
open. After `i18n.setLocale`, the next window takes the new one, as does
`menuItemLabel` then: an app that rebuilds its menu when its language
changes gets "Check for Updates…" in the new one.

## From pages

```zig
try app.bind(&service);
try app.registerEvent(updater.StateEvent);
```

```js
myzig.on("myzig-updater", (s) => {
  // s.kind: checking, upToDate, available (version, notes), downloading (done, total), ready, failed (message)
  // s.background: from a background check, not one the user asked for
});
await myzig.call("Updater.check");   // as the user asked: skipped versions too
await myzig.call("Updater.install"); // what the check found
await myzig.call("Updater.skip");    // background checks won't offer it again
await myzig.call("Updater.relaunch");
await myzig.call("Updater.setAutomaticChecks", false); // also setAutomaticDownloads, preferences()
```

## Not yet

- macOS `.app` bundles: the updater replaces one executable file, not a
  bundle (see [Updates](../updates.md#not-yet)), nor deltas.
- The window's app icon, and release notes laid out right to left in a
  window that is not.

## Example and tests

`example/` is version 1.0.0 of an app with an update banner, and a release
server on 127.0.0.1 (`example/releases.zig`) publishing 2.0.0. It updates a
pretend executable in the temporary directory, never itself.

```sh
cd plugins/updater
zig build test               # check, download, checksum, install, cleanup against the local server; the window's view and texts; the page, hidden
zig build test -Dpage=false
zig build check -Dtarget=x86_64-linux-gnu
```
