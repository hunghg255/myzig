# sqlite

SQLite from Zig and from pages. The plugin uses the system's library,
loaded when the first database opens: no C code is compiled, nothing is
linked or shipped.

| platform | library |
|---|---|
| Windows 10 and later | `winsqlite3.dll` (part of Windows), or `sqlite3.dll` |
| macOS | `/usr/lib/libsqlite3.dylib` |
| Linux | `libsqlite3.so.0` (packages `libsqlite3-0`, `sqlite-libs`) |

`MYZIG_SQLITE_LIBRARY` names another build. Without a library, opening
fails with `error.SqliteMissing`.

The package is `plugins/sqlite` (module `sqlite`). See
[Plugins](../plugins.md) for adding it to an app.

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

`Db.open(path, options)` takes `OpenOptions`:

| field | default | |
|---|---|---|
| `read_only` | false | open without writing |
| `busy_timeout_ms` | 5000 | how long a statement waits for another connection's lock; 0 fails at once |
| `guarded` | false | refuse SQL that controls transactions, attaches files or loads extensions (for SQL pages send) |

### Statements and values

- `exec`, `all` and `one` take one statement (a trailing `;` and comments
  are fine; more fails with `error.MultipleStatements`; `execScript` runs
  several) and a tuple of arguments bound to `?1`, `?2`... (`:name`,
  `$name` and `@name` bind by their index too). Every parameter needs a
  value (`error.WrongParameterCount`).
- Bound values: `null`, bools (0 or 1), integers (within `i64`), finite
  floats, text (`[]const u8`, valid UTF-8), `sqlite.blob(bytes)`, enums
  (their names), `sqlite.Value`, and optionals of these.
- Rows read into structs by column name: integers, floats, bools, enums
  (from text), `[]const u8` (copied), `sqlite.Value` and optionals (NULL).
  A field with a default may have no column, or NULL in it.
- `prepare` gives a `Statement` to `bind` (or `bindAll`), `step`, read
  (`int`, `float`, `text`, `bytes`, `value`, `read(T)`), `reset` for reuse
  and `finalize`. `query` returns dynamic `Rows` of `Value`s;
  `execValues` binds a slice of `Value`s.
- `begin`, `commit`, `rollback` and `inTransaction` are there for
  transactions that `transaction` doesn't fit.

### Errors and threads

Errors are Zig errors: `error.Constraint`, `error.Busy`,
`error.Interrupted`, `error.InvalidSql`, `error.Sqlite`, and others named
in `sqlite.Error`; after `error.Sqlite`, `db.diagnostics` has SQLite's
extended code and `diagnostics.text()` its message. A `Db` is used by one
thread at a time; `interrupt()` stops a running statement from another.

## From pages

Bind the service and serve the client:

```zig
var service: sqlite.Service = .init(gpa, .{}); // .directory, .busy_timeout_ms
defer service.deinit();
try app.bind(&service);
// ... .content = .{ .page = .{ .url = "/", .assets = &.{ index_html, sqlite.asset } } }
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

- **Values:** `null`, numbers, strings, booleans (0 or 1), `bigint`s for
  integers past 2^53 (results give them as `bigint`s, `lastInsertId`
  always), and `Uint8Array`s (any `ArrayBuffer` view) for blobs. What JSON
  can't carry travels as strings with its kind, turned back by the client.
- **Names, never paths:** pages open file names in the service's
  `directory` (the app's data directory by default): no directories, `..`,
  `:`, Windows' reserved names (`CON`, `COM1`...) or symbolic links. The
  directory is created for writable databases; `open(name, { readOnly:
  true })` opens one read-only.
- **Guarded SQL:** one statement per call, and no `BEGIN`, `COMMIT` or
  `SAVEPOINT` (use `transaction`, which is `BEGIN IMMEDIATE` and rolls back
  on any error), `ATTACH`, `DETACH` or `VACUUM INTO`.
- **Per page:** a connection belongs to the page that opened it: other
  windows can't use its id, and it closes when the page navigates, reloads
  or closes, or the service deinits. A reloaded page opens its databases
  again.
- **The main thread:** calls run there, as all bound methods do; keep
  queries short (`LIMIT`).

`sqlite.ServiceOptions`: `directory` (null: the app's data directory),
`busy_timeout_ms` (5000).

## Example and tests

`example/` is a notes page; `zig build run` shows it.

```sh
cd plugins/sqlite
zig build test               # the engine against the system's SQLite on temporary databases, and the page
zig build test -Dpage=false  # without the page (no webview needed)
zig build test-page          # the example's page alone, hidden, through the real webview
zig build check -Dtarget=x86_64-linux-gnu
```
