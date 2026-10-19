//! What a toast is made of on Windows, without the system: its XML (the
//! ToastGeneric template: title, subtitle and body, the actions as
//! buttons, a text input for an action that takes a reply, the sound),
//! the arguments its activation carries back (the notification's id and
//! the action chosen), and the tag it is removed by.
const std = @import("std");
const app_types = @import("../app_types.zig");
const notify_types = @import("../notify_types.zig");

/// Appends `s` escaped for XML text and attribute values.
fn escape(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '&' => try out.appendSlice(gpa, "&amp;"),
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '"' => try out.appendSlice(gpa, "&quot;"),
        '\'' => try out.appendSlice(gpa, "&apos;"),
        // Control characters are not XML; newlines and tabs are.
        0...8, 11, 12, 14...31 => {},
        else => try out.append(gpa, ch),
    };
}

/// Appends `s` percent-encoded (all but unreserved characters).
fn percent(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(gpa, ch);
        } else {
            var b: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&b, "%{X:0>2}", .{ch}) catch unreachable;
            try out.appendSlice(gpa, &b);
        }
    }
}

/// The arguments of an activation: "myzig=1&id=...&action=..." (`action`
/// empty for the toast itself), percent-encoded, and the id of the input
/// whose text is the reply ("&input=reply1").
pub fn arguments(gpa: std.mem.Allocator, id: []const u8, action: []const u8, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "myzig=1&id=");
    try percent(&out, gpa, id);
    try out.appendSlice(gpa, "&action=");
    try percent(&out, gpa, action);
    if (input.len > 0) {
        try out.appendSlice(gpa, "&input=");
        try percent(&out, gpa, input);
    }
    return out.toOwnedSlice(gpa);
}

/// What activation arguments say. Free with `deinit`.
pub const Activation = struct {
    id: []u8,
    action: []u8,
    /// The input holding the reply, empty for none.
    input: []u8,

    pub fn deinit(a: Activation, gpa: std.mem.Allocator) void {
        gpa.free(a.id);
        gpa.free(a.action);
        gpa.free(a.input);
    }
};

fn decode(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                try out.append(gpa, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(gpa, s[i]);
    }
    return out.toOwnedSlice(gpa);
}

/// The id and action of activation arguments `arguments` made; null for
/// arguments of another origin (a toast of an earlier version of the app).
pub fn parseArguments(gpa: std.mem.Allocator, args: []const u8) !?Activation {
    var id: ?[]const u8 = null;
    var action: []const u8 = "";
    var input: []const u8 = "";
    var mine = false;
    var it = std.mem.splitScalar(u8, args, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = pair[0..eq];
        const v = pair[eq + 1 ..];
        if (std.mem.eql(u8, k, "myzig")) mine = true else if (std.mem.eql(u8, k, "id")) id = v else if (std.mem.eql(u8, k, "action")) action = v else if (std.mem.eql(u8, k, "input")) input = v;
    }
    if (!mine) return null;
    const i = try decode(gpa, id orelse return null);
    errdefer gpa.free(i);
    const a = try decode(gpa, action);
    errdefer gpa.free(a);
    return .{ .id = i, .action = a, .input = try decode(gpa, input) };
}

/// The id of the input of the action at `index` (one that takes a reply).
pub fn inputId(buf: *[16]u8, index: usize) []const u8 {
    return std.fmt.bufPrint(buf, "reply{d}", .{index}) catch unreachable;
}

/// The toast's XML for `n` (an `app_types.Notification`).
pub fn build(gpa: std.mem.Allocator, n: anytype) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const launch = try arguments(gpa, n.id, "", "");
    defer gpa.free(launch);
    try out.appendSlice(gpa, "<toast launch=\"");
    try escape(&out, gpa, launch);
    try out.appendSlice(gpa, "\" activationType=\"foreground\"><visual><binding template=\"ToastGeneric\">");
    for ([_][]const u8{ n.title, n.subtitle, n.body }) |t| {
        if (t.len == 0) continue;
        try out.appendSlice(gpa, "<text>");
        try escape(&out, gpa, t);
        try out.appendSlice(gpa, "</text>");
    }
    try out.appendSlice(gpa, "</binding></visual>");
    const acts = notify_types.actions(n);
    if (acts.len > 0) {
        try out.appendSlice(gpa, "<actions>");
        // Inputs come first; each reply action submits its own.
        var buf: [16]u8 = undefined;
        for (acts, 0..) |a, i| if (a.reply) {
            try out.appendSlice(gpa, "<input id=\"");
            try out.appendSlice(gpa, inputId(&buf, i));
            try out.appendSlice(gpa, "\" type=\"text\"");
            if (a.placeholder.len > 0) {
                try out.appendSlice(gpa, " placeHolderContent=\"");
                try escape(&out, gpa, a.placeholder);
                try out.append(gpa, '"');
            }
            try out.appendSlice(gpa, "/>");
        };
        // A toast shows five buttons at most.
        for (acts[0..@min(acts.len, 5)], 0..) |a, i| {
            const args = try arguments(gpa, n.id, a.id, if (a.reply) inputId(&buf, i) else "");
            defer gpa.free(args);
            try out.appendSlice(gpa, "<action content=\"");
            try escape(&out, gpa, a.title);
            try out.appendSlice(gpa, "\" arguments=\"");
            try escape(&out, gpa, args);
            try out.appendSlice(gpa, "\" activationType=\"foreground\"");
            if (a.reply) {
                try out.appendSlice(gpa, " hint-inputId=\"");
                try out.appendSlice(gpa, inputId(&buf, i));
                try out.append(gpa, '"');
            }
            if (a.destructive) try out.appendSlice(gpa, " hint-buttonStyle=\"Critical\"");
            try out.appendSlice(gpa, "/>");
        }
        try out.appendSlice(gpa, "</actions>");
    }
    if (n.silent) try out.appendSlice(gpa, "<audio silent=\"true\"/>");
    try out.appendSlice(gpa, "</toast>");
    return out.toOwnedSlice(gpa);
}

