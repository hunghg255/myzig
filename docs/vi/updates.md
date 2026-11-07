<a id="updates"></a>

# Cập nhật

App build bằng myzig tự cập nhật từ các bản release đã ký, đăng trên GitHub, trong một bucket S3 hoặc trên bất kỳ web server nào. Cơ chế này theo [tự động cập nhật](../../../mygo/docs/updates.md) của mygo.

- `myzig build` ký bản cập nhật của từng nền tảng bằng khóa của bạn.
- [Plugin updater](plugins/updater.md) trong app tải phiên bản mới hơn về và kiểm tra chữ ký với public key mà app được cấp. Sau đó nó đặt phiên bản mới vào chỗ của app.

<a id="set-up"></a>

## Thiết lập

Tạo cặp khóa để ký bản cập nhật:

```sh
myzig keygen
```

Lệnh này viết `myzig-update.key`, khóa bí mật, và `myzig-update.pub`, public key. Chúng nằm trong `myzig/update-keys` thuộc thư mục cấu hình của bạn, và lệnh in ra đường dẫn đó. `--out` chọn thư mục khác.

Đừng để khóa bí mật trong repo; hãy giữ nó trong trình quản lý mật khẩu và trong secrets của CI. App đã cài chỉ nhận bản cập nhật ký bằng khóa này:

- mất khóa thì các app đó không cập nhật được nữa;
- ai có khóa cũng có thể đẩy code tới người dùng của bạn.

Thêm public key vào `myzig.zon`, cùng nơi đăng các bản release:

```zig
.updates = .{
    .public_key = "…the contents of myzig-update.pub…",
    .github = "you/my-app",
},
```

