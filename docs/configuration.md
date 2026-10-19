# Configuration

The [CLI](cli.md) reads an app's configuration from `myzig.zon` at its
root, or `myzig.json` (not both). Every field is optional; without a file,
the defaults below apply. Zig itself never reads it: `zig build` builds the
app from `build.zig` and `build.zig.zon`, and the configuration says how
the CLI runs, packages and names it.

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

Paths are relative to the app's root, or absolute. A field the CLI doesn't
know is an error that names it (`myzig.zon has no field nmae`), as is a
value of the wrong kind; a ZON syntax error gives its line and column.

## The app

| field | default | |
|---|---|---|
| `name` | the directory's name | the name people see: the bundle's, the installer's, the window class's |
| `identifier` | `com.myzig.<name>` | a reverse DNS name (letters, digits, `.` and `-`), as `com.example.myapp`: the bundle identifier, the uninstall key, the Windows manifest's name |
| `version` | `build.zig.zon`'s `.version`, else `0.1.0` | the version of packages and installers (Windows takes up to four numbers of it) |
| `copyright` | none | macOS's `NSHumanReadableCopyright`, Windows' `LegalCopyright` |
| `icon` | `resources/icon.png` when it exists | a square PNG (1024 pixels is best): `.icns`, `.ico`, Linux's sizes are made from it |
| `executable` | `build.zig.zon`'s `.name`, else the name in snake case | the artifact `build.zig` installs (`zig-out/bin/<executable>`) |

`name`, `version` and `identifier` cannot hold quotes or control
characters. Keep `identifier` the same as `AppOptions.id` in the app's
code, which names its single instance lock, URL handler and secrets (see
[The app](app.md)).

## Development and the frontend

| field | default | |
|---|---|---|
| `frontend` | `frontend` when the directory exists | the web frontend's sources, where `generate` and `dev` write `myzig.js` and `myzig.d.ts` |
| `frontend_dist` | `frontend` | the built frontend that the app embeds; the CLI writes its `myzig_assets.zig` and passes it as `-Dfrontend` |
| `dev_url` | none | an `http://` or `https://` URL: `myzig dev` waits for it and passes it as `MYZIG_DEV_URL` |
| `dev_command` | none | the dev server `myzig dev` runs first (`bun run dev`), in a shell, in the app's root |
| `build_command` | none | what `myzig build` runs first to build the frontend (`bun run build`) |
| `out` | `dist` | where `myzig build` puts packages |
| `watch` | none | accepted; `myzig dev` already watches the whole app directory |

A frontend without a build (plain HTML, as the web template's) has
`frontend` alone: the app embeds its sources. A frontend built by Vite or
another tool sets `frontend_dist` to its output, and `dev_command`,
`dev_url` and `build_command`:

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

See [Frontend](frontend.md) for the page's side.

## Integration

| field | default | |
|---|---|---|
| `resources` | none | files and directories shipped beside the app, besides what `resources/` holds |
| `url_schemes` | none | URL schemes the app opens (`myapp` for `myapp://...`): letters, digits, `+`, `-` and `.`, starting with a letter |
| `file_associations` | none | file types the app opens |

Everything in `resources/` but the icon ships with the app too: see
[Distribution](distribution.md#resources).

A file association is:

| field | default | |
|---|---|---|
| `ext` | required | extensions without the dot (`.{ "md", "markdown" }`) |
| `name` | `<EXT> file` | the type's name in the system |
| `mime_type` | `application/x-<executable>-<ext>` | the MIME type; Linux packages define the type when it is myzig's |
| `role` | `Editor` | `Editor` or `Viewer` (macOS) |

The packages register these with the system: `CFBundleURLTypes` and
`CFBundleDocumentTypes` in the macOS bundle, registry keys written by the
Windows installer, `MimeType=` in the Linux desktop entry. The app also
names them in its own options, `AppOptions.url_schemes` and
`AppOptions.file_extensions`, so that launches with such arguments reach
`on_open_url` and `on_open_file`, and can register them while it runs
(`myzig.system.registerUrlScheme`, `registerFileType`; see
[System](system.md)).

## macos

| field | default | |
|---|---|---|
| `minimum_system_version` | `12.0` | `LSMinimumSystemVersion` |
| `signing_identity` | `-` | `codesign`'s identity; `-` signs ad hoc (runs on the Mac that built it) |
| `entitlements` | none | an entitlements file for `codesign` |
| `provisioning_profile` | none | a profile embedded as `Contents/embedded.provisionprofile` before signing; it must match the app's identifier, entitlements and signing identity, and cannot be used with ad-hoc signing. See [provisioning profiles](distribution.md#provisioning-profiles) |
| `dmg_title` | the name | the disk image's volume name |
| `info_plist` | none | keys added to `Info.plist`, replacing myzig's |

```zig
.macos = .{
    .signing_identity = "Developer ID Application: Example Inc. (TEAMID)",
    .entitlements = "resources/macos/app.entitlements",
    .info_plist = .{ .NSCameraUsageDescription = "Scans documents", .LSUIElement = true },
},
```

## updates

Signed [updates](updates.md). `public_key` and one of `github` and `url`
are required.

| field | default | |
|---|---|---|
| `public_key` | | the contents of `myzig-update.pub` ([`myzig keygen`](cli.md#myzig-keygen)) |
| `github` | | the public repository (`owner/name`) whose releases hold the updates; apps read the manifests of its latest release |
| `tag_prefix` | `v` | the releases' tags: `v1.2.0` |
| `url` | | an HTTPS directory serving the updates instead of GitHub |
| `s3` | | the bucket that serves `url`, which `--upload` puts the files into: `bucket`, `prefix` (its directory), `region`, `endpoint` (a compatible service's, as Cloudflare R2's), `path_style` |
| `private_key` | | the path of `myzig-update.key` (may start with `~/`); `MYZIG_UPDATER_PRIVATE_KEY` comes first |
| `changelog` | `CHANGELOG.md` when it exists | the Markdown file whose `## <version>` section is the release notes |

```zig
.updates = .{
    .public_key = "…",
    .url = "https://downloads.example.com/my-app",
    .s3 = .{ .bucket = "downloads", .prefix = "my-app", .endpoint = "https://<account>.r2.cloudflarestorage.com" },
},
```

## windows

| field | default | |
|---|---|---|
| `installer` | true | write the NSIS installer's script, and make the installer when `makensis` is installed |

## linux

| field | default | |
|---|---|---|
| `maintainer` | the name | the Debian package's `Maintainer` |
| `comment` | none | the desktop entry's `Comment` |
| `categories` | `Utility` | the desktop entry's `Categories` |
| `depends` | none | more Debian dependencies, after GTK 3 and WebKitGTK |
| `command` | none | a command in `/usr/bin` that runs the app (letters, digits, `.`, `_`, `+`, `-`) |

## myzig.json

The same fields in JSON:

```json
{
  "name": "Hello",
  "dev_url": "http://localhost:5173",
  "file_associations": [{ "ext": ["md"], "name": "Markdown" }],
  "windows": { "installer": false }
}
```

## How it is read

The CLI reads the file with a ZON reader of its own (`cli/src/zon.zig`, so
that it reads the same across Zig versions and says where a mistake is),
fills in the defaults (from `build.zig.zon` and the directory), and checks
the result: extensions without dots, URL schemes and the identifier as
their systems want them, `dev_url` an http(s) URL, `role` `Editor` or
`Viewer`. `Config` in `cli/src/config.zig` is the reference.
