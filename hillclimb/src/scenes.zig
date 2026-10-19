//! The benchmark scenes, myzig's side; mygo/zz_myzig_hillclimb_test.go
//! builds the same ones with mygo. Each frame changes what it shows, as an
//! animation would, so every frame does all its work; but `caret` and
//! `spinner` (myzig's only), which change a few pixels of a full page, as
//! a caret blinking and a spinner turning do: what drawing only what
//! changed saves (`ui.damage`).
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

pub const Scene = enum {
    boxes,
    text,
    scroll,
    list,
    dashboard,
    layout,
    caret,
    spinner,

    /// Whether mygo's twin has the scene.
    pub fn inMygo(s: Scene) bool {
        return s != .caret and s != .spinner;
    }
};

pub const State = struct {
    scene: Scene,
    frame: usize = 0,
    time: f32 = 0,

    pub fn view(s: *State, c: *ui.Context) void {
        switch (s.scene) {
            .boxes => boxes(s, c),
            .text => text(s, c),
            .scroll => scroll(s, c),
            .list => list(s, c),
            .dashboard => dashboard(s, c),
            .layout => layoutScene(s, c),
            .caret, .spinner => page(s, c),
        }
    }
};

fn boxes(s: *State, c: *ui.Context) void {
    const t = s.time;
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(10), .gap = 4 });
    defer ui.end(c);
    for (0..20) |r| {
        ui.row(c, .{ .gap = 4 });
        defer ui.end(c);
        for (0..30) |col| {
            const i: f32 = @floatFromInt(r * 30 + col);
            _ = c.leaf(.{
                .width = .{ .px = 24 },
                .height = .{ .px = 24 },
                .radius = 6,
                .background = hsl(@mod(t * 60 + i * 3, 360)),
                .shadow = .{ .color = .{ .a = 0.2 }, .blur = 4, .y = 2 },
                .offset = .{ .y = 6 * @sin(t * 3 + i * 0.1) },
            }, .none, null);
        }
    }
}

fn text(s: *State, c: *ui.Context) void {
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(10), .gap = 6 });
    defer ui.end(c);
    for (0..15) |r| {
        ui.row(c, .{ .gap = 4 });
        defer ui.end(c);
        for (0..20) |col| {
            const i = r * 20 + col;
            ui.column(c, .{ .width = .{ .px = 40 } });
            defer ui.end(c);
            ui.textf(c, .{ .size = 13 }, "{d}", .{(s.frame * 7 + i * 13) % 10000});
        }
    }
}

fn scroll(s: *State, c: *ui.Context) void {
    const row_h = 28;
    const rows = 1000;
    const offset = @mod(s.time * 600, row_h * rows - 640);
    ui.column(c, .{ .width = .fill, .height = .fill, .clip = true });
    defer ui.end(c);
    ui.column(c, .{ .width = .fill, .offset = .{ .y = -offset } });
    defer ui.end(c);
    for (0..rows) |i| {
        ui.row(c, .{ .width = .fill, .height = .{ .px = row_h }, .padding = .xy(12, 0), .gap = 8, .align_items = .center });
        defer ui.end(c);
        ui.textf(c, .{ .size = 13 }, "Row {d} — a line of a long list", .{i});
        ui.spacer(c);
        ui.textf(c, .{ .size = 12 }, "{d}", .{i * 7 % 100});
    }
}

/// A virtual list of 100 000 rows, scrolled to another row each frame.
fn list(s: *State, c: *ui.Context) void {
    const rows = 100_000;
    const row = (s.frame * 3) % (rows - 40);
    var it = ui.list(c, .{ .count = rows, .row_height = 28, .scroll_to = @as(f32, @floatFromInt(row)) * 28 });
    while (it.next()) |i| {
        ui.row(c, .{ .width = .fill, .height = .{ .px = 28 }, .padding = .xy(12, 0), .gap = 8, .align_items = .center });
        defer ui.end(c);
        ui.textf(c, .{ .size = 13 }, "Row {d} — a line of a long list", .{i});
        ui.spacer(c);
        ui.textf(c, .{ .size = 12 }, "{d}", .{i * 7 % 100});
    }
    it.end();
}

