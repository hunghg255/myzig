//! The gallery's first pages: buttons, toggles, sliders and a text field;
//! a list of tasks; type; and ten thousand rows in a virtual list.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

/// A card with a title: its children follow, then `ui.end`.
pub fn card(c: *ui.Context, title: []const u8) void {
    ui.card(c, .{ .width = .fill, .gap = 12 });
    ui.text(c, title, .{ .weight = .semibold });
}

const Item = struct { title: [64]u8, len: usize, done: bool };

pub const Basics = struct {
    notifications: bool = true,
    remember: bool = false,
    sync: bool = true,
    volume: f32 = 0.6,
    speed: f32 = 3,
    view_mode: usize = 0,
    clicks: u32 = 0,
    name: ui.TextBuffer = .{},
    task: ui.TextBuffer = .{},
    filter: ui.TextBuffer = .{},
    items: [64]Item = undefined,
    count: usize = 0,

    pub fn init(b: *Basics) void {
        b.add("Write a UI toolkit in Zig");
        b.add("Draw it with Metal");
        b.add("Ship it");
        b.items[1].done = true;
    }

    fn add(b: *Basics, title: []const u8) void {
        if (b.count == b.items.len or title.len == 0) return;
        var it: Item = .{ .title = undefined, .len = @min(title.len, 64), .done = false };
        @memcpy(it.title[0..it.len], title[0..it.len]);
        b.items[b.count] = it;
        b.count += 1;
    }

    pub fn controls(g: *Basics, c: *ui.Context) void {
        ui.heading(c, "Controls");
        {
            card(c, "Buttons");
            defer ui.end(c);
            ui.row(c, .{ .gap = 8, .align_items = .center });
            defer ui.end(c);
            if (ui.button(c, "Primary", .{ .variant = .primary }).clicked) g.clicks += 1;
            if (ui.button(c, "Secondary", .{}).clicked) g.clicks += 1;
            if (ui.button(c, "Ghost", .{ .variant = .ghost }).clicked) g.clicks += 1;
            if (ui.button(c, "Delete", .{ .variant = .danger }).clicked) g.clicks = 0;
            _ = ui.button(c, "Disabled", .{ .disabled = true });
            ui.badge(c, c.print("{d} clicks", .{g.clicks}), c.theme.accent);
            ui.kbd(c, "⌘K");
        }
        {
            card(c, "Toggles");
            defer ui.end(c);
            _ = ui.toggle(c, "Notifications", &g.notifications);
            _ = ui.toggle(c, "Sync over cellular", &g.sync);
            _ = ui.checkbox(c, "Remember me", &g.remember);
            _ = ui.segmented(c, &.{ "List", "Grid", "Columns" }, &g.view_mode);
        }
        {
            card(c, "Sliders and progress");
            defer ui.end(c);
            ui.row(c, .{ .gap = 12, .align_items = .center });
            ui.text(c, "Volume", .{ .color = c.theme.muted });
            _ = ui.slider(c, &g.volume, .{ .width = .{ .px = 240 } });
            ui.textf(c, .{ .mono = true, .size = 12 }, "{d:.0}%", .{g.volume * 100});
            ui.end(c);
            ui.progress(c, g.volume, .{ .px = 340 });
            ui.row(c, .{ .gap = 12, .align_items = .center });
            ui.text(c, "Speed", .{ .color = c.theme.muted });
            _ = ui.slider(c, &g.speed, .{ .min = 1, .max = 10, .width = .{ .px = 240 } });
            ui.textf(c, .{ .mono = true, .size = 12 }, "{d:.1}×", .{g.speed});
            ui.end(c);
        }
        {
            card(c, "Text field");
            defer ui.end(c);
            ui.row(c, .{ .gap = 8, .align_items = .center });
            _ = ui.textField(c, &g.name, .{ .placeholder = "Your name" });
            ui.end(c);
            const name = g.name.text();
            ui.text(c, if (name.len == 0) "Type to be greeted." else c.print("Hello, {s}!", .{name}), .{ .color = c.theme.muted });
        }
    }

    pub fn tasks(g: *Basics, c: *ui.Context) void {
        ui.heading(c, "Tasks");
        ui.row(c, .{ .gap = 8, .align_items = .center });
        const r = ui.textField(c, &g.task, .{ .placeholder = "Something to do", .width = .{ .px = 300 } });
        const add_clicked = ui.button(c, "Add", .{ .variant = .primary }).clicked;
        ui.end(c);
        if (r.submitted or add_clicked) {
            g.add(std.mem.trim(u8, g.task.text(), " "));
            g.task.clear();
        }
        var left: usize = 0;
        for (g.items[0..g.count]) |it| left += @intFromBool(!it.done);
        ui.label(c, c.print("{d} of {d} left", .{ left, g.count }));
        ui.card(c, .{ .width = .fill, .padding = .xy(16, 6), .gap = 0 });
        defer ui.end(c);
        var remove: ?usize = null;
        for (g.items[0..g.count], 0..) |*it, i| {
            if (i > 0) ui.divider(c);
            ui.key(c, c.print("task-{d}", .{@intFromPtr(it)}));
            ui.row(c, .{ .width = .fill, .padding = .xy(0, 8), .align_items = .center, .gap = 8 });
            defer ui.end(c);
            _ = ui.checkbox(c, it.title[0..it.len], &it.done);
            ui.spacer(c);
            if (it.done) ui.badge(c, "done", c.theme.success);
            if (ui.button(c, "Remove", .{ .variant = .ghost, .size = 12 }).clicked) remove = i;
        }
        if (remove) |i| {
            std.mem.copyForwards(Item, g.items[i .. g.count - 1], g.items[i + 1 .. g.count]);
            g.count -= 1;
        }
        if (g.count == 0) ui.text(c, "Nothing to do.", .{ .color = c.theme.muted });
    }

    /// Ten thousand rows, filtered as you type: only those in view are built.
    pub fn bigList(g: *Basics, c: *ui.Context) void {
        const th = c.theme;
        ui.column(c, .{ .grow = 1, .height = .fill, .padding = .{ .top = 28, .left = 28, .right = 28 }, .gap = 12 });
        defer ui.end(c);
        ui.heading(c, "List");
        ui.row(c, .{ .gap = 8, .align_items = .center });
        ui.icon(c, "magnifyingglass", .{ .color = th.muted });
        _ = ui.textField(c, &g.filter, .{ .placeholder = "Filter 10 000 rows", .width = .{ .px = 280 } });
        ui.end(c);
        // The rows that match, as indices into the 10 000.
        var matches: std.ArrayList(u16) = .empty;
        const f = g.filter.text();
        for (0..10_000) |i| {
            if (f.len == 0 or std.mem.indexOf(u8, c.print("Item {d}", .{i}), f) != null)
                matches.append(c.alloc(), @intCast(i)) catch break;
        }
        ui.label(c, c.print("{d} rows · a virtual list builds only those in view", .{matches.items.len}));
        var rows = ui.list(c, .{ .count = matches.items.len, .row_height = 36, .gap = 0 });
        while (rows.next()) |i| {
            const n = matches.items[i];
            const row = ui.div(c).row().wFull().h(36).px(12).gap(10).itemsCenter().rounded(6).hover(th.surface_hover);
            defer row.end();
            ui.icon(c, if (n % 3 == 0) "star.fill" else "doc.text", .{ .size = 13, .frame = 18, .color = if (n % 3 == 0) th.accent else th.muted });
            ui.textf(c, .{}, "Item {d}", .{n});
            ui.spacer(c);
            ui.textf(c, .{ .size = 12, .color = th.muted, .mono = true }, "#{x:0>4}", .{n});
        }
        rows.end();
    }

    pub fn typography(_: *Basics, c: *ui.Context) void {
        ui.heading(c, "Typography");
        ui.card(c, .{ .width = .fill, .gap = 10, .max_width = 640 });
        defer ui.end(c);
        ui.text(c, "Large Title", .{ .size = 30, .weight = .bold });
        ui.text(c, "Title, semibold", .{ .size = 20, .weight = .semibold });
        ui.text(c, "Body text in the system font, at 14 points.", .{});
        ui.text(c, "Italic, for emphasis.", .{ .italic = true });
        ui.text(c, "const mono = \"monospaced, for code\";", .{ .mono = true, .size = 13 });
        ui.text(c, "Unicode: naïve café — 日本語 — Ελληνικά — ✓ ★ →", .{});
        const s = "Spans: bold, italic, code, a link, struck, marked.";
        // Spans are kept until the frame is drawn: in the frame's memory.
        const spans = c.alloc().dupe(ui.Span, &.{
            .{ .start = 7, .end = 11, .weight = .bold },
            .{ .start = 13, .end = 19, .italic = true },
            .{ .start = 21, .end = 25, .mono = true, .background = c.theme.surface_hover },
            .{ .start = 27, .end = 33, .color = c.theme.accent, .underline = true },
            .{ .start = 35, .end = 41, .strike = true },
            .{ .start = 43, .end = 49, .background = ui.Color.hex(0xffd60a).alpha(0.4) },
        }) catch &.{};
        ui.richText(c, s, spans, .{});
        ui.divider(c);
        ui.text(c, "Text wraps to the width its box gets. Resize the window to watch these lines break " ++
            "again: layout runs every frame, and each line is rasterized once into a glyph atlas at the " ++
            "display's scale, then drawn as textured quads together with every rectangle, border and " ++
            "shadow on screen.", .{ .wrap = true, .color = c.theme.muted, .leading = 1.4 });
    }
};
