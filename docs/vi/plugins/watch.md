# watch

Theo dõi file: `watch.Watcher` cho Zig và UI native, và `watch(name)` cho trang web. Trang chỉ theo dõi được các root mà app đặt tên, không bao giờ theo dõi đường dẫn do trang tự chọn.

- Package là `plugins/watch` (module `watch`). Nó phụ thuộc vào [mainthread](mainthread.md).
- Xem [Plugin](../plugins.md) để biết cách thêm vào app.
- Lõi của myzig có một watcher nhỏ hơn cho file của một tài liệu, `myzig.file_watch`. Xem [Hệ thống](../system.md).

<a id="from-zig"></a>

## Dùng từ Zig

```zig
const watch = @import("watch");

fn skipNodeModules(_: ?*anyopaque, path: []const u8, is_dir: bool) bool {
    return is_dir and std.mem.eql(u8, std.fs.path.basename(path), "node_modules");
}

const w = try watch.Watcher.init(gpa, io, project_dir, .{ .recursive = true, .ignore = skipNodeModules });
defer w.deinit();
while (true) { // trên một thread hoặc một Io task riêng
    const events = w.next(arena) catch break; // error.EndOfStream: đã đóng, hoặc thứ đang theo dõi đã biến mất
    for (events) |e| std.log.info("{t} {s}", .{ e.op, e.path }); // create, write, remove, rename (old_path)
}
```

| `watch.Options` | Mặc định | |
|---|---|---|
| `recursive` | false | theo dõi cả các thư mục bên trong |
| `ignore`, `ignore_ctx` | null | `fn (ctx, path, is_dir) bool`: loại bỏ đường dẫn (thư mục bị bỏ qua không bao giờ được mở) |
| `max_entries` | 8192 (65536 trên macOS) | số file và thư mục tối đa một watch bao quát |
| `debounce_ms` | 0 (50 ms) | khoảng yên lặng cần chờ; số âm thì báo ngay |
| `max_delay_ms` | 500 | thời gian chờ lâu nhất khi thay đổi vẫn liên tục tới |

**Hành vi**

- `path` của event là đường dẫn tương đối với thứ đang theo dõi, dùng dấu gạch chéo. `.` là chính đường dẫn đang theo dõi.
- Những gì đã có sẵn lúc bắt đầu theo dõi không được báo.
- Thông báo của hệ thống chỉ là gợi ý. Watch chờ cho yên lặng, xem lại, rồi báo những gì khác với lần trước:
  - file bị ghi nhiều lần là một `write`;
  - file được tạo rồi bị xóa giữa hai lần xem thì không có gì;
  - một lần xóa và một lần tạo cùng file id là một `rename`.

  Hãy coi event là gợi ý để đọc lại file.
- Nó không xem lại cho tới khi `next` được gọi. Không có gì bị dồn lại khi app bận, và không mất gì.
- Một file được theo dõi qua thư mục của nó. Bị ghi hoặc bị thay thế, như cách editor lưu file, là một `write` của `.`; bị xóa là một `remove`.
- Khi thứ đang theo dõi, hoặc thư mục chứa file, bị xóa hay bị thay thế, đợt cuối cùng có một `remove` của `.`. Sau đó `next` trả về `error.EndOfStream`.
- `close()`, gọi từ thread nào cũng được, kết thúc một `next` đang chờ. `next` cũng hủy được qua `Io`.

`watch.scan` và `watch.diff` là các snapshot và phép so sánh giữa chúng, nền tảng để dựng watcher.

| nền tảng | gợi ý |
|---|---|
| Windows | một `ReadDirectoryChangesW` dạng overlapped trên thư mục (cả cây khi recursive) |
| Linux | inotify, một watch cho mỗi thư mục đã thấy |
| macOS | FSEvents, một stream cho cả cây, event ở mức file |

<a id="from-pages"></a>

## Dùng từ trang web

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

const watcher = await watch("project", { recursive: true, path: "src" }); // resolve khi đã bắt đầu theo dõi
for await (const events of watcher) {
  for (const e of events) console.log(e.op, e.path, e.oldPath, e.isDir);
}
// watcher.close(), break, hoặc { signal }; watcher.closed hoàn tất khi Zig đã dừng nó
```

| `watch.ServiceOptions` | Mặc định | |
|---|---|---|
| `roots` | không có | những gì trang được phép theo dõi |
| `allow`, `allow_ctx` | null | `fn (ctx, window, name, path, recursive) bool`, được hỏi trước mỗi watch |
| `max_watches_per_page` | 8 | |
| `max_watches` | 128 | trên tất cả cửa sổ |

Một `watch.Root` có:

- `name`: chữ thường, chữ số và dấu gạch ngang, bắt đầu bằng chữ cái;
- `path` tuyệt đối, phải tồn tại, nếu không `init` thất bại;
- `recursive`, và `ignore` riêng.

**Hành vi**

- `path` của trang nằm trong root, dùng dấu gạch chéo. Nó không được ra khỏi root, cũng không được đi qua symbolic link.
- Watch đệ quy, và watch một thư mục trong root, cần root có `recursive`.
- Lỗi là `WatchError` có `code`: `denied`, `not-found`, `limit` (quá nhiều watch, hoặc quá nhiều mục), `path-encoding`, `io`.
- Zig lấy đợt kế tiếp khi trang đã nhận đợt trước.
- Watch của một cửa sổ dừng khi cửa sổ đóng, ở lần gọi hoặc đợt kế tiếp của service.

<a id="not-yet"></a>

## Chưa hỗ trợ

- `Resolve` của mygo, cấp root trong lúc app đang chạy. Thay vào đó hãy thêm root vào `roots` trước `init`.
- Windows: đổi tên chính thư mục đang theo dõi chỉ được phát hiện ở lần thay đổi kế tiếp bên trong nó. mygo theo dõi thêm cả thư mục cha.
- Gợi ý trên macOS và Linux biên dịch được trên mọi nền tảng, nhưng ít được chạy thực tế hơn bản cho Windows.

<a id="example-and-tests"></a>

## Ví dụ và test

`example/` theo dõi một sandbox trong thư mục tạm, mà trang thay đổi qua Zig. `zig build run` cho xem ví dụ này.

```sh
cd plugins/watch
zig build test               # snapshot, diff và watcher trên thư mục tạm, cùng trang web, chạy ẩn
zig build test -Dpage=false
zig build check -Dtarget=x86_64-linux-gnu
```

Test không bao giờ sleep. Chúng thay đổi file, rồi lấy từng đợt cho tới khi event mong đợi xuất hiện, với debounce tắt.
