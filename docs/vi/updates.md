<a id="updates"></a>

# Cập nhật

Các ứng dụng được xây dựng bằng myzig tự cập nhật từ các bản phát hành đã ký, được xuất bản trên GitHub, trong nhóm S3 hoặc trên bất kỳ máy chủ HTTPS nào, sau [tự động cập nhật](../../../mygo/docs/updates.md) của mygo. `myzig build` ký tên vào bản cập nhật của mỗi nền tảng bằng khóa của bạn và [updater](plugins/updater.md) trong ứng dụng sẽ tải xuống phiên bản mới hơn, kiểm tra chữ ký của nó với khóa chung mà ứng dụng được cấp và đặt nó vào vị trí của ứng dụng.

<a id="set-up"></a>

## Thiết lập

Tạo cặp khóa ký cập nhật:

```sh
myzig keygen
```

Nó ghi `myzig-update.key`, khóa bí mật và `myzig-update.pub`, khóa chung, vào `myzig/update-keys` trong thư mục cấu hình của bạn và in ở đâu (`--out` chọn thư mục khác). Giữ khóa bí mật ra khỏi kho lưu trữ, trong trình quản lý mật khẩu và trong bí mật của CI của bạn: các ứng dụng đã cài đặt chỉ chấp nhận các bản cập nhật được ký với nó, do đó, việc mất khóa sẽ khiến chúng bị mắc kẹt và bất kỳ ai có khóa đó đều có thể gửi mã cho người dùng của bạn.

Thêm khóa công khai vào `myzig.zon`, nơi phát hành các bản phát hành:

```zig
.updates = .{
    .public_key = "…the contents of myzig-update.pub…",
    .github = "you/my-app",
},
```

