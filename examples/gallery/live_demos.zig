//! The demos the documentation site runs in its pages (`live.zig`): one
//! small view for each, its state beside it. A page names one with
//! `<!-- demo: buttons height=120 -->` above its picture.
const std = @import("std");
const ui = @import("myzig").ui;
const chart = ui.chart;
const DataTable = @import("data_table.zig").DataTable;

pub const Demo = struct {
    name: []const u8,
    /// The demo's view, on state of its own that lasts as long as the app.
    view: *const fn () ui.View,
};

pub const all = [_]Demo{
    entry("buttons", Buttons),
    entry("toggles", Toggles),
    entry("sliders", Sliders),
    entry("text-input", TextInput),
    entry("virtual-list", VirtualList),
    entry("data-table", Table),
    entry("overlays", Overlays),
    entry("chart", Chart),
    entry("palettes", Palettes),
};

pub fn find(name: []const u8) ?Demo {
    for (all) |d| if (std.mem.eql(u8, d.name, name)) return d;
    return null;
}

fn entry(comptime name: []const u8, comptime T: type) Demo {
    return .{ .name = name, .view = struct {
        var state: T = .{};
        fn get() ui.View {
            return .init(&state, T.view);
        }
    }.get };
}

fn page(c: *ui.Context) void {
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(20), .gap = 12 });
}

const Buttons = struct {
    clicks: u32 = 0,

    fn view(s: *Buttons, c: *ui.Context) void {
        page(c);
        defer ui.end(c);
        ui.row(c, .{ .gap = 8, .align_items = .center });
        defer ui.end(c);
        if (ui.button(c, "Primary", .{ .variant = .primary }).clicked) s.clicks += 1;
        if (ui.button(c, "Secondary", .{}).clicked) s.clicks += 1;
        if (ui.button(c, "Ghost", .{ .variant = .ghost }).clicked) s.clicks += 1;
        if (ui.button(c, "Delete", .{ .variant = .danger }).clicked) s.clicks = 0;
        _ = ui.button(c, "Disabled", .{ .disabled = true });
        ui.badge(c, c.print("Clicks: {d}", .{s.clicks}), c.theme.accentInk());
    }
};

const Toggles = struct {
    notifications: bool = true,
    remember: bool = false,
    mode: usize = 0,

    fn view(s: *Toggles, c: *ui.Context) void {
        page(c);
        defer ui.end(c);
        _ = ui.toggle(c, "Notifications", &s.notifications);
        _ = ui.checkbox(c, "Remember me", &s.remember);
        _ = ui.segmented(c, &.{ "List", "Grid", "Columns" }, &s.mode);
        ui.text(c, if (s.remember) "Remembered" else "Not remembered", .{ .color = c.theme.muted });
    }
};

const Sliders = struct {
    volume: f32 = 0.6,

    fn view(s: *Sliders, c: *ui.Context) void {
        page(c);
        defer ui.end(c);
        ui.row(c, .{ .gap = 12, .align_items = .center });
        ui.text(c, "Volume", .{ .color = c.theme.muted });
        _ = ui.slider(c, &s.volume, .{ .width = .{ .px = 240 }, .label = "Volume" });
        ui.textf(c, .{ .size = 12 }, "{d:.0}%", .{s.volume * 100});
        ui.end(c);
        ui.progress(c, s.volume, .{ .px = 340 });
    }
};

const TextInput = struct {
    name: ui.TextBuffer = .{},

    fn view(s: *TextInput, c: *ui.Context) void {
        page(c);
        defer ui.end(c);
        _ = ui.textField(c, &s.name, .{ .placeholder = "Your name", .label = "Your name" });
        const name = s.name.text();
        ui.text(c, if (name.len == 0) "Type to be greeted." else c.print("Hello, {s}!", .{name}), .{ .color = c.theme.muted });
    }
};

const VirtualList = struct {
    filter: ui.TextBuffer = .{},

    fn view(s: *VirtualList, c: *ui.Context) void {
        page(c);
        defer ui.end(c);
        const th = c.theme;
        _ = ui.textField(c, &s.filter, .{ .placeholder = "Filter 10 000 rows", .label = "Filter", .width = .{ .px = 280 } });
        var matches: std.ArrayList(u16) = .empty;
        const f = s.filter.text();
        for (0..10_000) |i| {
            if (f.len == 0 or std.mem.indexOf(u8, c.print("Item {d}", .{i}), f) != null)
                matches.append(c.alloc(), @intCast(i)) catch break;
        }
        ui.label(c, c.print("{d} rows · only those in view are built", .{matches.items.len}));
        var rows = ui.list(c, .{ .count = matches.items.len, .row_height = 32 });
        while (rows.next()) |i| {
            const row = ui.div(c).row().wFull().h(32).px(10).itemsCenter().rounded(6).hover(th.surface_hover);
            defer row.end();
            ui.text(c, c.print("Item {d}", .{matches.items[i]}), .{});
        }
        rows.end();
    }
};

