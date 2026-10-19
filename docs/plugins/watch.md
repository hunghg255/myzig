# watch

File watching: `watch.Watcher` from Zig and native UI, and `watch(name)`
for pages, on the roots the app names, never on paths a page chooses.

The package is `plugins/watch` (module `watch`); it depends on
[mainthread](mainthread.md). See [Plugins](../plugins.md) for adding it to
an app. (myzig's core has a smaller watcher for one document's file,
`myzig.file_watch`; see [System](../system.md).)

## From Zig

```zig
const watch = @import("watch");

fn skipNodeModules(_: ?*anyopaque, path: []const u8, is_dir: bool) bool {
    return is_dir and std.mem.eql(u8, std.fs.path.basename(path), "node_modules");
}

const w = try watch.Watcher.init(gpa, io, project_dir, .{ .recursive = true, .ignore = skipNodeModules });
defer w.deinit();
while (true) { // on a thread or an Io task of its own
    const events = w.next(arena) catch break; // error.EndOfStream: closed, or what is watched went away
    for (events) |e| std.log.info("{t} {s}", .{ e.op, e.path }); // create, write, remove, rename (old_path)
}
```

- An event's `path` is relative to what is watched, with slashes; `.` is
  the watched path itself. What is there when the watch starts is not
  reported.
- The system's notifications are only hints: the watch then waits for
  quiet, looks again and reports what differs from what it saw. A file
  written many times is one `write`; one created and removed in between is
  nothing; a remove and a create of the same file id is a `rename`. Treat
  events as hints to read the files again.
- It does not look again until `next` is called: nothing piles up while
  the app is busy, and nothing is lost.
- A file is watched through its directory: written or replaced (as editors
  save) is a `write` of `.`, removed a `remove`. When what is watched (or a
  file's directory) is removed or replaced, the last batch has a `remove`
  of `.`, then `next` returns `error.EndOfStream`.
- `close()` (from any thread) ends a waiting `next`; `next` is also
  cancelable through `Io`.

`watch.Options`:

| field | default | |
|---|---|---|
| `recursive` | false | watch the directories inside too |
| `ignore`, `ignore_ctx` | null | `fn (ctx, path, is_dir) bool`: leaves paths out (an ignored directory is never opened) |
| `max_entries` | 8192 (65536 on macOS) | the most files and directories a watch covers |
| `debounce_ms` | 0 (50 ms) | quiet to wait for; negative reports at once |
| `max_delay_ms` | 500 | the longest changes wait while more keep coming |

`watch.scan` and `watch.diff` are the snapshots and their comparison that
the watcher is built on.

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
// ... .assets = &.{ index_html, watch.asset }
```

```js
import { watch, WatchError } from "/plugins/watch.js";

const watcher = await watch("project", { recursive: true, path: "src" }); // resolves once watched
for await (const events of watcher) {
  for (const e of events) console.log(e.op, e.path, e.oldPath, e.isDir);
}
// watcher.close(), break, or { signal }; watcher.closed settles once Zig stopped it
```

- A `watch.Root` has a `name` (lowercase letters, digits and dashes,
  starting with a letter), an absolute `path` that must exist (`init`
  fails otherwise), `recursive`, and its own `ignore`.
- A page's `path` is in the root, with slashes; it can't leave it nor go
  through a symbolic link. Recursive watches, and watches of a directory
  in the root, need a root with `recursive`.
- Errors are `WatchError`s with a `code`: `denied`, `not-found`, `limit`
  (too many watches, or too many entries), `path-encoding`, `io`.
- Zig takes the next batch once the page took the last.
- A window's watches stop once it has closed (on the service's next call
  or batch).

`watch.ServiceOptions`:

| field | default | |
|---|---|---|
| `roots` | none | what pages may watch |
| `allow`, `allow_ctx` | null | `fn (ctx, window, name, path, recursive) bool`, asked before each watch |
| `max_watches_per_page` | 8 | |
| `max_watches` | 128 | in all windows |

## Not yet

- mygo's `Resolve` (roots granted while the app runs): add roots to
  `roots` before `init`.
- Windows: renaming the watched directory itself is seen only at the next
  change in it (mygo also watches its parent).
- The macOS and Linux hints compile on every platform, but have run less
  than Windows'.

## Example and tests

`example/` watches a sandbox in the temporary directory, which the page
changes through Zig; `zig build run` shows it.

```sh
cd plugins/watch
zig build test               # snapshots, diffs and watchers on temporary directories, and the page, hidden
zig build test -Dpage=false
zig build check -Dtarget=x86_64-linux-gnu
```

The tests never sleep: they change files, then take batches until the
event they expect came (with debouncing off).
