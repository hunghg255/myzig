//! Empty, loading and inline notices, a command menu and an edge panel.
const ui = @import("myzig").ui;
const card = @import("basics.zig").card;
const gallery = @import("basics.zig");

const Command = enum { create, details, export_files };

pub const Feedback = struct {
    projects: bool = false,
    animated: bool = false,
    palette: ui.CommandState = .{},
    details: ui.OverlayState = .{},
    drawer: ui.DrawerState = .{},
    goal: i32 = 350,
    name: ui.TextBuffer = .{},
    status: []const u8 = "Use a command or open the details panel.",
    actions: ui.Actions(Command) = .init(.{
        .create = .{ .title = "Create project", .icon = "plus", .shortcut = .{ .key = 'n', .cmd = true } },
        .details = .{ .title = "Workspace settings", .icon = "gearshape" },
        .export_files = .{ .title = "Export files", .icon = "doc.text", .enabled = false },
    }),

    pub fn init(s: *Feedback) void {
        s.name.set("My workspace");
    }

    pub fn view(s: *Feedback, c: *ui.Context) void {
        gallery.heading(c, "Feedback and commands");
        gallery.intro(c, "Useful states for everyday app screens.");
        {
            card(c, "Inline alerts");
            defer ui.end(c);
            const info = ui.alert(c, "Changes saved locally", "Your files will sync when you reconnect.", .{});
            info.end();
            const warning = ui.alert(c, "Storage almost full", "Remove unused files or upgrade your workspace.", .{ .kind = .warning });
            warning.end();
            const danger = ui.alert(c, "Sync interrupted", "Your local changes are safe.", .{ .kind = .danger });
            if (ui.button(c, "Retry sync", .{ .size = 12 }).clicked) s.status = "Sync retried";
            danger.end();
        }
        {
            card(c, "Empty state");
            defer ui.end(c);
            if (s.projects) {
                const saved = ui.alert(c, "Project created", "Your workspace is ready.", .{ .kind = .success });
                saved.end();
            } else {
                const e = ui.empty(c, "No projects yet", "Create a project to get started with your workspace.", .{ .icon = "folder", .outline = true });
                defer e.end();
                if (ui.button(c, "Create project", .{ .variant = .primary }).clicked) s.run(.create);
            }
        }
        {
            card(c, "Skeleton placeholders");
            defer ui.end(c);
            _ = ui.toggle(c, "Animate placeholders", &s.animated);
            for (0..3) |_| {
                ui.row(c, .{ .width = .fill, .gap = 12, .align_items = .center });
                ui.skeleton(c, .{ .width = .{ .px = 40 }, .height = 40, .radius = 20, .animated = s.animated });
                ui.column(c, .{ .width = .fill, .gap = 8 });
                ui.skeleton(c, .{ .width = .{ .px = 180 }, .animated = s.animated });
                ui.skeleton(c, .{ .width = .fill, .height = 12, .animated = s.animated });
                ui.end(c);
                ui.end(c);
            }
        }
        s.panels(c);
    }

    pub fn panels(s: *Feedback, c: *ui.Context) void {
        card(c, "Commands and panels");
        defer ui.end(c);
        if (ui.button(c, "Open commands", .{}).clicked) s.palette.show();
        if (ui.button(c, "Open details", .{}).clicked) s.details.show();
        if (ui.button(c, "Open drawer", .{}).clicked) s.drawer.show();
        ui.label(c, "Ctrl/Cmd+K opens commands from any Gallery page.");
        ui.label(c, s.status);
    }

    fn run(s: *Feedback, cmd: Command) void {
        switch (cmd) {
            .create => {
                s.projects = true;
                s.status = "Project created";
            },
            .details => s.details.show(),
            .export_files => s.status = "Files exported",
        }
    }

    pub fn layers(s: *Feedback, c: *ui.Context) void {
        if (c.shortcut(.{ .key = 'k', .cmd = true })) s.palette.toggle();
        s.actions.setEnabled(.export_files, s.projects);
        if (s.actions.commandPalette(c, &s.palette, .{ .label = "Workspace commands" })) |cmd| s.run(cmd);
        if (ui.sheet(c, &s.details, .{ .label = "Workspace details" })) |panel| {
            defer panel.end();
            ui.heading(c, "Workspace details");
            ui.text(c, "Edit workspace settings without leaving the current screen.", .{ .color = c.theme.muted, .wrap = true });
            const field = ui.field(c, "Workspace name", .{});
            _ = ui.textField(c, &s.name, .{ .width = .fill });
            field.end();
            if (ui.button(c, "Save details", .{ .variant = .primary }).clicked) {
                s.status = "Details saved";
                s.details.close();
            }
            if (ui.button(c, "Close details", .{ .variant = .ghost }).clicked) s.details.close();
        }
        if (ui.drawer(c, &s.drawer, .{ .label = "Move goal" })) |d| {
            defer d.end();
            moveGoal(c, &s.goal, &s.drawer);
        }
    }
};

/// shadcn's drawer example: a daily goal set with two buttons.
pub fn moveGoal(c: *ui.Context, goal: *i32, drawer: *ui.DrawerState) void {
    ui.row(c, .{ .width = .fill, .justify = .center });
    defer ui.end(c);
    ui.column(c, .{ .width = .fill, .max_width = 384, .gap = 16 });
    defer ui.end(c);
    ui.text(c, "Move goal", .{ .size = 16, .weight = .semibold });
    ui.text(c, "Set your daily activity goal.", .{ .color = c.theme.muted });
    ui.row(c, .{ .width = .fill, .align_items = .center, .justify = .space_between });
    if (ui.button(c, "−", .{ .disabled = goal.* <= 200 }).clicked) goal.* -= 10;
    ui.column(c, .{ .align_items = .center });
    ui.text(c, c.print("{d}", .{goal.*}), .{ .size = 48, .weight = .bold });
    ui.text(c, "CALORIES/DAY", .{ .size = 12, .color = c.theme.muted });
    ui.end(c);
    if (ui.button(c, "+", .{ .disabled = goal.* >= 400 }).clicked) goal.* += 10;
    ui.end(c);
    if (ui.button(c, "Submit", .{ .variant = .primary, .width = .fill }).clicked) drawer.close();
    if (ui.button(c, "Cancel", .{ .width = .fill }).clicked) drawer.close();
}
