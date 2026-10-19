//! Notifications as toasts on Windows 10 and later, through the Windows
//! Runtime (ToastNotificationManager): the XML of `toast_xml.zig` loaded
//! into an XmlDocument, a ToastNotification of it tagged with the
//! notification's id (to replace and remove it), shown by the notifier of
//! the app's AppUserModelID. Its Activated event (a click, a button, a
//! reply) arrives on a thread of the system's: it goes to the `Sink`,
//! which passes it to the main thread. Toasts are kept while they may
//! still be activated (Windows drops the event of a released one).
const std = @import("std");
const com = @import("com.zig");
const winrt = @import("winrt.zig");
const xml = @import("toast_xml.zig");

const manager_class = "Windows.UI.Notifications.ToastNotificationManager";
const iid_manager_statics = com.GUID.parse("50ac103f-d235-4598-bbef-98fe4d1a3ad4");
const iid_manager_statics2 = com.GUID.parse("7ab93c52-0e48-4750-ba9d-1a4113981847");
const iid_toast_factory = com.GUID.parse("04124b20-82c6-4229-b109-fd9ed4662b53");
const iid_toast2 = com.GUID.parse("9dfb9fd1-143a-490e-90bf-b9fba7132de7");
const iid_xml_io = com.GUID.parse("6cd0e74e-ee65-4489-9ebf-ca43e87ba637");
const iid_xml_document = com.GUID.parse("f7f3a506-1e87-42d6-bcfb-b8c809fa5494");
pub const iid_activated_args = com.GUID.parse("e3bf92f3-c197-436f-8265-0625824f8dac");
pub const iid_activated_args2 = com.GUID.parse("ab7da512-cc61-568e-81be-304ac31038fa");

const m = winrt.first_method;
const statics_notifier_with_id = m + 1;
const statics2_history = m;
const history_remove_grouped_tag_with_id = m + 2;
const notifier_show = m;
const notifier_setting = m + 2;
const factory_create = m;
const toast_add_activated = m + 5;
const toast_remove_activated = m + 6;
const toast2_put_tag = m;
const toast2_get_tag = m + 1;
const toast2_put_group = m + 2;
const xml_load = m;
const args_arguments = m;
const args2_user_input = m;

/// The group of the app's toasts in the history.
pub const group = "myzig";

/// A toast was activated: what its arguments say, and the reply typed.
/// Owned (`std.heap.c_allocator`): `deinit` frees it.
pub const Activation = struct {
    id: []u8,
    action: []u8,
    reply: []u8,
    /// Through the COM activator (`toast_activator.zig`), not the
    /// toast's Activated event.
    via_com: bool = false,

    pub fn deinit(a: *Activation) void {
        const ca = std.heap.c_allocator;
        ca.free(a.id);
        ca.free(a.action);
        ca.free(a.reply);
        ca.destroy(a);
    }
};

/// Where activations go; `func` runs on the system's thread and owns
/// the activation.
pub const Sink = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, a: *Activation) void,
};

const Kept = struct { id: []u8, toast: com.Object, token: i64 };

