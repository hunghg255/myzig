# watch

File watching for myzig apps, after mygo's
[watch plugin](../../../mygo/docs/plugins/watch.md) and `mygo.WatchFiles`:
`Watcher` from Zig and native UI, and `watch(name)` for pages, on the
roots the app names, never paths.

## From Zig

```zig
const watch = @import("watch");

const w = try watch.Watcher.init(gpa, io, project_dir, .{ .recursive = true, .ignore = skipNodeModules });
defer w.deinit();
while (true) { // on a thread or an Io task of its own
    const events = w.next(arena) catch break; // error.EndOfStream: closed, or what is watched went away
    for (events) |e| std.log.info("{t} {s}", .{ e.op, e.path }); // create, write, remove, rename (old_path)
}
```

- An event's `path` is relative to what is watched, with slashes; `.` is
  itself. What is there when the watch starts is not reported.
- The system's notifications are only hints: the watch then waits for
  quiet (`debounce_ms`, 50 ms; negative reports at once; never more than
  `max_delay_ms`, 500 ms), looks again and reports what is different from
  what it saw. A file written many times is one write; one created and
  removed in between is nothing; a remove and a create of the same file id
  is a rename. Treat events as hints to read the files again.
- It does not look again until `next` is called: nothing piles up while
  the app is busy, and nothing is lost.
- A file is watched through its directory: written or replaced (as editors
  save) is a `write` of `.`, removed a `remove`. When what is watched (or a
  file's directory) is removed or replaced, the last batch has a `remove`
  of `.`, then `next` returns `error.EndOfStream`.
- `ignore` leaves out paths (an ignored directory is never opened);
  `max_entries` (8192, 65536 on macOS) limits what a watch covers.
- `close()` (any thread) ends a waiting `next`; `next` is also `Io`-cancelable.

| platform | hints |
|---|---|
| Windows | one overlapped `ReadDirectoryChangesW` on the directory (its tree when recursive) |
| Linux | inotify, a watch per directory seen |
| macOS | FSEvents, one stream for the tree, file-level events |

## From pages

```zig
var service: watch.Service = try .init(gpa, app.io, .{ .roots = &.{
    .{ .name = "project", .path = project_dir, .recursive = true },
    .{ .name = "settings", .path = settings_file },
} });
defer service.deinit();
try app.bind(&service);
try app.registerEvent(watch.BatchEvent);
// … .assets = &.{ index_html, watch.asset }
```

```js
import { watch, WatchError } from "/plugins/watch.js";

const watcher = await watch("project", { recursive: true, path: "src" }); // resolves once watched
for await (const events of watcher) {
  for (const e of events) console.log(e.op, e.path, e.oldPath, e.isDir);
}
// watcher.close(), break, or { signal }; watcher.closed settles once Zig stopped it
```

- Root names are lowercase letters, digits and dashes; their paths must
  be absolute and exist (`init` fails otherwise).
- `path` is in the root, with slashes; it can't leave it nor go through a
  symbolic link. Recursive watches, and watches of a directory in it, need
  a root with `recursive`.
- Errors are `WatchError`s with `code`: `denied`, `not-found`, `limit`
  (8 watches per page, 128 in all, or too many entries), `path-encoding`,
  `io`.
- Zig takes the next batch once the page took the last.
- `Options.allow` sees each watch (window, root, path, recursive).
- A window's watches stop once it has closed (on the service's next call
  or batch).

## Not yet

- mygo's `Resolve` (roots granted while the app runs): add roots to
  `options.roots` before `init`, or extend the service.
- Windows: renaming the watched directory itself is seen only at the next
  change in it (mygo also watches its parent).
- macOS and Linux hints are compiled here but were not run (this machine
  is Windows).

## Example and tests

`example/` watches a sandbox in the temporary directory that the page
changes through Zig. `zig build run` shows it.

```sh
zig build test               # snapshots, diffs and watchers on temporary directories, and the page, hidden
zig build test -Dpage=false
zig build check -Dtarget=x86_64-linux-gnu
```

Tests never sleep: they change files, then take batches until the event
they expect came (debouncing off).