const Table = struct {
    table: DataTable = .{},

    fn view(s: *Table, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(12) });
        defer ui.end(c);
        s.table.invoices(c);
    }
};

const sorts = [_][]const u8{ "Name", "Date modified", "Size" };

const Overlays = struct {
    pop: ui.OverlayState = .{},
    rename: ui.OverlayState = .{},
    sort: ui.Menu = .{},
    sort_by: usize = 0,
    name: ui.TextBuffer = .{},

    fn view(s: *Overlays, c: *ui.Context) void {
        page(c);
        defer ui.end(c);
        ui.row(c, .{ .gap = 8, .align_items = .center });
        const more = ui.button(c, "Edit name…", .{});
        if (more.clicked) s.pop.toggle();
        if (ui.popover(c, &s.pop, more, .{})) |p| {
            defer p.end();
            ui.text(c, "Name", .{ .weight = .semibold });
            _ = ui.textField(c, &s.name, .{ .placeholder = "A name", .label = "Name" });
            if (ui.button(c, "Done", .{ .variant = .primary }).clicked) s.pop.close();
        }
        const share = ui.button(c, "Share", .{});
        ui.tooltip(c, share, "Share with others");
        if (ui.button(c, "Rename…", .{}).clicked) s.rename.show();
        if (ui.menuButton(c, "Sort by", &s.sort, .{})) |m| {
            defer m.end();
            for (sorts, 0..) |by, i| if (m.item(by, .{ .checked = s.sort_by == i })) {
                s.sort_by = i;
            };
        }
        ui.end(c);
        ui.text(c, c.print("Sorted by {s}", .{sorts[s.sort_by]}), .{ .color = c.theme.muted });
        if (ui.dialog(c, &s.rename, .{})) |d| {
            defer d.end();
            ui.text(c, "Rename the note", .{ .weight = .bold, .size = 16 });
            if (ui.button(c, "Close", .{ .variant = .primary }).clicked) s.rename.close();
        }
    }
};

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun" };

const Chart = struct {
    fn view(_: *Chart, c: *ui.Context) void {
        page(c);
        defer ui.end(c);
        const r = chart.lineChart(c, &.{
            .{ .name = "Visitors", .values = &.{ 120, 180, 150, 260, 240, 310 } },
            .{ .name = "Sign-ups", .values = &.{ 30, 42, 38, 70, 64, 95 } },
        }, .{ .labels = &months, .curve = .monotone, .points = true, .height = 200 });
        ui.text(c, if (r.hover) |h| c.print("{s}, {s}", .{ if (h.series == 0) "Visitors" else "Sign-ups", months[h.index] }) else "Hover over the chart.", .{ .size = 12, .color = c.theme.muted });
    }
};

fn tagNames(comptime E: type) [@typeInfo(E).@"enum".field_names.len][]const u8 {
    var out: [@typeInfo(E).@"enum".field_names.len][]const u8 = undefined;
    for (@typeInfo(E).@"enum".field_names, 0..) |name, i| out[i] = name;
    return out;
}

const bases = tagNames(ui.themes.Base);
const accents = [_][]const u8{"base's own"} ++ tagNames(ui.themes.Accent);

const Palettes = struct {
    base: usize = 2,
    accent: usize = 2,
    base_select: ui.SelectState = .{},
    accent_select: ui.SelectState = .{},
    clicks: u32 = 0,
    on: bool = true,
    level: f32 = 0.6,

    fn view(s: *Palettes, c: *ui.Context) void {
        ui.themes.use(c, .{
            .base = @enumFromInt(s.base),
            .accent = if (s.accent == 0) null else @enumFromInt(s.accent - 1),
        });
        page(c);
        defer ui.end(c);
        ui.row(c, .{ .gap = 8, .align_items = .center });
        ui.label(c, "Base");
        _ = ui.select(c, &s.base, &bases, &s.base_select, .{ .width = .{ .px = 140 }, .label = "Base" });
        ui.label(c, "Accent");
        _ = ui.select(c, &s.accent, &accents, &s.accent_select, .{ .width = .{ .px = 140 }, .label = "Accent" });
        ui.end(c);
        ui.row(c, .{ .gap = 8, .align_items = .center });
        if (ui.button(c, "Preview", .{ .variant = .primary }).clicked) s.clicks += 1;
        _ = ui.button(c, "Secondary", .{});
        _ = ui.button(c, "Delete", .{ .variant = .danger });
        ui.badge(c, c.print("Clicks: {d}", .{s.clicks}), c.theme.accentInk());
        ui.end(c);
        _ = ui.toggle(c, "A switch", &s.on);
        _ = ui.slider(c, &s.level, .{ .width = .{ .px = 280 }, .label = "Level" });
    }
};
