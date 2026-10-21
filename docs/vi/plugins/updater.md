# updater

Cập nhật: kiểm tra bảng kê khai, tải xuống tệp thực thi mới xác minh SHA-256 và chữ ký của nó, đồng thời đặt nó vào vị trí của tệp đang chạy (nó chạy ở lần khởi chạy tiếp theo hoặc bây giờ với `relaunch`), theo tùy chọn của người dùng; dịch vụ dành cho biểu ngữ hoặc cửa sổ cập nhật trong một trang; và cửa sổ cập nhật mà người dùng Mac biết đến từ Sparkle, trong giao diện native, trên mọi nền tảng.

Gói này là `plugins/updater` (mô-đun `updater`); nó phụ thuộc vào [mainthread](mainthread.md). Xem [Plugin](../plugins.md) để thêm plugin vào ứng dụng và [Updates](../updates.md) để ký và xuất bản các bản cập nhật với `myzig build`.

<a id="the-manifest"></a>

## Bản kê khai

Mỗi nền tảng (và kiến trúc) có tệp kê khai riêng, tệp JSON được cung cấp qua HTTPS, `myzig build` ghi:

```json
{ "version": "2.0.0", "url": "app-2.0.0", "sha256": "<64 hex digits>", "signature": "<base64>", "notes": "Markdown", "date": "2026-10-19T08:00:00Z", "size": 1234567 }
```

