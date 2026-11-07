<a id="the-myzig-cli"></a>

# CLI myzig

`myzig` là công cụ dòng lệnh cho app myzig, theo mẫu `mygo` của mygo. Nó tạo app, chạy app trong lúc bạn sửa code, sinh client TypeScript cho các service đã bind, và build bản release cùng các gói cài đặt.

App không bắt buộc phải dùng nó. Mỗi app là một package Zig mà `zig build` tự build và chạy được. CLI chỉ gọi `zig build` với đúng các tùy chọn.

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

`myzig <command> --help` in ra các cờ của một lệnh. App được cấu hình trong `myzig.zon` (hoặc `myzig.json`), mô tả ở trang [Cấu hình](configuration.md).

<a id="install"></a>

## Cài đặt

CLI là một chương trình Zig trong thư mục `cli/` của repo myzig. Nó là một package riêng, phụ thuộc vào bản myzig nằm cạnh nó. Build bằng Zig 0.17 rồi đưa vào `PATH`:

```sh
cd myzig/cli
zig build -Doptimize=ReleaseSafe --prefix ~/.local   # installs ~/.local/bin/myzig
myzig version
```

- `zig build run -- <command>` chạy CLI mà không cần cài.
- `ZIG` chỉ định bản Zig mà CLI dùng để build app. Mặc định là `zig` trong `PATH`.

```sh
cd myzig/cli
zig build test   # unit tests: configuration, bundles, archives, resources, icons
zig build e2e    # makes apps with `myzig init` (in .zig-cache/tmp) and builds them against this checkout
```

<a id="myzig-init"></a>

## myzig init

```sh
myzig init my-app                    # native UI drawn by myzig
myzig init my-app --template web     # a web page calling Zig
```

Tạo app trong một thư mục mới hoặc thư mục rỗng:

| file | |
|---|---|
| `build.zig` | build của app: các bước `run` và `test`, và các tùy chọn CLI đặt (`-Dstrip`, `-Dwin32-res`, `-Dwindows-gui`, và `-Dfrontend` cho template web) |
| `build.zig.zon` | package, phụ thuộc vào myzig, `minimum_zig_version = "0.17.0"` |
| `src/main.zig` | một cửa sổ counter bằng UI native kèm test `ui.Tester`; hoặc một cửa sổ hiển thị `frontend/` có trang gọi `Greeter.greet` |
| `myzig.zon` | tên app, định danh (`com.example.<name>`) và icon; `.frontend` cho template web |
| `resources/icon.png` | icon mặc định của myzig, PNG 512 pixel |
| `frontend/` | template web: `index.html`, `main.js`, `style.css`, `myzig_assets.zig`, và client được sinh |
| `.gitignore` | `.zig-cache/`, `zig-out/`, `.myzig/`, `dist/` |

| cờ | |
|---|---|
| `--template native\|web` | UI native (mặc định), hoặc trang web |
| `--name NAME` | tên app (mặc định: tên thư mục) |
| `--myzig PATH\|URL` | một bản checkout của myzig, hoặc thứ mà `zig fetch` tải về |
| `--skip-generate` | không build template web để sinh client |

myzig được lấy từ đâu, theo thứ tự ưu tiên:

1. `--myzig`;
2. `MYZIG_ROOT`;
3. repo myzig trên GitHub ở đúng phiên bản của CLI (`git+https://github.com/hunghg255/myzig#v0.1.20` với CLI 0.1.20).

Bản checkout tới được bằng đường dẫn tương đối sẽ thành dependency dạng path (`.myzig = .{ .path = "../myzig" }`). URL, hoặc bản checkout nằm trên ổ đĩa khác, được tải bằng `zig fetch --save=myzig`.

Build của template web nhúng frontend qua `myzig_assets.zig`:

- CLI tự viết module này. Nó liệt kê các file của frontend, mỗi file qua `@embedFile`, dưới dạng `pub const files = [_]myzig.Asset{...}`.
- App import nó với tên `assets` và phục vụ `&assets.files`.
- CLI viết lại module mỗi khi file thay đổi (`generate`, `dev`, `build`). Thêm trang không cần đụng tới Zig.
- Nó bỏ qua client được sinh, file bắt đầu bằng dấu chấm và `node_modules`.

Sau đó:

