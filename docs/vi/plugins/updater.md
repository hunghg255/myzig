# updater

Cập nhật cho app, trên mọi nền tảng:

- kiểm tra một manifest;
- tải file thực thi mới, có xác minh SHA-256 và chữ ký;
- đặt nó vào chỗ của file đang chạy. Bản mới chạy ở lần mở sau, hoặc ngay lập tức với `relaunch`.

Plugin lưu tùy chọn của người dùng, có một service cho banner hay cửa sổ cập nhật trong trang, và vẽ bằng native UI cửa sổ cập nhật quen thuộc với người dùng Mac từ Sparkle.

Package là `plugins/updater` (module `updater`); nó phụ thuộc vào [mainthread](mainthread.md). Xem [Plugin](../plugins.md) để thêm nó vào app, và [Cập nhật](../updates.md) để ký và phát hành bản cập nhật bằng `myzig build`.

<a id="the-manifest"></a>

## Manifest

```json
{ "version": "2.0.0", "url": "app-2.0.0", "sha256": "<64 hex digits>", "signature": "<base64>", "notes": "Markdown", "date": "2026-10-19T08:00:00Z", "size": 1234567 }
```

Mỗi nền tảng và kiến trúc có manifest riêng: một file JSON phục vụ qua HTTPS, do `myzig build` viết ra.

