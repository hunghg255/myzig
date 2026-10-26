<a id="the-myzig-cli"></a>

# CLI myzig

`myzig` là công cụ dòng lệnh của các ứng dụng myzig, sau mygo's `mygo`: nó tạo các ứng dụng, chạy chúng khi bạn chỉnh sửa, ghi client TypeScript của các dịch vụ được ràng buộc của chúng, đồng thời xây dựng các bản phát hành và gói của chúng. Các ứng dụng không cần nó: mọi ứng dụng đều là một gói Zig mà `zig build` tự xây dựng và chạy, đồng thời CLI gọi `zig build` với các tùy chọn phù hợp.

```
myzig <command> [arguments]

  init <dir>      create an app (native UI, or a web frontend with --template web)
  dev [dir]       run the app, rebuilding and restarting it as its files change
  build [dir]     build the release and its packages (.app/.dmg, .exe/.zip, .deb/.tar.gz)
  generate [dir]  write the TypeScript client of the app's bound services
  icon <png>      render a PNG as .icns, .ico and the sizes platforms want
  doctor          check that this machine can build and run myzig apps
  version         print the version
```

`myzig <command> --help` in cờ của lệnh. Các ứng dụng được định cấu hình trong `myzig.zon` (hoặc `myzig.json`), được mô tả trong [Cấu hình](configuration.md).

<a id="install"></a>

## Cài đặt

CLI là một chương trình Zig trong `cli/` của kho lưu trữ myzig, một gói riêng phụ thuộc vào myzig bên cạnh nó. Xây dựng nó với Zig 0,17 và đặt nó trên `PATH`:

```sh
cd myzig/cli
zig build -Doptimize=ReleaseSafe --prefix ~/.local   # installs ~/.local/bin/myzig
myzig version
```

`zig build run -- <command>` chạy nó mà không cần cài đặt. `ZIG` đặt tên cho Zig CLI xây dựng ứng dụng với (`zig` trên `PATH` theo mặc định).

```sh
cd myzig/cli
zig build test   # unit tests: configuration, bundles, archives, resources, icons
zig build e2e    # makes apps with `myzig init` (in .zig-cache/tmp) and builds them against this checkout
```

<a id="myzig-init"></a>

## Myzig ban đầu

```sh
myzig init my-app                    # native UI drawn by myzig
myzig init my-app --template web     # a web page calling Zig
```

Tạo một ứng dụng trong một thư mục mới hoặc trống:

| tập tin | |
|---|---|
| `build.zig` | bản dựng của ứng dụng: các bước `run` và `test` cũng như các tùy chọn mà CLI đặt (`-Dstrip`, `-Dwin32-res`, `-Dwindows-gui` và `-Dfrontend` cho mẫu web) |
| `build.zig.zon` | gói, tùy thuộc vào myzig, `minimum_zig_version = "0.17.0"` |
| `src/main.zig` | một cửa sổ truy cập giao diện native với bài kiểm tra `ui.Tester`; hoặc một cửa sổ hiển thị `frontend/` có trang gọi `Greeter.greet` |
| `myzig.zon` | tên, mã nhận dạng (`com.example.<name>`) và biểu tượng của ứng dụng; `.frontend` cho mẫu web |
| `resources/icon.png` | Biểu tượng mặc định của myzig, PNG 512 pixel |
| `frontend/` | mẫu web: `index.html`, `main.js`, `style.css`, `myzig_assets.zig` và client được tạo |
| `.gitignore` | `.zig-cache/`, `zig-out/`, `.myzig/`, `dist/` |

| cờ | |
|---|---|
| `--template native\|web` | giao diện native (mặc định) hoặc một trang web |
| `--name NAME` | tên của ứng dụng (mặc định: của thư mục) |
| `--myzig PATH\|URL` | kiểm tra myzig hoặc những gì `zig fetch` tìm nạp |
| `--skip-generate` | không xây dựng mẫu web để viết client của nó |

Trong đó myzig đến từ: `--myzig`, khác `MYZIG_ROOT`, khác là kho lưu trữ myzig trên GitHub ở phiên bản CLI (`git+https://github.com/hunghg255/myzig#v0.1.10` cho CLI 0.1.10). Kiểm tra trở thành phần phụ thuộc đường dẫn (`.myzig = .{ .path = "../myzig" }`) khi có đường dẫn tương đối đến nó; một URL (hoặc bản checkout trên một ổ đĩa khác) được tìm nạp bằng `zig fetch --save=myzig`.