```sh
cd my-app
myzig dev        # run it, rebuilding as you edit
zig build run    # or with Zig alone
zig build test   # the template's test
myzig build      # the release and its package
```

<a id="myzig-dev"></a>

## myzig dev

```sh
myzig dev [dir] [-- app arguments]
```

Build app (Debug), sinh client nếu app có frontend, chạy app, và theo dõi các file của nó.

- Có thay đổi thì build lại. Bản build mới thay cho bản đang chạy, bản cũ thoát trước.
- Build lỗi thì app đang chạy vẫn giữ nguyên, và CLI báo lỗi. Sửa lỗi rồi lưu lại.
- Thoát app thì `myzig dev` cũng kết thúc.
- **Theo dõi file** dùng cơ chế của hệ thống: ReadDirectoryChangesW trên Windows, inotify trên Linux, kqueue trên macOS. Không polling.
  - Thay đổi được gom trong 150 ms trước khi build lại. Một lần lưu của editor hay một lần đổi branch chỉ tốn một lần build.
  - Cả thư mục app được theo dõi, trừ `.zig-cache`, `zig-out`, `.myzig`, `.git`, `node_modules`, thư mục output (`out`), các file CLI tự viết (`myzig_assets.zig`, `myzig.js`, `myzig.d.ts`) và file tạm của editor.
- **Hai prefix cài đặt** dùng luân phiên (`.myzig/dev/a` và `.myzig/dev/b`). Build không bao giờ ghi đè file thực thi đang chạy, vốn bị Windows khóa.
- **Biến môi trường**: app chạy với `MYZIG_DEV=1`, và `MYZIG_DEV_URL` khi có đặt `dev_url`.
- **Dev server**: đặt `dev_command` (`bun run dev`, ...) và `dev_url`.
  - CLI chạy lệnh đó trước, chờ tới khi URL trả lời, và dừng nó khi kết thúc.
  - Server tự reload frontend (hot reload của Vite). Chỉ thay đổi ở Zig mới build lại app, và cửa sổ của app nạp `MYZIG_DEV_URL`:

  ```zig
  const url = init.environ_map.get("MYZIG_DEV_URL") orelse "/";
  _ = try app.newWindow(.{ .title = "App", .content = .{ .page = .{ .url = url, .assets = &assets.files } } });
  ```

  Server dừng thì `myzig dev` cũng dừng theo.

| cờ | |
|---|---|
| `--skip-dev-command` | không chạy `dev_command` (server đã chạy sẵn) |
| `-- args` | tham số truyền cho app |

<a id="myzig-build"></a>

## myzig build

```sh
myzig build [dir]
myzig build --platform windows --arch x86_64
myzig build --platform windows --arch x86
myzig build --platform macos --arch universal
myzig build --platform web
```

Build bản release, mặc định là ReleaseSmall và đã strip. Kết quả được đóng gói vào `<out>/<platform>-<arch>` (`dist/macos-aarch64`, ...):

| nền tảng | gói |
|---|---|
| macOS | một `.app` và, nếu build trên Mac, một `.dmg` |
| Windows | một `.exe` kèm icon, manifest và tài nguyên phiên bản; một `.zip` portable chạy được ngay sau khi giải nén; một bộ cài bằng NSIS (`<slug>-setup-<version>-<arch>.exe`) |
| Linux | một thư mục, một `.tar.gz` và một `.deb` |

- Bản release cho Linux và Windows build được từ bất kỳ máy nào. Zig cross-compile, và myzig không link thư viện nào của các hệ đó.
- Bản release cho macOS cần macOS SDK. `.dmg` và việc ký code cần một máy Mac.

Xem [Phân phối](distribution.md) để biết mỗi gói chứa gì.

Trước khi build, nó:

- chạy `build_command` (build của frontend);
- viết `myzig_assets.zig` cho `frontend_dist`;
- kiểm tra icon là PNG vuông.

Nó build chỉ với các tùy chọn mà `build.zig` của app khai báo, đọc từ `zig build --help`. Nhờ vậy `build.zig` riêng của app vẫn chạy được. Bản release của app Windows nhận các tùy chọn sau nếu có khai báo: `-Dwindows-gui=true` (không có console), `-Dstrip=true`, `-Dwin32-res=<app.res>` và `-Dfrontend=<frontend_dist>`.