pub const Toaster = struct {
    gpa: std.mem.Allocator,
    aumid: []u8,
    notifier: com.Object,
    factory: com.Object,
    sink: Sink,
    handler: *com.Handler,
    kept: std.ArrayList(Kept) = .empty,

    /// The toaster of the app `aumid`; `error.Unsupported` before Windows 10
    /// (or without the Windows Runtime).
    pub fn create(gpa: std.mem.Allocator, aumid: []const u8, sink: Sink) !*Toaster {
        const statics = try winrt.factory(manager_class, &iid_manager_statics);
        defer com.release(statics);
        const id = try winrt.string(aumid);
        defer winrt.free(id);
        var notifier: ?com.Object = null;
        if (com.failed(com.call(statics, statics_notifier_with_id, .{ id, &notifier }))) return error.Unsupported;
        errdefer com.release(notifier);
        const factory = try winrt.factory("Windows.UI.Notifications.ToastNotification", &iid_toast_factory);
        errdefer com.release(factory);
        const self = try gpa.create(Toaster);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .aumid = try gpa.dupe(u8, aumid), .notifier = notifier orelse return error.Unsupported, .factory = factory, .sink = sink, .handler = undefined };
        self.handler = try com.Handler.create(self, onActivated);
        return self;
    }

    pub fn destroy(self: *Toaster) void {
        for (self.kept.items) |k| self.drop(k);
        self.kept.deinit(self.gpa);
        // Toasts the system still holds may call the handler: it finds no toaster.
        @atomicStore(?*anyopaque, &self.handler.ctx, null, .release);
        com.release(self.handler.object());
        com.release(self.notifier);
        com.release(self.factory);
        self.gpa.free(self.aumid);
        self.gpa.destroy(self);
    }

    fn drop(self: *Toaster, k: Kept) void {
        _ = com.call(k.toast, toast_remove_activated, .{k.token});
        com.release(k.toast);
        self.gpa.free(k.id);
    }

    /// The ToastNotification of `n` (an `app_types.Notification`), tagged,
    /// not shown.
    pub fn make(self: *Toaster, n: anytype) !com.Object {
        const text = try xml.build(self.gpa, n);
        defer self.gpa.free(text);
        const io = try winrt.activate("Windows.Data.Xml.Dom.XmlDocument", &iid_xml_io);
        defer com.release(io);
        const hs = try winrt.string(text);
        defer winrt.free(hs);
        if (com.failed(com.call(io, xml_load, .{hs}))) return error.BadXml;
        const doc = com.query(io, &iid_xml_document) orelse return error.NoInterface;
        defer com.release(doc);
        var out: ?com.Object = null;
        if (com.failed(com.call(self.factory, factory_create, .{ doc, &out }))) return error.Toast;
        const toast = out orelse return error.Toast;
        errdefer com.release(toast);
        if (com.query(toast, &iid_toast2)) |t2| {
            defer com.release(t2);
            var buf: [16]u8 = undefined;
            const tag = try winrt.string(xml.tag(&buf, n.id));
            defer winrt.free(tag);
            const g = try winrt.string(group);
            defer winrt.free(g);
            _ = com.call(t2, toast2_put_tag, .{tag});
            _ = com.call(t2, toast2_put_group, .{g});
        }
        return toast;
    }

    /// Listens to `toast`'s activations, keeping it as `id`'s (replacing
    /// the one kept for it).
    pub fn keep(self: *Toaster, id: []const u8, toast: com.Object) !void {
        var token: i64 = 0;
        if (com.failed(com.call(toast, toast_add_activated, .{ self.handler.object(), &token }))) return error.Toast;
        const owned = try self.gpa.dupe(u8, id);
        self.forget(id);
        // Keep the latest ones: an old toast left in the Action Center
        // loses its click.
        if (self.kept.items.len >= 64) self.drop(self.kept.orderedRemove(0));
        com.addRef(toast);
        self.kept.append(self.gpa, .{ .id = owned, .toast = toast, .token = token }) catch {
            com.release(toast);
            self.gpa.free(owned);
        };
    }

    fn forget(self: *Toaster, id: []const u8) void {
        for (self.kept.items, 0..) |k, i| if (std.mem.eql(u8, k.id, id)) {
            self.drop(self.kept.orderedRemove(i));
            return;
        };
    }

    /// Shows `n` as a toast.
    pub fn show(self: *Toaster, n: anytype) !void {
        const toast = try self.make(n);
        defer com.release(toast);
        try self.keep(n.id, toast);
        if (com.failed(com.call(self.notifier, notifier_show, .{toast}))) {
            self.forget(n.id);
            return error.Toast;
        }
    }

    /// Whether the user lets the app's toasts show (NotificationSetting
    /// Enabled); false for an id Windows knows no shortcut or package of.
    pub fn enabled(self: *Toaster) bool {
        var setting: i32 = -1;
        if (com.failed(com.call(self.notifier, notifier_setting, .{&setting}))) return false;
        return setting == 0;
    }

    /// Removes the toast of `id` from the screen and the Action Center.
    pub fn remove(self: *Toaster, id: []const u8) void {
        self.forget(id);
        const statics = winrt.factory(manager_class, &iid_manager_statics2) catch return;
        defer com.release(statics);
        var history: ?com.Object = null;
        if (com.failed(com.call(statics, statics2_history, .{&history}))) return;
        const h = history orelse return;
        defer com.release(h);
        var buf: [16]u8 = undefined;
        const tag = winrt.string(xml.tag(&buf, id)) catch return;
        defer winrt.free(tag);
        const g = winrt.string(group) catch return;
        defer winrt.free(g);
        const app = winrt.string(self.aumid) catch return;
        defer winrt.free(app);
        _ = com.call(h, history_remove_grouped_tag_with_id, .{ tag, g, app });
    }

    /// The handler of the toasts' Activated events (an object of
    /// TypedEventHandler<ToastNotification, IInspectable>), for tests.
    pub fn activatedHandler(self: *Toaster) com.Object {
        return self.handler.object();
    }
};

/// The tag of a toast (`make`), as UTF-8 in `gpa`.
pub fn tagOf(gpa: std.mem.Allocator, toast: com.Object) ![]u8 {
    const t2 = com.query(toast, &iid_toast2) orelse return error.NoInterface;
    defer com.release(t2);
    var s: winrt.HSTRING = null;
    if (com.failed(com.call(t2, toast2_get_tag, .{&s}))) return error.Toast;
    defer winrt.free(s);
    return winrt.utf8(gpa, s);
}

/// The activation `args` (ToastActivatedEventArgs) describe; null for
/// arguments of other origins.
pub fn activationOf(args: com.Object) ?*Activation {
    const ca = std.heap.c_allocator;
    const a1 = com.query(args, &iid_activated_args) orelse return null;
    defer com.release(a1);
    var hs: winrt.HSTRING = null;
    if (com.failed(com.call(a1, args_arguments, .{&hs}))) return null;
    defer winrt.free(hs);
    const text = winrt.utf8(ca, hs) catch return null;
    defer ca.free(text);
    const parsed = (xml.parseArguments(ca, text) catch return null) orelse return null;
    defer ca.free(parsed.input);
    var reply: []u8 = ca.dupe(u8, "") catch &.{};
    if (parsed.input.len > 0) if (com.query(args, &iid_activated_args2)) |a2| {
        defer com.release(a2);
        var input: ?com.Object = null;
        if (!com.failed(com.call(a2, args2_user_input, .{&input}))) if (input) |set| {
            defer com.release(set);
            if (com.query(set, &winrt.iid_map_string_object)) |map| {
                defer com.release(map);
                if (winrt.mapString(ca, map, parsed.input) catch null) |r| {
                    ca.free(reply);
                    reply = r;
                }
            }
        };
    };
    const out = ca.create(Activation) catch {
        ca.free(parsed.id);
        ca.free(parsed.action);
        ca.free(reply);
        return null;
    };
    out.* = .{ .id = parsed.id, .action = parsed.action, .reply = reply };
    return out;
}

/// Invoke(sender, args) of the Activated handler.
fn onActivated(ctx: ?*anyopaque, _: usize, args: usize) void {
    const self: *Toaster = @ptrCast(@alignCast(ctx orelse return));
    if (args == 0) return;
    const a = activationOf(@ptrFromInt(args)) orelse return;
    self.sink.func(self.sink.ctx, a);
}