Bản dựng của mẫu web nhúng frontend thông qua `myzig_assets.zig`, một mô-đun mà CLI ghi để liệt kê các tệp của frontend, mỗi tệp có `@embedFile`, dưới dạng `pub const files = [_]myzig.Asset{...}`. Ứng dụng nhập nó dưới dạng `assets` và phục vụ `&assets.files`. CLI ghi lại nó bất cứ khi nào các tệp thay đổi (`generate`, `dev`, `build`), vì vậy việc thêm một trang không cần Zig; nó loại bỏ client đã tạo, các tệp dấu chấm và `node_modules`.

Sau đó:

```sh
cd my-app
myzig dev        # run it, rebuilding as you edit
zig build run    # or with Zig alone
zig build test   # the template's test
myzig build      # the release and its package
```

<a id="myzig-dev"></a>

## Myzig nhà phát triển

```sh
myzig dev [dir] [-- app arguments]
```

Xây dựng ứng dụng (Gỡ lỗi), ghi client khi ứng dụng có frontend, chạy ứng dụng và xem các tệp của ứng dụng: một thay đổi sẽ xây dựng lại ứng dụng đó và bản dựng mới sẽ thay thế bản dựng đang chạy, bản dựng này sẽ thoát trước. Bản dựng bị lỗi sẽ giữ nguyên ứng dụng đang chạy và thông báo như vậy; sửa lỗi và lưu lại. Việc thoát khỏi ứng dụng kết thúc `myzig dev`.

- **Đang xem** là của hệ thống (ReadDirectoryChangesW trên Windows, inotify trên Linux, kqueue trên macOS): không có polling nào. Các thay đổi sẽ ổn định trong 150 mili giây trước khi xây dựng lại, do đó, việc lưu của người chỉnh sửa hoặc chuyển đổi nhánh là một lần xây dựng lại. Toàn bộ thư mục ứng dụng được theo dõi ngoại trừ `.zig-cache`, `zig-out`, `.myzig`, `.git`, `node_modules`, thư mục đầu ra (`out`), các tệp CLI ghi (`myzig_assets.zig`, `myzig.js`, `myzig.d.ts`) và các tệp tạm thời của người chỉnh sửa.
- **Hai tiền tố cài đặt** lần lượt (`.myzig/dev/a` và `.myzig/dev/b`): một bản dựng không bao giờ ghi đè lên tệp thực thi đang chạy, mà Windows vẫn bị khóa.
- **Môi trường**: ứng dụng chạy với `MYZIG_DEV=1` và `MYZIG_DEV_URL` khi `dev_url` được đặt.
- **Máy chủ nhà phát triển**: với `dev_command` (`bun run dev`, ...) và `dev_url`, CLI sẽ chạy lệnh trước, đợi cho đến khi URL trả lời và dừng lệnh khi lệnh đó kết thúc. Giao diện người dùng sau đó sẽ được máy chủ tải lại (tải lại nóng của Vite) và chỉ Zig thay đổi để xây dựng lại ứng dụng, có cửa sổ tải `MYZIG_DEV_URL`:

  ```zig
  const url = init.environ_map.get("MYZIG_DEV_URL") orelse "/";
  _ = try app.newWindow(.{ .title = "App", .content = .{ .page = .{ .url = url, .assets = &assets.files } } });
  ```

  Nếu máy chủ kết thúc, `myzig dev` cũng kết thúc theo đó.

| cờ | |
|---|---|
| `--skip-dev-command` | đừng chạy `dev_command` (máy chủ của nó đã chạy rồi) |
| `-- args` | đối số được truyền cho ứng dụng |

<a id="myzig-build"></a>

## Myzig xây dựng

```sh
myzig build [dir]
myzig build --platform windows --arch x86_64
myzig build --platform macos --arch universal
myzig build --platform web
```

Xây dựng bản phát hành (ReleaseSmall và bị loại bỏ theo mặc định) và đóng gói nó trong `<out>/<platform>-<arch>` (`dist/macos-aarch64`, ...): `.app` và trên máy Mac, `.dmg`; Windows `.exe` với các tài nguyên biểu tượng, tệp kê khai và phiên bản, trong `.zip` di động chạy đã được giải nén và trình cài đặt có NSIS (`<Name> Setup <version> <arch>.exe`); thư mục Linux, `.tar.gz` và `.deb`. Linux và Windows phát hành bản dựng từ bất kỳ máy nào, vì Zig biên dịch chéo và myzig không liên kết gì với bản dựng của chúng; Các bản phát hành macOS cần có macOS SDK, `.dmg` và ký mã trên máy Mac. Xem [Phân phối](distribution.md) để biết nội dung mỗi gói chứa.

