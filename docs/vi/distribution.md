<a id="building-and-distributing"></a>

# Xây dựng và phân phối

`myzig build` phát hành một ứng dụng và các gói mà mọi người cài đặt ứng dụng đó từ đó, cho macOS, Windows, Linux và các trình duyệt:

```sh
myzig build                                   # this machine's platform and architecture
myzig build --platform windows --arch x86_64  # any platform, from any machine
myzig build --platform windows --arch x86     # 32-bit Windows
myzig build --platform macos --arch universal # Apple silicon and Intel in one binary
myzig build --platform web                    # a static site (native UI only)
```

Bản phát hành được xây dựng bằng ReleaseSmall và loại bỏ (`--optimize fast` hoặc `safe` đối với các phiên bản khác), thành `dist/<platform>-<arch>` (`out` trong [myzig.zon](configuration.md) hoặc `--out`), mỗi bản dựng sẽ trống trước tiên. Các cờ nằm ​​trong [trang CLI](cli.md#myzig-build).

| nền tảng | `myzig build` làm ra cái gì |
|---|---|
| macOS | `<Name>.app`; trên máy Mac, được ký (đặc biệt theo mặc định) bằng `<Name> <version> <arch>.dmg`; ở nơi khác `<Name>-<version>-macos-<arch>.zip` của gói |
| Windows | có hai cách để vận chuyển nó: `<Name> Portable <version> <arch>.zip`, chạy khi được giải nén và không cài đặt gì (`<Name>/<Name>.exe` với các tài nguyên biểu tượng, tệp kê khai và phiên bản cũng như các tài nguyên bên cạnh nó, cũng được giải nén) và `<Name> Setup <version> <arch>.exe`, trình cài đặt NSIS, khi `makensis` được cài đặt (không có nó, một cảnh báo sẽ cho biết cách cài đặt nó) |
| Linux | `<executable>/` (tệp thực thi, mục nhập và biểu tượng trên màn hình của nó, tài nguyên); `<executable>-<version>-linux-<arch>.tar.gz`; `<package>_<version>_<arch>.deb` |
| trình duyệt | `dist/web`: `index.html`, tập lệnh của máy chủ, `app.wasm` và phông chữ (xem [Trình duyệt](browsers.md)) |

<a id="platforms"></a>

## Nền tảng

Zig biên dịch chéo và myzig tải những gì Linux và Windows có thay vì liên kết nó (GTK và WebKitGTK với trình tải của `dlopen`, WebView2 với `LoadLibrary`), vì vậy Linux và Windows phát hành bản dựng từ bất kỳ máy nào. macOS phát hành liên kết các khung công tác của Apple, cần có macOS SDK: xây dựng chúng trên máy Mac (Xcode hoặc Công cụ dòng lệnh). Ảnh đĩa (`hdiutil`) và ký mã (`codesign`) cũng cần có máy Mac. Khi tệp thực thi macOS được liên kết với máy Mac (có SDK được cung cấp), `myzig build --platform macos` nén gói thay vì tạo ảnh đĩa, giữ nguyên chế độ của tệp thực thi và chữ ký đặc biệt mà trình liên kết của Zig cung cấp cho nó, mà Apple silicon cần để chạy nó.

Bản phát hành cần những gì ở nơi nó chạy:

| nền tảng | nhu cầu |
|---|---|
| macOS | macOS 12 trở lên (`macos.minimum_system_version`) |
| Windows | Windows 10 trở lên; WebView2 Runtime cho các trang (một phần của Windows 11 và hầu hết Windows 10 lượt cài đặt) |
| Linux | GTK 3; WebKitGTK 4.1 cho các trang. `.deb` phụ thuộc vào `libgtk-3-0` và `libwebkit2gtk-4.1-0` |

Các ứng dụng của giao diện native không cần webview ở bất kỳ đâu và bản phát hành là một bản thực thi duy nhất có dung lượng từ megabyte đến vài megabyte: myzig không có thời gian chạy để gửi đi.

<a id="name-icon-and-version"></a>

## Tên, biểu tượng và phiên bản

Chúng đến từ `myzig.zon`, với giá trị mặc định là `build.zig.zon` và thư mục (xem [Cấu hình](configuration.md#the-app)):

- `name` đặt tên cho gói, `.exe`, trình cài đặt và các menu; `executable` là tạo phẩm `build.zig` cài đặt và đặt tên cho gói và lệnh Linux.
- `version` đi vào tài nguyên phiên bản `Info.plist` (`CFBundleVersion`, `CFBundleShortVersionString`), Windows' (tối đa bốn số, `1.2.3` là 1.2.3.0) và gói Debian (`1.2.0-beta-1` là `1.2.0~beta.1`). Giữ nó trong `build.zig.zon` và bỏ nó ra khỏi `myzig.zon`, để có một nơi để thay đổi nó.
- `icon` là PNG hình vuông. CLI tạo các biểu tượng của nền tảng từ nó: `icon.icns` trong `Resources` của gói, nhóm biểu tượng của `.exe` (16 đến 256 pixel) và `.ico` của trình cài đặt và PNG có kích thước 512 pixel bên cạnh tệp thực thi Linux và 256 và 512 pixel trong `.deb`'s `hicolor` chủ đề. `myzig icon` cho họ xem; `myzig icon --new` ghi biểu tượng mặc định.

<a id="resources"></a>

## Tài nguyên

Các tệp mà ứng dụng đọc trong thời gian chạy sẽ xuất hiện bên cạnh nó: mọi thứ trong thư mục `resources/` của ứng dụng ngoại trừ biểu tượng cũng như các tệp và thư mục `resources` có tên trong `myzig.zon`.

| nền tảng | họ đi đâu |
|---|---|
| macOS | `<Name>.app/Contents/Resources/` |
| Windows | bên cạnh `<Name>.exe` (và trong trình cài đặt) |
| Linux | bên cạnh tệp thực thi, `/opt/<executable>/` trong `.deb` |

Các tệp mà ứng dụng nhúng (`@embedFile`, `myzig_assets.zig` của frontend) không cần tài nguyên: chúng nằm trong tệp thực thi. Thích nhúng những gì nhỏ và cố định; gửi dưới dạng tài nguyên lớn, được cấp phép riêng hoặc thư viện gốc (của [terminal](plugins/terminal.md) mà nó tìm thấy bên cạnh tệp thực thi).

Một ứng dụng tìm thấy thư mục thực thi của nó với `std.process.executableDirPath(io, &buf)` (trên macOS, `Contents/MacOS`, có `../Resources` chứa tài nguyên).

## macOS

`<Name>.app/Contents` giữ:

- `MacOS/<Name>`, tệp thực thi (một tệp nhị phân phổ quát với `--arch universal`, được CLI nối với tên `lipo`, mỗi lát được căn chỉnh thành 16 KiB);
- `Info.plist`: `CFBundleName`, `CFBundleDisplayName`, `CFBundleIdentifier`, các phiên bản, `CFBundleExecutable`, `LSMinimumSystemVersion`, `NSPrincipalClass` (`NSApplication`), `NSHighResolutionCapable`, `NSSupportsAutomaticGraphicsSwitching`, `CFBundleIconFile`, `NSHumanReadableCopyright`, `CFBundleDocumentTypes` cho `file_associations` và `CFBundleURLTypes` cho `url_schemes`;
- `Resources/`: `icon.icns` và các tài nguyên.

`macos.info_plist` thêm khóa hoặc thay thế myzig, chẳng hạn như mô tả cách sử dụng (`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`) hoặc `LSUIElement` cho một ứng dụng nằm trong thanh menu.

<a id="signing"></a>

### Ký tên

Trên máy Mac, gói được ký bằng `codesign --force --deep --sign <macos.signing_identity>`. Mặc định, `-`, ký đặc biệt: ứng dụng chạy trên máy Mac đã xây dựng ứng dụng đó và ở nơi khác sau khi người dùng cho phép. Với ID nhà phát triển (`"Developer ID Application: Example Inc. (TEAMID)"`), CLI cũng bật thời gian chạy cứng (`--options runtime`) và dấu thời gian an toàn, thêm `macos.entitlements` khi được đặt và ký vào ảnh đĩa.

Việc công chứng vẫn chưa được CLI thực hiện. Sau `myzig build`, gửi ảnh đĩa và ghim phiếu:

```sh
xcrun notarytool submit "dist/macos-aarch64/My App 1.0.0 aarch64.dmg" --keychain-profile notary --wait
xcrun stapler staple "dist/macos-aarch64/My App 1.0.0 aarch64.dmg"
```

<a id="provisioning-profiles"></a>

### Hồ sơ cung cấp

Các quyền bị hạn chế, chẳng hạn như Thông báo liên lạc, cần có hồ sơ cấp phép cho phép chúng, bao gồm cả việc phân phối ID nhà phát triển. Đặt `macos.provisioning_profile` theo đường dẫn của nó, liên quan đến dự án hoặc tuyệt đối: `myzig build` sao chép nó vào `Contents/embedded.provisionprofile` của gói trước khi ký, để ứng dụng đã ký và ảnh đĩa của nó giữ nó.

```zig
.macos = .{
    .signing_identity = "Developer ID Application: Example Inc. (TEAMID)",
    .provisioning_profile = "profiles/App.provisionprofile",
    .entitlements = "resources/macos/app.entitlements",
},
```

Hồ sơ phải khớp với chứng chỉ ký, mã định danh gói và các quyền, mã định danh ứng dụng và nhóm đi kèm. myzig nhúng nó như đã cho; nó không tạo hồ sơ cũng như không lấy các quyền từ chúng và Apple kiểm tra những gì họ ủy quyền khi ứng dụng chạy. Không thể sử dụng cấu hình với tính năng ký đặc biệt (`signing_identity = "-"`, mặc định): `myzig build` dừng trước khi xây dựng. Giữ các cấu hình nằm ngoài tầm kiểm soát phiên bản và cung cấp đường dẫn của chúng trong môi trường của bản dựng. Xem [Ký mã nội bộ: hồ sơ cung cấp](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles) của Apple.

<a id="the-disk-image"></a>

### Hình ảnh đĩa

`<Name> <version> <arch>.dmg` là hình ảnh nén, chỉ đọc (`ULMO`) có tiêu đề `macos.dmg_title`. Mở nó sẽ hiển thị ứng dụng bên cạnh liên kết đến `/Applications` trong cửa sổ Finder được trình bày bởi `.DS_Store` CLI ghi, với biểu tượng của ứng dụng là âm lượng. `--skip-dmg` bỏ nó đi.

<a id="windows"></a>

## Cửa sổ

`<Name>.exe` là một ứng dụng GUI (không có cửa sổ bảng điều khiển) trong các bản phát hành và mang các tài nguyên mà CLI biên dịch và liên kết (`-Dwin32-res`, mà `build.zig` của mẫu khai báo):

- biểu tượng, trong kích thước sử dụng Explorer và thanh tác vụ;
- một bảng kê khai: nhận thức về DPI trên mỗi màn hình, các điều khiển chung 6, Windows 10 và 11, UTF-8 làm trang mã, chạy dưới quyền người dùng (`asInvoker`);
- thông tin phiên bản: `FileDescription`, `ProductName`, `FileVersion`, `LegalCopyright`, `OriginalFilename`.

Ứng dụng có `build.zig` không khai báo `-Dwin32-res` sẽ nhận được cảnh báo và có thể thực thi mà không có chúng.

`--arch x86` tạo bản phát hành 32-bit (`dist/windows-x86`, `x86-windows-gnu`) cho Windows 32-bit, Windows 64-bit cũng chạy được: cùng tệp thực thi, tài nguyên, tệp zip và trình cài đặt, dùng WebView2 của ứng dụng 32-bit. Tệp kê khai yêu cầu chạy dưới quyền người đã mở ứng dụng (`asInvoker`); nếu không có, Windows sẽ đòi nâng quyền với ứng dụng 32-bit có tên chứa "update", "setup" hoặc "install". `--arch x86` cũng xây dựng cho Linux 32-bit (một `.deb` `i386`), nhưng chưa được kiểm thử; macOS không có ứng dụng 32-bit.

<a id="the-installer"></a>

### Trình cài đặt

Với `windows.installer` (mặc định), CLI ghi `installer.nsi` và biên dịch nó khi [NSIS](https://nsis.sourceforge.io) được cài đặt (`makensis` trên `PATH` hoặc trong `Program Files\NSIS`): `<Name> Setup <version> <arch>.exe`. Nó cài đặt cho người dùng mà không có quyền quản trị viên:

- vào `%LOCALAPPDATA%\Programs\<Name>`, với lối tắt menu Bắt đầu và lối tắt trên màn hình mà trang kết thúc cung cấp;
- các liên kết tệp và URL scheme của `myzig.zon`, trong `HKCU\Software\Classes`;
- trình gỡ cài đặt mà Cài đặt > Ứng dụng liệt kê, trong `identifier` của ứng dụng; trước tiên, nó chạy ứng dụng với `windows.uninstall_run` để ứng dụng hoàn tác những gì nó tự thiết lập và đề nghị xóa các thư mục của `windows.uninstall_data`;
- trước khi sao chép tệp (và trước khi gỡ cài đặt), hãy kiểm tra xem ứng dụng có chạy không. Windows thay thế không có tệp nào mà chương trình đang chạy lưu giữ, do đó, việc cài đặt qua ứng dụng đang chạy (hoặc `OpenConsole.exe` và `conpty.dll` của terminal) sẽ để lại các tệp cũ bên cạnh các tệp mới. Trình cài đặt cố gắng mở từng `.exe` và `.dll` nó cài đặt bên cạnh `<Name>.exe` (`name` của `myzig.zon`) để ghi; trong khi một cái được giữ, nó sẽ hỏi: **Có** yêu cầu đóng các cửa sổ của ứng dụng và sau năm giây kết thúc `<Name>.exe` và các quá trình nó bắt đầu (`taskkill /F /T`); **Không** chờ người dùng đóng nó rồi kiểm tra lại; **Hủy** dừng. Cài đặt im lặng (`/S`) sẽ đóng nó, tương tự như Có.

Không có NSIS, `.zip` là gói.

Việc ký mã (`signtool`, Ký tin cậy Azure) chưa được CLI thực hiện: ký `<Name>.exe` trước khi tạo trình cài đặt, sau đó là trình cài đặt.

## Linux

Thư mục và `.tar.gz` chạy từ bất cứ nơi nào chúng được giải nén: tệp thực thi, `<executable>.desktop` (chạy `./<executable>`) và `<executable>.png`.

Gói Debian cài đặt:

| con đường | |
|---|---|
| `/opt/<executable>/` | ứng dụng và tài nguyên của nó |
| `/usr/share/applications/<executable>.desktop` | mục trên máy tính để bàn: `Name`, `Comment`, `Exec` (với `%U` khi ứng dụng mở tệp hoặc URL), `Icon`, `Categories`, `MimeType`, `StartupWMClass` |
| `/usr/share/icons/hicolor/{256x256,512x512}/apps/<executable>.png` | biểu tượng |
| `/usr/share/mime/packages/<executable>.xml` | các loại MIME myzig định nghĩa cho `file_associations` không có loại nào |
| `/usr/bin/<linux.command>` | một liên kết đến ứng dụng khi `linux.command` được đặt |

Nó phụ thuộc vào GTK 3 và WebKitGTK 4.1 (`libgtk-3-0 | libgtk-3-0t64, libwebkit2gtk-4.1-0`) và `linux.depends`. Cài đặt nó với `sudo apt install ./my-app_1.0.0_amd64.deb`.

Các định dạng khác (RPM, AppImage, Flatpak) chưa được tạo; `.tar.gz` là nơi họ sẽ bắt đầu.

<a id="url-schemes-and-file-types"></a>

## Lược đồ URL và loại tệp

`url_schemes` và `file_associations` trong `myzig.zon` đăng ký ứng dụng với hệ thống khi ứng dụng được cài đặt: `Info.plist` trên macOS, khóa đăng ký của trình cài đặt trên Windows, mục nhập máy tính để bàn và gói MIME trên Linux. Ứng dụng đặt tên giống nhau trong `AppOptions.url_schemes` và `AppOptions.file_extensions`, đồng thời nhận chúng trong `on_open_url` và `on_open_file`, khi ra mắt và từ những lần ra mắt sau này (xem [Ứng dụng](app.md)). Một ứng dụng chưa được cài đặt (`.zip`, tarball, `myzig dev`) có thể tự đăng ký khi chạy với `myzig.system.registerUrlScheme` và `registerFileType` (xem [Hệ thống](system.md)).

<a id="publishing"></a>

## Xuất bản

Xây dựng các gói của từng nền tảng, trên một máy hoặc một gói trên mỗi nền tảng và tải chúng lên nơi mọi người tải xuống ứng dụng (bản phát hành GitHub, trang web). Để biết các bản cập nhật, `myzig build` ký vào bản cập nhật của từng nền tảng và viết bảng kê khai của nó, [updater](plugins/updater.md) kiểm tra và `myzig build --upload` xuất bản chúng: xem [Cập nhật](updates.md).

Bản phác thảo quy trình làm việc của Hành động GitHub: Linux và Windows được xây dựng trên một trình chạy Linux, macOS trên trình chạy Mac (đối với SDK, hình ảnh đĩa và ký):

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

Thay vào đó, trên trình chạy Mac, `--arch universal` tạo một gói gồm cả hai kiến trúc.

<a id="not-yet"></a>

## Chưa hỗ trợ

Các bản dựng của mygo cũng công chứng, ký các tệp thực thi Windows, gói các tệp thực thi của trình trợ giúp và hồ sơ cung cấp, gửi bản dịch các chuỗi của hệ thống và cài đặt bằng tập lệnh Linux; CLI của myzig chưa thực hiện điều nào trong số này.
