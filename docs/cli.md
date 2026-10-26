# The myzig CLI

`myzig` is the command line tool of myzig apps, after mygo's `mygo`: it
makes apps, runs them as you edit them, writes the TypeScript client of
their bound services, and builds their releases and packages. Apps don't
need it: every app is a Zig package that `zig build` builds and runs on its
own, and the CLI calls `zig build` with the right options.

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

`myzig <command> --help` prints a command's flags. Apps are configured in
`myzig.zon` (or `myzig.json`), described in
[Configuration](configuration.md).

## Install

The CLI is a Zig program in `cli/` of the myzig repository, a package of
its own that depends on the myzig next to it. Build it with Zig 0.17 and
put it on the `PATH`:

```sh
cd myzig/cli
zig build -Doptimize=ReleaseSafe --prefix ~/.local   # installs ~/.local/bin/myzig
myzig version
```

`zig build run -- <command>` runs it without installing. `ZIG` names the
Zig the CLI builds apps with (the `zig` on the `PATH` by default).

```sh
cd myzig/cli
zig build test   # unit tests: configuration, bundles, archives, resources, icons
zig build e2e    # makes apps with `myzig init` (in .zig-cache/tmp) and builds them against this checkout
```

## myzig init

```sh
myzig init my-app                    # native UI drawn by myzig
myzig init my-app --template web     # a web page calling Zig
```

Creates an app in a new or empty directory:

| file | |
|---|---|
| `build.zig` | the app's build: `run` and `test` steps, and the options the CLI sets (`-Dstrip`, `-Dwin32-res`, `-Dwindows-gui`, and `-Dfrontend` for the web template) |
| `build.zig.zon` | the package, depending on myzig, `minimum_zig_version = "0.17.0"` |
| `src/main.zig` | a counter window of native UI with a `ui.Tester` test; or a window showing `frontend/` whose page calls `Greeter.greet` |
| `myzig.zon` | the app's name, identifier (`com.example.<name>`) and icon; `.frontend` for the web template |
| `resources/icon.png` | myzig's default icon, a 512-pixel PNG |
| `frontend/` | web template: `index.html`, `main.js`, `style.css`, `myzig_assets.zig`, and the generated client |
| `.gitignore` | `.zig-cache/`, `zig-out/`, `.myzig/`, `dist/` |

| flag | |
|---|---|
| `--template native\|web` | native UI (the default), or a web page |
| `--name NAME` | the app's name (default: the directory's) |
| `--myzig PATH\|URL` | a checkout of myzig, or what `zig fetch` fetches |
| `--skip-generate` | don't build the web template to write its client |

Where myzig comes from: `--myzig`, else `MYZIG_ROOT`, else the myzig
repository on GitHub at the CLI's version
(`git+https://github.com/hunghg255/myzig#v0.1.10` for CLI 0.1.10). A
checkout becomes a path dependency (`.myzig = .{ .path = "../myzig" }`)
when a relative path reaches it; a URL (or a checkout on another drive) is
fetched with `zig fetch --save=myzig`.

The web template's build embeds the frontend through `myzig_assets.zig`, a
module the CLI writes that lists the frontend's files, each with
`@embedFile`, as `pub const files = [_]myzig.Asset{...}`. The app imports
it as `assets` and serves `&assets.files`. The CLI writes it again
whenever the files change (`generate`, `dev`, `build`), so adding a page
needs no Zig; it leaves out the generated client, dot files and
`node_modules`.

Then:

```sh
cd my-app
myzig dev        # run it, rebuilding as you edit
zig build run    # or with Zig alone
zig build test   # the template's test
myzig build      # the release and its package
```

## myzig dev

```sh
myzig dev [dir] [-- app arguments]
```

Builds the app (Debug), writes its client when it has a frontend, runs it,
and watches its files: a change rebuilds it, and the new build replaces the
running one, which quits first. A build that fails keeps the running app
and says so; fix the error and save. Quitting the app ends `myzig dev`.

- **Watching** is the system's (ReadDirectoryChangesW on Windows, inotify
  on Linux, kqueue on macOS): nothing polls. Changes settle for 150 ms
  before a rebuild, so an editor's save or a branch switch is one rebuild.
  The whole app directory is watched except `.zig-cache`, `zig-out`,
  `.myzig`, `.git`, `node_modules`, the output directory (`out`), the files
  the CLI writes (`myzig_assets.zig`, `myzig.js`, `myzig.d.ts`) and
  editors' temporary files.
