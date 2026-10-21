# watch

Xem tệp: `watch.Watcher` từ Zig và giao diện native và `watch(name)` cho các trang, ở phần gốc là tên ứng dụng, không bao giờ xem trên đường dẫn mà trang chọn.

Gói này là `plugins/watch` (mô-đun `watch`); nó phụ thuộc vào [mainthread](mainthread.md). Xem [Plugin](../plugins.md) để thêm plugin vào ứng dụng. (Lõi của myzig có trình theo dõi nhỏ hơn cho tệp của một tài liệu, `myzig.file_watch`; xem [Hệ thống](../system.md).)

<a id="from-zig"></a>

## Sử dụng từ Zig

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

- `path` của một sự kiện liên quan đến nội dung được xem, có dấu gạch chéo; `.` chính là đường dẫn được theo dõi. Có gì khi đồng hồ bắt đầu không được báo cáo.
- Thông báo của hệ thống chỉ là gợi ý: sau đó đồng hồ sẽ đợi yên tĩnh, nhìn lại và báo cáo những gì khác với những gì nó nhìn thấy. Một tập tin được viết nhiều lần là một `write`; một cái được tạo ra và loại bỏ ở giữa thì không là gì cả; việc xóa và tạo cùng một id tệp là `rename`. Hãy coi các sự kiện như gợi ý để đọc lại các tập tin.
- Nó không nhìn lại cho đến khi `next` được gọi: không có gì chồng chất trong khi ứng dụng đang bận và không có gì bị mất.
- Một tập tin được xem qua thư mục của nó: được viết hoặc thay thế (khi người chỉnh sửa lưu) là `write` của `.`, đã xóa `remove`. Khi nội dung đang xem (hoặc thư mục của tệp) bị xóa hoặc thay thế, lô cuối cùng có `remove` là `.`, sau đó `next` trả về `error.EndOfStream`.
- `close()` (từ bất kỳ chuỗi nào) kết thúc quá trình chờ đợi `next`; `next` cũng có thể hủy được thông qua `Io`.

`watch.Options`:

| lĩnh vực | mặc định | |
|---|---|---|
| `recursive` | false | xem các thư mục bên trong quá |
| `ignore`, `ignore_ctx` | null | `fn (ctx, path, is_dir) bool`: loại bỏ các đường dẫn (thư mục bị bỏ qua sẽ không bao giờ được mở) |
| `max_entries` | 8192 (65536 trên macOS) | hầu hết các tập tin và thư mục mà một chiếc đồng hồ bao gồm |
| `debounce_ms` | 0 (50 mili giây) | yên tĩnh chờ đợi; báo cáo tiêu cực cùng một lúc |
| `max_delay_ms` | 500 | những thay đổi dài nhất hãy chờ đợi trong khi nhiều thay đổi khác tiếp tục đến |

`watch.scan` và `watch.diff` là ảnh chụp nhanh và sự so sánh của chúng mà trình theo dõi được xây dựng trên đó.

| nền tảng | gợi ý |
|---|---|
| Windows | một cái chồng chéo `ReadDirectoryChangesW` trên thư mục (cây của nó khi đệ quy) |
| Linux | inotify, theo dõi mỗi thư mục được xem |
| macOS | FSEvents, một luồng cho cây, các sự kiện ở cấp độ tệp |

<a id="from-pages"></a>

## Sử dụng từ trang web

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

- `watch.Root` có `name` (chữ thường, chữ số và dấu gạch ngang, bắt đầu bằng một chữ cái), `path` tuyệt đối phải tồn tại (`init` nếu không thì không thành công), `recursive` và `ignore` của chính nó.
- `path` của một trang nằm ở thư mục gốc, có dấu gạch chéo; nó không thể rời khỏi nó cũng như không đi qua một liên kết tượng trưng. Đồng hồ đệ quy và đồng hồ của một thư mục trong thư mục gốc cần có gốc với `recursive`.
- Lỗi là `WatchError` với `code`: `denied`, `not-found`, `limit` (quá nhiều đồng hồ hoặc quá nhiều mục), `path-encoding`, `io`.
- Zig lấy đợt tiếp theo sau khi trang lấy đợt cuối cùng.
- Đồng hồ của cửa sổ sẽ dừng sau khi cửa sổ đóng (trong cuộc gọi hoặc đợt tiếp theo của dịch vụ).

`watch.ServiceOptions`:

| lĩnh vực | mặc định | |
|---|---|---|
| `roots` | không có | những trang nào có thể xem |
| `allow`, `allow_ctx` | null | `fn (ctx, window, name, path, recursive) bool`, được hỏi trước mỗi lần xem |
| `max_watches_per_page` | 8 | |
| `max_watches` | 128 | trong tất cả các cửa sổ |

<a id="not-yet"></a>

## Chưa hỗ trợ

- mygo's `Resolve` (root được cấp trong khi ứng dụng chạy): thêm root vào `roots` trước `init`.
- Windows: việc đổi tên thư mục đã xem chỉ được nhìn thấy ở lần thay đổi tiếp theo trong đó (mygo cũng theo dõi thư mục mẹ của nó).
- Gợi ý macOS và Linux biên dịch trên mọi nền tảng nhưng chạy ít hơn Windows'.

<a id="example-and-tests"></a>

## Ví dụ và kiểm thử

`example/` xem hộp cát trong thư mục tạm thời mà trang này thay đổi thông qua Zig; `zig build run` hiển thị nó.

```sh
cd plugins/watch
zig build test               # snapshots, diffs and watchers on temporary directories, and the page, hidden
zig build test -Dpage=false
zig build check -Dtarget=x86_64-linux-gnu
```

Các bài kiểm tra không bao giờ ngủ: chúng thay đổi tệp, sau đó thực hiện theo đợt cho đến khi sự kiện mà chúng mong đợi xảy ra (với việc gỡ lỗi).
