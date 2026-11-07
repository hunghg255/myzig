<a id="configuration"></a>

# Cấu hình

[CLI](cli.md) đọc cấu hình của app từ `myzig.zon` ở thư mục gốc của app, hoặc từ `myzig.json` (không dùng cả hai). Cấu hình cho CLI biết cách chạy, đóng gói và đặt tên app.

```zig
.{
    .name = "My App",
    .identifier = "com.example.myapp",
    .version = "1.2.0",              // mặc định: lấy từ build.zig.zon
    .copyright = "© 2026 Example Inc.",
    .icon = "resources/icon.png",    // mặc định nếu file tồn tại
    .executable = "my_app",          // artifact mà build.zig cài đặt
    .frontend = "frontend",          // mã nguồn của frontend web
    .frontend_dist = "frontend",     // thứ mà build.zig nhúng vào
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

- Mọi trường đều không bắt buộc. Không có file thì các giá trị mặc định bên dưới được dùng.
- Bản thân Zig không bao giờ đọc file này: `zig build` build app từ `build.zig` và `build.zig.zon`.
- Đường dẫn tính từ thư mục gốc của app, hoặc là đường dẫn tuyệt đối.
- Trường mà CLI không biết là lỗi, kèm tên trường (`myzig.zon has no field nmae`). Giá trị sai kiểu cũng vậy.
- Lỗi cú pháp ZON báo dòng và cột.

<a id="the-app"></a>

## App

| Trường | Mặc định | |
|---|---|---|
| `name` | tên thư mục | tên người dùng nhìn thấy: tên của bundle, của trình cài đặt, của window class |
| `identifier` | `com.myzig.<name>` | tên kiểu DNS đảo ngược (chữ cái, chữ số, `.` và `-`), như `com.example.myapp`: bundle identifier, khóa gỡ cài đặt, tên trong manifest của Windows |
| `version` | `.version` của `build.zig.zon`, nếu không có thì `0.1.0` | phiên bản của package và trình cài đặt (Windows lấy tối đa bốn số) |
| `copyright` | không có | `NSHumanReadableCopyright` của macOS, `LegalCopyright` của Windows |
| `icon` | `resources/icon.png` nếu file tồn tại | một ảnh PNG vuông (tốt nhất 1024 pixel): `.icns`, `.ico` và các kích thước cho Linux được tạo từ nó |
| `executable` | `.name` của `build.zig.zon`, nếu không có thì tên app dạng snake case | artifact mà `build.zig` cài đặt (`zig-out/bin/<executable>`) |

- `name`, `version` và `identifier` không được chứa dấu nháy hay ký tự điều khiển.
- Giữ `identifier` giống `AppOptions.id` trong code của app. Id đó đặt tên cho khóa single instance, handler URL và secret của app (xem [App](app.md)).

<a id="development-and-the-frontend"></a>

## Phát triển và frontend

| Trường | Mặc định | |
|---|---|---|
| `frontend` | `frontend` nếu thư mục tồn tại | mã nguồn frontend web, nơi `generate` và `dev` ghi `myzig.js` và `myzig.d.ts` |
| `frontend_dist` | `frontend` | frontend đã build mà app nhúng vào; CLI ghi `myzig_assets.zig` của nó và truyền vào qua `-Dfrontend` |
| `dev_url` | không có | một URL `http://` hoặc `https://`: `myzig dev` chờ URL này và truyền nó qua `MYZIG_DEV_URL` |
| `dev_command` | không có | dev server mà `myzig dev` chạy trước (`bun run dev`), trong shell, ở thư mục gốc của app |
| `build_command` | không có | lệnh `myzig build` chạy trước để build frontend (`bun run build`) |
| `out` | `dist` | nơi `myzig build` đặt các package |
| `watch` | không có | được chấp nhận; `myzig dev` vốn đã theo dõi toàn bộ thư mục app |

- Frontend không cần build (HTML thuần, như template web) chỉ có `frontend`: app nhúng thẳng mã nguồn.
- Frontend build bằng Vite hay công cụ khác đặt `frontend_dist` là thư mục output, cùng `dev_command`, `dev_url` và `build_command`:

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

