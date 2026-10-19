//! The gallery's inputs: choices, ranges, fields, dates and times, colors,
//! menus of choices, and a form that checks what it is given.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const card = @import("basics.zig").card;

const Plan = enum { free, pro, team };

const fonts = [_][]const u8{ "Avenir", "Courier", "Futura", "Georgia", "Gill Sans", "Helvetica", "Menlo", "Optima", "Palatino", "Times" };
const cities = [_][]const u8{ "Amsterdam", "Berlin", "Lisbon", "London", "Madrid", "Paris", "Prague", "Rome", "Vienna" };
const sizes = [_][]const u8{ "Small", "Medium", "Large", "Extra large" };
const tags = [_][]const u8{ "design", "docs", "bug", "feature", "help wanted", "performance", "ui", "zig" };

pub const Inputs = struct {
    plan: Plan = .pro,
    alignment: u8 = 0,
    stars: u8 = 4,
    links: u32 = 0,
    low: f64 = 200,
    high: f64 = 700,
    copies: f64 = 2,
    copies_text: ui.TextBuffer = .{},
    load: f64 = 0.72,
    query: ui.TextBuffer = .{},
    tokens: ui.Tokens = .{},
    day: ui.Date = .{ .year = 2026, .month = 10, .day = 19 },
    due: ui.Date = .{ .year = 2026, .month = 11, .day = 2 },
    at: ui.Time = .{ .hour = 9, .minute = 30 },
    tint: ui.Color = .hex(0x0a84ff),
    picker: ui.ColorPicker = .{},
    well: ui.ColorPicker = .{},
    size: usize = 1,
    size_box: ui.SelectState = .{},
    font: ?usize = 5,
    font_box: ui.ComboboxState = .{},
    city: ui.TextBuffer = .{},
    city_box: ui.AutocompleteState = .{},
    name: ui.TextBuffer = .{},
    email: ui.TextBuffer = .{},
    password: ui.TextBuffer = .{},
    sounds: bool = true,
    signed_in: bool = true,
    submitted: bool = false,

    pub fn init(s: *Inputs) void {
        _ = s.tokens.append("zig");
        _ = s.tokens.append("ui");
        s.email.set("ada@example");
    }

    pub fn view(s: *Inputs, c: *ui.Context) void {
        const th = c.theme;
        ui.heading(c, "Inputs");
        {
            card(c, "Choices");
            defer ui.end(c);
            _ = ui.radioGroup(c, &s.plan, &.{
                .{ .label = "Free", .value = .free },
                .{ .label = "Pro", .value = .pro },
                .{ .label = "Team", .value = .team },
            }, .{ .row = true, .gap = 16 });
            ui.row(c, .{ .gap = 16, .align_items = .center });
            _ = ui.radio(c, &s.alignment, 0, "Left");
            _ = ui.radio(c, &s.alignment, 1, "Center");
            _ = ui.radio(c, &s.alignment, 2, "Right");
            ui.end(c);
            ui.row(c, .{ .gap = 16, .align_items = .center });
            _ = ui.rating(c, &s.stars, .{});
            ui.text(c, c.print("{d} of 5", .{s.stars}), .{ .color = th.muted });
            if (ui.link(c, "Privacy policy", .{})) s.links += 1;
            if (s.links > 0) ui.text(c, c.print("opened {d}×", .{s.links}), .{ .size = 12, .color = th.muted });
            ui.end(c);
        }
        {
            card(c, "Ranges");
            defer ui.end(c);
            ui.row(c, .{ .gap = 12, .align_items = .center });
            ui.text(c, "Price", .{ .color = th.muted });
            _ = ui.rangeSlider(c, &s.low, &s.high, .{ .min = 0, .max = 1000, .step = 10, .width = 240 });
            ui.text(c, c.print("${d:.0} – ${d:.0}", .{ s.low, s.high }), .{ .mono = true, .size = 12 });
            ui.end(c);
            ui.row(c, .{ .gap = 12, .align_items = .center });
            ui.text(c, "Copies", .{ .color = th.muted });
            _ = ui.stepper(c, &s.copies, .{ .min = 1, .max = 20 });
            _ = ui.numberInput(c, &s.copies, &s.copies_text, .{ .min = 1, .max = 20 });
            ui.end(c);
            ui.row(c, .{ .gap = 12, .align_items = .center });
            ui.text(c, "Disk", .{ .color = th.muted });
            ui.meter(c, s.load, .{ .warning = 0.7, .critical = 0.9, .width = .{ .px = 240 } });
            ui.text(c, c.print("{d:.0}%", .{s.load * 100}), .{ .mono = true, .size = 12 });
            ui.spinner(c, .{});
            ui.text(c, "Loading…", .{ .size = 12, .color = th.muted });
            ui.end(c);
        }
        {
            card(c, "Fields");
            defer ui.end(c);
            ui.row(c, .{ .gap = 12, .align_items = .center });
            const r = ui.searchField(c, &s.query, .{ .placeholder = "Search the gallery" });
            if (r.submitted) s.query.clear();
            ui.avatar(c, "Ada Lovelace", .{});
            ui.avatar(c, "Grace Hopper", .{});
            ui.avatar(c, "Linus", .{ .size = 24 });
            ui.end(c);
            _ = ui.tokenField(c, &s.tokens, &tags, .{ .placeholder = "Add a tag", .width = 420 });
        }
        {
            card(c, "Dates, times and colors");
            defer ui.end(c);
            ui.row(c, .{ .gap = 24, .align_items = .start });
            defer ui.end(c);
            _ = ui.calendar(c, &s.day, .{ .today = .{ .year = 2026, .month = 10, .day = 19 } });
            ui.column(c, .{ .gap = 12 });
            ui.row(c, .{ .gap = 8, .align_items = .center });
            ui.text(c, "Due", .{ .color = th.muted });
            _ = ui.dateInput(c, &s.due, .{});
            _ = ui.timeInput(c, &s.at, .{});
            ui.end(c);
            ui.row(c, .{ .gap = 8, .align_items = .center });
            ui.text(c, "Accent", .{ .color = th.muted });
            _ = ui.colorWell(c, &s.tint, &s.well);
            ui.end(c);
            _ = ui.colorPicker(c, &s.tint, &s.picker);
            ui.end(c);
        }
        {
            card(c, "Menus of choices");
            defer ui.end(c);
            ui.row(c, .{ .gap = 12, .align_items = .center });
            defer ui.end(c);
            _ = ui.select(c, &s.size, &sizes, &s.size_box, .{ .width = .{ .px = 160 } });
            _ = ui.combobox(c, &s.font, &fonts, &s.font_box, .{ .placeholder = "Font", .width = .{ .px = 180 } });
            _ = ui.autocomplete(c, &s.city, &cities, &s.city_box, .{ .placeholder = "City", .width = .{ .px = 180 } });
        }
        s.form(c);
    }

    fn form(s: *Inputs, c: *ui.Context) void {
        card(c, "A form");
        defer ui.end(c);
        var v: ui.Validation = .{};
        var fm = ui.form(c, .{});
        {
            defer fm.end();
            const n = fm.field("Name", .{ .err = if (s.submitted) v.check(ui.validate.required(s.name.text())) else "" });
            _ = ui.textField(c, &s.name, .{ .placeholder = "Ada Lovelace", .width = .{ .px = 260 } });
            n.end();
            const e = fm.field("Email", .{ .description = "For receipts.", .err = v.check(ui.validate.email(s.email.text())) });
            _ = ui.textField(c, &s.email, .{ .width = .{ .px = 260 } });
            e.end();
            const p = fm.field("Password", .{ .err = if (s.submitted) v.check(ui.validate.minLength(c, s.password.text(), 8)) else "" });
            _ = ui.textField(c, &s.password, .{ .password = true, .width = .{ .px = 260 } });
            p.end();
            const set = ui.fieldset(c, "Notifications", .{ .disabled = !s.signed_in });
            const snd = fm.field("Sound effects", .{});
            _ = ui.toggle(c, "", &s.sounds);
            snd.end();
            set.end();
        }
        ui.row(c, .{ .gap = 12, .align_items = .center });
        defer ui.end(c);
        _ = ui.checkbox(c, "Signed in", &s.signed_in);
        if (ui.button(c, "Submit", .{ .variant = .primary }).clicked) s.submitted = true;
        if (s.submitted) ui.text(c, if (v.ok()) "All good." else c.print("{d} to fix", .{v.errors}), .{ .color = if (v.ok()) c.theme.success else c.theme.danger });
    }
};
