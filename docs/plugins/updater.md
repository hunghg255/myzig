# updater

Updates for an app, on every platform:

- checks a manifest;
- downloads the new executable, verifying its SHA-256 and its signature;
- puts it in place of the running one. It runs at the next launch, or now
  with `relaunch`.

It keeps the user's preferences, has a service for an update banner or
window in a page, and draws the update window Mac users know from Sparkle
in native UI.

The package is `plugins/updater` (module `updater`); it depends on
[mainthread](mainthread.md). See [Plugins](../plugins.md) for adding it to
an app, and [Updates](../updates.md) to sign and publish updates with
`myzig build`.

## The manifest

```json
{ "version": "2.0.0", "url": "app-2.0.0", "sha256": "<64 hex digits>", "signature": "<base64>", "notes": "Markdown", "date": "2026-10-19T08:00:00Z", "size": 1234567 }
```

Each platform and architecture has its own manifest: a JSON file served
over HTTPS, which `myzig build` writes.

| Field | |
|---|---|
| `version` | semantic (`1.2.3`, `v1.2.3`, `2.0.0-beta.1`); only a newer one is an update (`updater.isNewer`) |
| `url` | absolute, or relative to the manifest's URL |
| `sha256` | of the executable, 64 hex digits |
| `signature` | the Ed25519 signature of the SHA-256, in base64, by the key of [`myzig keygen`](../cli.md#myzig-keygen) |
| `notes`, `date`, `size` | optional |

- An updater given the public key (`public_key`) refuses a manifest
  without a signature, and a download the key did not sign.
- A download larger than `size`, or than `max_size` (1 GiB), fails.
- Publish the executable first and the manifest last. An app then never
  sees a manifest whose file is not there yet. `myzig build --upload` does
  this.

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

- `download` takes an optional `updater.Progress`: `ctx`, and
  `func(ctx, done, total)`. `total` is null when the server didn't say.
- `install` replaces the executable: `exe_path`, or the running one when
  null. The running app goes on as it was.
- Without `public_key`, the manifest's SHA-256 is the trust: serve it over
  HTTPS.
- Errors: `error.BadManifest`, `BadVersion`, `HttpStatus`,
  `ChecksumMismatch`, `TooLarge`, `SizeMismatch`, `Unsigned`,
  `BadSignature`, `BadPublicKey`, and the network's.
- `updater.Prefs` keeps the user's choices in `updater.json`:
  - `automaticChecks` (on), `automaticDownloads` (off), `skippedVersion`,
    `lastCheck`;
  - `Prefs.load`, `save`, `due(now, interval)`,
    `dueAt(now, interval, checked_since_launch)` and `offers(version)`.

<details>
<summary>How install replaces a running executable</summary>

- On macOS and Linux the rename replaces it at once.
- Windows lets a running executable be renamed (`MoveFileExW`;
  `Io.Dir.rename` refuses it) but not replaced. So it moves aside to
  `<exe>.old` first, and back if moving the new one in fails.
- `cleanup` removes `<exe>.old` at the next start.

</details>

## The service

```zig
var service: updater.Service = try .init(gpa, app, .{ .manifest_url = url, .current = version, .public_key = key });
defer service.deinit();
service.startBackgroundChecks(10_000); // in 10 s, then once a day, if the user lets it
```

| `updater.ServiceOptions` | Default | |
|---|---|---|
| `manifest_url` | required | |
| `current` | required | the running version |
| `public_key` | null | the contents of `myzig-update.pub`: only updates it signs install |
| `exe_path` | null | the executable to replace; the running one |
| `prefs_dir` | null | where `updater.json` lives; the app's data directory |
| `interval_s` | 1 day | seconds between background checks |

**Background checks**

- The first runs 10 seconds after launch, whenever the last check was. A
  version that came out since the app last ran shows when it opens again.
- Then once a day while the app runs.
- They don't offer a skipped version, but they offer the next one.
- With automatic downloads they install without asking.

Checks and downloads run on a task of the app's `Io`. Their states reach
the main thread ([mainthread](mainthread.md)) and every page. Native code
follows the service through `service.listener`, an `updater.Listener`: the
update window does.

## The update window

`updater.Window` is mygo's update window in native UI. It needs no
webview, so it works in apps of native UI and of pages alike.

```zig
var window: updater.Window = undefined;
window.init(&service, .{}); // follows the service; .language, .width, .height
defer window.deinit();
```

- When a new version is out, it shows its release notes: Markdown, with
  links that open in the browser.
- It offers **Install Update**, **Remind Me Later** and **Skip This
  Version**, with "Automatically download and install updates in the
  future".
- Installing shows the download with a progress bar, then offers to
  relaunch.
- Escape and Enter answer with the window's cancel and default buttons.

**A "Check for Updates…" menu item.** Label it
`updater.menuItemLabel("")`, in the language the app shows. It calls
`window.checkForUpdates()`, which checks as the user asked:

- the window shows at once;
- it says when the app is up to date or the check failed;
- it shows updates the user skipped too;
- while a check is under way, calling it again brings its window to the
  front.

`updater.WindowView` is the window's view alone, which a `ui.Tester`
drives.

### Languages

The window speaks the user's language when the plugin has it. Other
languages get English. The languages:

- English, Chinese (Simplified and Traditional), Dutch, French, German,
  Italian, Japanese, Korean, Polish, Portuguese (Brazil), Russian, Spanish,
  Turkish and Ukrainian;
- with their locales' decimal marks ("1,5 MB").

Its texts are a catalog of `src/locales/*.json`, checked at compile time
([Languages](../i18n.md)). `updater.Texts` says them.

- A window takes the language the app shows (`i18n.locale()`, or
  `WindowOptions.language`) when its check begins. It keeps it while it is
  open.
- After `i18n.setLocale`, the next window takes the new one, and so does
  `menuItemLabel`. An app that rebuilds its menu when its language changes
  gets "Check for Updates…" in the new one.

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
await myzig.call("Updater.availableVersion"); // what the last check found, "" for nothing (a badge, a settings row)
await myzig.call("Updater.relaunch");
await myzig.call("Updater.setAutomaticChecks", false); // also setAutomaticDownloads, preferences()
```

## Not yet

- macOS `.app` bundles: the updater replaces one executable file, not a
  bundle (see [Updates](../updates.md#not-yet)).
- Deltas.
- The window's app icon.
- Release notes laid out right to left in a window that is not.

## Example and tests

`example/` is version 1.0.0 of an app with an update banner. A release
server on 127.0.0.1 (`example/releases.zig`) publishes 2.0.0. The example
updates a pretend executable in the temporary directory, never itself.

```sh
cd plugins/updater
zig build test               # check, download, checksum, install, cleanup against the local server; the window's view and texts; the page, hidden
zig build test -Dpage=false
zig build check -Dtarget=x86_64-linux-gnu
```
