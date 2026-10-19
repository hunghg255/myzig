//! The update window's view, in native UI, after mygo's updater/native:
//! what the window shows of each step (checking, up to date, a new version
//! with its release notes, the download, ready to relaunch, an error) and
//! the buttons that answer it. It holds no window and no service, so a
//! `ui.Tester` drives it; `Window` (window.zig) shows it.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const Texts = @import("texts.zig").Texts;

pub const Step = enum { checking, up_to_date, available, downloading, ready, check_failed, install_failed };

pub const Action = enum { ok, cancel, skip, later, install, relaunch };

pub const Button = struct {
    action: Action,
    label: []const u8,
    /// Enter answers with it; it is drawn as the primary button.
    default: bool = false,
    /// Escape answers with it.
    cancel: bool = false,
    /// Set apart on the leading side ("Skip This Version").
    aside: bool = false,
};

pub const Answer = struct {
    ctx: *anyopaque,
    /// The user's answer, and the checkbox "Automatically download and
    /// install updates in the future".
    func: *const fn (ctx: *anyopaque, action: Action, automatic: bool) void,
};

pub const View = struct {
    texts: Texts,
    app_name: []const u8,
    /// The running version.
    current: []const u8,
    step: Step = .checking,
    /// The new version, its release notes (Markdown) and, when it failed,
    /// what went wrong.
    version: []const u8 = "",
    notes: []const u8 = "",
    detail: []const u8 = "",
    done: u64 = 0,
    total: ?u64 = null,
    /// The checkbox of a new version.
    automatic: bool = false,
    answer: ?Answer = null,
    /// Counts the steps shown; a step's buttons answer once.
    prompt: u32 = 0,
    answered: ?u32 = null,

    /// Shows `step`: its buttons answer again.
    pub fn show(v: *View, step: Step) void {
        if (step != v.step or step != .downloading) v.prompt += 1;
        v.step = step;
    }

    /// The buttons of the step, as mygo's views have them.
    pub fn buttons(v: *const View) []const Button {
        const t = &v.texts;
        const S = struct {
            threadlocal var buf: [3]Button = undefined;
        };
        const b = &S.buf;
        switch (v.step) {
            .checking, .downloading => {
                b[0] = .{ .action = .cancel, .label = t.text(.cancel), .cancel = true };
                return b[0..1];
            },
            .up_to_date, .check_failed, .install_failed => {
                b[0] = .{ .action = .ok, .label = t.text(.ok), .default = true, .cancel = true };
                return b[0..1];
            },
            .available => {
                b[0] = .{ .action = .skip, .label = t.text(.skip), .aside = true };
                b[1] = .{ .action = .later, .label = t.text(.remindLater), .cancel = true };
                b[2] = .{ .action = .install, .label = t.text(.install), .default = true };
                return b[0..3];
            },
            .ready => {
                b[0] = .{ .action = .later, .label = t.text(.later), .cancel = true };
                b[1] = .{ .action = .relaunch, .label = t.text(.relaunch), .default = true };
                return b[0..2];
            },
        }
    }

    /// The title and message of the step, in the frame's memory.
    pub fn title(v: *const View, a: std.mem.Allocator) []const u8 {
        const t = &v.texts;
        return switch (v.step) {
            .checking => t.text(.checking),
            .up_to_date => t.text(.upToDate),
            .available => t.print(a, .available, .{ .app = v.app_name }),
            .downloading => t.text(.downloading),
            .ready => t.text(.ready),
            .check_failed, .install_failed => t.text(.@"error"),
        };
    }

    pub fn message(v: *const View, a: std.mem.Allocator) []const u8 {
        const t = &v.texts;
        return switch (v.step) {
            .checking => "",
            .up_to_date => t.print(a, .upToDateMessage, .{ .app = v.app_name, .version = v.current }),
            .available => t.print(a, .availableMessage, .{ .app = v.app_name, .version = v.version, .current = v.current }),
            .downloading => if (v.total) |n| (if (n > 0) t.print(a, .progress, .{ .done = t.megabytes(a, v.done), .total = t.megabytes(a, n) }) else "") else "",
            .ready => t.print(a, .readyMessage, .{ .app = v.app_name, .version = v.version }),
            .check_failed => t.text(.checkError),
            .install_failed => t.text(.installError),
        };
    }

    /// Answers with `action`, once a step.
    pub fn respond(v: *View, action: Action) void {
        if (v.answered == v.prompt) return;
        v.answered = v.prompt;
        if (v.answer) |a| a.func(a.ctx, action, v.automatic);
    }

    pub fn build(v: *View, c: *ui.Context) void {
        const a = c.alloc();
        const t = &v.texts;
        ui.direction.set(c, if (t.rtl()) .rtl else .ltr);
        const bs = v.buttons();
        for (bs) |b| {
            if ((b.cancel and c.shortcut(.{ .key = ui.Shortcut.escape })) or (b.default and c.shortcut(.{ .key = ui.Shortcut.enter }))) v.respond(b.action);
        }
        const off = v.answered == v.prompt;
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .{ .top = 18, .left = 20, .right = 20, .bottom = 20 }, .gap = 12 });
        defer ui.end(c);
        {
            ui.column(c, .{ .width = .fill, .grow = 1, .gap = 6 });
            defer ui.end(c);
            ui.text(c, v.title(a), .{ .weight = .bold, .wrap = true });
            const msg = v.message(a);
            if (msg.len > 0) ui.text(c, msg, .{ .wrap = true, .size = 13 });
            switch (v.step) {
                .checking => ui.spinner(c, .{}),
                .downloading => ui.progress(c, if (v.total) |n| (if (n > 0) @floatCast(@as(f64, @floatFromInt(v.done)) / @as(f64, @floatFromInt(n))) else 0) else 0, .fill),
                else => {},
            }
            if (v.detail.len > 0) ui.text(c, v.detail, .{ .size = 11, .color = c.theme.muted, .wrap = true });
            if (v.step == .available and v.notes.len > 0) {
                ui.text(c, t.text(.releaseNotes), .{ .size = 11, .weight = .bold });
                ui.scroll(c, .{ .width = .fill, .grow = 1, .padding = .xy(12, 8), .background = c.theme.surface, .border = c.theme.border, .radius = 6 });
                defer ui.end(c);
                const res = ui.markdown(c, v.notes, .{ .size = 12 });
                if (res.link) |url| _ = myzig.shell.openUrl(url);
            }
            if (v.step == .available) _ = ui.checkbox(c, t.text(.automaticDownloads), &v.automatic);
        }
        ui.row(c, .{ .width = .fill, .gap = 10, .align_items = .center });
        defer ui.end(c);
        for (bs) |b| if (b.aside) v.button(c, b, off);
        ui.spacer(c);
        for (bs) |b| if (!b.aside) v.button(c, b, off);
    }

    fn button(v: *View, c: *ui.Context, b: Button, off: bool) void {
        ui.key(c, @tagName(b.action));
        if (ui.button(c, b.label, .{ .variant = if (b.default) .primary else .secondary, .size = 13, .disabled = off }).clicked and !off) v.respond(b.action);
    }
};

