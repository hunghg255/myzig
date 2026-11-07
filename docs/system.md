# The system around the app

Beyond its windows, an app talks to the desktop it runs on. It:

- asks the user for files;
- opens links in the browser;
- keeps its data where each system wants it;
- follows the system's appearance;
- stores passwords in the system's keychain;
- records recent documents and opens at login;
- keeps the computer awake while it works;
- watches files other apps change.

Each of these is one call. It does the right thing on macOS, Linux and
Windows, and something sensible (or `error.Unsupported`) in browsers.

Calls that run modally (dialogs) or touch the windowing system run on the
main thread: from a menu click, a bound method or a view. See
[the application](app.md) for threads.

## Dialogs

`myzig.dialog` has the system's open and save panels and message boxes.
They block until the user answers, and return the answer:

```zig
const myzig = @import("myzig");

fn importImages(gpa: std.mem.Allocator) !void {
    const paths = (try myzig.dialog.open(gpa, .{
        .title = "Import",
        .button = "Import",
        .multiple = true,
        .extensions = &.{ "png", "jpg" },
    })) orelse return; // canceled
    defer myzig.dialog.freePaths(gpa, paths);
    for (paths) |p| std.log.info("import {s}", .{p});
}

fn exportAs(gpa: std.mem.Allocator) !void {
    const path = (try myzig.dialog.save(gpa, .{ .name = "Untitled.md", .extensions = &.{"md"} })) orelse return;
    defer gpa.free(path);
    // write the file at `path`
}
```

| `dialog.OpenOptions` | |
|---|---|
| `title`, `message` | |
| `button` | the default button's label |
| `directory` | where the panel starts |
| `files`, `directories` | what may be chosen; folders only with `.files = false, .directories = true` |
| `multiple` | |
| `extensions` | without dots |
| `show_hidden` | |

`dialog.SaveOptions` has `title`, `button`, `message`, `directory`,
`extensions`, `show_hidden` and `create_directories`, and `name`: the
file name it starts with.

A message box returns the index of the button pressed, and whether its
checkbox was checked. The first button is the default.

```zig
const r = myzig.dialog.message(.{
    .title = "Delete the note?",
    .detail = "You can't undo this action.",
    .kind = .warning, // .info, .warning, .critical
    .buttons = &.{ "Delete", "Cancel" },
    .checkbox = "Don't ask again",
});
if (r.button == 0) deleteNote();
if (r.checked) prefs.ask_before_delete = false;
```

| | macOS | Linux | Windows | browsers |
|---|---|---|---|---|
| open, save | `NSOpenPanel`, `NSSavePanel` | GTK's native file chooser (the desktop portal's where there is one) | the common file dialogs | `error.Unsupported` |
| message | `NSAlert`, with the checkbox | GTK's message dialog | a message box | `alert` for one button, else `confirm` |

- On Windows the save dialog doesn't filter by `extensions` yet.
- Native UI also has dialogs of its own, drawn inside the window: see
  [overlays](ui/overlays.md).

## Opening things in other apps

`myzig.shell` hands URLs and files to the apps the user chose for them:

```zig
_ = myzig.shell.openUrl("https://ziglang.org"); // any scheme: https:, mailto:, ...
_ = myzig.shell.openPath("/Users/ada/report.pdf"); // in its default app
myzig.shell.showInFolder("/Users/ada/report.pdf"); // in Finder or the file manager
_ = myzig.shell.trash("/Users/ada/old.txt"); // to the Trash
myzig.shell.beep(); // the system's alert sound
```

- `openUrl`, `openPath` and `trash` return whether they did it.
- `showInFolder` selects the file in a Finder window on macOS, and opens
  its folder elsewhere.
- On Linux they run `xdg-open`; on Windows, the shell's open verb.
- In a browser `openUrl` opens a tab. The browser may block it outside a
  click.
- `beep` works on macOS and in browsers.

**`trash`** works on macOS (the Trash) and Windows (the recycle bin,
through `IFileOperation`). On Windows a relative path is the working
directory's. It returns false elsewhere so far.

`trash` never deletes for good. Where the item cannot go to the trash, it
returns false and leaves the item where it is. On Windows that is:

- an item too big for the recycle bin;
- an item on a drive without one, as network shares and many removable
  drives are.

Windows would otherwise delete these without asking.

## The app's directories

`myzig.appPath` gives the app's own directories, where each system wants
them. It creates them (all but `temp`) when they are missing:

```zig
const logs = try myzig.appPath(gpa, .logs, "Notes");
defer gpa.free(logs);
```

