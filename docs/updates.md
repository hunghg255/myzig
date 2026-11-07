# Updates

Apps built with myzig update themselves from signed releases, published
on GitHub, in an S3 bucket or on any web server. It follows mygo's
[auto-updates](../../mygo/docs/updates.md).

- `myzig build` signs each platform's update with your key.
- The [updater plugin](plugins/updater.md) in the app downloads a newer
  version and checks its signature against the public key the app was
  given. Then it puts the new version in place of the app.

## Set up

Create the key pair that signs updates:

```sh
myzig keygen
```

It writes `myzig-update.key`, the secret key, and `myzig-update.pub`, the
public key. They go to `myzig/update-keys` in your configuration
directory, and it prints where. `--out` chooses another directory.

Keep the secret key out of the repository, in a password manager and in
the secrets of your CI. Installed apps accept only updates signed with
it:

- losing it strands them;
- anyone who has it can ship code to your users.

Add the public key to `myzig.zon`, with where releases are published:

```zig
.updates = .{
    .public_key = "…the contents of myzig-update.pub…",
    .github = "you/my-app",
},
```

| Field | |
|---|---|
| `github` | a public repository whose releases hold the updates, tagged `v1.2.0` and so on (`tag_prefix`); apps read the manifests of its latest release |
| `url` | instead of `github`, for your own server or an [S3 bucket](#publishing-to-s3): the URL of a directory |

- `url` can be https, or http on an intranet. Apps trust the signature,
  not the transport.
- Manifests name the executable relative to themselves. So the app's
  `manifest_url` chooses the directory, whatever `url` says. You might
  use one directory per environment.

Give the app the same public key and the URL of its platform's manifest,
which `myzig build` prints. These are `updater.Service`'s `public_key`
and `manifest_url`:

```zig
var service: updater.Service = try .init(gpa, app, .{
    .manifest_url = "https://github.com/you/my-app/releases/latest/download/update-windows-x86_64.json",
    .current = "1.2.0",
    .public_key = "…the contents of myzig-update.pub…",
});
```

## Build and publish

Give `myzig build` the secret key in one of two ways:

- the `MYZIG_UPDATER_PRIVATE_KEY` environment variable;
- a file named by `updates.private_key`, a path which may start with
  `~/`.

```sh
MYZIG_UPDATER_PRIVATE_KEY="$(cat path/to/myzig-update.key)" myzig build
```

Next to the packages of each platform it writes:

- `my-app-1.2.0-windows-x86_64.exe` (`my-app-1.2.0-linux-x86_64`, ...):
  the executable the updater puts in place of the installed one;
- `update-windows-x86_64.json`, the manifest: the version, its release
  notes, the date, and the URL, size, SHA-256 and Ed25519 signature of
  the executable.

Without a key or with the wrong one:

- Without a key, `myzig build` builds the packages and skips the update
  files, after a warning.
- `myzig build --upload` needs the key. Without it, it stops before
  building: installed apps cannot update to a release without manifests.
- A key that does not match `updates.public_key` stops the build too.

The release notes are the version's section in `CHANGELOG.md`.
`updates.changelog` names another file. The section is under a `## 1.2.0`
heading, or `## [1.2.0] - 2026-09-19` as in
[Keep a Changelog](https://keepachangelog.com). When the file exists, it
must have that section.

Publish the files where `updates` points to:

- **GitHub**: `myzig build --upload` uploads them, with the packages, to
  a draft release of the version.
  - It uses the GitHub CLI (`gh`, signed in with `gh auth login` or
    `GH_TOKEN`).
  - Publishing the release makes it the latest, which apps check. They
    read the manifests from
    `https://github.com/you/my-app/releases/latest/download/`.
- **S3**: `myzig build --upload` uploads them, with the packages, to the
  bucket of `updates.s3`; see [below](#publishing-to-s3).
- **Your server**: upload the executables and the manifests to the `url`
  directory. Upload the manifests last, so apps never see a manifest
  whose file is missing.

Each platform and architecture has its own manifest, such as
`macos-aarch64`, `macos-universal`, `windows-x86_64` or `windows-x86`. A
build only looks at its own.

### Publishing to S3

When a bucket of Amazon S3, or of a compatible service such as
Cloudflare R2, serves `url`, directly or through a CDN, name it in
`updates.s3`:

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

`myzig build --upload` then uploads the packages and the update to it.
The manifest goes last, which publishes the update of the platform.

- It needs no other tool. The CLI signs requests with AWS Signature
  Version 4.
- Credentials: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and, for
  temporary ones, `AWS_SESSION_TOKEN`.
- Region: `s3.region`, else `AWS_REGION` (or `AWS_DEFAULT_REGION`), else
  `us-east-1`, which R2 accepts.
- The manifests keep their names from version to version. They are
  uploaded with `Cache-Control: no-cache`, so a CDN checks them again.

<details>
<summary>Where the bucket's name goes</summary>

- On Amazon S3, the bucket is named in the host name of requests.
- With `endpoint`, or a bucket name with dots, it is named in their
  path.
- Set `path_style` to `false` for services that only take it in the host
  name, or to `true` to force the path.

</details>

## Not yet

mygo's updates do more, which myzig does not yet:

- **Whole apps.** The updater replaces one executable, not a macOS
  `.app` bundle or the resources beside the executable. Replacing the
  executable of a bundle signed with a Developer ID breaks its seal.
- **Delta updates**, which download only what changed.
- **Releases with a tag prefix of their own** found through the GitHub
  API, for a repository whose latest release is another's.
