# The application

An app is one `myzig.App`. It runs the platform's event loop, and owns
the windows, the menu bar and the tray icons. It hands the app what
reaches it from the system: URLs, files, later launches, appearance
changes, notification clicks, the network.

Elsewhere:

- windows: [Windows](windows.md);
- menus and trays: [Menus](menus.md);
- the system's services (dialogs, paths, secrets, recent documents, open
  at login): [System](system.md).

## The main function

```zig
const std = @import("std");
const myzig = @import("myzig");

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{
        .name = "Notes",
        .id = "com.example.notes",
    });
    defer app.destroy();

    var state: Notes = .{};
    _ = try app.newWindow(.{ .title = "Notes", .content = .{ .view = .init(&state, Notes.view) } });
    try app.run();
}
```

**`App.create`** takes the process's `std.process.Init` (its allocator,
I/O, arguments and environment) and the app's options. It:

- parses myzig's own flags (`--myzig-*`, see [Testing](ui/testing.md));
- on macOS, sets up the menu bar with the default menus
  ([Menus](menus.md));
- returns the app.

Call it from `main`, on the main thread. On macOS it fails with
`error.NotMainThread` elsewhere.

**`run`** runs the event loop until the app quits, and returns.

- With `--myzig-generate=DIR` it writes the generated client instead
  ([Bindings](bindings.md)).
- With `--myzig-snapshot=PNG` it draws the first window of native UI to a
  file.
- Both return at once, so the same `main` serves the app, its client and
  its snapshots.

**`destroy`** closes the windows that are left, removes the tray icons
and the menu bar, and unregisters global shortcuts. It releases the
single instance lock, and frees the app.

### Options

`myzig.AppOptions` (every field has a default):