const Seen = struct {
    action: ?Action = null,
    automatic: bool = false,
    fn answered(ctx: *anyopaque, action: Action, automatic: bool) void {
        const s: *Seen = @ptrCast(@alignCast(ctx));
        s.action = action;
        s.automatic = automatic;
    }
};

fn tester(t: *ui.Tester, v: *View) !void {
    try t.init(std.testing.allocator, .init(v, View.build), .{ .width = 520, .height = 360 });
}

test "a new version: its notes, the checkbox, and the buttons answer once" {
    var seen: Seen = .{};
    var v: View = .{ .texts = .init("en"), .app_name = "Notes", .current = "1.0.0", .answer = .{ .ctx = &seen, .func = Seen.answered } };
    v.version = "2.0.0";
    v.notes = "Faster and *better*.";
    v.show(.available);
    var t: ui.Tester = undefined;
    try tester(&t, &v);
    defer t.deinit();
    t.frame();
    try std.testing.expect(t.hasText("A new version of Notes is available!"));
    try std.testing.expect(t.containsText("Notes 2.0.0 is now available—you have 1.0.0."));
    try std.testing.expect(t.hasText("Release Notes:"));
    try std.testing.expect(t.containsText("Faster and"));
    try t.clickText("Automatically download and install updates in the future");
    t.frame();
    try t.clickText("Install Update");
    t.frame();
    try std.testing.expectEqual(Action.install, seen.action.?);
    try std.testing.expect(seen.automatic);
    // Answered: the buttons wait for the next step.
    seen.action = null;
    try t.clickText("Remind Me Later");
    t.frame();
    try std.testing.expectEqual(null, seen.action);
    v.total = 2_000_000;
    v.done = 500_000;
    v.show(.downloading);
    t.frame();
    try std.testing.expect(t.hasText("Downloading update…"));
    try std.testing.expect(t.hasText("0.5 MB of 2.0 MB"));
    v.show(.ready);
    t.frame();
    try std.testing.expect(t.containsText("Notes 2.0.0 is installed"));
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter }));
    t.frame();
    try std.testing.expectEqual(Action.relaunch, seen.action.?);
}

test "the window speaks the language it opened in" {
    var seen: Seen = .{};
    var v: View = .{ .texts = .init("de"), .app_name = "Notizen", .current = "1.0", .answer = .{ .ctx = &seen, .func = Seen.answered } };
    v.show(.up_to_date);
    var t: ui.Tester = undefined;
    try tester(&t, &v);
    defer t.deinit();
    t.frame();
    try std.testing.expect(t.hasText("Sie sind auf dem neuesten Stand!"));
    try std.testing.expect(t.containsText("Notizen 1.0 ist derzeit die neueste verfügbare Version."));
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
    t.frame();
    try std.testing.expectEqual(Action.ok, seen.action.?);
    v.texts = .init("zh-Hans");
    v.show(.check_failed);
    v.detail = "HttpStatus";
    t.frame();
    try std.testing.expect(t.hasText("更新出错！") or t.containsText("出错"));
    try std.testing.expect(t.hasText("HttpStatus"));
}
