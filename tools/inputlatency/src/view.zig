//! The window a run measures, by mode: a text area typed into, a list of a
//! million rows scrolled, a box dragged over rows of text, a box crossing
//! the window every second (anim), or boxes casting wide shadows, which
//! keep the GPU busy (heavy). On Windows a probe in the top left corner
//! shows the number of the last event handled (or frame built), which the
//! tool reads back from the desktop (`probe.zig`).
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const plan = @import("plan.zig");
const probe = @import("probe.zig");

const sentence = "The quick brown fox jumps over the lazy dog. ";
/// The text typed into: the sentence 40 times.
const paragraph = blk: {
    var p: [sentence.len * 40]u8 = undefined;
    for (0..40) |i| @memcpy(p[i * sentence.len ..][0..sentence.len], sentence);
    break :blk p;
};

pub const State = struct {
    mode: plan.Mode,
    text: ui.TextArea,
    /// The dragged box's place.
    offset: ui.Point = .{},
    grab: ui.Point = .{},
    /// How many boxes heavy draws.
    boxes: usize = 30,
    /// Shows `seq` in the probe (Windows).
    show_probe: bool = false,
    seq: u64 = 0,
    /// Each frame of the animations, before it is drawn (Windows: its
    /// number in the probe).
    on_frame: ?*const fn (s: *State) void = null,

    pub fn init(gpa: std.mem.Allocator, mode: plan.Mode) State {
        return .{ .mode = mode, .text = .init(gpa, &paragraph) };
    }

    pub fn deinit(s: *State) void {
        s.text.deinit();
    }

    /// The point of the dragged box a press takes, in the view.
    pub fn boxPoint(s: *const State) ui.Point {
        return .{ .x = 40 + s.offset.x, .y = 40 + s.offset.y };
    }

    pub fn view(s: *State, c: *ui.Context) void {
        if (!s.mode.input()) if (s.on_frame) |f| f(s);
        const th = c.theme;
        const root = ui.div(c).wFull().hFull();
        switch (s.mode) {
            .type => {
                // Typed into without a click: focused from the start.
                if (s.text.id != 0 and c.focus == 0) c.focus = s.text.id;
                const pad = ui.div(c).wFull().hFull().p(16);
                _ = ui.textArea(c, &s.text, .{ .height = .fill });
                pad.end();
            },
            .scroll => {
                var rows = ui.list(c, .{ .count = 1_000_000, .row_height = 28 });
                while (rows.next()) |i| {
                    const row = ui.div(c).row().wFull().h(28).gap(8).px(4).itemsCenter();
                    defer row.end();
                    ui.textf(c, .{}, "Row {d}", .{i});
                    ui.spacer(c);
                    ui.text(c, "detail", .{ .color = th.muted });
                }
                rows.end();
            },
            .drag => {
                const rows = ui.div(c).wFull().hFull().column();
                for (0..30) |i| ui.textf(c, .{}, "Row {d} of the content under the box", .{i});
                rows.end();
                const box = ui.div(c).absolute().size(80, 80).bg(th.accent).offset(s.offset.x, s.offset.y);
                const it = box.interaction();
                if (it.pressed) {
                    const m = c.input.mouse;
                    if (c.input.pressed) s.grab = .{ .x = m.x - s.offset.x, .y = m.y - s.offset.y };
                    s.offset = .{ .x = m.x - s.grab.x, .y = m.y - s.grab.y };
                    c.changed = true;
                }
                box.end();
            },
            .anim, .heavy => {
                // Across the window every second, a frame each refresh.
                const t: f32 = @floatCast(@mod(c.time, 1));
                const n: usize = if (s.mode == .anim) 1 else s.boxes;
                for (0..n) |i| {
                    const fi: f32 = @floatFromInt(i);
                    const x = if (s.mode == .anim) t * 720 else @mod(fi, 20) * 36 + t * 80;
                    const y = if (s.mode == .anim) 100 else @floor(fi / 20) * 50 + 20;
                    var b = ui.div(c).absolute().offset(x, y).rounded(if (s.mode == .anim) 8 else 16).bg(th.accent);
                    b = if (s.mode == .anim) b.size(80, 80) else b.size(160, 120).shadow(.{ .color = .{ .a = 0.3 }, .blur = 48, .y = 8 });
                    b.end();
                }
                c.animationFrame();
            },
        }
        if (s.show_probe) {
            const p = ui.div(c).absolute().offset(probe.origin, probe.origin).size(probe.side, probe.side).bg(probe.color(s.seq));
            p.end();
        }
        root.end();
    }
};
