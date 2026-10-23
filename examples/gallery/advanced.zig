//! Joined actions, searchable choices, date ranges and local file paths.
const std = @import("std");
const ui = @import("myzig").ui;
const card = @import("basics.zig").card;

pub const Advanced = struct {
    styles: [3]bool = .{ true, false, false },
    alignment: [3]bool = .{ true, false, false },
    languages: [5]bool = .{ true, false, true, false, false },
    multi: ui.MultiSelectState = .{},
    range: ?ui.DateRange = null,
    dates: ui.DateRangeState = .{},
    drag: ui.DragDrop = .{},
    files: ui.FileList,
    message: []const u8 = "Choose an action.",
    file_message: []const u8 = "Paths only: no files are read or uploaded.",

    pub fn init(gpa: std.mem.Allocator) Advanced {
        return .{ .files = .init(gpa) };
    }

    pub fn deinit(s: *Advanced) void {
        s.files.deinit();
        s.drag.deinit();
    }

    pub fn view(s: *Advanced, c: *ui.Context) void {
        ui.heading(c, "Actions and choices");
        ui.label(c, "Joined buttons, multiple choices, date ranges and file drops.");
        s.groups(c);
        s.choices(c);
        s.dateRange(c);
        s.drop(c);
    }

    pub fn groups(s: *Advanced, c: *ui.Context) void {
        card(c, "Button and toggle groups");
        defer ui.end(c);
        var actions = ui.buttonGroup(c, .{ .label = "Document actions" });
        if (actions.button("Save document", .{ .variant = .primary })) s.message = "Document saved";
        if (actions.button("Duplicate", .{})) s.message = "Document duplicated";
        if (actions.button("Archive", .{})) s.message = "Document archived";
        actions.end();
        ui.label(c, s.message);
        ui.label(c, "Multiple formatting choices");
        _ = ui.toggleGroup(c, &.{ .{ .label = "Bold" }, .{ .label = "Italic" }, .{ .label = "Underline" } }, &s.styles, .{ .multiple = true, .label = "Formatting" });
        ui.label(c, "One alignment is required");
        _ = ui.toggleGroup(c, &.{ .{ .label = "Left" }, .{ .label = "Center" }, .{ .label = "Right" } }, &s.alignment, .{ .allow_empty = false, .label = "Alignment" });
    }

    pub fn choices(s: *Advanced, c: *ui.Context) void {
        card(c, "Multi-select");
        defer ui.end(c);
        _ = ui.multiSelect(c, &s.multi, &.{ "Zig", "TypeScript", "Rust", "Go", "Python" }, &s.languages, .{ .label = "Languages" });
        ui.row(c, .{ .gap = 6 });
        defer ui.end(c);
        for (s.languages, [_][]const u8{ "Zig", "TypeScript", "Rust", "Go", "Python" }) |on, name| {
            if (on) ui.badge(c, name, c.theme.accent);
        }
    }

    pub fn dateRange(s: *Advanced, c: *ui.Context) void {
        card(c, "Date range picker");
        defer ui.end(c);
        _ = ui.dateRangeInput(c, &s.range, &s.dates, .{ .calendar = .{
            .today = .{ .year = 2026, .month = 10, .day = 23 },
            .min = .{ .year = 2026, .month = 10, .day = 1 },
            .max = .{ .year = 2026, .month = 12, .day = 31 },
            .disabled = weekend,
            .first_weekday = 1,
        } });
        ui.label(c, "October–December 2026 · Weekdays only · Select both endpoints");
    }

    fn weekend(date: ui.Date) bool {
        return date.weekday() == 0 or date.weekday() == 6;
    }

    pub fn drop(s: *Advanced, c: *ui.Context) void {
        card(c, "File drop zone");
        defer ui.end(c);
        const r = ui.fileDropZone(c, &s.drag, &s.files, .{ .max_files = 4 });
        if (r.browse) {
            // A deterministic Gallery example; production apps can open
            // their own file dialog in response to this event.
            _ = s.files.add("workspace/design-notes.md") catch {};
            s.file_message = "Added an example path. Drop local files to add more.";
            c.changed = true;
        }
        if (r.rejected > 0) s.file_message = "This example accepts up to four paths.";
        if (r.err != null) s.file_message = "Could not keep the dropped paths.";
        ui.label(c, s.file_message);
    }
};
