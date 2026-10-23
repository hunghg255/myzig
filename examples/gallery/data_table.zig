//! App-owned filtering, sorting and paging around the virtualized table.
const std = @import("std");
const ui = @import("myzig").ui;
const card = @import("basics.zig").card;

const Record = struct { name: []const u8, status: []const u8, amount: u32 };
const records = [_]Record{
    .{ .name = "Ada Lovelace", .status = "Paid", .amount = 240 },
    .{ .name = "Grace Hopper", .status = "Pending", .amount = 180 },
    .{ .name = "Alan Turing", .status = "Paid", .amount = 360 },
    .{ .name = "Margaret Hamilton", .status = "Pending", .amount = 120 },
    .{ .name = "Edsger Dijkstra", .status = "Paid", .amount = 480 },
    .{ .name = "Barbara Liskov", .status = "Paid", .amount = 200 },
    .{ .name = "Donald Knuth", .status = "Pending", .amount = 320 },
    .{ .name = "Frances Allen", .status = "Paid", .amount = 160 },
};

pub const DataTable = struct {
    state: ui.TableState = .{},
    query: ui.TextBuffer = .{},
    paid: bool = false,
    loading: bool = false,
    visible: [3]bool = .{ true, true, true },
    widths: [3]f32 = .{ 260, 130, 110 },
    page: usize = 1,

    pub fn view(s: *DataTable, c: *ui.Context) void {
        ui.heading(c, "Data table");
        ui.label(c, "Search, filter, sort, paginate and resize. Column indices remain stable.");
        card(c, "Invoices");
        defer ui.end(c);
        ui.row(c, .{ .width = .fill, .gap = 12, .align_items = .center });
        const edited = ui.textField(c, &s.query, .{ .label = "Search customers", .placeholder = "Search customers", .width = .{ .px = 260 } });
        const filtered = ui.checkbox(c, "Paid only", &s.paid);
        _ = ui.checkbox(c, "Loading preview", &s.loading);
        ui.end(c);
        if (edited.changed or filtered) {
            s.page = 1;
            s.state.selected = null;
        }
        ui.row(c, .{ .gap = 12 });
        ui.label(c, "Show columns:");
        _ = ui.checkbox(c, "Customer", &s.visible[0]);
        _ = ui.checkbox(c, "Status", &s.visible[1]);
        _ = ui.checkbox(c, "Amount", &s.visible[2]);
        ui.end(c);
        if (s.loading) {
            for (0..4) |_| ui.skeleton(c, .{ .height = 30, .width = .fill });
            return;
        }
        var matching: [records.len]usize = undefined;
        var count: usize = 0;
        for (records, 0..) |record, index| {
            if (s.paid and !std.mem.eql(u8, record.status, "Paid")) continue;
            if (std.ascii.findIgnoreCase(record.name, s.query.text()) == null) continue;
            matching[count] = index;
            count += 1;
        }
        if (s.state.sort) |sort| std.mem.sort(usize, matching[0..count], sort, less);
        const page_size = 3;
        const page_count = @max(1, std.math.divCeil(usize, count, page_size) catch unreachable);
        s.page = std.math.clamp(s.page, 1, page_count);
        const start = @min(count, (s.page - 1) * page_size);
        const shown = matching[start..@min(count, start + page_size)];
        if (count == 0) {
            const empty = ui.empty(c, "No invoices found", "Try a different customer name or clear the filter.", .{});
            if (ui.button(c, "Reset filters", .{}).clicked) {
                s.query.set("");
                s.paid = false;
                c.changed = true;
            }
            empty.end();
        } else if (!s.visible[0] and !s.visible[1] and !s.visible[2]) {
            ui.label(c, "Choose a column to display.");
        } else {
            const cols = [_]ui.TableColumn{
                .{ .title = "Customer", .sortable = true, .hidden = !s.visible[0], .min_width = 120, .max_width = 400 },
                .{ .title = "Status", .sortable = true, .hidden = !s.visible[1], .min_width = 80, .max_width = 200 },
                .{ .title = "Amount", .sortable = true, .hidden = !s.visible[2], .min_width = 80, .max_width = 200, .alignment = .end },
            };
            var table = ui.table(c, &s.state, &cols, shown.len, .{ .height = .{ .px = 148 }, .row_height = 38, .column_widths = &s.widths });
            while (table.next()) |row| {
                const record = records[shown[row]];
                while (table.cell()) |column| switch (column) {
                    0 => ui.text(c, record.name, .{ .color = table.textColor() }),
                    1 => ui.text(c, record.status, .{ .color = table.textColor() }),
                    else => ui.text(c, c.print("${d}", .{record.amount}), .{ .color = table.textColor() }),
                };
            }
            const result = table.end();
            if (result.sorted) {
                s.state.selected = null;
                c.changed = true;
            }
        }
        ui.row(c, .{ .width = .fill, .gap = 12, .align_items = .center });
        ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "{d} invoices · Page {d} of {d}", .{ count, s.page, page_count });
        ui.spacer(c);
        if (ui.pagination(c, &s.page, .{ .page_count = page_count })) s.state.selected = null;
        ui.end(c);
    }

    fn less(sort: ui.TableSort, a: usize, b: usize) bool {
        const order = switch (sort.column) {
            0 => std.mem.order(u8, records[a].name, records[b].name),
            1 => std.mem.order(u8, records[a].status, records[b].status),
            else => std.math.order(records[a].amount, records[b].amount),
        };
        if (order == .eq) return a < b;
        return if (sort.descending) order == .gt else order == .lt;
    }
};