- `url` là tuyệt đối hoặc tương đối với URL của tệp kê khai.
- Các phiên bản có ngữ nghĩa (`1.2.3`, `v1.2.3`, `2.0.0-beta.1`); chỉ có bản mới hơn là bản cập nhật (`updater.isNewer`).
- `signature` là chữ ký Ed25519 của SHA-256, trong base64, bằng khóa của [`myzig keygen`](../cli.md#myzig-keygen). Trình cập nhật được cung cấp khóa chung (`public_key`) từ chối một bảng kê khai không có khóa và bản tải xuống không ký.
- `notes`, `date` và `size` là tùy chọn; tải xuống lớn hơn `size` hoặc lớn hơn `max_size` (1 GiB), không thành công.
- Xuất bản tệp thực thi trước và tệp kê khai cuối cùng để ứng dụng không bao giờ nhìn thấy tệp kê khai chưa có tệp ở đó (`myzig build --upload`).

<a id="from-zig"></a>

## Sử dụng từ Zig

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

- `download` nhận một tùy chọn `updater.Progress` (`ctx` và `func(ctx, done, total)`, với `total` null khi máy chủ không nói).
- `install` thay thế tệp thực thi (`exe_path`, tệp đang chạy khi null). Windows cho phép đổi tên một tệp thực thi đang chạy nhưng không được thay thế, do đó, nó chuyển sang `<exe>.old` trước tiên (và quay lại nếu việc di chuyển tệp mới không thành công), mà `cleanup` sẽ loại bỏ ở lần khởi động tiếp theo; trên macOS và Linux việc đổi tên sẽ thay thế nó cùng một lúc. Ứng dụng đang chạy vẫn tiếp tục như cũ.
- Nếu không có `public_key`, SHA-256 của tệp kê khai là sự tin cậy: phân phối nó qua HTTPS.
- Lỗi: `error.BadManifest`, `BadVersion`, `HttpStatus`, `ChecksumMismatch`, `TooLarge`, `SizeMismatch`, `Unsigned`, `BadSignature`, `BadPublicKey` và mạng.
- `updater.Prefs` giữ các lựa chọn của người dùng ở `updater.json`: `automaticChecks` (bật), `automaticDownloads` (tắt), `skippedVersion`, `lastCheck`; `Prefs.load`, `save`, `due(now, interval)`, `dueAt(now, interval, checked_since_launch)` và `offers(version)`.

<a id="the-service"></a>

## Dịch vụ

```zig
var service: updater.Service = try .init(gpa, app, .{ .manifest_url = url, .current = version, .public_key = key });
defer service.deinit();
service.startBackgroundChecks(10_000); // in 10 s, then once a day, if the user lets it
```

Kiểm tra nền sẽ chạy 10 giây sau khi khởi chạy, bất cứ khi nào có lần kiểm tra cuối cùng, sau đó mỗi ngày một lần khi ứng dụng chạy, do đó, phiên bản xuất hiện kể từ lần cuối ứng dụng chạy sẽ hiển thị khi ứng dụng mở lại. Họ không cung cấp phiên bản bị bỏ qua (nhưng phiên bản tiếp theo) và với tính năng tải xuống tự động, họ sẽ cài đặt mà không cần hỏi. Việc kiểm tra và tải xuống chạy theo nhiệm vụ của `Io` của ứng dụng; trạng thái của chúng đạt tới luồng chính ([mainthread](mainthread.md)), mọi trang và code native theo sau dịch vụ (`service.listener`, `updater.Listener`: cửa sổ cập nhật).

`updater.ServiceOptions`:

| lĩnh vực | mặc định | |
|---|---|---|
| `manifest_url` | bắt buộc | |
| `current` | bắt buộc | phiên bản đang chạy |
| `public_key` | null | nội dung của `myzig-update.pub`: chỉ cập nhật nó có dấu hiệu cài đặt |
| `exe_path` | null | tệp thực thi để thay thế; cái đang chạy |
| `prefs_dir` | null | nơi `updater.json` sống; thư mục dữ liệu của ứng dụng |
| `interval_s` | 1 ngày | giây giữa các lần kiểm tra lý lịch |

<a id="the-update-window"></a>

## Cửa sổ cập nhật

`updater.Window` là cửa sổ cập nhật của mygo trong giao diện native, vì vậy nó không cần webview, trong các ứng dụng của giao diện native và các trang tương tự. Khi có phiên bản mới, nó sẽ hiển thị ghi chú phát hành (Đánh dấu, với các liên kết mở trong trình duyệt) và cung cấp **Cài đặt bản cập nhật**, **Nhắc tôi sau** và **Bỏ qua phiên bản này**, với "Tự động tải xuống và cài đặt các bản cập nhật trong tương lai"; quá trình cài đặt hiển thị quá trình tải xuống kèm theo thanh tiến trình, sau đó đề nghị khởi chạy lại. Thoát và Nhập câu trả lời bằng các nút hủy và mặc định của cửa sổ.

```zig
var window: updater.Window = undefined;
window.init(&service, .{}); // follows the service; .language, .width, .height
defer window.deinit();
```

Mục "Kiểm tra bản cập nhật..." trong menu của ứng dụng, được gắn nhãn `updater.menuItemLabel("")` (bằng ngôn ngữ mà ứng dụng hiển thị), gọi `window.checkForUpdates()`: nó kiểm tra khi người dùng yêu cầu, do đó, cửa sổ hiển thị ngay lập tức và cho biết khi nào ứng dụng được cập nhật hoặc kiểm tra không thành công; nó cũng hiển thị các bản cập nhật mà người dùng đã bỏ qua. Trong khi quá trình kiểm tra đang được tiến hành, việc gọi lại sẽ đưa cửa sổ của nó lên phía trước. `updater.WindowView` chỉ là view của cửa sổ mà `ui.Tester` điều khiển.

<a id="languages"></a>

### Ngôn ngữ

Cửa sổ nói ngôn ngữ của người dùng khi plugin có: tiếng Anh, tiếng Trung (Giản thể và Phồn thể), tiếng Hà Lan, tiếng Pháp, tiếng Đức, tiếng Ý, tiếng Nhật, tiếng Hàn, tiếng Ba Lan, tiếng Bồ Đào Nha (Brazil), tiếng Nga, tiếng Tây Ban Nha, tiếng Thổ Nhĩ Kỳ và tiếng Ukraina, với dấu thập phân của ngôn ngữ ("1,5 MB"); các ngôn ngữ khác có được tiếng Anh. Văn bản của nó là một danh mục `src/locales/*.json`, được kiểm tra tại thời điểm biên dịch ([Ngôn ngữ](../i18n.md)); `updater.Texts` nói vậy.

Một cửa sổ nói ngôn ngữ mà ứng dụng hiển thị (`i18n.locale()` hoặc `WindowOptions.language`) khi quá trình kiểm tra bắt đầu và giữ cửa sổ đó khi cửa sổ mở. Sau `i18n.setLocale`, cửa sổ tiếp theo sẽ có cửa sổ mới, cũng như `menuItemLabel`: một ứng dụng xây dựng lại menu khi ngôn ngữ của nó thay đổi sẽ nhận được "Kiểm tra cập nhật..." trong cửa sổ mới.

<a id="from-pages"></a>

## Sử dụng từ trang web

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
await myzig.call("Updater.relaunch");
await myzig.call("Updater.setAutomaticChecks", false); // also setAutomaticDownloads, preferences()
```

<a id="not-yet"></a>

## Chưa hỗ trợ

- macOS `.app` gói: trình cập nhật thay thế một tệp thực thi, không phải một gói (xem [Cập nhật](../updates.md#not-yet)), cũng như delta.
- Biểu tượng ứng dụng của cửa sổ và ghi chú phát hành được sắp xếp từ phải sang trái trong một cửa sổ không có.

<a id="example-and-tests"></a>

## Ví dụ và kiểm thử

`example/` là phiên bản 1.0.0 của một ứng dụng có biểu ngữ cập nhật và máy chủ phát hành trên 127.0.0.1 (`example/releases.zig`) xuất bản 2.0.0. Nó cập nhật một tệp thực thi giả vờ trong thư mục tạm thời, không bao giờ là chính nó.

```sh
cd plugins/updater
zig build test               # check, download, checksum, install, cleanup against the local server; the window's view and texts; the page, hidden
zig build test -Dpage=false
zig build check -Dtarget=x86_64-linux-gnu
```
