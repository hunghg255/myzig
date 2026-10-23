//! Content rows, framed inputs and page navigation, shared by Gallery
//! and its documentation snapshots.
const ui = @import("myzig").ui;
const card = @import("basics.zig").card;

pub const Composites = struct {
    search: ui.TextBuffer = .{},
    url: ui.TextBuffer = .{},
    amount: ui.TextBuffer = .{},
    locked: ui.TextBuffer = .{},
    page: usize = 6,
    history_page: usize = 1,
    action: []const u8 = "Choose an item action.",
    input_action: []const u8 = "Affixes focus the input. Tab reaches its actions.",

    pub fn init(s: *Composites) void {
        s.search.set("native widgets");
        s.url.set("myzig.dev");
        s.amount.set("120");
        s.locked.set("Managed by your team");
    }

    pub fn view(s: *Composites, c: *ui.Context) void {
        ui.heading(c, "Items, input groups and pagination");
        ui.label(c, "Compose everyday app screens from reusable controls.");
        s.items(c);
        s.inputs(c);
        s.pages(c);
    }

    fn items(s: *Composites, c: *ui.Context) void {
        card(c, "Items");
        defer ui.end(c);
        {
            const row = ui.item(c, .{ .label = "Project report" });
            defer row.end();
            row.icon("doc.text");
            row.content("Project report", "PDF document · Updated today · 2.4 MB");
            if (ui.button(c, "Open report", .{ .size = 12 }).clicked) s.action = "Opened report";
        }
        {
            const row = ui.item(c, .{ .variant = .muted, .label = "Team member" });
            defer row.end();
            row.avatar("Ada Lovelace", .{ .size = 36 });
            row.content("Ada Lovelace", "Workspace owner · ada@example.com");
            ui.badge(c, "Owner", c.theme.accent);
            if (ui.button(c, "Message", .{ .variant = .ghost, .size = 12 }).clicked) s.action = "Message Ada";
        }
        {
            const row = ui.item(c, .{ .variant = .plain, .size = .small });
            defer row.end();
            row.icon("checkmark.circle.fill");
            row.content("All files synced", "Your workspace is up to date.");
            ui.badge(c, "Ready", c.theme.accent);
        }
        ui.label(c, s.action);
    }

    fn inputs(s: *Composites, c: *ui.Context) void {
        card(c, "Input groups");
        defer ui.end(c);
        {
            const f = ui.field(c, "Search", .{});
            defer f.end();
            var g = ui.inputGroup(c, .{ .width = .{ .px = 520 } });
            defer g.end();
            g.icon("magnifyingglass");
            if (g.input(&s.search, .{ .placeholder = "Search widgets" }).submitted) s.input_action = "Search submitted";
            if (g.button("Clear search", .{ .variant = .ghost, .size = 12 })) {
                s.search.set("");
                s.input_action = "Search cleared";
            }
        }
        {
            const f = ui.field(c, "Website", .{});
            defer f.end();
            var g = ui.inputGroup(c, .{ .width = .{ .px = 520 } });
            defer g.end();
            g.text("https://");
            _ = g.input(&s.url, .{ .placeholder = "example.com" });
            if (g.button("Use URL", .{ .size = 12 })) s.input_action = "URL selected";
        }
        {
            const f = ui.field(c, "Budget", .{ .description = "Units and prefixes stay outside the editable value." });
            defer f.end();
            var g = ui.inputGroup(c, .{ .width = .{ .px = 280 } });
            defer g.end();
            g.text("$");
            _ = g.input(&s.amount, .{});
            g.text("USD / month");
        }
        {
            var g = ui.inputGroup(c, .{ .width = .{ .px = 520 }, .disabled = true });
            defer g.end();
            g.icon("doc.text");
            _ = g.input(&s.locked, .{ .label = "Managed setting" });
            _ = g.button("Edit", .{ .variant = .ghost, .size = 12 });
        }
        ui.label(c, s.input_action);
    }

    fn pages(s: *Composites, c: *ui.Context) void {
        card(c, "Pagination");
        defer ui.end(c);
        ui.label(c, "Known total · Numbered pages with ellipses");
        ui.textf(c, .{ .weight = .medium }, "Page {d} of 20", .{s.page});
        for (0..2) |i| {
            const row = ui.item(c, .{ .size = .small });
            row.icon("doc.text");
            row.content(c.print("Document {d}", .{(s.page - 1) * 2 + i + 1}), "This preview changes with the selected page.");
            row.end();
        }
        _ = ui.pagination(c, &s.page, .{ .page_count = 20 });
        ui.divider(c);
        ui.label(c, "Unknown total · Fetch history one page at a time");
        _ = ui.pagination(c, &s.history_page, .{ .has_next = s.history_page < 4, .label = "History pages" });
    }
};