- **Two install prefixes** in turn (`.myzig/dev/a` and `.myzig/dev/b`): a
  build never overwrites the executable that runs, which Windows keeps
  locked.
- **The environment**: the app runs with `MYZIG_DEV=1`, and
  `MYZIG_DEV_URL` when `dev_url` is set.
- **A dev server**: with `dev_command` (`bun run dev`, ...) and `dev_url`,
  the CLI runs the command first, waits until the URL answers, and stops
  it when it ends. The frontend is then the server's to reload (Vite's hot
  reload), and only Zig changes rebuild the app, whose window loads
  `MYZIG_DEV_URL`:

  ```zig
  const url = init.environ_map.get("MYZIG_DEV_URL") orelse "/";
  _ = try app.newWindow(.{ .title = "App", .content = .{ .page = .{ .url = url, .assets = &assets.files } } });
  ```

  If the server ends, `myzig dev` ends with it.

| flag | |
|---|---|
| `--skip-dev-command` | don't run `dev_command` (its server already runs) |
| `-- args` | arguments passed to the app |

## myzig build

```sh
myzig build [dir]
myzig build --platform windows --arch x86_64
myzig build --platform windows --arch x86
myzig build --platform macos --arch universal
myzig build --platform web
```

Builds the release (ReleaseSmall and stripped by default) and packages it
in `<out>/<platform>-<arch>` (`dist/macos-aarch64`, ...): a `.app` and, on
a Mac, a `.dmg`; a Windows `.exe` with its icon, manifest and version
resources, in a portable `.zip` that runs unpacked, and an installer with
NSIS (`<Name> Setup <version> <arch>.exe`); a Linux directory, a
`.tar.gz` and a `.deb`. Linux and Windows releases build from any machine,
as Zig cross-compiles and myzig links nothing of theirs; macOS releases
need the macOS SDK, and the `.dmg` and code signing a Mac. See
[Distribution](distribution.md) for what each package holds.

Before building, it runs `build_command` (the frontend's build) and writes
`myzig_assets.zig` for `frontend_dist`. It checks that the icon is a square
PNG, and builds with only the options the app's `build.zig` declares (read
from `zig build --help`), so an app's own `build.zig` keeps working: a
release of a Windows app gets `-Dwindows-gui=true` (no console),
`-Dstrip=true`, `-Dwin32-res=<app.res>` and `-Dfrontend=<frontend_dist>`
when declared.

| flag | |
|---|---|
| `--platform macos\|windows\|linux\|web` | the system to build for (default: this one); `web` builds a static site for browsers in `<out>/web` (native UI only; see [Browsers](browsers.md)) |
| `--arch x86_64\|aarch64\|x86\|universal` | the architecture (default: this one); `x86` is 32-bit, for Windows and Linux (also `386`, `i386`); `universal` is macOS's, both joined in one binary |
| `--optimize small\|fast\|safe` | ReleaseSmall (default), ReleaseFast or ReleaseSafe (`debug` too) |
| `--out DIR` | the output directory (default: `out` of `myzig.zon`, `dist`) |
| `--skip-build-command` | don't run `build_command` |
| `--skip-dmg` | don't make the macOS disk image |
| `--upload` | upload the packages and the signed update where `updates` points: the bucket of `updates.s3`, else a draft GitHub release of the version (see [Updates](updates.md)) |

With `updates` in `myzig.zon` and the signing key
(`MYZIG_UPDATER_PRIVATE_KEY`, or `updates.private_key`), it also writes the
signed update of the platform beside the packages: the executable, as
`<name>-<version>-<platform>-<arch>`, and its manifest,
`update-<platform>-<arch>.json`. Without the key it warns and writes
neither, and `--upload` stops before building: a release without
manifests is one that installed apps cannot update to. A macOS build
stops before building, too, when `macos.provisioning_profile` is set and
the app is signed ad hoc.

The targets are `<arch>-macos`, `<arch>-windows-gnu`, `<arch>-linux-gnu`
and `wasm32-wasi`. Intermediate files go in `.myzig/build/`.

Every build starts from nothing: before anything builds (`build_command`
too), `myzig build` deletes `<out>` and `.myzig/build/` and makes `<out>`
again, so it holds only this build's package, of one platform. Packages of
several platforms are built one after another, each kept elsewhere
(`--out dist/mac`, ...). An `<out>` that is the app's directory or holds
it is refused.

## myzig generate

```sh
myzig generate [dir]
```

