# Building and distributing

`myzig build` makes the release of an app and the packages people install
it from, for macOS, Windows, Linux and browsers:

```sh
myzig build                                   # this machine's platform and architecture
myzig build --platform windows --arch x86_64  # any platform, from any machine
myzig build --platform windows --arch x86     # 32-bit Windows
myzig build --platform macos --arch universal # Apple silicon and Intel in one binary
myzig build --platform web                    # a static site (native UI only)
```

The release is built with ReleaseSmall and stripped (`--optimize fast` or
`safe` for others), into `dist/<platform>-<arch>` (`out` in
[myzig.zon](configuration.md), or `--out`), which each build empties
first. The flags are in
[the CLI's page](cli.md#myzig-build).

| platform | what `myzig build` makes |
|---|---|
| macOS | `<Name>.app`; on a Mac, signed (ad hoc by default) with `<Name> <version> <arch>.dmg`; elsewhere `<Name>-<version>-macos-<arch>.zip` of the bundle |
| Windows | two ways to ship it: `<Name> Portable <version> <arch>.zip`, which runs where it is unpacked and installs nothing (`<Name>/<Name>.exe` with its icon, manifest and version resources, and the resources beside it, also left unzipped), and `<Name> Setup <version> <arch>.exe`, the NSIS installer, when `makensis` is installed (without it, a warning says how to install it) |
| Linux | `<executable>/` (the executable, its desktop entry and icon, the resources); `<executable>-<version>-linux-<arch>.tar.gz`; `<package>_<version>_<arch>.deb` |
| browsers | `dist/web`: `index.html`, the host's scripts, `app.wasm` and the fonts (see [Browsers](browsers.md)) |

## Platforms

Zig cross-compiles, and myzig loads what Linux and Windows have instead of
linking it (GTK and WebKitGTK with `dlopen`, WebView2's loader with
`LoadLibrary`), so Linux and Windows releases build from any machine.
macOS releases link Apple's frameworks, which needs the macOS SDK: build
them on a Mac (Xcode or the Command Line Tools). The disk image (`hdiutil`)
and code signing (`codesign`) need a Mac too. Where a macOS executable is
linked off a Mac (with an SDK provided), `myzig build --platform macos`
zips the bundle instead of making a disk image, keeping the executable's
mode and the ad hoc signature Zig's linker gives it, which Apple silicon
needs to run it.

What a release needs where it runs:

| platform | needs |
|---|---|
| macOS | macOS 12 or later (`macos.minimum_system_version`) |
| Windows | Windows 10 or later; the WebView2 Runtime for pages (part of Windows 11, and of most Windows 10 installs) |
| Linux | GTK 3; WebKitGTK 4.1 for pages. The `.deb` depends on `libgtk-3-0` and `libwebkit2gtk-4.1-0` |

Apps of native UI need no webview anywhere, and a release is a single
executable of well under a megabyte to a few megabytes: myzig has no
runtime to ship.

## Name, icon and version

They come from `myzig.zon`, with defaults from `build.zig.zon` and the
directory (see [Configuration](configuration.md#the-app)):

- `name` names the bundle, the `.exe`, the installer and the menus;
  `executable` is the artifact `build.zig` installs, and names the Linux
  package and command.
- `version` goes into `Info.plist` (`CFBundleVersion`,
  `CFBundleShortVersionString`), Windows' version resources (up to four
  numbers, `1.2.3` as 1.2.3.0) and the Debian package (`1.2.0-beta-1` as
  `1.2.0~beta.1`). Keep it in `build.zig.zon` and leave it out of
  `myzig.zon`, so there is one place to change it.
- `icon` is a square PNG. The CLI makes the platforms' icons from it:
  `icon.icns` in the bundle's `Resources`, the `.exe`'s icon group
  (16 to 256 pixels) and the installer's `.ico`, and PNGs of 512 pixels
  beside the Linux executable and of 256 and 512 pixels in the `.deb`'s
  `hicolor` theme. `myzig icon` shows them; `myzig icon --new` writes the
  default icon.

## Resources

Files the app reads at run time ship beside it: everything in the app's
`resources/` directory except the icon, and the files and directories
`resources` names in `myzig.zon`.

| platform | where they go |
|---|---|
| macOS | `<Name>.app/Contents/Resources/` |
| Windows | beside `<Name>.exe` (and in the installer) |
| Linux | beside the executable, `/opt/<executable>/` in the `.deb` |

Files the app embeds (`@embedFile`, the frontend's `myzig_assets.zig`)
need no resources: they are in the executable. Prefer embedding what is
small and fixed; ship as resources what is large, licensed separately, or a
native library (the [terminal plugin](plugins/terminal.md)'s, which it
finds beside the executable).

An app finds its executable's directory with
`std.process.executableDirPath(io, &buf)` (on macOS, `Contents/MacOS`,
whose `../Resources` holds the resources).

## macOS

`<Name>.app/Contents` holds:

- `MacOS/<Name>`, the executable (a universal binary with `--arch
  universal`, joined by the CLI as `lipo` would, each slice aligned to
  16 KiB);
- `Info.plist`: `CFBundleName`, `CFBundleDisplayName`,
  `CFBundleIdentifier`, the versions, `CFBundleExecutable`,
  `LSMinimumSystemVersion`, `NSPrincipalClass` (`NSApplication`),
  `NSHighResolutionCapable`, `NSSupportsAutomaticGraphicsSwitching`,
  `CFBundleIconFile`, `NSHumanReadableCopyright`, `CFBundleDocumentTypes`
  for `file_associations` and `CFBundleURLTypes` for `url_schemes`;
- `Resources/`: `icon.icns` and the resources.

`macos.info_plist` adds keys or replaces myzig's, such as usage
descriptions (`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`)
or `LSUIElement` for an app that lives in the menu bar.

### Signing

On a Mac, the bundle is signed with `codesign --force --deep --sign
<macos.signing_identity>`. The default, `-`, signs ad hoc: the app runs on
the Mac that built it, and elsewhere after the user allows it. With a
Developer ID (`"Developer ID Application: Example Inc. (TEAMID)"`), the CLI
also turns on the hardened runtime (`--options runtime`) and a secure
timestamp, adds `macos.entitlements` when set, and signs the disk image.

Notarization is not done by the CLI yet. After `myzig build`, submit the
disk image and staple the ticket:

```sh
xcrun notarytool submit "dist/macos-aarch64/My App 1.0.0 aarch64.dmg" --keychain-profile notary --wait
xcrun stapler staple "dist/macos-aarch64/My App 1.0.0 aarch64.dmg"
```

### Provisioning profiles

Restricted entitlements, such as Communication Notifications, need a
provisioning profile that authorizes them, Developer ID distribution
included. Set `macos.provisioning_profile` to its path, relative to the
project or absolute: `myzig build` copies it to the bundle's
`Contents/embedded.provisionprofile` before signing, so the signed app and
its disk image hold it.

```zig
.macos = .{
    .signing_identity = "Developer ID Application: Example Inc. (TEAMID)",
    .provisioning_profile = "profiles/App.provisionprofile",
    .entitlements = "resources/macos/app.entitlements",
},
```

The profile must match the signing certificate, the bundle identifier and
the entitlements, the application and team identifiers included. myzig
embeds it as given; it neither makes profiles nor derives entitlements
from them, and Apple checks what they authorize when the app runs. A
profile cannot be used with ad-hoc signing (`signing_identity = "-"`, the
default): `myzig build` stops before building. Keep profiles out of
version control, and give their paths in the build's environment. See
Apple's
[Inside code signing: provisioning profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

### The disk image

`<Name> <version> <arch>.dmg` is a compressed, read-only image (`ULMO`)
titled `macos.dmg_title`. Opening it shows the app beside a link to
`/Applications` in a Finder window laid out by a `.DS_Store` the CLI
writes, with the app's icon as the volume's. `--skip-dmg` leaves it out.

## Windows

`<Name>.exe` is a GUI app (no console window) in releases, and carries
resources the CLI compiles and links (`-Dwin32-res`, which the template's
`build.zig` declares):

- the icon, in the sizes Explorer and the taskbar use;
- a manifest: per-monitor DPI awareness, common controls 6, Windows 10 and
  11, UTF-8 as the code page, running as the user (`asInvoker`);
- version information: `FileDescription`, `ProductName`, `FileVersion`,
  `LegalCopyright`, `OriginalFilename`.

An app whose `build.zig` doesn't declare `-Dwin32-res` gets a warning and
an executable without them.

`--arch x86` makes a 32-bit release (`dist/windows-x86`, `x86-windows-gnu`)
for 32-bit Windows, which 64-bit Windows runs too: the same executable,
resources, zip and installer, the WebView2 of a 32-bit app. The manifest
asks to run as the user who started the app (`asInvoker`); without that,
Windows asks to elevate a 32-bit app whose name says "update", "setup" or
"install". `--arch x86` also builds for 32-bit Linux (an `i386` `.deb`),
which isn't tested yet; macOS has no 32-bit apps.

### The installer

With `windows.installer` (the default), the CLI writes `installer.nsi`, and
compiles it when [NSIS](https://nsis.sourceforge.io) is installed
(`makensis` on the `PATH`, or in `Program Files\NSIS`):
`<Name> Setup <version> <arch>.exe`. It installs for the user,
without administrator rights:

- into `%LOCALAPPDATA%\Programs\<Name>`, with a Start menu shortcut, and a
  desktop shortcut the finish page offers;
- the file associations and URL schemes of `myzig.zon`, under
  `HKCU\Software\Classes`;
- an uninstaller that Settings > Apps lists, under the app's `identifier`;
  it runs the app with `windows.uninstall_run` first, for the app to undo
  what it set up itself, and offers to delete the folders of
  `windows.uninstall_data`;
- before copying files (and before uninstalling), a check that the app
  isn't running. Windows replaces no file a running program holds, so an
  install over a running app (or its terminal's `OpenConsole.exe` and
  `conpty.dll`) would leave old files beside new ones. The installer tries
  to open each `.exe` and `.dll` it installs beside `<Name>.exe` (the
  `name` of `myzig.zon`) for writing; while one is held it asks: **Yes**
  asks the app's windows to close, and after five seconds ends
  `<Name>.exe` and the processes it started (`taskkill /F /T`); **No**
  waits for the user to close it, then checks again; **Cancel** stops. A
  silent install (`/S`) closes it, as Yes does.

Without NSIS, the `.zip` is the package.

Code signing (`signtool`, Azure Trusted Signing) is not done by the CLI
yet: sign `<Name>.exe` before making the installer, then the installer.

## Linux

The directory and the `.tar.gz` run from wherever they are unpacked: the
executable, `<executable>.desktop` (which runs `./<executable>`) and
`<executable>.png`.

The Debian package installs:

| path | |
|---|---|
| `/opt/<executable>/` | the app and its resources |
| `/usr/share/applications/<executable>.desktop` | the desktop entry: `Name`, `Comment`, `Exec` (with `%U` when the app opens files or URLs), `Icon`, `Categories`, `MimeType`, `StartupWMClass` |
| `/usr/share/icons/hicolor/{256x256,512x512}/apps/<executable>.png` | the icon |
| `/usr/share/mime/packages/<executable>.xml` | the MIME types myzig defines for `file_associations` without one |
| `/usr/bin/<linux.command>` | a link to the app, when `linux.command` is set |

It depends on GTK 3 and WebKitGTK 4.1 (`libgtk-3-0 | libgtk-3-0t64,
libwebkit2gtk-4.1-0`) and `linux.depends`. Install it with `sudo apt
install ./my-app_1.0.0_amd64.deb`.

Other formats (RPM, AppImage, Flatpak) are not made yet; the `.tar.gz` is
what they would start from.

## URL schemes and file types

`url_schemes` and `file_associations` in `myzig.zon` register the app with
the system when it is installed: `Info.plist` on macOS, the installer's
registry keys on Windows, the desktop entry and MIME package on Linux. The
app names the same ones in `AppOptions.url_schemes` and
`AppOptions.file_extensions`, and gets them in `on_open_url` and
`on_open_file`, on launch and from later launches (see [The app](app.md)).
An app that isn't installed (the `.zip`, the tarball, `myzig dev`) can
register itself while it runs with `myzig.system.registerUrlScheme` and
`registerFileType` (see [System](system.md)).

## Publishing

Build each platform's packages, on one machine or one per platform, and
upload them where people download apps (a GitHub release, a website). For
updates, `myzig build` signs each platform's update and writes its
manifest, which the [updater plugin](plugins/updater.md) checks, and
`myzig build --upload` publishes them: see [Updates](updates.md).

A sketch of a GitHub Actions workflow: Linux and Windows build on one
Linux runner, macOS on a Mac runner (for the SDK, the disk image and
signing):

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

On the Mac runner, `--arch universal` makes one bundle of both
architectures instead.

## Not yet

mygo's builds also notarize, sign Windows executables, bundle helper
executables and provisioning profiles, ship the translations of the
system's strings, and install with a Linux script; myzig's CLI does none of
these yet.