Xem [Frontend](frontend.md) cho phía trang web.

<a id="integration"></a>

## Tích hợp với hệ thống

| Trường | Mặc định | |
|---|---|---|
| `resources` | không có | file và thư mục đi kèm app, ngoài những gì có trong `resources/` |
| `url_schemes` | không có | các URL scheme app mở được (`myapp` cho `myapp://...`): chữ cái, chữ số, `+`, `-` và `.`, bắt đầu bằng chữ cái |
| `file_associations` | không có | các loại file app mở được |

Mọi thứ trong `resources/`, trừ icon, cũng đi kèm app: xem [Phân phối](distribution.md#resources).

Một file association gồm:

| Trường | Mặc định | |
|---|---|---|
| `ext` | bắt buộc | phần mở rộng, không có dấu chấm (`.{ "md", "markdown" }`) |
| `name` | `<EXT> file` | tên của loại file trong hệ thống |
| `mime_type` | `application/x-<executable>-<ext>` | kiểu MIME; package Linux định nghĩa kiểu này khi nó thuộc về myzig |
| `role` | `Editor` | `Editor` hoặc `Viewer` (macOS) |

Các package đăng ký chúng với hệ thống:

- macOS: `CFBundleURLTypes` và `CFBundleDocumentTypes` trong bundle;
- Windows: các khóa registry do trình cài đặt ghi;
- Linux: `MimeType=` trong desktop entry.

App cũng khai báo chúng trong tùy chọn của mình, `AppOptions.url_schemes` và `AppOptions.file_extensions`. Nhờ đó các lần khởi chạy với tham số như vậy sẽ tới `on_open_url` và `on_open_file`. App cũng có thể đăng ký chúng khi đang chạy (`myzig.system.registerUrlScheme`, `registerFileType`; xem [Hệ thống](system.md)).

<a id="macos"></a>

## macos

| Trường | Mặc định | |
|---|---|---|
| `minimum_system_version` | `12.0` | `LSMinimumSystemVersion` |
| `signing_identity` | `-` | identity cho `codesign`; `-` ký ad hoc (chạy được trên chiếc Mac đã build nó) |
| `entitlements` | không có | file entitlements cho `codesign` |
| `provisioning_profile` | không có | profile được nhúng thành `Contents/embedded.provisionprofile` trước khi ký (xem bên dưới) |
| `dmg_title` | tên app | tên volume của ảnh đĩa |
| `icon` | không có | file `.icns` mà bundle dùng thay cho icon render từ `icon` (xem bên dưới) |
| `info_plist` | không có | các khóa thêm vào `Info.plist`, thay thế khóa của myzig |

- `provisioning_profile` phải khớp identifier, entitlements và signing identity của app. Không dùng được với ký ad hoc. Xem [provisioning profile](distribution.md#provisioning-profiles).
- `icon` dành cho icon vẽ riêng từng kích thước, tạo bằng `iconutil` từ một `.iconset`. `myzig dev` hiện file PNG.

```zig
.macos = .{
    .signing_identity = "Developer ID Application: Example Inc. (TEAMID)",
    .entitlements = "resources/macos/app.entitlements",
    .info_plist = .{ .NSCameraUsageDescription = "Scans documents", .LSUIElement = true },
},
```

<a id="updates"></a>

## updates

[Cập nhật](updates.md) có chữ ký. Bắt buộc có `public_key` và một trong hai `github` hoặc `url`.

| Trường | Mặc định | |
|---|---|---|
| `public_key` | | nội dung của `myzig-update.pub` ([`myzig keygen`](cli.md#myzig-keygen)) |
| `github` | | repository công khai (`owner/name`) có các release chứa bản cập nhật; app đọc manifest của release mới nhất |
| `tag_prefix` | `v` | tag của các release: `v1.2.0` |
| `url` | | một thư mục HTTPS phục vụ bản cập nhật thay cho GitHub |
| `s3` | | bucket phục vụ `url`, nơi `--upload` đưa file lên: `bucket`, `prefix` (thư mục trong bucket), `region`, `endpoint` (của một dịch vụ tương thích, như Cloudflare R2), `path_style` |
| `private_key` | | đường dẫn tới `myzig-update.key` (có thể bắt đầu bằng `~/`); `MYZIG_UPDATER_PRIVATE_KEY` được ưu tiên |
| `changelog` | `CHANGELOG.md` nếu file tồn tại | file Markdown có mục `## <version>` làm release notes |

```zig
.updates = .{
    .public_key = "…",
    .url = "https://downloads.example.com/my-app",
    .s3 = .{ .bucket = "downloads", .prefix = "my-app", .endpoint = "https://<account>.r2.cloudflarestorage.com" },
},
```

<a id="windows"></a>

## windows

| Trường | Mặc định | |
|---|---|---|
| `installer` | true | ghi script cho trình cài đặt NSIS, và tạo trình cài đặt nếu đã cài `makensis` |
| `uninstall_run` | không có | tham số trình gỡ cài đặt dùng để chạy app, và chờ app chạy xong, trước khi xóa file |
| `uninstall_data` | không có | các thư mục dữ liệu của app, dạng đường dẫn NSIS (`$APPDATA\\MyApp`), mà trình gỡ cài đặt đề nghị xóa luôn |
| `install_dir_name` | tên app | thư mục trong `%LOCALAPPDATA%\Programs` nơi trình cài đặt đặt app |
| `installer_include` | không có | script NSIS riêng của app mà trình cài đặt include, như `resources/installer.nsh` |

- `uninstall_run` để app gỡ những gì nó tự thiết lập: một lệnh trên `PATH`, menu của File Explorer.
- `uninstall_data` hỏi trước khi xóa. Gỡ cài đặt ở chế độ im lặng thì giữ lại các thư mục này.
- `install_dir_name` dùng chẳng hạn cho tên ASCII `ZhiLian` của một app tên `智链`. Shortcut và Settings › Apps vẫn dùng tên app. App đã cài được cập nhật tại chỗ.
- `installer_include` được include sau `MUI2.nsh` và các ngôn ngữ. Nó có thể định nghĩa các macro `customInit`, `customInstall` và `customUnInstall`. Cài đặt im lặng cũng chạy chúng.

| Macro | Chạy khi |
|---|---|
| `customInit` | trình cài đặt khởi động (`.onInit`) |
| `customInstall` | cuối quá trình cài, khi file đã nằm trong `$INSTDIR` |
| `customUnInstall` | khi gỡ cài đặt, trước khi xóa thư mục của app |

<a id="linux"></a>

## linux

| Trường | Mặc định | |
|---|---|---|
| `maintainer` | tên app | `Maintainer` của package Debian |
| `comment` | không có | `Comment` của desktop entry |
| `categories` | `Utility` | `Categories` của desktop entry |
| `depends` | không có | thêm các dependency Debian, sau GTK 3 và WebKitGTK |
| `command` | không có | một lệnh trong `/usr/bin` để chạy app (chữ cái, chữ số, `.`, `_`, `+`, `-`), hoặc một danh sách lệnh |

<a id="myzig-json"></a>

## myzig.json

Các trường giống hệt, viết bằng JSON:

```json
{
  "name": "Hello",
  "dev_url": "http://localhost:5173",
  "file_associations": [{ "ext": ["md"], "name": "Markdown" }],
  "windows": { "installer": false }
}
```

<a id="how-it-is-read"></a>

## Cách CLI đọc file

CLI đọc file bằng bộ đọc ZON riêng (`cli/src/zon.zig`). Bộ đọc này cho kết quả như nhau trên mọi phiên bản Zig và chỉ ra chỗ sai. Sau đó CLI:

1. điền các giá trị mặc định, từ `build.zig.zon` và thư mục;
2. kiểm tra kết quả: phần mở rộng không có dấu chấm, URL scheme và identifier đúng như hệ thống yêu cầu, `dev_url` là URL http(s), `role` là `Editor` hoặc `Viewer`.

`Config` trong `cli/src/config.zig` là nguồn tham chiếu.