Builds the app for this machine (into `.myzig/generate`) and runs it with
`--myzig-generate=<frontend>`, which writes `myzig.js` and `myzig.d.ts`,
the client of its bound services and events, into the frontend's sources
and exits without showing a window. It needs `frontend` in `myzig.zon`
(or a `frontend/` directory), and an app that calls `app.run()`. `dev`
writes the client on every build too. See [Bindings](bindings.md) for the
client.

## myzig icon

```sh
myzig icon resources/icon.png              # icon.icns, icon.ico, icon-16.png ... icon-1024.png beside it
myzig icon logo.png --out resources/icons
myzig icon --new resources/icon.png        # write myzig's default icon
```

Renders a square PNG as `icon.icns` (macOS), `icon.ico` (Windows) and PNGs
of 16, 32, 48, 64, 128, 256, 512 and 1024 pixels. `myzig build` makes the
platforms' icons from `myzig.zon`'s `icon` itself; this command is for
looking at them, or for other tools. Use a PNG of 1024 pixels for the
sharpest result.

## myzig keygen

```sh
myzig keygen                 # into <config>/myzig/update-keys
myzig keygen --out keys --force
```

Creates the Ed25519 key pair that signs updates: `myzig-update.key`, the
secret, and `myzig-update.pub`, and prints the `updates` to put in
`myzig.zon`. The configuration directory is `%APPDATA%` on Windows,
`~/Library/Application Support` on macOS and `$XDG_CONFIG_HOME` (or
`~/.config`) on Linux. Keep the secret key out of the repository, in a
password manager and the secrets of CI: installed apps accept only updates
signed with it. `--force` replaces keys that are there. See
[Updates](updates.md).

## myzig doctor

Checks what building and running myzig apps needs on this machine:

| | |
|---|---|
| all | Zig 0.17 or later (`ZIG`, else `zig` on the `PATH`) |
| macOS | macOS 12 or later; the SDK (`xcrun --show-sdk-path`, the Command Line Tools) |
| Linux | GTK 3 (`libgtk-3.so.0`) and WebKitGTK (`libwebkit2gtk-4.1.so.0` or 4.0) |
| Windows | the WebView2 Runtime (pages need it); no SDK, Zig links Windows apps itself |
| optional | `hdiutil` (disk images), `makensis` (the Windows installer), `bun` (frontends with a dev server), `git` (fetching myzig in `init`) |

It exits with an error when a required check fails.

## myzig version

Prints the CLI's version (`myzig --version`, `-v`), which follows myzig's
(`myzig.version`).

## The flags of apps

Every myzig app understands these flags, which the CLI and tests use. They
never show a window on the screen:

| flag | |
|---|---|
| `--myzig-generate=DIR` | write the generated client (`myzig.js`, `myzig.d.ts`) into DIR and exit |
| `--myzig-snapshot=PNG` | render the first native UI window offscreen to a PNG and exit |
| `--myzig-script=STEPS` | with `--myzig-snapshot`: steps run first (`click:Tasks;type:Hi;key:enter`; see [Testing](ui/testing.md)) |
| `--myzig-dark` | with `--myzig-snapshot`: the dark appearance |
| `--myzig-wait=SECONDS` | with `--myzig-snapshot`: run the event loop that long first |
| `--myzig-hidden` | never show windows; the app's directories are temporary (headless) |
| `--myzig-eval=JS` | evaluate JS in each page once its DOM is ready (implies hidden); `myzig.log` prints to stderr |

## Environment variables

| variable | |
|---|---|
| `ZIG` | the Zig the CLI runs |
| `MYZIG_ROOT` | the myzig `init` depends on, when `--myzig` isn't given |
| `MYZIG_DEV` | set to `1` in apps `myzig dev` runs |
| `MYZIG_DEV_URL` | set to `dev_url` in apps `myzig dev` runs |
| `MYZIG_DEBUG` | in apps: log windows' ids and frames, for tools and tests |
| `MYZIG_UPDATER_PRIVATE_KEY` | the secret key that signs updates (before `updates.private_key`) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | the credentials `--upload` puts files into `updates.s3` with |
| `AWS_REGION`, `AWS_DEFAULT_REGION` | the bucket's region, when `updates.s3.region` is not set |

## What mygo's CLI has that this one doesn't yet

`mygo install-skills`, `mygo i18n check`, delta updates and macOS bundle
updates (`mygo build` signs an archive of the whole app), the `-web` live reload of native UI in a browser, code signing on Windows
and notarization on macOS, and putting plugins' native libraries into apps.
