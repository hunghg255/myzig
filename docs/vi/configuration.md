<a id="configuration"></a>

# Cấu hình

[CLI](cli.md) đọc cấu hình của ứng dụng từ `myzig.zon` ở thư mục gốc hoặc `myzig.json` (không phải cả hai). Mọi trường đều là tùy chọn; không có tệp, các giá trị mặc định bên dưới sẽ được áp dụng. Bản thân Zig không bao giờ đọc nó: `zig build` xây dựng ứng dụng từ `build.zig` và `build.zig.zon`, đồng thời cấu hình cho biết cách CLI chạy, đóng gói và đặt tên cho nó.

```zig
.{
    .name = "My App",
    .identifier = "com.example.myapp",
    .version = "1.2.0",              // default: build.zig.zon's
    .copyright = "© 2026 Example Inc.",
    .icon = "resources/icon.png",    // default when it exists
    .executable = "my_app",          // the artifact build.zig installs
    .frontend = "frontend",          // the web frontend's sources
    .frontend_dist = "frontend",     // what build.zig embeds
    .dev_url = "http://localhost:5173",
    .dev_command = "bun run dev",
    .build_command = "bun run build",
    .out = "dist",
    .resources = .{"third_party/licenses"},
    .url_schemes = .{"myapp"},
    .file_associations = .{.{ .ext = .{"md"}, .name = "Markdown Document" }},
    .macos = .{ .minimum_system_version = "12.0", .signing_identity = "-" },
    .windows = .{ .installer = true },
    .linux = .{ .maintainer = "Jane <jane@example.com>", .command = "my-app" },
}
```

Đường dẫn có liên quan đến thư mục gốc hoặc tuyệt đối của ứng dụng. Một trường mà CLI không biết là một lỗi đặt tên cho nó (`myzig.zon has no field nmae`), cũng như một giá trị không đúng loại; lỗi cú pháp ZON đưa ra dòng và cột của nó.

<a id="the-app"></a>

## Ứng dụng

| lĩnh vực | mặc định | |
|---|---|---|
| `name` | tên của thư mục | tên mà mọi người nhìn thấy: gói, trình cài đặt, lớp cửa sổ |
| `identifier` | `com.myzig.<name>` | tên DNS đảo ngược (chữ cái, chữ số, `.` và `-`), dưới dạng `com.example.myapp`: mã định danh gói, khóa gỡ cài đặt, tên của tệp kê khai Windows |
| `version` | `build.zig.zon` của `.version`, khác `0.1.0` | phiên bản của gói và trình cài đặt (Windows chiếm tối đa bốn số) |
| `copyright` | không có | macOS's `NSHumanReadableCopyright`, Windows' `LegalCopyright` |
| `icon` | `resources/icon.png` khi nó tồn tại | một PNG hình vuông (1024 pixel là tốt nhất): Kích thước của `.icns`, `.ico`, Linux được tạo từ nó |
| `executable` | `build.zig.zon`'s `.name`, nếu không thì tên trong vỏ rắn | tạo phẩm `build.zig` cài đặt (`zig-out/bin/<executable>`) |

`name`, `version` và `identifier` không thể giữ dấu ngoặc kép hoặc ký tự điều khiển. Giữ `identifier` giống với `AppOptions.id` trong mã của ứng dụng, đặt tên cho khóa phiên bản duy nhất, trình xử lý URL và bí mật (xem [Ứng dụng](app.md)).

<a id="development-and-the-frontend"></a>

## Phát triển và frontend

| lĩnh vực | mặc định | |
|---|---|---|
| `frontend` | `frontend` khi thư mục tồn tại | nguồn của frontend web, trong đó `generate` và `dev` viết `myzig.js` và `myzig.d.ts` |
| `frontend_dist` | `frontend` | frontend được xây dựng mà ứng dụng nhúng; CLI ghi `myzig_assets.zig` của nó và chuyển nó dưới dạng `-Dfrontend` |
| `dev_url` | không có | một URL `http://` hoặc `https://`: `myzig dev` đợi nó và chuyển nó dưới dạng `MYZIG_DEV_URL` |
| `dev_command` | không có | máy chủ nhà phát triển `myzig dev` chạy đầu tiên (`bun run dev`), trong shell, trong thư mục gốc của ứng dụng |
| `build_command` | không có | `myzig build` chạy gì đầu tiên để xây dựng frontend (`bun run build`) |
| `out` | `dist` | nơi `myzig build` đặt các gói |
| `watch` | không có | được chấp nhận; `myzig dev` đã xem toàn bộ thư mục ứng dụng |