| Trường | |
|---|---|
| `version` | theo semantic versioning (`1.2.3`, `v1.2.3`, `2.0.0-beta.1`); chỉ bản mới hơn mới là bản cập nhật (`updater.isNewer`) |
| `url` | tuyệt đối, hoặc tương đối so với URL của manifest |
| `sha256` | của file thực thi, 64 chữ số hex |
| `signature` | chữ ký Ed25519 của SHA-256, dạng base64, bằng khóa của [`myzig keygen`](../cli.md#myzig-keygen) |
| `notes`, `date`, `size` | không bắt buộc |

- Updater có public key (`public_key`) sẽ từ chối manifest không có chữ ký, và bản tải về mà khóa đó không ký.
- Bản tải về lớn hơn `size`, hoặc lớn hơn `max_size` (1 GiB), sẽ thất bại.
- Phát hành file thực thi trước, manifest sau cùng. Nhờ vậy app không bao giờ thấy một manifest mà file của nó chưa có. `myzig build --upload` làm đúng như vậy.

<a id="from-zig"></a>

## Từ Zig

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

- `download` nhận một `updater.Progress` không bắt buộc: `ctx`, và `func(ctx, done, total)`. `total` là null khi server không báo.
- `install` thay file thực thi: `exe_path`, hoặc file đang chạy khi là null. App đang chạy vẫn tiếp tục như cũ.
- Không có `public_key` thì SHA-256 trong manifest là thứ duy nhất để tin: hãy phục vụ nó qua HTTPS.
- Lỗi: `error.BadManifest`, `BadVersion`, `HttpStatus`, `ChecksumMismatch`, `TooLarge`, `SizeMismatch`, `Unsigned`, `BadSignature`, `BadPublicKey`, và lỗi mạng.
- `updater.Prefs` lưu lựa chọn của người dùng trong `updater.json`:
  - `automaticChecks` (bật), `automaticDownloads` (tắt), `skippedVersion`, `lastCheck`;
  - `Prefs.load`, `save`, `due(now, interval)`, `dueAt(now, interval, checked_since_launch)` và `offers(version)`.

<details>
<summary>Cách install thay một file thực thi đang chạy</summary>

- Trên macOS và Linux, thao tác rename thay nó ngay lập tức.
- Windows cho phép đổi tên file thực thi đang chạy (`MoveFileExW`; `Io.Dir.rename` thì từ chối) nhưng không cho thay thế. Vì vậy file cũ được dời sang `<exe>.old` trước, và dời lại nếu việc đưa file mới vào thất bại.
- `cleanup` xóa `<exe>.old` ở lần khởi động sau.

</details>

<a id="the-service"></a>

## Service

```zig
var service: updater.Service = try .init(gpa, app, .{ .manifest_url = url, .current = version, .public_key = key });
defer service.deinit();
service.startBackgroundChecks(10_000); // in 10 s, then once a day, if the user lets it
```

| `updater.ServiceOptions` | Mặc định | |
|---|---|---|
| `manifest_url` | bắt buộc | |
| `current` | bắt buộc | phiên bản đang chạy |
| `public_key` | null | nội dung của `myzig-update.pub`: chỉ bản cập nhật do nó ký mới được cài |
| `exe_path` | null | file thực thi cần thay; mặc định là file đang chạy |
| `prefs_dir` | null | nơi chứa `updater.json`; mặc định là thư mục dữ liệu của app |
| `interval_s` | 1 ngày | số giây giữa các lần kiểm tra nền |

**Kiểm tra nền**

- Lần đầu chạy 10 giây sau khi mở app, bất kể lần kiểm tra trước là khi nào. Phiên bản ra mắt từ lần chạy trước sẽ hiện ra khi app mở lại.
- Sau đó mỗi ngày một lần khi app còn chạy.
- Chúng không đề xuất phiên bản đã bị bỏ qua, nhưng vẫn đề xuất phiên bản kế tiếp.
- Khi bật tải tự động, chúng cài luôn mà không hỏi.

Kiểm tra và tải về chạy trên một task của `Io` của app. State của chúng được đưa về main thread ([mainthread](mainthread.md)) và tới mọi trang. Code native theo dõi service qua `service.listener`, một `updater.Listener`: cửa sổ cập nhật dùng cách này.

<a id="the-update-window"></a>

## Cửa sổ cập nhật

`updater.Window` là cửa sổ cập nhật của mygo viết bằng native UI. Nó không cần webview, nên dùng được cả trong app native UI lẫn app dùng trang.

```zig
var window: updater.Window = undefined;
window.init(&service, .{}); // follows the service; .language, .width, .height
defer window.deinit();
```

- Khi có phiên bản mới, nó hiện release notes: Markdown, link mở trong trình duyệt.
- Nó đưa ra **Install Update**, **Remind Me Later** và **Skip This Version**, kèm "Automatically download and install updates in the future".
- Khi cài, nó hiện quá trình tải với thanh tiến trình, rồi đề nghị khởi động lại.
- Escape và Enter tương ứng với nút hủy và nút mặc định của cửa sổ.

**Mục menu "Check for Updates…".** Đặt label cho nó bằng `updater.menuItemLabel("")`, theo ngôn ngữ app đang hiển thị. Mục này gọi `window.checkForUpdates()`, kiểm tra theo yêu cầu của người dùng:

- cửa sổ hiện ra ngay;
- nó báo khi app đã là bản mới nhất hoặc khi kiểm tra thất bại;
- nó hiện cả những bản cập nhật người dùng đã bỏ qua;
- khi đang kiểm tra mà gọi lại thì cửa sổ được đưa lên trước.

`updater.WindowView` chỉ là view của cửa sổ, do `ui.Tester` điều khiển.

<a id="languages"></a>

### Ngôn ngữ

Cửa sổ dùng ngôn ngữ của người dùng nếu plugin có ngôn ngữ đó. Các ngôn ngữ khác dùng tiếng Anh. Các ngôn ngữ có sẵn:

- tiếng Anh, tiếng Trung (giản thể và phồn thể), tiếng Hà Lan, Pháp, Đức, Ý, Nhật, Hàn, Ba Lan, Bồ Đào Nha (Brazil), Nga, Tây Ban Nha, Thổ Nhĩ Kỳ và Ukraina;
- kèm dấu thập phân theo locale của từng ngôn ngữ ("1,5 MB").

Chữ của nó là một catalog trong `src/locales/*.json`, được kiểm tra lúc biên dịch ([Ngôn ngữ](../i18n.md)). `updater.Texts` cung cấp các chữ này.

- Một cửa sổ lấy ngôn ngữ app đang hiển thị (`i18n.locale()`, hoặc `WindowOptions.language`) khi lần kiểm tra của nó bắt đầu. Nó giữ ngôn ngữ đó khi còn mở.
- Sau `i18n.setLocale`, cửa sổ kế tiếp lấy ngôn ngữ mới, và `menuItemLabel` cũng vậy. App dựng lại menu khi đổi ngôn ngữ sẽ có "Check for Updates…" bằng ngôn ngữ mới.

<a id="from-pages"></a>

## Từ trang

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
await myzig.call("Updater.availableVersion"); // what the last check found, "" for nothing (a badge, a settings row)
await myzig.call("Updater.relaunch");
await myzig.call("Updater.setAutomaticChecks", false); // also setAutomaticDownloads, preferences()
```

<a id="not-yet"></a>

## Chưa có

- Bundle `.app` của macOS: updater thay một file thực thi, không phải cả bundle (xem [Cập nhật](../updates.md#not-yet)).
- Cập nhật delta.
- Icon app trong cửa sổ.
- Release notes viết từ phải sang trái trong một cửa sổ không theo chiều đó.

<a id="example-and-tests"></a>

## Ví dụ và test

`example/` là phiên bản 1.0.0 của một app có banner cập nhật. Một server phát hành trên 127.0.0.1 (`example/releases.zig`) công bố bản 2.0.0. Ví dụ này cập nhật một file thực thi giả trong thư mục tạm, không bao giờ cập nhật chính nó.

```sh
cd plugins/updater
zig build test               # check, download, checksum, install, cleanup against the local server; the window's view and texts; the page, hidden
zig build test -Dpage=false
zig build check -Dtarget=x86_64-linux-gnu
```