| `myzig.AppDir` | macOS | Linux | Windows |
|---|---|---|---|
| `data` | `~/Library/Application Support/Name` | `$XDG_DATA_HOME/Name` (`~/.local/share/Name`) | `%APPDATA%\Name` |
| `config` | `~/Library/Application Support/Name` | `$XDG_CONFIG_HOME/Name` (`~/.config/Name`) | `%APPDATA%\Name` |
| `cache` | `~/Library/Caches/Name` | `$XDG_CACHE_HOME/Name` (`~/.cache/Name`) | `%LOCALAPPDATA%\Name\Cache` |
| `logs` | `~/Library/Logs/Name` | `$XDG_STATE_HOME/Name/logs` (`~/.local/state/Name/logs`) | `%LOCALAPPDATA%\Name\Logs` |
| `temp` | `$TMPDIR` | `$TMPDIR` or `/tmp` | `%TEMP%` |

XDG variables that aren't absolute paths are ignored, as the specification
says.

`myzig.path` also knows the user's standard folders. It takes a
`myzig.Directory`: `data` and `cache` (the app's own, created), `home`,
`documents`, `downloads`, `desktop` or `temp`:

```zig
const downloads = try myzig.path(gpa, .downloads, app.options.name);
defer gpa.free(downloads);
```

In a browser both answer with directories of the in-memory WASI file
system the page hosts: `/home`, `/tmp`, `/home/.local/share/Name`. It
lasts as long as the page.

## Appearance

- `myzig.isDark()` tells whether the system shows dark mode.
- `myzig.accentColor()` returns the accent color the user chose, as sRGB
  `[3]f32`.

Native UI follows both by itself (see [styling](ui/styling.md)). These
are for apps that draw or choose colors of their own.

- macOS: the app's effective appearance and `controlAccentColor`.
- Linux: dark when `GTK_THEME` names a dark theme; the accent is a fixed
  blue.
- Windows: the "apps use light theme" setting.
- Browsers: `prefers-color-scheme`, or the page's own
  `data-myzig-theme="dark"` or `"light"` on its root element.

## Locale and languages

`myzig.system` answers with the user's locale and languages, for apps
that format or translate themselves. [i18n](i18n.md) does both:

```zig
const tag = try myzig.system.locale(gpa); // "en-US", BCP 47
defer gpa.free(tag);
const region = try myzig.system.region(gpa); // "US"
defer gpa.free(region);
const langs = try myzig.system.languages(gpa); // most preferred first
defer myzig.system.freeList(gpa, langs);
```

On Linux they come from `LANGUAGE`, `LC_ALL`, `LC_MESSAGES`, `LC_TIME`
and `LANG`, turned into BCP 47 tags. In a browser they come from
`navigator.languages`.

## Recent documents

```zig
try myzig.system.addRecentDocument(app, "/Users/ada/Notes.md");
const recent = try myzig.system.recentDocuments(app);
defer myzig.system.freeList(app.gpa, recent);
myzig.system.clearRecentDocuments(app);
```

`addRecentDocument` records a file in two lists:

- the system's: macOS's Open Recent menu and Dock menu, Windows' Recent
  items and the app's jump list, Linux's recently used files;
- the app's own, kept in `recent-documents.txt` in its data directory.

`recentDocuments` returns the app's own list: newest first, ten at most,
only the files that still exist. `clearRecentDocuments` forgets them. On
Linux, the user's other recent files stay.

[Documents](documents.md) record what they open and show the list in
their File menu.

**Jump list.** On Windows, `system.setJumpList(app, tasks)` sets the
Tasks of the app's jump list, shown by a right click on its taskbar
button. Elsewhere it does nothing.

- Each task is a `JumpTask` with a `title`, `description`, `path`, `args`
  and an icon.
- Windows keeps the list after the app quits: set it once at startup.
- A task best runs a URL of the app's own scheme, which reaches
  `on_open_url`.

## Open at login

```zig
try myzig.system.setOpenAtLogin(app, true);
const on = myzig.system.openAtLogin(app);
if (myzig.system.wasOpenedAtLogin(app)) {
    // started by the system: stay in the tray, show no window
}
```

| Platform | The app opens at login with |
|---|---|
| Windows | a Run entry |
| Linux | an XDG autostart entry |
| macOS 13 and later | a login item (for bundled apps) |

`wasOpenedAtLogin` tells such a launch apart on Windows and Linux, where
the entry passes `--myzig-login`.

<details>
<summary>Administrator rights at login on Windows</summary>

The Run entry starts the app with the user's normal (unelevated) token,
even when the user is an administrator. So the app cannot create network
adapters, change the system's proxy or write to protected folders.

An app that needs administrator rights does not call `setOpenAtLogin`:

- It registers a logon task in Task Scheduler with the run level
  `HighestAvailable` instead (`schtasks /Create /SC ONLOGON /RL HIGHEST`).
  That starts it elevated without asking.
- Creating the task needs administrator rights itself. So the app asks
  for them once, as the user turns the setting on.
- `wasOpenedAtLogin` does not tell such a launch apart. Give the task's
  command an argument of the app's own for that.

</details>

## URL schemes and file types

The app opens its own URLs (`notes://open?id=4`) and files of its types
when the system hands them over. They reach `AppOptions.on_open_url` and
`on_open_file`. See [the application](app.md) for the handlers, and for
`url_schemes` and `file_extensions` to name them.

```zig
try myzig.system.registerUrlScheme(app, "notes"); // cheap: at every launch
if (!myzig.system.isUrlSchemeRegistered(app, "notes")) {}
try myzig.system.unregisterUrlScheme(app, "notes");
try myzig.system.registerFileType(app, "md", "Markdown Document");
try myzig.system.unregisterFileType(app, "md");
```

`registerUrlScheme` makes the app the user's handler of the scheme:

| Platform | How |
|---|---|
| Windows | in the registry |
| Linux | in a desktop entry made the default in `mimeapps.list`, as `xdg-mime default` does |
| macOS | as the default handler of a scheme the bundle's `Info.plist` must declare ([distribution](distribution.md) writes it) |

`unregisterUrlScheme` undoes it on Windows and Linux.

`registerFileType` adds the app to a file extension's Open with list on
Windows. macOS declares file types in the bundle and Linux in the app's
desktop entry. There it returns `error.Unsupported`.

## Keeping the system awake

```zig
const awake = try myzig.system.preventSleep(app, "Exporting the video", .system);
defer awake.release();
```

- `.system` keeps the computer from sleeping while idle. The display may
  still turn off.
- `.display` keeps the display on too.

It uses power requests on Windows and power assertions on macOS. On
Linux it uses the screen saver's inhibition over the session bus, which
keeps both awake.

## Secrets

`myzig.secrets` stores passwords and tokens encrypted for the user by the
system, by service and account, as keytar does:

```zig
try myzig.secrets.set(gpa, "com.example.notes", "ada@example.com", token);
if (try myzig.secrets.get(gpa, "com.example.notes", "ada@example.com")) |t| {
    defer gpa.free(t);
    // use the token
}
_ = try myzig.secrets.delete("com.example.notes", "ada@example.com"); // false if there was none
```

- macOS: generic passwords in the Keychain.
- Windows: generic credentials of the Credential Manager, the target
  `service/account`, encrypted with DPAPI.
- Linux: the user's keyring (GNOME Keyring, KWallet, KeePassXC) through
  libsecret, loaded with `dlopen`, with keytar's schema. Secrets are text
  there (no NUL bytes). Without libsecret, `error.Unsupported`.
- Browsers: `error.Unsupported`.

## Watching files

`myzig.file_watch.watch` calls a handler on the main thread when a file
may have changed: written, replaced, renamed or deleted by another app.

- A change to another file of its folder can wake it too, so the handler
  looks at the file itself.
- It uses kqueue on macOS, inotify on Linux and change notifications on
  Windows. Nothing polls.
- Browsers have no watches (`error.Unsupported`).

```zig
const Doc = struct {
    path: []const u8,

    fn onChange(ctx: ?*anyopaque) callconv(.c) void {
        const d: *Doc = @ptrCast(@alignCast(ctx));
        _ = d; // stat d.path, read it again if it changed
    }
};

const w = try myzig.file_watch.watch(doc.path, &doc, Doc.onChange);
defer w.cancel();
```

[Documents](documents.md) watch their files this way. The
[watch plugin](plugins/watch.md) watches whole directory trees.

## Pipes and processes

`myzig.fdwatch` runs a handler on the main thread when a file descriptor
(a pipe, a pseudo-terminal) has bytes to read, and when a child process
exits. It needs no thread of the app's own, and does not poll:

```zig
const out = try myzig.fdwatch.readable(pipe_fd, &job, Job.onOutput);
defer out.cancel();
const done = try myzig.fdwatch.exited(pid, &job, Job.onExit);
defer done.cancel();
```

- The handler has the same signature as a file watch's,
  `fn (ctx: ?*anyopaque) callconv(.c) void`. It reads what is there.
- It also runs once at the end of the file.
- macOS uses libdispatch sources, Linux GLib's.
- Windows apps wait on handles instead. There both return
  `error.Unsupported` for now; the [terminal plugin](plugins/terminal.md)
  uses ConPTY.
