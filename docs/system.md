# The system around the app

Beyond its windows, an app talks to the desktop it runs on: it asks the
user for files, opens links in the browser, keeps its data where each
system wants it, follows the system's appearance, stores passwords in the
system's keychain, records recent documents, opens at login, keeps the
computer awake while it works, and watches files other apps change. Each of
these is one call that does the right thing on macOS, Linux and Windows,
and something sensible (or `error.Unsupported`) in browsers.

Calls that run modally (dialogs) or touch the windowing system run on the
main thread, from a menu click, a bound method or a view; see
[the application](app.md) for threads.

## Dialogs

`myzig.dialog` has the system's open and save panels and message boxes.
They block until the user answers and return the answer:

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

`dialog.OpenOptions` has `title`, `button` (the default button's label),
`message`, `directory` (where the panel starts), `files` and `directories`
(what may be chosen; folders only with `.files = false, .directories =
true`), `multiple`, `extensions` (without dots) and `show_hidden`.
`dialog.SaveOptions` has `title`, `button`, `message`, `directory`, `name`
(the file name it starts with), `extensions`, `show_hidden` and
`create_directories`.

A message box returns the index of the button pressed, the first being
the default, and whether its checkbox was checked:

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

On Windows the open dialog chooses a single file for now, and neither
dialog filters by `extensions` yet. Native UI also has dialogs of its own,
drawn inside the window: see [overlays](ui/overlays.md).

## Opening things in other apps

`myzig.shell` hands URLs and files to the apps the user chose for them:

```zig
_ = myzig.shell.openUrl("https://ziglang.org"); // any scheme: https:, mailto:, ...
_ = myzig.shell.openPath("/Users/ada/report.pdf"); // in its default app
myzig.shell.showInFolder("/Users/ada/report.pdf"); // in Finder or the file manager
_ = myzig.shell.trash("/Users/ada/old.txt"); // to the Trash
myzig.shell.beep(); // the system's alert sound
```

`openUrl`, `openPath` and `trash` return whether they did it.
`showInFolder` selects the file in a Finder window on macOS, and opens its
folder elsewhere. On Linux they run `xdg-open`; on Windows the shell's open
verb. `trash` works on macOS (the Trash) and Windows (the recycle bin,
through `IFileOperation`; a relative path is the working directory's), and
returns false elsewhere so far; `beep` works on macOS and in browsers. In
a browser `openUrl` opens a tab, which the browser may block outside a
click.

`trash` never deletes for good: where the item cannot go to the trash it
returns false and leaves the item where it is. On Windows that is an item
too big for the recycle bin, or on a drive without one, as network shares
and many removable drives are, which Windows would otherwise delete
without asking.

## The app's directories

`myzig.appPath` gives the app's own directories, where each system wants
them, and creates them (all but `temp`) when they are missing:

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
`documents`, `downloads`, `desktop` and `temp`:

```zig
const downloads = try myzig.path(gpa, .downloads, app.options.name);
defer gpa.free(downloads);
```

In a browser both answer with directories of the in-memory WASI file
system the page hosts (`/home`, `/tmp`, `/home/.local/share/Name`), which
lasts as long as the page.

## Appearance

`myzig.isDark()` tells whether the system shows dark mode, and
`myzig.accentColor()` returns the accent color the user chose, as sRGB
`[3]f32`. Native UI follows both by itself (see
[styling](ui/styling.md)); these are for apps that draw or choose colors of
their own.

- macOS: the app's effective appearance and `controlAccentColor`.
- Linux: dark when `GTK_THEME` names a dark theme; the accent is a fixed
  blue.
- Windows: the "apps use light theme" setting.
- Browsers: `prefers-color-scheme`, or the page's own
  `data-myzig-theme="dark"` or `"light"` on its root element.

## Locale and languages

`myzig.system` answers with the user's locale and languages, for apps that
format or translate themselves ([i18n](i18n.md) does both):

```zig
const tag = try myzig.system.locale(gpa); // "en-US", BCP 47
defer gpa.free(tag);
const region = try myzig.system.region(gpa); // "US"
defer gpa.free(region);
const langs = try myzig.system.languages(gpa); // most preferred first
defer myzig.system.freeList(gpa, langs);
```

On Linux they come from `LANGUAGE`, `LC_ALL`, `LC_MESSAGES`, `LC_TIME` and `LANG`,
turned into BCP 47 tags; in a browser from `navigator.languages`.

## Recent documents

```zig
try myzig.system.addRecentDocument(app, "/Users/ada/Notes.md");
const recent = try myzig.system.recentDocuments(app);
defer myzig.system.freeList(app.gpa, recent);
myzig.system.clearRecentDocuments(app);
```

`addRecentDocument` records a file in the system's list (macOS's Open
Recent menu and Dock menu, Windows' Recent items and the app's jump list,
Linux's recently used files) and in the app's own, kept in
`recent-documents.txt` in its data directory. `recentDocuments` returns the
app's own list, newest first, ten at most, only the files that still exist.
`clearRecentDocuments` forgets them; on Linux, the user's other recent
files stay. [Documents](documents.md) record what they open and show the
list in their File menu.

On Windows, `system.setJumpList(app, tasks)` sets the Tasks of the app's
jump list (a right click on its taskbar button), each a `JumpTask` with a
`title`, `description`, `path`, `args` and an icon. Windows keeps the list
after the app quits: set it once at startup. A task best runs a URL of the
app's own scheme, which reaches `on_open_url`. Elsewhere it does nothing.

## Open at login

```zig
try myzig.system.setOpenAtLogin(app, true);
const on = myzig.system.openAtLogin(app);
if (myzig.system.wasOpenedAtLogin(app)) {
    // started by the system: stay in the tray, show no window
}
```

The app opens at login with a Run entry on Windows, an XDG autostart entry
on Linux, and a login item on macOS 13 and later (for bundled apps).
`wasOpenedAtLogin` tells such a launch apart on Windows and Linux, where
the entry passes `--myzig-login`.

## URL schemes and file types

The app opens its own URLs (`notes://open?id=4`) and files of its types
when the system hands them over, through `AppOptions.on_open_url` and
`on_open_file` (see [the application](app.md) for the handlers, and
`url_schemes` and `file_extensions` to name them):

```zig
try myzig.system.registerUrlScheme(app, "notes"); // cheap: at every launch
if (!myzig.system.isUrlSchemeRegistered(app, "notes")) {}
try myzig.system.unregisterUrlScheme(app, "notes");
try myzig.system.registerFileType(app, "md", "Markdown Document");
try myzig.system.unregisterFileType(app, "md");
```

`registerUrlScheme` makes the app the user's handler of the scheme: in the
registry on Windows, in a desktop entry made the default in `mimeapps.list` on Linux (as `xdg-mime default` does),
and on macOS as the default handler of a scheme which the bundle's
`Info.plist` must declare ([distribution](distribution.md) writes it).
`unregisterUrlScheme` undoes it on Windows and Linux.
`registerFileType` adds the app to a file extension's Open with list on
Windows; macOS declares file types in the bundle and Linux in the app's
desktop entry, where it returns `error.Unsupported`.

## Keeping the system awake

```zig
const awake = try myzig.system.preventSleep(app, "Exporting the video", .system);
defer awake.release();
```

`.system` keeps the computer from sleeping while idle (the display may
still turn off); `.display` keeps the display on too. It uses power
requests on Windows, power assertions on macOS, and on Linux the screen
saver's inhibition over the session bus, which keeps both awake.

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
  libsecret, loaded with `dlopen`, with keytar's schema; secrets are text
  there (no NUL bytes). Without libsecret, `error.Unsupported`.
- Browsers: `error.Unsupported`.

## Watching files

`myzig.file_watch.watch` calls a handler on the main thread when a file
may have changed: written, replaced, renamed or deleted by another app. A
change to another file of its folder can wake it too, so the handler looks
at the file itself. It uses kqueue on macOS, inotify on Linux and change
notifications on Windows; nothing polls. Browsers have no watches
(`error.Unsupported`).

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
exits, without a thread of the app's own and without polling:

```zig
const out = try myzig.fdwatch.readable(pipe_fd, &job, Job.onOutput);
defer out.cancel();
const done = try myzig.fdwatch.exited(pid, &job, Job.onExit);
defer done.cancel();
```

The handler has the same signature as a file watch's,
`fn (ctx: ?*anyopaque) callconv(.c) void`, and reads what is there; it
also runs once at the end of the file. macOS uses libdispatch sources,
Linux GLib's. Windows apps wait on handles instead, and there both return
`error.Unsupported` for now (the [terminal plugin](plugins/terminal.md)
uses ConPTY there).