/// The tag a toast is replaced and removed by: the id itself when short
/// (Windows takes 16 characters before the Creators Update, 64 after),
/// else its hash in hex.
pub fn tag(buf: *[16]u8, id: []const u8) []const u8 {
    if (id.len > 0 and id.len <= 16) {
        @memcpy(buf[0..id.len], id);
        return buf[0..id.len];
    }
    _ = std.fmt.bufPrint(buf, "{x:0>16}", .{std.hash.Wyhash.hash(0, id)}) catch unreachable;
    return buf;
}

test "a toast's XML: escaped texts, actions, a reply's input, silence" {
    const gpa = std.testing.allocator;
    const plain = try build(gpa, app_types.Notification{ .id = "a&b", .title = "Tom & <Jerry>", .body = "\"hi\"\x01" });
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("<toast launch=\"myzig=1&amp;id=a%26b&amp;action=\" activationType=\"foreground\"><visual><binding template=\"ToastGeneric\"><text>Tom &amp; &lt;Jerry&gt;</text><text>&quot;hi&quot;</text></binding></visual></toast>", plain);
    const n: notify_types.WithActions = .{ .id = "chat", .title = "Ada", .subtitle = "Re: lunch", .silent = true, .actions = &.{
        .{ .id = "read", .title = "Mark as Read" },
        .{ .id = "reply", .title = "Reply", .reply = true, .placeholder = "Message" },
    } };
    const x = try build(gpa, n);
    defer gpa.free(x);
    try std.testing.expect(std.mem.indexOf(u8, x, "<text>Re: lunch</text>") != null);
    try std.testing.expect(std.mem.indexOf(u8, x, "<input id=\"reply1\" type=\"text\" placeHolderContent=\"Message\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, x, "<action content=\"Reply\" arguments=\"myzig=1&amp;id=chat&amp;action=reply&amp;input=reply1\" activationType=\"foreground\" hint-inputId=\"reply1\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, x, "<audio silent=\"true\"/></toast>") != null);
    // The input comes before the buttons.
    try std.testing.expect(std.mem.indexOf(u8, x, "<input").? < std.mem.indexOf(u8, x, "<action ").?);
}

test "activation arguments there and back; others' are not ours" {
    const gpa = std.testing.allocator;
    const args = try arguments(gpa, "mail:7 é&x=1", "mark read", "reply2");
    defer gpa.free(args);
    const a = (try parseArguments(gpa, args)).?;
    defer a.deinit(gpa);
    try std.testing.expectEqualStrings("mail:7 é&x=1", a.id);
    try std.testing.expectEqualStrings("mark read", a.action);
    try std.testing.expectEqualStrings("reply2", a.input);
    try std.testing.expect((try parseArguments(gpa, "action=viewConversation&conversationId=9813")) == null);
    const bad = (try parseArguments(gpa, "myzig=1&id=50%&action=%zz")).?;
    defer bad.deinit(gpa);
    try std.testing.expectEqualStrings("50%", bad.id);
    try std.testing.expectEqualStrings("%zz", bad.action);
}

test "tags: short ids as they are, long ones hashed to 16 characters" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("chat:ada", tag(&buf, "chat:ada"));
    const long = tag(&buf, "a notification id far longer than sixteen");
    try std.testing.expectEqual(@as(usize, 16), long.len);
    var again: [16]u8 = undefined;
    try std.testing.expectEqualStrings(long, tag(&again, "a notification id far longer than sixteen"));
}
