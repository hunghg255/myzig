# sqlite

SQLite từ Zig và từ các trang. Plugin sử dụng thư viện của hệ thống, được tải khi cơ sở dữ liệu đầu tiên mở: không có mã C nào được biên dịch, không có gì được liên kết hoặc vận chuyển.

| nền tảng | thư viện |
|---|---|
| Windows 10 trở lên | `winsqlite3.dll` (một phần của Windows) hoặc `sqlite3.dll` |
| macOS | `/usr/lib/libsqlite3.dylib` |
| Linux | `libsqlite3.so.0` (gói `libsqlite3-0`, `sqlite-libs`) |

`MYZIG_SQLITE_LIBRARY` đặt tên cho một công trình khác. Không có thư viện, việc mở không thành công bằng `error.SqliteMissing`.

Gói này là `plugins/sqlite` (mô-đun `sqlite`). Xem [Plugin](../plugins.md) để thêm plugin vào ứng dụng.

<a id="from-zig"></a>

## Sử dụng từ Zig

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

`Db.open(path, options)` lấy `OpenOptions`:

| lĩnh vực | mặc định | |
|---|---|---|
| `read_only` | false | mở mà không viết |
| `busy_timeout_ms` | 5000 | khoảng thời gian một câu lệnh chờ khóa của kết nối khác; 0 thất bại cùng một lúc |
| `guarded` | false | từ chối SQL kiểm soát các giao dịch, đính kèm tệp hoặc tải tiện ích mở rộng (đối với các trang SQL gửi) |

<a id="statements-and-values"></a>

### Tuyên bố và giá trị

- `exec`, `all` và `one` lấy một câu lệnh (dấu sau `;` và các nhận xét đều ổn; nhiều lỗi hơn với `error.MultipleStatements`; `execScript` chạy một số) và một bộ đối số được liên kết với `?1`, `?2`... (`:name`, `$name` và `@name` cũng liên kết theo chỉ mục của họ). Mọi tham số đều cần một giá trị (`error.WrongParameterCount`).
- Giá trị giới hạn: `null`, bools (0 hoặc 1), số nguyên (trong `i64`), số float hữu hạn, văn bản (`[]const u8`, UTF-8 hợp lệ), `sqlite.blob(bytes)`, enums (tên của chúng), `sqlite.Value` và các tùy chọn trong số này.
- Các hàng được đọc thành cấu trúc theo tên cột: số nguyên, số float, bools, enum (từ văn bản), `[]const u8` (đã sao chép), `sqlite.Value` và các tùy chọn (NULL). Trường có giá trị mặc định có thể không có cột hoặc NULL trong đó.
- `prepare` cung cấp `Statement` cho `bind` (hoặc `bindAll`), `step`, đọc (`int`, `float`, `text`, `bytes`, `value`, `read(T)`), `reset` để tái sử dụng và `finalize`. `query` trả về động `Rows` của `Value`s; `execValues` liên kết một lát `Value`s.
- `begin`, `commit`, `rollback` và `inTransaction` dành cho các giao dịch `transaction` không phù hợp.

<a id="errors-and-threads"></a>

### Lỗi và luồng

Lỗi là lỗi Zig: `error.Constraint`, `error.Busy`, `error.Interrupted`, `error.InvalidSql`, `error.Sqlite` và các lỗi khác có tên trong `sqlite.Error`; sau `error.Sqlite`, `db.diagnostics` có mã mở rộng của SQLite và tin nhắn của nó `diagnostics.text()`. `Db` được sử dụng bởi một luồng tại một thời điểm; `interrupt()` dừng một câu lệnh đang chạy từ một câu lệnh khác.

<a id="from-pages"></a>

## Sử dụng từ trang web

Liên kết dịch vụ và phục vụ khách hàng:

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

- **Giá trị:** `null`, số, chuỗi, booleans (0 hoặc 1), `bigint`s cho các số nguyên vượt quá 2^53 (kết quả cung cấp cho chúng dưới dạng `bigint`s, `lastInsertId` luôn) và `Uint8Array`s (bất kỳ view `ArrayBuffer` nào) cho các đốm màu. Những gì JSON không thể thực hiện sẽ di chuyển dưới dạng các chuỗi thuộc loại của nó, được khách hàng quay lại.
- **Tên, không bao giờ đường dẫn:** các trang mở tên tệp trong `directory` của dịch vụ (thư mục dữ liệu của ứng dụng theo mặc định): không có thư mục, `..`, `:`, Windows' tên dành riêng (`CON`, `COM1`...) hoặc liên kết tượng trưng. Thư mục được tạo cho cơ sở dữ liệu có thể ghi được; `open(name, { readOnly: true })` mở một tệp chỉ đọc.
- **SQL được bảo vệ:** một câu lệnh cho mỗi cuộc gọi và không có `BEGIN`, `COMMIT` hoặc `SAVEPOINT` (sử dụng `transaction`, tức là `BEGIN IMMEDIATE` và khôi phục nếu có bất kỳ lỗi nào), `ATTACH`, `DETACH` hoặc `VACUUM INTO`.
- **Mỗi trang:** một kết nối thuộc về trang đã mở nó: các cửa sổ khác không thể sử dụng id của nó và nó sẽ đóng khi trang điều hướng, tải lại hoặc đóng hoặc hủy kích hoạt dịch vụ. Một trang được tải lại sẽ mở lại cơ sở dữ liệu của nó.
- **Các lệnh gọi luồng chính:** chạy ở đó, giống như tất cả các phương thức bị ràng buộc; giữ các truy vấn ngắn gọn (`LIMIT`).

`sqlite.ServiceOptions`: `directory` (null: thư mục dữ liệu của ứng dụng), `busy_timeout_ms` (5000).

<a id="example-and-tests"></a>

## Ví dụ và kiểm thử

`example/` là trang ghi chú; `zig build run` hiển thị nó.

```sh
cd plugins/sqlite
zig build test               # the engine against the system's SQLite on temporary databases, and the page
zig build test -Dpage=false  # without the page (no webview needed)
zig build test-page          # the example's page alone, hidden, through the real webview
zig build check -Dtarget=x86_64-linux-gnu
```