| field | what it does |
|---|---|
| `name` | the app's name: menus, notifications, the data directory, autostart entries (default `"myzig"`) |
| `id` | reverse DNS (`"com.example.notes"`): the single instance lock, URL handler and autostart entries, secrets' default service; the name when empty |
| `quit_on_last_window_closed` | quit when the last window closes (default true) |
| `quit_on_signal` | Ctrl+C and SIGTERM quit the app (default true) |
| `url_schemes` | the schemes the app opens (`"notes"` for `notes://...`) |
| `file_extensions` | the extensions of files it opens, lower case, without the dot (`"md"`) |
| `secure_origins` | origins of plain http servers (`"http://192.168.1.10:8080"`) whose pages are secure contexts, as https ones, so they may ask for the camera or the microphone ([permissions](pages.md#page-events)); WebView2 only, WebKit has no such setting |
| `on_open_url` | a URL of its schemes was opened |
| `on_open_file` | a file of its types was opened |
| `on_second_instance` | a later launch handed its command line over |
| `on_appearance` | the system switched between light (`false`) and dark (`true`) |
| `on_notification` | a notification was clicked |
| `on_network` | the computer went online or offline, or its connection's cost changed |

The handlers are `myzig.Handler(T)`: a method of the app's and a pointer
to call it with.

```zig
const Notes = struct {
    dark: bool = false,

    fn openUrl(n: *Notes, url: []const u8) void {
        _ = n;
        std.log.info("open {s}", .{url});
    }
    fn appearance(n: *Notes, dark: bool) void {
        n.dark = dark;
    }
};

var notes: Notes = .{};
const app = try myzig.App.create(init, .{
    .name = "Notes",
    .url_schemes = &.{"notes"},
    .on_open_url = .of(&notes, Notes.openUrl),
    .on_appearance = .of(&notes, Notes.appearance),
});
```

Handlers run on the main thread. The strings they get live for the call:
copy what you keep.

## Threads

AppKit, GTK, Win32, the pages and native UI live on the main thread.
myzig calls the app there: views, bound methods, menu clicks, handlers,
timers. The app needs no locks for its own state as long as it stays
there.

Work that takes long belongs on a thread of its own. Its result goes back
to the main thread:

- `myzig.App.after(ms, ctx, func)` calls `func(ctx)` on the main thread
  after `ms` milliseconds (`func` is `fn (?*anyopaque) callconv(.c) void`).
  On macOS it may be called from any thread (libdispatch). On Linux and
  Windows call it from the main thread.
- The [mainthread plugin](plugins/mainthread.md) posts work to the main
  thread from any other, on every platform. It uses the main thread's own
  queue: libdispatch, GLib's main context, a message-only window.
- `Window.sendOwned` queues a message for a page from any thread, and an
  `Event`'s `emit` sends typed events ([Bindings](bindings.md)).
- After state changed outside the view's events (a timer, a process's
  output), `Window.redraw` draws native UI again at the next refresh.

Nothing polls. Frames are drawn on input, resizes, or while an animation
runs, and an idle app uses no CPU.

`myzig.runFor(seconds)` runs the event loop for a while and returns. It
is for headless tests that wait for replies, processes or timers.

## Quitting

`app.quit()` stops the event loop. `run` returns once the current event
is handled, and `main` goes on to `destroy`. The app quits by itself:

- when its last window closes, unless `quit_on_last_window_closed` is
  false (a tray app, a menu bar app);
- on Ctrl+C and SIGTERM, and on Windows on Ctrl+Break and the console
  closing, unless `quit_on_signal` is false. The signal quits on the main
  thread, as `quit` does; a second one exits at once;
- on macOS, from the app menu's Quit (⌘Q) and the Dock. These stop the
  loop rather than exit, so `run` returns and `defer`s run.

A window can keep itself open when the user closes it, with
`on_close_request` ([Windows](windows.md#closing)). On macOS, clicking
the Dock icon of an app without visible windows reopens the last one.

### Relaunching

`app.relaunch()` quits the same way, then starts the app again, as after
changing a setting that needs a restart.

- It starts it once `destroy` freed it: its windows closed, its single
  instance lock released.
- It runs the executable the app runs from: the new one, after an update
  replaced it.
- It passes the launch's arguments, without myzig's own flags, in the
  launch's working directory.
- Under `myzig dev` the build exits with code 75 instead, for `myzig dev`
  to start it again.
- Hidden and headless runs only quit. In browsers `relaunch` is `quit`.

<details>
<summary>Coming back in front on Windows</summary>

On Windows only the app in front may bring a window forward, and it gives
that up as its windows close. So `relaunch` passes the right on first
(`AllowSetForegroundWindow`). The new instance then opens in front,
rather than behind with a flashing taskbar button.

</details>

## A single instance

Many apps should run once: a second launch hands its command line to the
first and exits.

```zig
const State = struct {
    window: ?*myzig.Window = null,

    fn second(st: *State, s: myzig.SecondInstance) void {
        std.log.info("launched again in {s} with {d} arguments", .{ s.working_dir, s.args.len });
        if (st.window) |w| w.focus();
    }
};

var state: State = .{};
const app = try myzig.App.create(init, .{
    .name = "Notes",
    .id = "com.example.notes",
    .on_second_instance = .of(&state, State.second),
});
defer app.destroy();
if (!app.requestSingleInstanceLock()) return; // another instance has it
```

`requestSingleInstanceLock`:

- returns true in the first instance. That one then gets each later
  launch's arguments and working directory in `on_second_instance`,
  without the program and myzig's flags;
- in a later instance, hands its command line over and returns false:
  return from `main`.

The URLs and files among a later launch's arguments also reach
`on_open_url` and `on_open_file`, as the first launch's do.

The lock is named after `id`:

| Platform | Lock |
|---|---|
| macOS, Linux | a Unix socket in `XDG_RUNTIME_DIR`, `TMPDIR` or `/tmp`; one a crashed instance left is replaced |
| Windows | a named mutex. Its holder's hidden window gets the command line (`WM_COPYDATA`) and may take the foreground |
| browsers | there is one page, always the first instance |

A macOS bundle opened again from Finder is activated by macOS instead.

## Bringing the app forward

`app.focus()` brings the app to the front with its windows in their
order, as a tray icon's click opens the app's settings.

- A window of the app already in front stays there.
- Else the one the user had last comes forward: the highest of its
  windows in the z-order on Windows, `activateIgnoringOtherApps:` on
  macOS, the first that shows on Linux.
- Flyouts that never take the keyboard bring nothing forward.

A window's own `focus()` brings that window.

## Deep links and file associations

An app opens URLs of its own schemes (`notes://open/42`) and files of its
types. The system launches it with them, or hands them to it while it
runs:

```zig
const app = try myzig.App.create(init, .{
    .name = "Notes",
    .id = "com.example.notes",
    .url_schemes = &.{"notes"},
    .file_extensions = &.{ "md", "txt" },
    .on_open_url = .of(&state, State.openUrl),
    .on_open_file = .of(&state, State.openFile),
});
```

- Windows and Linux start the app with the URL or the file as an
  argument. `run` hands those of the app's schemes to `on_open_url`.
- It hands the files of its extensions that exist to `on_open_file`:
  paths and `file:` URLs, made absolute.
- On macOS they arrive as Apple events (`application:openURLs:`), to the
  same handlers.
- With a single instance, later launches' URLs and files reach the first
  instance's handlers.

The system has to know the app handles them:

- **Packages** declare them. `url_schemes` and `file_associations` in
  `myzig.zon` go into the macOS bundle's `Info.plist`, the Linux
  `.desktop` file and MIME types, and the Windows installer
  ([Configuration](configuration.md), [Distribution](distribution.md)).
- **At run time**, `myzig.system.registerUrlScheme(app, "notes")` makes
  the app the user's handler of a scheme: the registry on Windows, an XDG
  `.desktop` entry on Linux, the default handler on macOS. On macOS the
  scheme must also be in `Info.plist`. `registerFileType` does the same
  for an extension. See [System](system.md).

## Notifications

```zig
try app.notify(.{
    .id = "sync",
    .title = "Synced",
    .subtitle = "Notes",
    .body = "42 notes are up to date.",
});
app.removeNotification("sync");

// Buttons, and a reply field.
try app.notify(.{
    .id = "chat-42",
    .title = "Ada",
    .body = "Lunch?",
    .actions = &.{
        .{ .id = "reply", .title = "Reply", .reply = true, .placeholder = "Message" },
        .{ .id = "mute", .title = "Mute", .destructive = true },
    },
});
```

| `myzig.Notification` | |
|---|---|
| `id` | for `removeNotification` and for the response |
| `title`, `subtitle`, `body` | |
| `silent` | no sound |
| `actions` | `myzig.NotificationAction`: an `id`, a `title`, `reply` for a text field with its `placeholder`, `destructive` |
| `group` | gathers the notifications that share it in Notification Center (macOS's thread identifier), such as a conversation's messages |

A click reaches `on_notification` as a `myzig.NotificationResponse`:

- the notification's `id`;
- the `action` chosen, empty for a click on the notification itself;
- the `reply` typed.

| platform | how |
|---|---|
| macOS | UNUserNotificationCenter, actions as a notification category: the app must be a bundle (`myzig build`) |
| Linux | the desktop's notification server over D-Bus; one with the id of one showing replaces it |
| Windows | toasts (WinRT's ToastNotificationManager), with buttons and a reply field (below) |
| browsers | `error.Unsupported` |

**On Windows:**

- Toasts show under the app's `id` as its AppUserModelID. An unpackaged
  app gets a Start menu shortcut carrying it on its first notification.
- Clicks arrive while the app runs, and after it quit. The shortcut names
  the app's toast activator: a CLSID derived from its `id`, registered
  under `HKCU\Software\Classes\CLSID`.
- So a click starts the app with `--myzig-toast-activated`, and reaches
  `on_notification` once `run` starts. A running app gets it directly.
- Where toasts can't be shown, the balloon of the app's first tray icon
  shows instead.

### Sender avatars on macOS

An incoming direct message can name its sender. macOS 12 and later show
the sender's avatar with the app's small icon:

```zig
try app.notify(.{
    .id = "message:7",
    .group = "conversation:3",
    .title = "Ada",
    .subtitle = "Lunch",
    .body = "See you at noon",
    .sender = .{ .id = "user:ada", .name = "Ada", .avatar = avatar_png },
});
```

- `sender.id` identifies the person in the app. It is not taken for an
  email address or a phone number.
- `name` defaults to the `title`.
- `avatar` is an encoded image (PNG, JPEG) the app has at hand.
- `group` is the conversation's identifier, the notification's `id`
  without one.
- It is an incoming message from one person, not a group chat's or an
  outgoing one.
- macOS lays the notification out: the subtitle goes above the body.
- Windows, Linux and browsers ignore `sender`.

The app needs:

- the **Communication Notifications** capability of its Apple App ID;
- `INSendMessageIntent` in its `Info.plist`'s `NSUserActivityTypes`;
- a signature with the
  `com.apple.developer.usernotifications.communication` entitlement;
- a provisioning profile that authorizes it, also for Developer ID
  distribution.

Don't give the restricted entitlement to an ad-hoc build: macOS may
refuse to launch it.

myzig checks the signed entitlement before it donates the message to
SiriKit and updates the notification's content with it. The ordinary
notification shows when:

- the app lacks the capability;
- the sender lacks its `id` or a readable `avatar`;
- the donation or the update fails.

A notification being prepared that is removed or replaced under its `id`
meanwhile never shows.

## Appearance

`on_appearance` hears the system switch between light and dark.

- Native UI follows it by itself, unless a window has a fixed `theme`.
- Pages have `prefers-color-scheme`.
- The handler is for the app's own colors.

`myzig.isDark()` and `myzig.accentColor()` read the current appearance
([System](system.md)).

## The network

```zig
const s = app.networkStatus();
if (!s.online) showOffline();
if (s.metered) askBeforeDownloading();
```

`myzig.NetworkStatus` has two fields:

| Field | |
|---|---|
| `online` | a route out: macOS's satisfied path, Linux's GNetworkMonitor, Windows' local or internet connectivity. A captive portal counts, as for browsers' `navigator.onLine` |
| `metered` | the connection is cellular, a hotspot, Low Data Mode, or has a capped or roaming cost |

- `on_network` is called only when one of them changes. The systems also
  report route and interface changes that leave them as they were, and
  myzig filters those out.
- The app starts watching when `run` starts, and only if `on_network` is
  set.

## The Dock and the taskbar

- `app.setBadge("3")` puts a badge on the app: on the Dock icon (macOS),
  as a count on the launcher entry of docks with the Unity launcher API
  (Linux), or drawn over the taskbar button (Windows, its overlay icon).
  Empty removes it.
- `Window.setProgress` shows a task's progress on the taskbar button
  (Windows), the launcher entry (Linux) or a bar over the Dock icon
  (macOS). `Window.flash` asks for attention
  ([Windows](windows.md#attention-and-progress)).
- `myzig.system.setJumpList` gives the Windows taskbar button's jump list
  tasks, and recent documents fill it ([System](system.md)).

## Start at login

- `myzig.system.setOpenAtLogin(app, true)` opens the app when the user
  logs in: a login item on macOS 13 and later, for bundles; a Run entry
  on Windows; an XDG autostart entry on Linux.
- `openAtLogin(app)` tells whether it will.
- `wasOpenedAtLogin(app)` tells whether this launch is such a one (the
  entry passes `--myzig-login`). It is for an app that starts quietly,
  without a window.

See [System](system.md).

## Platforms

| | macOS | Linux | Windows | browsers |
|---|---|---|---|---|
| event loop | AppKit | GTK 3 (`dlopen`) | Win32 messages | the page's frames |
| single instance | Unix socket | Unix socket | named mutex | always first |
| deep links, files | Apple events | arguments | arguments | no |
| notifications | UNUserNotificationCenter | D-Bus | tray balloons, toasts | no |
| network status | Network.framework | GNetworkMonitor | network list manager | assumed online |
| badge | the Dock | Unity launcher | the taskbar button's overlay icon | no |
| signals | SIGINT, SIGTERM | SIGINT, SIGTERM | console control events | no |

In browsers ([Browsers](browsers.md)) the app is a page:

- `App.create` and `run` work as elsewhere.
- Windows of native UI fill the page's canvas.
- What has no meaning there fails with `error.Unsupported` (trays,
  notifications) or does nothing.
- Global shortcuts and flyouts are not there at all.
