//! The gallery's overlays: popovers, tooltips, dialogs, an alert, menus
//! (from a button, a menu button and a right click) and toasts.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const card = @import("basics.zig").card;
const gallery = @import("basics.zig");

const sorts = [_][]const u8{ "Name", "Date modified", "Size", "Kind" };
const folders = [_][]const u8{ "Inbox", "Archive", "Projects" };
const places = [_][]const u8{ "Top left", "Top center", "Top right", "Bottom left", "Bottom center", "Bottom right" };

pub const Overlays = struct {
    pop: ui.OverlayState = .{},
    rename: ui.OverlayState = .{},
    alert: ui.OverlayState = .{},
    sort: ui.Menu = .{},
    more: ui.Menu = .{},
    ctx: ui.Menu = .{},
    sort_by: usize = 0,
    pinned: bool = false,
    name: ui.TextBuffer = .{},
    note_name: ui.TextBuffer = .{},
    status_buf: [96]u8 = undefined,
    status: []const u8 = "Nothing chosen yet.",
    toasts: ui.Toasts = .{},
    undo: u64 = 0,
    shown: u32 = 0,
    /// When the pretend upload began, for its toast to say it is done.
    upload_at: f64 = -1,
    place: usize = 5,
    place_box: ui.SelectState = .{},

    fn setStatus(s: *Overlays, comptime fmt: []const u8, args: anytype) void {
        s.status = std.fmt.bufPrint(&s.status_buf, fmt, args) catch s.status;
    }

    pub fn init(s: *Overlays) void {
        s.note_name.set("Groceries");
    }

    pub fn view(s: *Overlays, c: *ui.Context) void {
        const th = c.theme;
        gallery.heading(c, "Overlays");
        {
            card(c, "Popovers and tooltips");
            defer ui.end(c);
            ui.row(c, .{ .gap = 8, .align_items = .center });
            defer ui.end(c);
            const more = ui.button(c, "Edit name…", .{});
            if (more.clicked) s.pop.toggle();
            if (ui.popover(c, &s.pop, more, .{})) |p| {
                defer p.end();
                ui.text(c, "Name", .{ .weight = .semibold });
                _ = ui.textField(c, &s.name, .{ .placeholder = "A name" });
                if (ui.button(c, "Done", .{ .variant = .primary }).clicked) s.pop.close();
            }
            const share = ui.button(c, "Share", .{});
            ui.tooltip(c, share, "Share with others");
            const print = ui.button(c, "Print", .{});
            ui.tooltip(c, print, "Print it, on paper");
            if (s.name.text().len > 0) ui.text(c, c.print("Named “{s}”", .{s.name.text()}), .{ .color = th.muted });
        }
        {
            card(c, "Dialogs");
            defer ui.end(c);
            ui.row(c, .{ .gap = 8, .align_items = .center });
            defer ui.end(c);
            if (ui.button(c, "Rename…", .{}).clicked) s.rename.show();
            if (ui.button(c, "Delete…", .{ .variant = .danger }).clicked) s.alert.show();
            ui.text(c, s.status, .{ .color = th.muted });
            if (ui.dialog(c, &s.rename, .{})) |d| {
                defer d.end();
                ui.text(c, "Rename the note", .{ .weight = .bold, .size = 16 });
                _ = ui.textField(c, &s.note_name, .{ .width = .{ .px = 280 } });
                ui.row(c, .{ .gap = 8, .justify = .end, .width = .fill });
                defer ui.end(c);
                if (ui.button(c, "Cancel", .{}).clicked) s.rename.close();
                if (ui.button(c, "Save", .{ .variant = .primary }).clicked) {
                    s.status = "Renamed.";
                    s.rename.close();
                }
            }
            switch (ui.alertDialog(c, &s.alert, "Delete “Groceries”?", "You can't undo this.", &.{ "Cancel", "Delete" })) {
                .none => {},
                .chosen => |i| s.setStatus("Alert: chose {s}.", .{if (i == 1) "Delete" else "Cancel"}),
                .dismissed => s.status = "Alert dismissed.",
            }
        }
        {
            card(c, "Menus");
            defer ui.end(c);
            ui.row(c, .{ .gap = 8, .align_items = .center });
            if (ui.menuButton(c, "Sort by", &s.sort, .{})) |m| {
                defer m.end();
                for (sorts, 0..) |by, i| if (m.item(by, .{ .checked = s.sort_by == i })) {
                    s.sort_by = i;
                };
            }
            const more = ui.button(c, "More", .{});
            if (ui.buttonMenu(c, &s.more, more)) |m| {
                defer m.end();
                if (m.item("Duplicate", .{ .shortcut = "⌘D" })) s.status = "Duplicated.";
                if (m.item("Export…", .{})) s.status = "Exported.";
            }
            ui.text(c, c.print("Sorted by {s}", .{sorts[s.sort_by]}), .{ .color = th.muted });
            ui.end(c);
            const row = ui.pressable(c, .{ .width = .fill, .padding = .all(12), .radius = 8, .background = th.surface_hover }, null);
            ui.text(c, if (s.pinned) "📌 A note (right click me)" else "A note (right click me)", .{});
            ui.end(c);
            if (ui.contextMenu(c, &s.ctx, row)) |m| {
                defer m.end();
                if (m.item("Rename", .{ .shortcut = "F2" })) s.rename.show();
                if (m.item("Pinned", .{ .checked = s.pinned })) s.pinned = !s.pinned;
                if (m.submenu("Move to")) |sub| {
                    defer sub.end();
                    for (folders) |f| if (sub.item(f, .{})) {
                        s.setStatus("Moved to {s}.", .{f});
                    };
                }
                m.separator();
                if (m.item("Delete", .{})) s.alert.show();
            }
        }
        {
            card(c, "Toasts");
            defer ui.end(c);
            s.toastButtons(c);
        }
    }

    fn toastButtons(s: *Overlays, c: *ui.Context) void {
        ui.row(c, .{ .gap = 8 });
        if (ui.button(c, "Show a toast", .{}).clicked) {
            s.shown += 1;
            _ = s.toasts.add(.{ .title = c.print("Saved {d} time(s)", .{s.shown}), .description = "Sunday, December 03, 2023 at 9:00 AM" });
        }
        if (ui.button(c, "Success", .{}).clicked) _ = s.toasts.success("Event has been created");
        if (ui.button(c, "Info", .{}).clicked) _ = s.toasts.info("Be at the area 10 minutes before the event time");
        if (ui.button(c, "Warning", .{}).clicked) _ = s.toasts.warning("Event start time cannot be earlier than 8am");
        if (ui.button(c, "Error", .{}).clicked) _ = s.toasts.failure("Event has not been created");
        ui.end(c);
        ui.row(c, .{ .gap = 8 });
        if (ui.button(c, "With an action", .{}).clicked) s.undo = s.toasts.add(.{ .title = "Moved to Trash", .action = "Undo", .cancel = "Dismiss" });
        if (ui.button(c, "Upload", .{}).clicked) {
            _ = s.toasts.loading("Uploading report.pdf…", "upload");
            s.upload_at = c.time;
        }
        ui.end(c);
        ui.row(c, .{ .gap = 16, .align_items = .center });
        _ = ui.toggle(c, "Rich colors", &s.toasts.rich_colors);
        _ = ui.toggle(c, "Expanded", &s.toasts.expand);
        _ = ui.toggle(c, "Close buttons", &s.toasts.close_button);
        ui.label(c, "Position");
        if (ui.select(c, &s.place, &places, &s.place_box, .{ .width = .{ .px = 150 }, .label = "Position" }).changed)
            s.toasts.position = @enumFromInt(s.place);
        ui.end(c);
        // The pretend upload takes two seconds.
        if (s.upload_at >= 0) {
            const left: f32 = @floatCast(2 - (c.time - s.upload_at));
            if (left <= 0) {
                _ = s.toasts.add(.{ .title = "report.pdf uploaded", .kind = .success, .key = "upload" });
                s.upload_at = -1;
            } else c.frameIn(left);
        }
    }

    /// The toasts, over everything: built last in the window.
    pub fn toastLayer(s: *Overlays, c: *ui.Context) void {
        const r = ui.toasts(c, &s.toasts);
        if (r.action) |id| if (id == s.undo) {
            s.status = "Undone.";
        };
    }
};