`github` là một kho lưu trữ công cộng có các bản phát hành được gắn thẻ `v1.2.0`, v.v. (`tag_prefix`), lưu giữ các bản cập nhật; apps đọc bản kê khai của bản phát hành mới nhất. Đối với máy chủ của riêng bạn hoặc [bộ chứa S3](#publishing-to-s3), thay vào đó, hãy đặt `url` URL HTTPS của một thư mục.

Cung cấp cho ứng dụng cùng một khóa công khai và URL của tệp kê khai nền tảng mà `myzig build` in (`updater.Service`'s `public_key` và `manifest_url`):

```zig
var service: updater.Service = try .init(gpa, app, .{
    .manifest_url = "https://github.com/you/my-app/releases/latest/download/update-windows-x86_64.json",
    .current = "1.2.0",
    .public_key = "…the contents of myzig-update.pub…",
});
```

<a id="build-and-publish"></a>

## Xây dựng và xuất bản

Cung cấp `myzig build` khóa bí mật, trong biến môi trường `MYZIG_UPDATER_PRIVATE_KEY` hoặc dưới dạng tệp có `updates.private_key` (một đường dẫn có thể bắt đầu bằng `~/`):

```sh
MYZIG_UPDATER_PRIVATE_KEY="$(cat path/to/myzig-update.key)" myzig build
```

Bên cạnh các gói của mỗi nền tảng có ghi:

- `my-app-1.2.0-windows-x86_64.exe` (`my-app-1.2.0-linux-x86_64`, ...), tệp thực thi mà trình cập nhật đặt vào vị trí của tệp đã cài đặt và
- `update-windows-x86_64.json`, tệp kê khai: phiên bản, ghi chú phát hành, ngày và URL, kích thước, chữ ký SHA-256 và Ed25519 của tệp thực thi.

Nếu không có khóa, `myzig build` sẽ xây dựng các gói và bỏ qua các tệp cập nhật sau một cảnh báo. `myzig build --upload` cần khóa: nó dừng trước khi xây dựng vì bản phát hành không có tệp kê khai là bản phát hành mà các ứng dụng đã cài đặt không thể cập nhật. Khóa không khớp `updates.public_key` cũng dừng quá trình xây dựng.

Ghi chú phát hành là phần của phiên bản trong `CHANGELOG.md` (`updates.changelog` đặt tên cho một tệp khác), dưới tiêu đề `## 1.2.0` hoặc `## [1.2.0] - 2026-09-19` như trong [Keep a Changelog](https://keepachangelog.com). Khi tập tin tồn tại, nó phải có phần đó.

Xuất bản các tệp trong đó `updates` trỏ tới:

- **GitHub**: `myzig build --upload` tải chúng cùng với các gói lên bản phát hành nháp của phiên bản bằng GitHub CLI (`gh`, đăng nhập bằng `gh auth login` hoặc `GH_TOKEN`). Việc xuất bản bản phát hành sẽ làm cho bản phát hành trở thành bản mới nhất, ứng dụng nào sẽ kiểm tra: chúng đọc bản kê khai từ `https://github.com/you/my-app/releases/latest/download/`.
- **S3**: `myzig build --upload` tải chúng lên cùng với các gói vào nhóm `updates.s3`; xem [bên dưới](#publishing-to-s3).
- **Máy chủ của bạn**: tải các tệp thực thi và tệp kê khai lên thư mục `url`. Tải tệp kê khai lên sau cùng để ứng dụng không bao giờ nhìn thấy tệp kê khai bị thiếu tệp.

Mỗi nền tảng và kiến trúc, chẳng hạn như `macos-aarch64`, `macos-universal` hoặc `windows-x86_64`, đều có tệp kê khai riêng và bản dựng chỉ xem xét bản dựng riêng của nó.

<a id="publishing-to-s3"></a>

### Xuất bản lên S3

Khi một nhóm Amazon S3 hoặc một dịch vụ tương thích như Cloudflare R2 phục vụ `url`, trực tiếp hoặc thông qua CDN, hãy đặt tên nó trong `updates.s3`:

```zig
.updates = .{
    .public_key = "…",
    .url = "https://downloads.example.com/my-app",
    .s3 = .{
        .bucket = "downloads",
        .prefix = "my-app", // the directory in the bucket that url serves
        .endpoint = "https://<account>.r2.cloudflarestorage.com", // not for Amazon S3
    },
},
```

`myzig build --upload` sau đó tải các gói và bản cập nhật lên gói đó và cuối cùng là tệp kê khai xuất bản bản cập nhật của nền tảng. Nó không cần công cụ nào khác: các yêu cầu được ký bằng AWS Signature Phiên bản 4 trong CLI, với thông tin xác thực là `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` và đối với các thông tin tạm thời là `AWS_SESSION_TOKEN` và vùng `s3.region`, nếu không thì là `AWS_REGION` (hoặc `AWS_DEFAULT_REGION`), nếu không thì là `us-east-1` mà R2 chấp nhận. Các tệp kê khai có tên thay đổi theo từng phiên bản, được tải lên với `Cache-Control: no-cache`, do đó CDN sẽ kiểm tra lại chúng.

Vùng lưu trữ được đặt tên theo tên máy chủ của các yêu cầu trên Amazon S3 và trong đường dẫn của chúng bằng `endpoint` (hoặc tên vùng lưu trữ có dấu chấm); đặt `path_style` thành `false` cho các dịch vụ chỉ lấy nó trong tên máy chủ hoặc thành `true` để buộc đường dẫn.

<a id="not-yet"></a>

## Chưa hỗ trợ

Các bản cập nhật của mygo làm được nhiều việc hơn, điều mà myzig chưa làm được:

- **Toàn bộ ứng dụng.** Trình cập nhật thay thế một tệp thực thi, không phải gói macOS `.app` hoặc các tài nguyên bên cạnh tệp thực thi; việc thay thế tệp thực thi của gói được ký bằng ID nhà phát triển sẽ phá vỡ dấu niêm phong của gói đó.
- **Cập nhật Delta**, chỉ tải xuống những gì đã thay đổi.
- **Các bản phát hành có tiền tố thẻ riêng** được tìm thấy thông qua API GitHub, dành cho kho lưu trữ có bản phát hành mới nhất là của một kho lưu trữ khác.
