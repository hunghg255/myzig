# sqlite

SQLite cho Zig và cho trang web. Plugin dùng thư viện của hệ thống, nạp khi database đầu tiên được mở. Không có code C nào được biên dịch, và không có gì bị link hay đóng gói kèm.

| nền tảng | thư viện |
|---|---|
| Windows 10 trở lên | `winsqlite3.dll` (có sẵn trong Windows), hoặc `sqlite3.dll` |
| macOS | `/usr/lib/libsqlite3.dylib` |
| Linux | `libsqlite3.so.0` (package `libsqlite3-0`, `sqlite-libs`) |

- `MYZIG_SQLITE_LIBRARY` chỉ định một bản build khác.
- Không có thư viện thì việc mở database thất bại với `error.SqliteMissing`.

Package là `plugins/sqlite` (module `sqlite`). Xem [Plugin](../plugins.md) để biết cách thêm vào app.

<a id="from-zig"></a>

## Dùng từ Zig

```zig
const sqlite = @import("sqlite");

var db = try sqlite.Db.open("notes.db", .{}); // hoặc ":memory:"
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
}.body); // được commit, hoặc rollback khi body thất bại
```

`Db.open(path, options)` nhận `OpenOptions`:

| `OpenOptions` | Mặc định | |
|---|---|---|
| `read_only` | false | mở mà không ghi |
| `busy_timeout_ms` | 5000 | thời gian một câu lệnh chờ khóa của connection khác; 0 thì thất bại ngay |
| `guarded` | false | từ chối SQL điều khiển transaction, attach file hoặc nạp extension (cho SQL do trang gửi) |

<a id="statements-and-values"></a>

### Câu lệnh và giá trị

**Một câu lệnh.** `exec`, `all` và `one` nhận một câu lệnh và một tuple tham số.

- Dấu `;` ở cuối và comment đều được. Nhiều câu lệnh hơn thì thất bại với `error.MultipleStatements`. `execScript` chạy được nhiều câu.
- Tham số bind vào `?1`, `?2`... `:name`, `$name` và `@name` cũng bind theo chỉ số của chúng.
- Mọi tham số đều phải có giá trị (`error.WrongParameterCount`).

**Giá trị bind được:** `null`, bool (0 hoặc 1), số nguyên (trong phạm vi `i64`), số thực hữu hạn, chữ (`[]const u8`, UTF-8 hợp lệ), `sqlite.blob(bytes)`, enum (theo tên), `sqlite.Value`, và optional của các kiểu này.

**Dòng kết quả** được đọc vào struct theo tên cột.

- Kiểu trường: số nguyên, số thực, bool, enum (từ chữ), `[]const u8` (được sao chép), `sqlite.Value` và optional (NULL).
- Trường có giá trị mặc định có thể không có cột tương ứng, hoặc cột đó là NULL.

**Mức thấp hơn**

- `prepare` trả về một `Statement`. Bạn có thể `bind` (hoặc `bindAll`), `step`, đọc (`int`, `float`, `text`, `bytes`, `value`, `read(T)`), `reset` để dùng lại và `finalize`.
- `query` trả về `Rows` động gồm các `Value`. `execValues` bind một slice các `Value`.
- `begin`, `commit`, `rollback` và `inTransaction` dành cho các transaction mà `transaction` không phù hợp.

<a id="errors-and-threads"></a>

### Lỗi và thread

- Lỗi là lỗi Zig: `error.Constraint`, `error.Busy`, `error.Interrupted`, `error.InvalidSql`, `error.Sqlite`, và các lỗi khác có tên trong `sqlite.Error`.
- Sau `error.Sqlite`, `db.diagnostics` có mã lỗi mở rộng của SQLite và `diagnostics.text()` có thông báo lỗi.
- Mỗi lúc chỉ một thread dùng một `Db`. `interrupt()` dừng câu lệnh đang chạy từ một thread khác.

<a id="from-pages"></a>

## Dùng từ trang web

Bind service và phục vụ client:

```zig
var service: sqlite.Service = .init(gpa, .{}); // .directory, .busy_timeout_ms
defer service.deinit();
try app.bind(&service);
// ... .content = .{ .page = .{ .url = "/", .assets = &.{ index_html, sqlite.asset } } }
```

```js
import { open } from "/plugins/sqlite.js";

const db = await open("app.db"); // tên file trong thư mục dữ liệu của app, hoặc ":memory:"
await db.execute("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, title TEXT)");
const { changes, lastInsertId } = await db.execute("INSERT INTO notes(title) VALUES (?)", ["Hi"]);
const { columns, rows } = await db.query("SELECT id, title FROM notes WHERE id = ?", [lastInsertId]);
await db.transaction([{ sql: "DELETE FROM notes WHERE id = ?", params: [1] }]);
await db.close();
```

| `sqlite.ServiceOptions` | Mặc định | |
|---|---|---|
| `directory` | null | nơi chứa database của trang; null là thư mục dữ liệu của app |
| `busy_timeout_ms` | 5000 | |

**Giá trị**

- `null`, số, chuỗi, boolean (0 hoặc 1), và `Uint8Array` (bất kỳ view nào của `ArrayBuffer`) cho blob.
- `bigint` cho số nguyên vượt quá 2^53. Kết quả trả chúng về dạng `bigint`, và `lastInsertId` luôn là `bigint`.
- Những gì JSON không chở được thì đi dưới dạng chuỗi kèm loại của nó. Client chuyển nó về lại.

**Tên file, không bao giờ là đường dẫn.** Trang mở các tên file trong `directory` của service.

- Không thư mục, không `..`, không `:`, không tên dành riêng của Windows (`CON`, `COM1`...) và không symbolic link.
- Thư mục được tạo ra cho database có thể ghi.
- `open(name, { readOnly: true })` mở database ở chế độ chỉ đọc.

**SQL có bảo vệ.** Mỗi lần gọi một câu lệnh. Những câu sau bị từ chối:

- `BEGIN`, `COMMIT` hoặc `SAVEPOINT`. Hãy dùng `transaction`, tức `BEGIN IMMEDIATE` và rollback khi có bất kỳ lỗi nào.
- `ATTACH`, `DETACH` hoặc `VACUUM INTO`.

**Theo từng trang.** Một connection thuộc về trang đã mở nó.

- Cửa sổ khác không dùng được id của nó.
- Nó đóng khi trang điều hướng, reload hoặc đóng, hoặc khi service deinit.
- Trang reload thì mở lại database của mình.

**Main thread.** Các lời gọi chạy trên main thread, như mọi method đã bind. Hãy giữ truy vấn ngắn (`LIMIT`).

<a id="example-and-tests"></a>

## Ví dụ và test

`example/` là một trang ghi chú. `zig build run` cho xem nó.

```sh
cd plugins/sqlite
zig build test               # engine chạy với SQLite của hệ thống trên database tạm, và trang web
zig build test -Dpage=false  # không có trang (không cần webview)
zig build test-page          # chỉ trang của ví dụ, chạy ẩn, qua webview thật
zig build check -Dtarget=x86_64-linux-gnu
```
