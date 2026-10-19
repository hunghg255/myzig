# sqlite

SQLite for myzig apps, from Zig and from pages, after mygo's
[SQLite plugin](../../../mygo/docs/plugins/sqlite.md). It uses the system's
library, loaded when the first database opens (no C code, nothing to link
or ship):

| platform | library |
|---|---|
| Windows 10 and later | `winsqlite3.dll` (part of Windows), or `sqlite3.dll` |
| macOS | `/usr/lib/libsqlite3.dylib` |
| Linux | `libsqlite3.so.0` (`libsqlite3-0` / `sqlite-libs`) |

`MYZIG_SQLITE_LIBRARY` names another build.

## From Zig

```zig
const sqlite = @import("sqlite");

var db = try sqlite.Db.open("notes.db", .{}); // or ":memory:"
defer db.close();
try db.execScript("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, title TEXT, done INTEGER)");
const r = try db.exec("INSERT INTO notes(title, done) VALUES (?, ?)", .{ "Hello", false });
// r.changes == 1, r.last_insert_id == 1

const Note = struct { id: i64, title: []const u8, done: bool };
const notes = try db.all(Note, arena, "SELECT id, title, done FROM notes WHERE done = ?", .{false});
const first = try db.one(Note, arena, "SELECT * FROM notes WHERE id = ?", .{1}); // ?Note

try db.transaction(ctx, struct {
    fn body(d: *sqlite.Db, c: @TypeOf(ctx)) !void {
        _ = try d.exec("INSERT INTO notes(title, done) VALUES (?, 0)", .{c.title});
    }
}.body); // committed, or rolled back when body fails
```

- `exec`, `all` and `one` take one statement (a trailing `;` and comments
  are fine; more fails with `error.MultipleStatements`) and a tuple of
  arguments bound to `?1`, `?2`… (`:name`, `$name` and `@name` bind by
  their index too). Every parameter needs a value.
- Bound values: `null`, bools (0 or 1), integers (within `i64`), finite
  floats, text (`[]const u8`, valid UTF-8), `sqlite.blob(bytes)`, enums
  (their names), `sqlite.Value`, and optionals of these.
- Rows read into structs by column name: integers, floats, bools, enums
  (from text), `[]const u8` (copied), `sqlite.Value` and optionals (NULL).
  A field with a default may have no column, or NULL in it.
- `prepare` gives a `Statement` to bind (`bind`, `bindAll`), `step`,
  read (`int`, `float`, `text`, `bytes`, `value`, `read(T)`) and `reset`
  for reuse. `query` returns dynamic `Rows` of `Value`s.
- Errors are Zig errors (`error.Constraint`, `error.Busy`,
  `error.Interrupted`, `error.Sqlite`…); `db.diagnostics` has SQLite's
  extended code and message. `interrupt()` stops a running statement from
  another thread. `busy_timeout_ms` (5 s) is how long a statement waits
  for another connection's lock.
- A `Db` is used by one thread at a time.

## From pages

Bind the service and serve the client:

```zig
var service: sqlite.Service = .init(gpa, .{}); // .directory, .busy_timeout_ms
defer service.deinit();
try app.bind(&service);
// … .content = .{ .page = .{ .url = "/", .assets = &.{ index_html, sqlite.asset } } }
```

```js
import { open } from "/plugins/sqlite.js";

const db = await open("app.db"); // a file name in the app's data directory, or ":memory:"
await db.execute("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, title TEXT)");
const { changes, lastInsertId } = await db.execute("INSERT INTO notes(title) VALUES (?)", ["Hi"]);
const { columns, rows } = await db.query("SELECT id, title FROM notes WHERE id = ?", [lastInsertId]);
await db.transaction([{ sql: "DELETE FROM notes WHERE id = ?", params: [1] }]);
await db.close();
```

- Values as in mygo: `null`, numbers, strings, booleans (0 or 1),
  `bigint`s for integers past 2^53 (results give them as `bigint`s,
  `lastInsertId` always), and `Uint8Array`s (any `ArrayBuffer` view) for
  blobs. On the wire, what JSON can't carry travels as strings with its
  kind (`WireRows.special`), turned back by the client.
- Pages open file names, never paths: no directories, `..`, `:`, Windows'
  reserved names (`CON`, `COM1`…) or symbolic links. The directory is
  created for writable databases. `open(name, { readOnly: true })`.
- Their SQL is guarded: one statement per call, and no `BEGIN`/`COMMIT`/
  `SAVEPOINT` (use `transaction`, which is `BEGIN IMMEDIATE` and rolls
  back on any error), `ATTACH`, `DETACH` or `VACUUM INTO`.
- A connection belongs to the window that opened it: other windows can't
  use its id, and it closes when the window has closed (on the service's
  next call) or the service deinits.
- Calls run on the main thread, as myzig's bound methods do: keep queries
  short (`LIMIT`), as for any work on the main thread.

## Example and tests

`example/` is a notes page. `zig build run` runs it; nothing else here
shows a window.

```sh
zig build test        # the engine against the system's SQLite on temporary databases, and the page
zig build test -Dpage=false   # without the page (no webview needed)
zig build test-page   # the example's page alone, hidden, through the real webview (--myzig-eval)
zig build check -Dtarget=x86_64-linux-gnu   # type-check another platform
```
