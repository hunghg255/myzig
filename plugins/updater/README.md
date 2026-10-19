# updater

Updates for myzig apps, after mygo's
[updater plugin](../../../mygo/docs/plugins/updater.md): check a manifest,
download the new executable verifying its SHA-256, put it in place of the
running one (it runs at the next launch, or now with `relaunch`), with the
user's preferences, signatures checked against the app's public key, a
service for an update banner or window in a page, and the update window in
native UI.

## The manifest

```json
{ "version": "2.0.0", "url": "app-2.0.0", "sha256": "<64 hex digits>", "notes": "Markdown", "size": 1234567 }
```

`url` is absolute or relative to the manifest's. Versions are semantic
(`1.2.3`, `v1.2.3`, `2.0.0-beta.1`); only a newer one is an update. Publish
the executable first, the manifest last, so an app never sees a manifest
whose file is not there yet. Each platform has its own manifest.

## From Zig

```zig
const updater = @import("updater");

var u: updater.Updater = .{ .gpa = gpa, .io = io, .client = &client, .manifest_url = url, .current = "1.4.2" };
u.cleanup(); // at startup: removes what the last update left
if (try u.check(arena)) |update| { // update.version, .notes, .size
    const staged = try u.download(arena, update, progress); // <exe>.update, checksum verified (removed if not)
    try u.install(staged);
    try u.relaunch(&.{}); // optional: start the new version, then quit
}
```

`install` replaces the executable. Windows lets a running executable be
renamed but not replaced, so it moves aside to `<exe>.old` first (put back
if the move of the new one fails), which `cleanup` removes on the next
start; on macOS and Linux the rename replaces it at once. The running app
goes on as it was.

`Prefs` keeps the user's choices in `updater.json` (automatic checks,
automatic downloads, the version skipped, the last check).

## From pages

```zig
var service: updater.Service = try .init(gpa, app, .{ .manifest_url = url, .current = version });
defer service.deinit();
try app.bind(&service);
try app.registerEvent(updater.StateEvent);
service.startBackgroundChecks(10_000); // when due (a day, interval_s) and the user lets it
```

```js
myzig.on("myzig-updater", (s) => {
  // s.kind: checking, upToDate, available (version, notes), downloading (done, total), ready, failed (message)
});
await myzig.call("Updater.check");   // as the user asked: skipped versions too
await myzig.call("Updater.install"); // what the check found
await myzig.call("Updater.skip");    // background checks won't offer it again
await myzig.call("Updater.relaunch");
await myzig.call("Updater.setAutomaticChecks", false); // also setAutomaticDownloads, preferences()
```

Background checks don't offer a skipped version, and with automatic
downloads install without asking. Checks and downloads run on a task of the
app's `Io`; their states reach every page through the main thread (package
[`mainthread`](../mainthread)).

## Signed updates and the update window

`myzig build` signs each platform's update with the key of `myzig keygen`
and writes its manifest (`"signature"`, the Ed25519 signature of the
SHA-256); give the updater the public key (`.public_key`) and it installs
only what that key signed. `updater.Window` is mygo's Sparkle-like update
window in native UI, with its release notes in Markdown and its texts in
15 languages (`src/locales/*.json`, an `i18n.Catalog`), in the language the
app shows when each check begins. See [the docs](../../docs/plugins/updater.md)
and [Updates](../../docs/updates.md).

## Not yet

- macOS `.app` bundles: this replaces one executable file, not a bundle;
  nor delta updates.

## Example and tests

`example/` is version 1.0.0 of an app with an update banner, and a release
server on 127.0.0.1 (`releases.zig`) publishing 2.0.0. It updates a
pretend executable in the temporary directory, never itself.

```sh
zig build test               # check, download, checksum, install, cleanup against the local server; the page, hidden
zig build test -Dpage=false
zig build check -Dtarget=x86_64-linux-gnu
```