| Trường | |
|---|---|
| `github` | một repo công khai có các release chứa bản cập nhật, gắn tag `v1.2.0`, v.v. (`tag_prefix`); app đọc manifest của release mới nhất |
| `url` | thay cho `github`, dùng với server riêng hoặc [bucket S3](#publishing-to-s3): URL của một thư mục |

- `url` có thể là https, hoặc http trong mạng nội bộ. App tin vào chữ ký, không tin vào đường truyền.
- Manifest ghi tên file thực thi theo đường dẫn tương đối với chính nó. Vì vậy `manifest_url` của app quyết định thư mục, bất kể `url` ghi gì. Bạn có thể dùng mỗi môi trường một thư mục.

Cho app cùng public key đó và URL manifest của nền tảng, do `myzig build` in ra. Đây là `public_key` và `manifest_url` của `updater.Service`:

```zig
var service: updater.Service = try .init(gpa, app, .{
    .manifest_url = "https://github.com/you/my-app/releases/latest/download/update-windows-x86_64.json",
    .current = "1.2.0",
    .public_key = "…the contents of myzig-update.pub…",
});
```

<a id="build-and-publish"></a>

## Build và đăng bản release

Đưa khóa bí mật cho `myzig build` theo một trong hai cách:

- biến môi trường `MYZIG_UPDATER_PRIVATE_KEY`;
- một file do `updates.private_key` chỉ tới, là đường dẫn có thể bắt đầu bằng `~/`.

```sh
MYZIG_UPDATER_PRIVATE_KEY="$(cat path/to/myzig-update.key)" myzig build
```

Cạnh các gói của mỗi nền tảng, nó viết:

- `my-app-1.2.0-windows-x86_64.exe` (`my-app-1.2.0-linux-x86_64`, ...): file thực thi mà updater đặt vào chỗ bản đã cài;
- `update-windows-x86_64.json`, manifest: phiên bản, release notes, ngày, và URL, kích thước, SHA-256 và chữ ký Ed25519 của file thực thi.

Khi không có khóa hoặc sai khóa:

- Không có khóa, `myzig build` vẫn build các gói và bỏ qua file cập nhật, sau một cảnh báo.
- `myzig build --upload` cần khóa. Không có khóa thì nó dừng trước khi build: app đã cài không thể cập nhật lên bản release thiếu manifest.
- Khóa không khớp với `updates.public_key` cũng làm build dừng lại.

Release notes là phần của phiên bản đó trong `CHANGELOG.md`. `updates.changelog` chỉ định file khác. Phần này nằm dưới tiêu đề `## 1.2.0`, hoặc `## [1.2.0] - 2026-09-19` như [Keep a Changelog](https://keepachangelog.com). Nếu file tồn tại, nó phải có phần đó.

Đăng các file lên nơi `updates` trỏ tới:

- **GitHub**: `myzig build --upload` tải chúng lên, cùng các gói, vào một bản nháp release của phiên bản.
  - Nó dùng GitHub CLI (`gh`, đăng nhập bằng `gh auth login` hoặc `GH_TOKEN`).
  - Publish bản release sẽ biến nó thành bản mới nhất, là bản app kiểm tra. App đọc manifest từ `https://github.com/you/my-app/releases/latest/download/`.
- **S3**: `myzig build --upload` tải chúng lên, cùng các gói, vào bucket của `updates.s3`; xem [bên dưới](#publishing-to-s3).
- **Server riêng**: tải file thực thi và manifest lên thư mục `url`. Tải manifest lên sau cùng, để app không bao giờ thấy manifest mà file của nó chưa có.

Mỗi nền tảng và kiến trúc có manifest riêng, như `macos-aarch64`, `macos-universal`, `windows-x86_64` hoặc `windows-x86`. Mỗi bản build chỉ xem manifest của chính nó.

<a id="publishing-to-s3"></a>

### Đăng lên S3

Khi một bucket của Amazon S3, hoặc của dịch vụ tương thích như Cloudflare R2, phục vụ `url`, trực tiếp hoặc qua CDN, hãy khai báo nó trong `updates.s3`:

```zig
.updates = .{
    .public_key = "…",
    .url = "https://downloads.example.com/my-app",
    .s3 = .{
        .bucket = "downloads",
        .prefix = "my-app", // thư mục trong bucket mà url phục vụ
        .endpoint = "https://<account>.r2.cloudflarestorage.com", // không dùng cho Amazon S3
    },
},
```

Khi đó `myzig build --upload` tải các gói và bản cập nhật lên bucket. Manifest được tải lên sau cùng, đây là bước publish bản cập nhật của nền tảng.

- Không cần công cụ nào khác. CLI tự ký request bằng AWS Signature Version 4.
- Thông tin đăng nhập: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` và, với thông tin tạm thời, `AWS_SESSION_TOKEN`.
- Region: `s3.region`, nếu không có thì `AWS_REGION` (hoặc `AWS_DEFAULT_REGION`), nếu không nữa thì `us-east-1`, R2 chấp nhận giá trị này.
- Manifest giữ nguyên tên qua các phiên bản. Chúng được tải lên với `Cache-Control: no-cache`, để CDN luôn kiểm tra lại.

<details>
<summary>Tên bucket nằm ở đâu</summary>

- Trên Amazon S3, tên bucket nằm trong host name của request.
- Khi có `endpoint`, hoặc tên bucket có dấu chấm, nó nằm trong path.
- Đặt `path_style` là `false` cho dịch vụ chỉ nhận tên trong host name, hoặc `true` để luôn dùng path.

</details>

<a id="not-yet"></a>

## Chưa hỗ trợ

Cơ chế cập nhật của mygo làm được nhiều hơn, những phần myzig chưa có:

- **Cập nhật cả app.** Updater thay một file thực thi, không thay cả bundle `.app` của macOS hay các tài nguyên nằm cạnh file thực thi. Thay file thực thi của bundle đã ký bằng Developer ID sẽ làm hỏng con dấu của nó.
- **Cập nhật delta**, chỉ tải phần thay đổi.
- **Release có tag prefix riêng** tìm qua GitHub API, cho repo mà release mới nhất thuộc về thứ khác.
