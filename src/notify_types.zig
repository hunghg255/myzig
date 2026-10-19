//! Notifications' actions and replies, the same on every platform: the
//! buttons a notification offers (macOS's UNNotificationAction, Windows'
//! toast actions, the freedesktop actions on Linux), one of which may
//! take a reply typed in the notification.
//!
//!     try app.notify(.{ .id = "chat:ada", .title = "Ada", .body = "Lunch?", .actions = &.{
//!         .{ .id = "reply", .title = "Reply", .reply = true, .placeholder = "Message" },
//!         .{ .id = "read", .title = "Mark as Read" },
//!     } });
//!
//! `on_notification` then gets `.{ .id = "chat:ada", .action = "reply", .reply = "Sure" }`.
//!
//! Until `app_types.Notification` has `actions` and `NotificationResponse`
//! has `reply`, the backends read them through `actions` and `response`,
//! which see whether the fields are there.
const std = @import("std");
const app_types = @import("app_types.zig");

pub const Action = struct {
    /// What `on_notification` gets as the response's `action`.
    id: []const u8,
    title: []const u8,
    /// A text field comes with the action: what the user typed reaches
    /// the response's `reply` (macOS: UNTextInputNotificationAction;
    /// Windows: a toast's input; Linux servers show no field: no reply).
    reply: bool = false,
    /// The field's placeholder.
    placeholder: []const u8 = "",
    /// Shown as destructive (red on macOS).
    destructive: bool = false,
};

/// The actions of `n` (an `app_types.Notification`): none when it has no
/// `actions`.
pub fn actions(n: anytype) []const Action {
    if (@hasField(@TypeOf(n), "actions")) return n.actions;
    return &.{};
}

/// A notification with actions, as `app_types.Notification` is to have
/// it: what tests build them with meanwhile.
pub const WithActions = struct {
    id: []const u8 = "",
    title: []const u8,
    subtitle: []const u8 = "",
    body: []const u8 = "",
    silent: bool = false,
    actions: []const Action = &.{},
};

/// A response with `reply` when `app_types.NotificationResponse` has one.
pub fn response(id: []const u8, action: []const u8, reply: []const u8) app_types.NotificationResponse {
    var r: app_types.NotificationResponse = .{ .id = id, .action = action };
    if (@hasField(app_types.NotificationResponse, "reply")) r.reply = reply;
    return r;
}

/// The reply of `r`, empty when it has none.
pub fn replyOf(r: app_types.NotificationResponse) []const u8 {
    if (@hasField(app_types.NotificationResponse, "reply")) return r.reply;
    return "";
}

test "a response keeps its id and action, whatever fields responses have" {
    const r = response("chat:ada", "reply", "Sure");
    try std.testing.expectEqualStrings("chat:ada", r.id);
    try std.testing.expectEqualStrings("reply", r.action);
    if (@hasField(app_types.NotificationResponse, "reply")) try std.testing.expectEqualStrings("Sure", replyOf(r));
    try std.testing.expectEqual(@as(usize, 0), actions(app_types.Notification{ .title = "x" }).len);
    try std.testing.expectEqual(@as(usize, 1), actions(WithActions{ .title = "x", .actions = &.{.{ .id = "a", .title = "A" }} }).len);
}