| cờ | |
|---|---|
| `--platform macos\|windows\|linux\|web` | hệ thống đích (mặc định: máy hiện tại); `web` build một site tĩnh cho trình duyệt vào `<out>/web` (chỉ UI native; xem [Trình duyệt](browsers.md)) |
| `--arch x86_64\|aarch64\|x86\|universal` | kiến trúc (mặc định: máy hiện tại); `x86` là 32-bit, cho Windows và Linux (cũng nhận `386`, `i386`); `universal` là của macOS, gộp cả hai vào một binary |
| `--optimize small\|fast\|safe` | ReleaseSmall (mặc định), ReleaseFast hoặc ReleaseSafe (có cả `debug`) |
| `--out DIR` | thư mục output (mặc định: `out` trong `myzig.zon`, `dist`) |
| `--skip-build-command` | không chạy `build_command` |
| `--skip-dmg` | không tạo disk image cho macOS |
| `--skip-installer` | không tạo bộ cài Windows, cũng không tìm NSIS |
| `--upload` | tải các gói và bản cập nhật đã ký lên nơi `updates` trỏ tới: bucket của `updates.s3`, nếu không thì một bản nháp GitHub release của phiên bản đó (xem [Cập nhật](updates.md)) |

**Bản cập nhật đã ký.** Đặt `updates` trong `myzig.zon` và cung cấp khóa ký (`MYZIG_UPDATER_PRIVATE_KEY`, hoặc `updates.private_key`). Khi đó build viết thêm bản cập nhật đã ký của nền tảng cạnh các gói:

- file thực thi, tên `<name>-<version>-<platform>-<arch>`;
- manifest của nó, `update-<platform>-<arch>.json`.

Không có khóa thì nó cảnh báo và không viết gì cả. Khi đó `--upload` dừng trước khi build: app đã cài không thể cập nhật lên một bản release thiếu manifest. Build macOS cũng dừng trước khi build nếu có đặt `macos.provisioning_profile` mà app chỉ được ký ad hoc.

Các target là `<arch>-macos`, `<arch>-windows-gnu`, `<arch>-linux-gnu` và `wasm32-wasi`. File trung gian nằm trong `.myzig/build/`.

**Mỗi lần build bắt đầu từ con số không.** Trước khi build bất cứ thứ gì, kể cả `build_command`:

- `myzig build` xóa `<out>` và `.myzig/build/` rồi tạo lại `<out>`. Thư mục này chỉ chứa gói của lần build này, cho một nền tảng.
- Muốn có gói cho nhiều nền tảng thì build lần lượt, mỗi lần để ở chỗ khác (`--out dist/mac`, ...).
- `<out>` trùng với thư mục app hoặc chứa thư mục app sẽ bị từ chối.

<a id="myzig-generate"></a>

## myzig generate

```sh
myzig generate [dir]
```

Build app cho máy hiện tại (vào `.myzig/generate`) và chạy nó với `--myzig-generate=<frontend>`. Lệnh này viết `myzig.js` và `myzig.d.ts`, client của các service và event đã bind, vào mã nguồn frontend. App thoát mà không hiện cửa sổ nào.

- Cần có `frontend` trong `myzig.zon` (hoặc thư mục `frontend/`), và app phải gọi `app.run()`.
- `dev` cũng sinh client ở mỗi lần build.

Xem [Binding](bindings.md) về client.

<a id="myzig-icon"></a>

## myzig icon

```sh
myzig icon resources/icon.png              # icon.icns, icon.ico, icon-16.png ... icon-1024.png beside it
myzig icon logo.png --out resources/icons
myzig icon --new resources/icon.png        # write myzig's default icon
```

Chuyển một PNG vuông thành `icon.icns` (macOS), `icon.ico` (Windows) và các PNG 16, 32, 48, 64, 128, 256, 512 và 1024 pixel.

- `myzig build` tự tạo icon cho các nền tảng từ `icon` trong `myzig.zon`. Lệnh này để bạn xem trước, hoặc dùng cho công cụ khác.
- Dùng PNG 1024 pixel để có kết quả sắc nét nhất.

<a id="myzig-keygen"></a>

## myzig keygen

```sh
myzig keygen                 # into <config>/myzig/update-keys
myzig keygen --out keys --force
```