fn dashboard(s: *State, c: *ui.Context) void {
    const t = s.time;
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(16), .gap = 12 });
    defer ui.end(c);
    for (0..3) |r| {
        ui.row(c, .{ .gap = 12 });
        defer ui.end(c);
        for (0..4) |col| {
            const i = r * 4 + col;
            const v = 0.5 + 0.5 * @sin(t * 2 + @as(f32, @floatFromInt(i)));
            ui.column(c, .{
                .width = .{ .px = 200 },
                .padding = .all(14),
                .gap = 8,
                .radius = 12,
                .background = .white,
                .shadow = .{ .color = .{ .a = 0.12 }, .blur = 16, .y = 4 },
            });
            defer ui.end(c);
            ui.textf(c, .{ .size = 13 }, "Metric {d}", .{i});
            ui.textf(c, .{ .size = 28, .weight = .bold }, "{d}", .{@as(u32, @intFromFloat(v * 1000))});
            ui.row(c, .{ .width = .{ .px = 172 }, .height = .{ .px = 6 }, .radius = 3, .background = .hex(0xe0e0e5) });
            _ = c.leaf(.{ .width = .{ .px = 172 * v }, .height = .{ .px = 6 }, .radius = 3, .background = .hex(0x0a84ff) }, .none, null);
            ui.end(c);
            ui.textf(c, .{ .size = 11 }, "updated {d}s ago", .{s.frame % 60});
        }
    }
}

/// Two columns of cards of wrapping text, tags and a counter: a document
/// mostly as it was, one card's counter changing each frame, as most
/// frames of an app are (laid out again only where it changed).
fn layoutScene(s: *State, c: *ui.Context) void {
    ui.row(c, .{ .width = .fill, .height = .fill, .padding = .all(12), .gap = 12 });
    defer ui.end(c);
    for (0..2) |col| {
        ui.column(c, .{ .width = .fill, .gap = 8, .align_items = .stretch });
        defer ui.end(c);
        for (0..10) |r| {
            const i = col * 10 + r;
            ui.column(c, .{ .padding = .all(10), .gap = 6, .radius = 8, .background = .white, .align_items = .stretch });
            defer ui.end(c);
            {
                ui.row(c, .{ .gap = 8, .align_items = .center });
                defer ui.end(c);
                ui.textf(c, .{ .size = 14, .weight = .semibold }, "Card {d}", .{i});
                ui.spacer(c);
                if (s.frame % 20 == i) ui.textf(c, .{ .size = 12 }, "{d}", .{s.frame}) else ui.text(c, "–", .{ .size = 12 });
            }
            ui.text(c, "A paragraph of words that wraps across the width its card is given, as prose does in a column of cards.", .{ .size = 13, .wrap = true });
            ui.row(c, .{ .gap = 6 });
            defer ui.end(c);
            for ([_][]const u8{ "layout", "text", "cache" }) |tag| {
                ui.column(c, .{ .padding = .xy(6, 2), .radius = 4, .background = .hex(0xe0e0e5) });
                defer ui.end(c);
                ui.text(c, tag, .{ .size = 11 });
            }
        }
    }
}

/// A page of 108 cards that stays as it is, but for a caret blinking (on
/// every other frame) or a spinner turning.
fn page(s: *State, c: *ui.Context) void {
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(16), .gap = 8 });
    defer ui.end(c);
    for (0..18) |r| {
        ui.row(c, .{ .gap = 10 });
        defer ui.end(c);
        for (0..6) |col| {
            ui.column(c, .{ .padding = .all(8), .radius = 8, .background = .white, .shadow = .{ .color = .{ .a = 0.1 }, .blur = 8, .y = 2 } });
            defer ui.end(c);
            ui.textf(c, .{ .size = 13 }, "Card {d}, a line", .{r * 6 + col});
        }
    }
    if (s.scene == .caret) {
        if (s.frame % 2 == 0) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 300, .y = 200 }, .width = .{ .px = 2 }, .height = .{ .px = 18 }, .background = .hex(0x0a84ff) }, .none, null);
    } else _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 600, .y = 20 }, .width = .{ .px = 24 }, .height = .{ .px = 24 }, .radius = 4, .background = .hex(0x0a84ff), .transform = .rotation(@floatFromInt(s.frame * 6 % 360)) }, .none, null);
}

fn hsl(h: f32) ui.Color {
    const sat: f32 = 0.7;
    const l: f32 = 0.55;
    const k = struct {
        fn f(n: f32, hh: f32, ss: f32, ll: f32) f32 {
            const kk = @mod(n + hh / 30, 12);
            const a = ss * @min(ll, 1 - ll);
            return ll - a * @max(-1, @min(@min(kk - 3, 9 - kk), 1));
        }
    }.f;
    return .{ .r = k(0, h, sat, l), .g = k(8, h, sat, l), .b = k(4, h, sat, l) };
}
