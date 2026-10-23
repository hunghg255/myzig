//! Empty, loading and inline notices, a command menu and an edge panel.
const ui = @import("myzig").ui;
const card = @import("basics.zig").card;

const Command = enum { create, details, export_files };

pub const Feedback = struct {
    projects: bool = false,
    animated: bool = false,
    palette: ui.CommandState = .{},
    details: ui.OverlayState = .{},
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
        ui.heading(c, "Feedback and commands");
        ui.label(c, "Useful states for everyday app screens.");
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
    }
};