Tạo cặp khóa Ed25519 để ký bản cập nhật: `myzig-update.key` là khóa bí mật, và `myzig-update.pub`. Lệnh in ra phần `updates` cần đưa vào `myzig.zon`.

- Thư mục cấu hình là `%APPDATA%` trên Windows, `~/Library/Application Support` trên macOS và `$XDG_CONFIG_HOME` (hoặc `~/.config`) trên Linux.
- Đừng để khóa bí mật trong repo; hãy giữ nó trong trình quản lý mật khẩu và secrets của CI. App đã cài chỉ nhận bản cập nhật ký bằng khóa này.
- `--force` thay thế khóa đã có.

Xem [Cập nhật](updates.md).

<a id="myzig-doctor"></a>

## myzig doctor

Kiểm tra những gì máy này cần để build và chạy app myzig:

| | |
|---|---|
| tất cả | Zig 0.17 trở lên (`ZIG`, nếu không thì `zig` trong `PATH`) |
| macOS | macOS 12 trở lên; SDK (`xcrun --show-sdk-path`, Command Line Tools) |
| Linux | GTK 3 (`libgtk-3.so.0`) và WebKitGTK (`libwebkit2gtk-4.1.so.0` hoặc 4.0) |
| Windows | WebView2 Runtime (trang web cần nó); không cần SDK, Zig tự link app Windows |
| tùy chọn | `hdiutil` (disk image), `makensis` (bộ cài Windows), `bun` (frontend có dev server), `git` (tải myzig trong `init`) |

Lệnh thoát với lỗi khi một mục bắt buộc không đạt.

<a id="myzig-version"></a>

## myzig version

In ra phiên bản của CLI (`myzig --version`, `-v`). Phiên bản này theo phiên bản của myzig (`myzig.version`).

<a id="the-flags-of-apps"></a>

## Các cờ của app

Mọi app myzig đều hiểu các cờ sau, được CLI và test dùng. Chúng không bao giờ hiện cửa sổ lên màn hình:

| cờ | |
|---|---|
| `--myzig-generate=DIR` | viết client được sinh (`myzig.js`, `myzig.d.ts`) vào DIR rồi thoát |
| `--myzig-snapshot=PNG` | render cửa sổ UI native đầu tiên offscreen ra PNG rồi thoát |
| `--myzig-script=STEPS` | đi kèm `--myzig-snapshot`: các bước chạy trước (`click:Tasks;type:Hi;key:enter`; xem [Test](ui/testing.md)) |
| `--myzig-dark` | đi kèm `--myzig-snapshot`: giao diện tối |
| `--myzig-wait=SECONDS` | đi kèm `--myzig-snapshot`: chạy event loop trong khoảng thời gian đó trước |
| `--myzig-hidden` | không bao giờ hiện cửa sổ; các thư mục của app là thư mục tạm (headless) |
| `--myzig-eval=JS` | chạy JS trong mỗi trang khi DOM sẵn sàng (ngầm định hidden); `myzig.log` in ra stderr |

<a id="environment-variables"></a>

## Biến môi trường

| biến | |
|---|---|
| `ZIG` | bản Zig mà CLI chạy |
| `MYZIG_ROOT` | bản myzig mà `init` phụ thuộc vào, khi không có `--myzig` |
| `MYZIG_DEV` | đặt là `1` trong app do `myzig dev` chạy |
| `MYZIG_DEV_URL` | đặt bằng `dev_url` trong app do `myzig dev` chạy |
| `MYZIG_DEBUG` | trong app: log id và frame của cửa sổ, cho công cụ và test |
| `MYZIG_UPDATER_PRIVATE_KEY` | khóa bí mật ký bản cập nhật (ưu tiên hơn `updates.private_key`) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | thông tin đăng nhập mà `--upload` dùng để đưa file vào `updates.s3` |
| `AWS_REGION`, `AWS_DEFAULT_REGION` | region của bucket, khi không đặt `updates.s3.region` |

<a id="what-mygo-s-cli-has-that-this-one-doesn-t-yet"></a>

## Những gì CLI của mygo có mà CLI này chưa có

- `mygo install-skills`
- `mygo i18n check`
- cập nhật delta, và cập nhật cả bundle trên macOS (`mygo build` ký một archive chứa toàn bộ app)
- live reload `-web` của UI native trong trình duyệt
- ký code trên Windows và notarization trên macOS
- đưa thư viện native của plugin vào app