Trước khi xây dựng, nó chạy `build_command` (bản dựng của frontend) và ghi `myzig_assets.zig` cho `frontend_dist`. Nó kiểm tra xem biểu tượng có phải là PNG hình vuông không và xây dựng chỉ với các tùy chọn mà ứng dụng `build.zig` khai báo (đọc từ `zig build --help`), do đó, `build.zig` của chính ứng dụng vẫn tiếp tục hoạt động: bản phát hành ứng dụng Windows nhận được `-Dwindows-gui=true` (không có bảng điều khiển), `-Dstrip=true`, `-Dwin32-res=<app.res>` và `-Dfrontend=<frontend_dist>` khi được khai báo.

| cờ | |
|---|---|
| `--platform macos\|windows\|linux\|web` | hệ thống để xây dựng (mặc định: hệ thống này); `web` xây dựng một trang web tĩnh cho các trình duyệt trong `<out>/web` (chỉ giao diện native; xem [Trình duyệt](browsers.md)) |
| `--arch x86_64\|aarch64\|universal` | kiến trúc (mặc định: cái này); `universal` là của macOS, cả hai đều được nối thành một nhị phân |
| `--optimize small\|fast\|safe` | ReleaseSmall (mặc định), ReleaseFast hoặc ReleaseSafe (`debug` cũng vậy) |
| `--out DIR` | thư mục đầu ra (mặc định: `out` của `myzig.zon`, `dist`) |
| `--skip-build-command` | đừng chạy `build_command` |
| `--skip-dmg` | đừng tạo ảnh đĩa macOS |
| `--upload` | tải lên các gói và bản cập nhật đã ký trong đó `updates` chỉ ra: nhóm `updates.s3`, nếu không thì bản phát hành GitHub nháp của phiên bản (xem [Cập nhật](updates.md)) |

Với `updates` trong `myzig.zon` và khóa ký (`MYZIG_UPDATER_PRIVATE_KEY` hoặc `updates.private_key`), nó cũng ghi bản cập nhật đã ký của nền tảng bên cạnh các gói: tệp thực thi, dưới dạng `<name>-<version>-<platform>-<arch>` và tệp kê khai của nó, `update-<platform>-<arch>.json`. Nếu không có khóa, nó sẽ không cảnh báo và ghi gì cả, và `--upload` dừng trước khi xây dựng: bản phát hành không có bảng kê khai là bản phát hành mà các ứng dụng đã cài đặt không thể cập nhật. Quá trình xây dựng macOS cũng dừng trước khi xây dựng khi `macos.provisioning_profile` được đặt và ứng dụng được ký đặc biệt.

Các mục tiêu là `<arch>-macos`, `<arch>-windows-gnu`, `<arch>-linux-gnu` và `wasm32-wasi`. Các tệp trung gian nằm trong `.myzig/build/`.

Mọi bản dựng đều bắt đầu từ con số không: trước khi bất kỳ bản dựng nào (`build_command` cũng vậy), `myzig build` xóa `<out>` và `.myzig/build/` và tạo lại `<out>`, vì vậy nó chỉ giữ gói của bản dựng này, của một nền tảng. Các gói của một số nền tảng được xây dựng lần lượt, mỗi gói được giữ ở nơi khác (`--out dist/mac`, ...). `<out>` là thư mục của ứng dụng hoặc chứa nó sẽ bị từ chối.

<a id="myzig-generate"></a>

## Myzig tạo ra

```sh
myzig generate [dir]
```

Xây dựng ứng dụng cho máy này (vào `.myzig/generate`) và chạy nó với `--myzig-generate=<frontend>`, ghi `myzig.js` và `myzig.d.ts`, client của các dịch vụ và sự kiện bị ràng buộc của nó, vào các nguồn của frontend và thoát ra mà không hiển thị cửa sổ. Nó cần `frontend` trong `myzig.zon` (hoặc thư mục `frontend/`) và một ứng dụng gọi `app.run()`. `dev` cũng ghi client trên mọi bản dựng. Xem [Bindings](bindings.md) để biết client.

<a id="myzig-icon"></a>

## Biểu tượng myzig

```sh
myzig icon resources/icon.png              # icon.icns, icon.ico, icon-16.png ... icon-1024.png beside it
myzig icon logo.png --out resources/icons
myzig icon --new resources/icon.png        # write myzig's default icon
```

Hiển thị hình vuông PNG dưới dạng `icon.icns` (macOS), `icon.ico` (Windows) và PNG có kích thước 16, 32, 48, 64, 128, 256, 512 và 1024 pixel. `myzig build` tạo biểu tượng của nền tảng từ chính `myzig.zon` của `icon`; lệnh này dùng để xem chúng hoặc dùng cho các công cụ khác. Sử dụng PNG 1024 pixel để có kết quả sắc nét nhất.

<a id="myzig-keygen"></a>

## Myzig chìa khóa

```sh
myzig keygen                 # into <config>/myzig/update-keys
myzig keygen --out keys --force
```

