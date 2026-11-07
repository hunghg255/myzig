<a id="building-and-distributing"></a>

# Build và phân phối

`myzig build` tạo bản release của app và các gói để người dùng cài đặt, cho macOS, Windows, Linux và trình duyệt:

```sh
myzig build                                   # this machine's platform and architecture
myzig build --platform windows --arch x86_64  # any platform, from any machine
myzig build --platform windows --arch x86     # 32-bit Windows
myzig build --platform macos --arch universal # Apple silicon and Intel in one binary
myzig build --platform web                    # a static site (native UI only)
```

- Bản release được build bằng ReleaseSmall và đã strip. `--optimize fast` hoặc `safe` để chọn chế độ khác.
- Nó nằm trong `dist/<platform>-<arch>`, hoặc `out` trong [myzig.zon](configuration.md), hoặc `--out`. Mỗi lần build sẽ xóa trống thư mục này trước.
- Các flag nằm ở [trang CLI](cli.md#myzig-build).

| nền tảng | những gì `myzig build` tạo ra |
|---|---|
| macOS | `<Name>.app`; trên Mac thì được ký (mặc định ad hoc) kèm `<slug>-<version>-<arch>.dmg`; ở nơi khác là `<Name>-<version>-macos-<arch>.zip` chứa bundle |
| Windows | hai cách phát hành: `<slug>-portable-<version>-<arch>.zip`, chạy ngay tại chỗ giải nén và không cài gì (`<Name>/<Name>.exe` kèm icon, manifest và thông tin phiên bản, các resource nằm cạnh, cũng được để sẵn ở dạng chưa nén), và `<slug>-setup-<version>-<arch>.exe`, bộ cài NSIS, khi đã cài `makensis` (không có thì một cảnh báo chỉ cách cài) |
| Linux | `<executable>/` (file thực thi, desktop entry và icon của nó, các resource); `<executable>-<version>-linux-<arch>.tar.gz`; `<package>_<version>_<arch>.deb` |
| trình duyệt | `dist/web`: `index.html`, các script của host, `app.wasm` và font (xem [Trình duyệt](browsers.md)) |

`<slug>` là tên file thực thi viết thường, nối bằng gạch ngang, như `my-app` cho `my_app`. Disk image và các gói Windows được đặt theo tên này, vì GitHub bỏ các ký tự không phải ASCII khỏi tên file của một release.

<a id="platforms"></a>

## Nền tảng

Bản release cho Linux và Windows build được từ bất kỳ máy nào:

- Zig biên dịch chéo được.
- myzig nạp những gì Linux và Windows có sẵn thay vì link chúng: GTK và WebKitGTK bằng `dlopen`, loader của WebView2 bằng `LoadLibrary`.

Bản release macOS link các framework của Apple, việc này cần macOS SDK. Hãy build chúng trên Mac (Xcode hoặc Command Line Tools). Disk image (`hdiutil`) và ký code (`codesign`) cũng cần Mac.

Khi file thực thi macOS được link ngoài Mac (có cung cấp SDK), `myzig build --platform macos` nén bundle thành zip thay vì tạo disk image. File zip giữ quyền của file thực thi và chữ ký ad hoc mà linker của Zig gắn vào, thứ mà Apple silicon cần để chạy nó.

Bản release cần gì ở máy chạy nó:

| nền tảng | cần |
|---|---|
| macOS | macOS 12 trở lên (`macos.minimum_system_version`) |
| Windows | Windows 10 trở lên; WebView2 Runtime cho page (có sẵn trong Windows 11 và phần lớn bản cài Windows 10) |
| Linux | GTK 3; WebKitGTK 4.1 cho page. Gói `.deb` phụ thuộc `libgtk-3-0` và `libwebkit2gtk-4.1-0` |

App native UI không cần webview ở đâu cả. Một bản release là một file thực thi duy nhất, từ dưới một megabyte tới vài megabyte: myzig không có runtime nào phải kèm theo.

<a id="name-icon-and-version"></a>

## Tên, icon và phiên bản

Chúng lấy từ `myzig.zon`, với giá trị mặc định từ `build.zig.zon` và tên thư mục (xem [Cấu hình](configuration.md#the-app)):

- `name` là tên của bundle, file `.exe`, bộ cài và các menu.
- `executable` là artifact mà `build.zig` cài đặt. Nó là tên gói và tên lệnh trên Linux.
- `version` được ghi vào `Info.plist` (`CFBundleVersion`, `CFBundleShortVersionString`), thông tin phiên bản của Windows và gói Debian.
  - Windows nhận tối đa bốn số: `1.2.3` thành 1.2.3.0.
  - Debian: `1.2.0-beta-1` thành `1.2.0~beta.1`.
  - Hãy để nó trong `build.zig.zon` và bỏ khỏi `myzig.zon`, để chỉ có một chỗ phải sửa.
- `icon` là một ảnh PNG vuông. `myzig icon` hiện các icon mà CLI tạo ra từ nó, `myzig icon --new` ghi ra icon mặc định. CLI tạo ra:
  - `icon.icns` trong `Resources` của bundle;
  - nhóm icon của file `.exe` (16 tới 256 pixel) và file `.ico` của bộ cài;
  - ảnh PNG 512 pixel cạnh file thực thi trên Linux, và PNG 256 và 512 pixel trong theme `hicolor` của gói `.deb`.

<a id="resources"></a>

## Resource

Các file mà app đọc lúc chạy được phát hành kèm bên cạnh nó: mọi thứ trong thư mục `resources/` của app trừ icon, và các file và thư mục mà `resources` trong `myzig.zon` liệt kê.

| nền tảng | chúng nằm ở đâu |
|---|---|
| macOS | `<Name>.app/Contents/Resources/` |
| Windows | cạnh `<Name>.exe` (và trong bộ cài) |
| Linux | cạnh file thực thi, `/opt/<executable>/` trong gói `.deb` |

File mà app nhúng vào (`@embedFile`, `myzig_assets.zig` của frontend) không cần resource: chúng nằm sẵn trong file thực thi.

- Nhúng những gì nhỏ và cố định.
- Phát hành dưới dạng resource những gì lớn, có giấy phép riêng, hoặc là thư viện native. Thư viện của [plugin terminal](plugins/terminal.md) là loại này, và plugin tìm chúng cạnh file thực thi.

App tìm thư mục chứa file thực thi của nó bằng `std.process.executableDirPath(io, &buf)`. Trên macOS đó là `Contents/MacOS`, và `../Resources` của nó chứa các resource.

<a id="macos"></a>

## macOS

`<Name>.app/Contents` chứa:

- `MacOS/<Name>`, file thực thi. Với `--arch universal`, đây là một universal binary, được CLI ghép lại như `lipo` làm, mỗi phần căn theo 16 KiB.
- `Info.plist`: `CFBundleName`, `CFBundleDisplayName`, `CFBundleIdentifier`, các phiên bản, `CFBundleExecutable`, `LSMinimumSystemVersion`, `NSPrincipalClass` (`NSApplication`), `NSHighResolutionCapable`, `NSSupportsAutomaticGraphicsSwitching`, `CFBundleIconFile`, `NSHumanReadableCopyright`, `CFBundleDocumentTypes` cho `file_associations` và `CFBundleURLTypes` cho `url_schemes`.
- `Resources/`: `icon.icns` và các resource.

`macos.info_plist` thêm key hoặc thay key của myzig. Dùng nó cho các mô tả mục đích sử dụng (`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`) hoặc `LSUIElement` cho app sống trên thanh menu.

<a id="signing"></a>

### Ký code

Trên Mac, bundle được ký bằng `codesign --force --deep --sign <macos.signing_identity>`.

- Mặc định là `-`, ký ad hoc. App chạy được trên chiếc Mac đã build nó, và trên máy khác sau khi người dùng cho phép.
- Với Developer ID (`"Developer ID Application: Example Inc. (TEAMID)"`), CLI bật thêm hardened runtime (`--options runtime`) và timestamp an toàn. Nó thêm `macos.entitlements` khi có, và ký cả disk image.

CLI chưa làm notarization. Sau `myzig build`, hãy gửi disk image lên và staple ticket:

```sh
xcrun notarytool submit dist/macos-aarch64/my-app-1.0.0-aarch64.dmg --keychain-profile notary --wait
xcrun stapler staple dist/macos-aarch64/my-app-1.0.0-aarch64.dmg
```

<a id="provisioning-profiles"></a>

### Provisioning profile

Các entitlement bị hạn chế, như Communication Notifications, cần một provisioning profile cho phép chúng, kể cả khi phân phối bằng Developer ID. Đặt `macos.provisioning_profile` là đường dẫn tới nó, tương đối theo project hoặc tuyệt đối. `myzig build` copy nó vào `Contents/embedded.provisionprofile` của bundle trước khi ký, nên app đã ký và disk image của nó đều chứa profile.

```zig
.macos = .{
    .signing_identity = "Developer ID Application: Example Inc. (TEAMID)",
    .provisioning_profile = "profiles/App.provisionprofile",
    .entitlements = "resources/macos/app.entitlements",
},
```

- Profile phải khớp với chứng chỉ ký, bundle identifier và các entitlement, kể cả application identifier và team identifier.
- myzig nhúng nó nguyên trạng. myzig không tạo profile và không suy ra entitlement từ profile. Apple kiểm tra những gì profile cho phép khi app chạy.
- Không dùng được profile với chữ ký ad hoc (`signing_identity = "-"`, mặc định): `myzig build` dừng trước khi build.
- Đừng đưa profile vào version control, hãy truyền đường dẫn của chúng qua môi trường build.

Xem bài [Inside code signing: provisioning profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles) của Apple.

<a id="the-disk-image"></a>

### Disk image

`<slug>-<version>-<arch>.dmg` là một image nén, chỉ đọc (`ULMO`), có tiêu đề là `macos.dmg_title`.

- Mở nó ra sẽ thấy app nằm cạnh một link tới `/Applications`, trong cửa sổ Finder được sắp xếp bằng file `.DS_Store` mà CLI ghi ra.
- Icon của app cũng là icon của volume.
- `--skip-dmg` bỏ qua bước này.
- Khi `diskutil` có lệnh `image` (macOS 27, nơi `hdiutil convert` bị lỗi), CLI nén nó bằng `diskutil image create from`.

<a id="windows"></a>

## Windows

Ở bản release, `<Name>.exe` là app GUI (không có cửa sổ console). Nó mang các resource mà CLI compile và link vào (`-Dwin32-res`, do `build.zig` của template khai báo):

- icon, ở các kích thước mà Explorer và thanh taskbar dùng;
- một manifest: nhận biết DPI theo từng màn hình, common controls 6, Windows 10 và 11, UTF-8 làm code page, chạy dưới quyền người dùng (`asInvoker`);
- thông tin phiên bản: `FileDescription`, `ProductName`, `FileVersion`, `LegalCopyright`, `OriginalFilename`.

App mà `build.zig` không khai báo `-Dwin32-res` sẽ nhận một cảnh báo và một file thực thi không có các resource đó.

**32-bit.** `--arch x86` tạo bản release 32-bit (`dist/windows-x86`, `x86-windows-gnu`) cho Windows 32-bit, và Windows 64-bit cũng chạy được nó.

- Vẫn đủ file thực thi, resource, zip và bộ cài, cùng WebView2 dành cho app 32-bit.
- Manifest yêu cầu chạy dưới quyền người dùng đã mở app (`asInvoker`). Không có nó, Windows sẽ đòi nâng quyền cho app 32-bit có tên chứa "update", "setup" hoặc "install".
- `--arch x86` cũng build cho Linux 32-bit (gói `.deb` `i386`), phần này chưa được test. macOS không có app 32-bit.

<a id="the-installer"></a>

### Bộ cài

Với `windows.installer` (mặc định), CLI ghi ra `installer.nsi`. Nó compile file này khi đã cài [NSIS](https://nsis.sourceforge.io) (`makensis` có trong `PATH`, hoặc trong `Program Files\NSIS`): `<slug>-setup-<version>-<arch>.exe`. Bộ cài cài cho người dùng hiện tại, không cần quyền quản trị:

- vào `%LOCALAPPDATA%\Programs\<Name>`, kèm shortcut trong Start menu, và shortcut ngoài desktop mà trang cuối của bộ cài đề nghị;
- các liên kết file và URL scheme của `myzig.zon`, dưới `HKCU\Software\Classes`;
- một trình gỡ cài đặt được liệt kê trong Settings > Apps, theo `identifier` của app. Nó chạy app với `windows.uninstall_run` trước, để app tự gỡ những gì nó đã thiết lập. Nó đề nghị xóa các thư mục trong `windows.uninstall_data`;
- trước khi copy file, và trước khi gỡ cài đặt, một bước kiểm tra app không đang chạy (xem bên dưới).

Không có NSIS thì file `.zip` là gói phát hành.

**App đang chạy.** Windows không thay được file mà một chương trình đang chạy giữ. Cài đè lên app đang chạy, hoặc lên `OpenConsole.exe` và `conpty.dll` của terminal trong app, sẽ để lại file cũ lẫn với file mới. Vì vậy bộ cài thử mở để ghi từng file `.exe` và `.dll` mà nó cài cạnh `<Name>.exe` (`name` của `myzig.zon`). Khi còn file bị giữ, nó hỏi:

- **Yes** yêu cầu các cửa sổ của app đóng lại. Sau năm giây, nó kết thúc `<Name>.exe` và các tiến trình mà app đã khởi chạy (`taskkill /F /T`).
- **No** chờ người dùng tự đóng app, rồi kiểm tra lại.
- **Cancel** dừng cài đặt.
- Cài đặt im lặng (`/S`) đóng app, như khi chọn Yes.

CLI chưa ký code (`signtool`, Azure Trusted Signing). Hãy ký `<Name>.exe` trước khi tạo bộ cài, rồi ký bộ cài.

<a id="linux"></a>

## Linux

Thư mục và file `.tar.gz` chạy được ở bất cứ đâu chúng được giải nén. Chúng chứa file thực thi, `<executable>.desktop` (chạy `./<executable>`) và `<executable>.png`.

Gói Debian cài:

| đường dẫn | |
|---|---|
| `/opt/<executable>/` | app và các resource của nó |
| `/usr/share/applications/<executable>.desktop` | desktop entry: `Name`, `Comment`, `Exec` (có `%U` khi app mở file hoặc URL), `Icon`, `Categories`, `MimeType`, `StartupWMClass` |
| `/usr/share/icons/hicolor/{256x256,512x512}/apps/<executable>.png` | icon |
| `/usr/share/mime/packages/<executable>.xml` | các MIME type mà myzig định nghĩa cho những `file_associations` chưa có |
| `/usr/bin/<linux.command>` | một link tới app, khi có đặt `linux.command` |

Nó phụ thuộc GTK 3 và WebKitGTK 4.1 (`libgtk-3-0 | libgtk-3-0t64, libwebkit2gtk-4.1-0`) và `linux.depends`. Cài bằng `sudo apt install ./my-app_1.0.0_amd64.deb`.

Các định dạng khác (RPM, AppImage, Flatpak) chưa được tạo. File `.tar.gz` là điểm khởi đầu cho chúng.

<a id="url-schemes-and-file-types"></a>

## URL scheme và loại file

`url_schemes` và `file_associations` trong `myzig.zon` đăng ký app với hệ thống khi nó được cài:

- macOS: `Info.plist`;
- Windows: các registry key của bộ cài;
- Linux: desktop entry và gói MIME.

App khai báo đúng những thứ đó trong `AppOptions.url_schemes` và `AppOptions.file_extensions`. Nó nhận chúng trong `on_open_url` và `on_open_file`, lúc khởi động và từ những lần mở sau (xem [App](app.md)).

App chưa được cài (file `.zip`, tarball, `myzig dev`) có thể tự đăng ký trong lúc chạy bằng `myzig.system.registerUrlScheme` và `registerFileType` (xem [Hệ thống](system.md)).

<a id="publishing"></a>

## Phát hành

Build các gói cho từng nền tảng, trên một máy hoặc mỗi nền tảng một máy. Tải chúng lên nơi người dùng tải app: một GitHub release, một website.

Để cập nhật, `myzig build` ký bản cập nhật của từng nền tảng và ghi manifest của nó, thứ mà [plugin updater](plugins/updater.md) kiểm tra. `myzig build --upload` phát hành chúng: xem [Cập nhật](updates.md).

Phác thảo một workflow GitHub Actions. Linux và Windows build trên một runner Linux, macOS trên một runner Mac (để có SDK, disk image và ký code):

```yaml
jobs:
  release:
    strategy:
      matrix:
        include:
          - { os: ubuntu-latest, platforms: "linux windows" }
          - { os: macos-latest, platforms: "macos" }
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v2
        with: { version: 0.17.0 }
      - run: git clone https://github.com/hunghg255/myzig ../myzig && (cd ../myzig/cli && zig build --prefix ~/.local)
      - run: |
          for p in ${{ matrix.platforms }}; do
            for a in x86_64 aarch64; do ~/.local/bin/myzig build --platform $p --arch $a; done
          done
          ~/.local/bin/myzig build --platform windows --arch x86   # 32-bit Windows
      - uses: actions/upload-artifact@v4
        with: { name: dist-${{ matrix.os }}, path: dist }
```

Trên runner Mac, `--arch universal` tạo một bundle duy nhất cho cả hai kiến trúc.

<a id="not-yet"></a>

## Chưa có

Bản build của mygo còn làm những việc sau, CLI của myzig chưa làm việc nào:

- notarize;
- ký file thực thi Windows;
- đóng gói kèm các file thực thi phụ;
- kèm bản dịch các chuỗi của hệ thống;
- cài đặt bằng script trên Linux.