Giao diện người dùng không có bản dựng (đơn giản HTML, như mẫu web) chỉ có `frontend`: ứng dụng nhúng các nguồn của nó. Giao diện người dùng do Vite xây dựng hoặc một công cụ khác đặt `frontend_dist` làm đầu ra của nó và `dev_command`, `dev_url` và `build_command`:

```zig
.{
    .name = "Notes",
    .frontend = "frontend",
    .frontend_dist = "frontend/dist",
    .dev_command = "bun run --cwd frontend dev",
    .dev_url = "http://localhost:5173",
    .build_command = "bun run --cwd frontend build",
}
```

Xem [Frontend](frontend.md) để biết phía bên của trang.

<a id="integration"></a>

## Tích hợp

| lĩnh vực | mặc định | |
|---|---|---|
| `resources` | không có | các tập tin và thư mục được gửi bên cạnh ứng dụng, bên cạnh những gì `resources/` chứa |
| `url_schemes` | không có | Lược đồ URL mà ứng dụng mở ra (`myapp` cho `myapp://...`): chữ cái, chữ số, `+`, `-` và `.`, bắt đầu bằng một chữ cái |
| `file_associations` | không có | loại tệp ứng dụng sẽ mở |

Mọi thứ đều có trong `resources/` nhưng biểu tượng cũng đi kèm với ứng dụng: xem [Phân phối](distribution.md#resources).

Một liên kết tập tin là:

| lĩnh vực | mặc định | |
|---|---|---|
| `ext` | bắt buộc | phần mở rộng không có dấu chấm (`.{ "md", "markdown" }`) |
| `name` | `<EXT> file` | tên loại trong hệ thống |
| `mime_type` | `application/x-<executable>-<ext>` | loại MIME; Các gói Linux xác định loại khi nó là của myzig |
| `role` | `Editor` | `Editor` hoặc `Viewer` (macOS) |

Các gói đăng ký những thứ này với hệ thống: `CFBundleURLTypes` và `CFBundleDocumentTypes` trong gói macOS, các khóa đăng ký được viết bởi trình cài đặt Windows, `MimeType=` trong mục nhập Linux trên máy tính để bàn. Ứng dụng cũng đặt tên cho chúng theo các tùy chọn riêng, `AppOptions.url_schemes` và `AppOptions.file_extensions`, để các lần khởi chạy có đối số như vậy đạt tới `on_open_url` và `on_open_file`, đồng thời có thể đăng ký chúng trong khi chạy (`myzig.system.registerUrlScheme`, `registerFileType`; xem [Hệ thống](system.md)).

## macos

| lĩnh vực | mặc định | |
|---|---|---|
| `minimum_system_version` | `12.0` | `LSMinimumSystemVersion` |
| `signing_identity` | `-` | Danh tính của `codesign`; `-` ký đặc biệt (chạy trên máy Mac đã xây dựng nó) |
| `entitlements` | không có | tệp quyền lợi cho `codesign` |
| `provisioning_profile` | không có | một hồ sơ được nhúng dưới dạng `Contents/embedded.provisionprofile` trước khi ký; nó phải khớp với mã nhận dạng, quyền lợi và danh tính ký của ứng dụng và không thể được sử dụng với chức năng ký đặc biệt. Xem [hồ sơ cung cấp](distribution.md#provisioning-profiles) |
| `dmg_title` | cái tên | tên ổ đĩa của ảnh đĩa |
| `info_plist` | không có | các khóa được thêm vào `Info.plist`, thay thế các khóa của myzig |

```zig
.macos = .{
    .signing_identity = "Developer ID Application: Example Inc. (TEAMID)",
    .entitlements = "resources/macos/app.entitlements",
    .info_plist = .{ .NSCameraUsageDescription = "Scans documents", .LSUIElement = true },
},
```

<a id="updates"></a>

## Cập nhật

Đã ký [cập nhật](updates.md). `public_key` và một trong `github` và `url` là bắt buộc.

| lĩnh vực | mặc định | |
|---|---|---|
| `public_key` | | nội dung của `myzig-update.pub` ([`myzig keygen`](cli.md#myzig-keygen)) |
| `github` | | kho lưu trữ công cộng (`owner/name`) có bản phát hành chứa các bản cập nhật; ứng dụng đọc bản kê khai của bản phát hành mới nhất |
| `tag_prefix` | `v` | thẻ của bản phát hành: `v1.2.0` |
| `url` | | thư mục HTTPS phục vụ các bản cập nhật thay vì GitHub |
| `s3` | | nhóm phục vụ `url`, `--upload` đặt các tệp vào: `bucket`, `prefix` (thư mục của nó), `region`, `endpoint` (một dịch vụ tương thích, như của Cloudflare R2), `path_style` |
| `private_key` | | đường dẫn của `myzig-update.key` (có thể bắt đầu bằng `~/`); `MYZIG_UPDATER_PRIVATE_KEY` đến trước |
| `changelog` | `CHANGELOG.md` khi nó tồn tại | tệp Markdown có phần `## <version>` là ghi chú phát hành |

```zig
.updates = .{
    .public_key = "…",
    .url = "https://downloads.example.com/my-app",
    .s3 = .{ .bucket = "downloads", .prefix = "my-app", .endpoint = "https://<account>.r2.cloudflarestorage.com" },
},
```

<a id="windows"></a>

## Các cửa sổ

| lĩnh vực | mặc định | |
|---|---|---|
| `installer` | true | viết tập lệnh của trình cài đặt NSIS và tạo trình cài đặt khi `makensis` được cài đặt |
| `uninstall_run` | không có | đối số mà trình gỡ cài đặt chạy ứng dụng và chờ đợi trước khi lấy đi các tệp của nó: để ứng dụng hoàn tác những gì nó tự thiết lập (một lệnh trên `PATH`, menu của File Explorer) |
| `uninstall_data` | không có | các thư mục chứa dữ liệu của ứng dụng, dưới dạng đường dẫn NSIS (`$APPDATA\\MyApp`), trình gỡ cài đặt cũng đề nghị xóa, hãy hỏi trước; việc gỡ cài đặt im lặng sẽ giữ chúng |

## linux

| lĩnh vực | mặc định | |
|---|---|---|
| `maintainer` | cái tên | `Maintainer` của gói Debian |
| `comment` | không có | mục nhập trên máy tính để bàn của `Comment` |
| `categories` | `Utility` | mục nhập trên máy tính để bàn của `Categories` |
| `depends` | không có | nhiều phần phụ thuộc Debian hơn, sau GTK 3 và WebKitGTK |
| `command` | không có | một lệnh trong `/usr/bin` chạy ứng dụng (chữ cái, chữ số, `.`, `_`, `+`, `-`) |

## myzig.json

Các trường tương tự trong JSON:

```json
{
  "name": "Hello",
  "dev_url": "http://localhost:5173",
  "file_associations": [{ "ext": ["md"], "name": "Markdown" }],
  "windows": { "installer": false }
}
```

<a id="how-it-is-read"></a>

## Nó được đọc như thế nào

CLI đọc tệp bằng trình đọc ZON riêng (`cli/src/zon.zig`, để nó đọc giống nhau trên các phiên bản Zig và cho biết lỗi ở đâu), điền vào các giá trị mặc định (từ `build.zig.zon` và thư mục) rồi kiểm tra kết quả: tiện ích mở rộng không có dấu chấm, URL scheme và mã nhận dạng theo yêu cầu của hệ thống, `dev_url` URL http(s), `role` `Editor` hoặc `Viewer`. `Config` trong `cli/src/config.zig` là tài liệu tham khảo.