Tạo cặp khóa Ed25519 ký các bản cập nhật: `myzig-update.key`, bí mật và `myzig-update.pub`, đồng thời in `updates` để đặt vào `myzig.zon`. Thư mục cấu hình là `%APPDATA%` trên Windows, `~/Library/Application Support` trên macOS và `$XDG_CONFIG_HOME` (hoặc `~/.config`) trên Linux. Giữ khóa bí mật ra khỏi kho lưu trữ, trong trình quản lý mật khẩu và bí mật của CI: các ứng dụng đã cài đặt chỉ chấp nhận các bản cập nhật được ký với nó. `--force` thay thế các phím ở đó. Xem [Cập nhật](updates.md).

<a id="myzig-doctor"></a>

## Myzig bác sĩ

Kiểm tra những gì việc xây dựng và chạy ứng dụng myzig cần trên máy này:

| | |
|---|---|
| tất cả | Zig 0,17 trở lên (`ZIG`, nếu không thì `zig` trên `PATH`) |
| macOS | macOS 12 trở lên; SDK (`xcrun --show-sdk-path`, Công cụ dòng lệnh) |
| Linux | GTK 3 (`libgtk-3.so.0`) và WebKitGTK (`libwebkit2gtk-4.1.so.0` hoặc 4.0) |
| Windows | WebView2 Runtime (các trang cần nó); không có SDK, Zig liên kết chính ứng dụng Windows |
| tùy chọn | `hdiutil` (hình ảnh đĩa), `makensis` (trình cài đặt Windows), `bun` (frontend với máy chủ nhà phát triển), `git` (tìm nạp myzig trong `init`) |

Nó thoát ra với lỗi khi kiểm tra bắt buộc không thành công.

<a id="myzig-version"></a>

## Myzig phiên bản

In phiên bản của CLI (`myzig --version`, `-v`), theo sau phiên bản của myzig (`myzig.version`).

<a id="the-flags-of-apps"></a>

## Cờ của ứng dụng

Mọi ứng dụng myzig đều hiểu những cờ này mà CLI và các bài kiểm tra sử dụng. Họ không bao giờ hiển thị một cửa sổ trên màn hình:

| cờ | |
|---|---|
| `--myzig-generate=DIR` | ghi client đã tạo (`myzig.js`, `myzig.d.ts`) vào DIR và thoát |
| `--myzig-snapshot=PNG` | hiển thị cửa sổ giao diện native đầu tiên ngoài màn hình thành PNG và thoát |
| `--myzig-script=STEPS` | với `--myzig-snapshot`: các bước chạy trước (`click:Tasks;type:Hi;key:enter`; xem [Thử nghiệm](ui/testing.md)) |
| `--myzig-dark` | với `--myzig-snapshot`: bề ngoài tối tăm |
| `--myzig-wait=SECONDS` | với `--myzig-snapshot`: chạy vòng lặp sự kiện dài như vậy trước tiên |
| `--myzig-hidden` | không bao giờ hiển thị cửa sổ; thư mục của app là thư mục tạm (headless) |
| `--myzig-eval=JS` | đánh giá JS trong mỗi trang khi DOM của nó đã sẵn sàng (ngụ ý bị ẩn); `myzig.log` in ra thiết bị lỗi chuẩn |

<a id="environment-variables"></a>

## Biến môi trường

| biến | |
|---|---|
| `ZIG` | Zig CLI chạy |
| `MYZIG_ROOT` | myzig `init` tùy thuộc vào thời điểm không cung cấp `--myzig` |
| `MYZIG_DEV` | được đặt thành `1` trong ứng dụng `myzig dev` chạy |
| `MYZIG_DEV_URL` | được đặt thành `dev_url` trong ứng dụng `myzig dev` chạy |
| `MYZIG_DEBUG` | trong ứng dụng: ghi lại id và khung của cửa sổ, cho các công cụ và kiểm tra |
| `MYZIG_UPDATER_PRIVATE_KEY` | khóa bí mật ký các bản cập nhật (trước `updates.private_key`) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | thông tin xác thực `--upload` đặt các tệp vào `updates.s3` với |
| `AWS_REGION`, `AWS_DEFAULT_REGION` | vùng của nhóm khi `updates.s3.region` không được đặt |

<a id="what-mygo-s-cli-has-that-this-one-doesn-t-yet"></a>

## CLI của mygo có những gì mà cái này chưa có

`mygo install-skills`, `mygo i18n check`, bản cập nhật delta và bản cập nhật gói macOS (`mygo build` ký vào kho lưu trữ của toàn bộ ứng dụng), `-web` tải lại trực tiếp giao diện native trong trình duyệt, ký mã trên Windows và công chứng trên macOS, đồng thời đưa thư viện gốc của plugin vào ứng dụng.
