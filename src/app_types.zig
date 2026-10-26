//! What the application is made of, the same on every platform: its
//! options and the handlers of what reaches it from the system (URLs,
//! files, later instances, appearance changes, notification clicks).
const std = @import("std");

/// A function of the app's to call with a `T`: `.of(&state, State.method)`,
/// where `fn method(s: *State, value: T) void`.
pub fn Handler(comptime T: type) type {
    return struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, value: T) void,

        pub fn of(ptr: anytype, comptime func: fn (@TypeOf(ptr), T) void) @This() {
            const P = @TypeOf(ptr);
            return .{ .ctx = @ptrCast(ptr), .func = struct {
                fn call(c: *anyopaque, v: T) void {
                    func(@as(P, @ptrCast(@alignCast(c))), v);
                }
            }.call };
        }

        pub fn call(h: @This(), v: T) void {
            h.func(h.ctx, v);
        }
    };
}

pub const NetworkStatus = @import("network.zig").Status;

/// A later launch of the app, forwarded to the first instance.
pub const SecondInstance = struct {
    /// Its command line arguments, without the program.
    args: []const []const u8,
    working_dir: []const u8,
};

/// A notification shown by `App.notify`.
pub const Notification = struct {
    /// Identifies it to `on_notification` and `removeNotification`.
    id: []const u8 = "",
    title: []const u8,
    subtitle: []const u8 = "",
    body: []const u8 = "",
    /// No sound.
    silent: bool = false,
    /// Buttons (and a reply field) on it, where the system has them.
    actions: []const NotificationAction = &.{},
    /// Gathers the notifications that share it in Notification Center
    /// (macOS's thread), such as a conversation's messages; for a
    /// `sender`, the conversation's identifier (the notification's id
    /// without one). Ignored elsewhere.
    group: []const u8 = "",
    /// The sender of an incoming direct message: macOS 12 and later show
    /// its avatar with the app's small icon, where the signed app has the
    /// Communication Notifications capability (docs/app.md); otherwise, or
    /// when preparing it fails, the ordinary notification shows. Ignored
    /// elsewhere.
    sender: ?NotificationSender = null,
};

/// The sender of an incoming direct message (`Notification.sender`).
pub const NotificationSender = struct {
    /// Identifies the person in the app (not taken for an email address
    /// or a phone number).
    id: []const u8,
    /// The name shown; the notification's title when empty.
    name: []const u8 = "",
    /// An encoded image (PNG, JPEG): the avatar. Without one, or without
    /// an id, the notification is an ordinary one.
    avatar: []const u8 = "",
};

pub const NotificationAction = @import("notify_types.zig").Action;

/// A notification was clicked (`action` is empty) or one of its actions chosen.
pub const NotificationResponse = struct {
    id: []const u8,
    action: []const u8 = "",
    /// What was typed in the action's reply field.
    reply: []const u8 = "",
};

pub const Options = struct {
    name: []const u8 = "myzig",
    /// Identifies the app to the system: its single instance lock, its
    /// URL handler and autostart entries, its secrets' default service.
    /// Reverse DNS ("com.example.notes"); the name when empty.
    id: []const u8 = "",
    /// Quit when the last window closes.
    quit_on_last_window_closed: bool = true,
    /// The URL schemes the app opens ("myapp" for myapp://...): the
    /// arguments of the launch and of later instances that are such URLs
    /// reach `on_open_url`.
    url_schemes: []const []const u8 = &.{},
    /// The extensions of the files the app opens, without the dot, lower
    /// case ("md"): such files among the arguments reach `on_open_file`.
    file_extensions: []const []const u8 = &.{},
    on_open_url: ?Handler([]const u8) = null,
    on_open_file: ?Handler([]const u8) = null,
    /// In the first instance, once `requestSingleInstanceLock` holds the
    /// lock: another launch handed its command line over.
    on_second_instance: ?Handler(SecondInstance) = null,
    /// The system switched between light (false) and dark (true).
    on_appearance: ?Handler(bool) = null,
    on_notification: ?Handler(NotificationResponse) = null,
    /// The computer went online or offline, or its connection's cost
    /// changed (`App.networkStatus` asks for it).
    on_network: ?Handler(NetworkStatus) = null,
    /// Ctrl+C and SIGTERM (Ctrl+C, Ctrl+Break and the console closing on
    /// Windows) quit the app on the main thread, as `App.quit`; a second
    /// one exits at once.
    quit_on_signal: bool = true,
    /// Origins of plain http servers ("http://192.168.1.10:8080") whose
    /// pages are secure contexts, as https ones, so that they may ask for
    /// the camera, the microphone, ... (WebView2; WebKit has no such
    /// setting). Granting those stays the `permission` event's.
    secure_origins: []const []const u8 = &.{},

    /// The id the system knows the app by.
    pub fn appId(o: Options) []const u8 {
        return if (o.id.len > 0) o.id else o.name;
    }
};

test "a handler calls its method" {
    const S = struct {
        n: usize = 0,
        fn add(s: *@This(), v: usize) void {
            s.n += v;
        }
    };
    var s: S = .{};
    const h = Handler(usize).of(&s, S.add);
    h.call(3);
    h.call(4);
    try std.testing.expectEqual(@as(usize, 7), s.n);
    try std.testing.expectEqualStrings("Notes", (Options{ .name = "Notes" }).appId());
}
