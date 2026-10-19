//! An assistant's chat that glows, after mygo's examples/chat-glow, drawn
//! with shaders written once (`*.zsl`): the orb (its avatar), the ring
//! around the composer, the shimmer of "Thinking…" (a box over the text
//! that reads it from the backdrop), and the window's edge glowing while
//! it answers.
//!
//!     zig build run-chat-glow
//!     zig-out/bin/chat-glow --myzig-snapshot=/tmp/chat.png --myzig-script="click:Plan three days in Kyoto;wait:2"
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const palette = @embedFile("palette.zsl");
pub const orb = ui.shader.compile("chat-orb", palette ++ @embedFile("orb.zsl"));
pub const ring = ui.shader.compile("chat-ring", palette ++ @embedFile("ring.zsl"));
pub const edge = ui.shader.compile("chat-edge", palette ++ @embedFile("edge.zsl"));
pub const shimmer = ui.shader.compile("chat-shimmer", @embedFile("shimmer.zsl"));

const think_time = 1.6;
const words_per_second = 28.0;
const fade_in = 0.35;
const fade_out = 0.9;
const liven = 0.5;
const ring_pad = 12;
const field_radius = 16;
const max_width = 660;

const suggestions = [_][]const u8{ "Summarize my week", "Draft a reply to the team", "Plan three days in Kyoto" };

const replies = [_][]const u8{
    "Here's your week at a glance.\n\nYou shipped the new onboarding flow on Tuesday, and sign-ups are up 18% since. Thursday's design review settled the navigation question: tabs stay, the sidebar goes. Two things still need you: the Q3 budget draft is due Monday, and Priya is waiting on your feedback for the pricing page.",
    "Here's a draft:\n\nHi all, thanks for pushing through this sprint. The release is on track for Friday; the remaining risk is the migration, which Sam is testing tonight. If anything slips, we'll cut the export feature and ship it the week after.",
    "Day 1: Higashiyama. Start at Kiyomizu-dera early, walk down Sannenzaka to Gion, and end with dinner in Pontocho.\n\nDay 2: Arashiyama. The bamboo grove at sunrise, Tenryu-ji's garden, then the river by boat.\n\nDay 3: Fushimi Inari before the crowds, and a last evening at Nishiki Market.",
};

const Message = struct {
    mine: bool,
    buf: [256]u8 = undefined,
    len: usize = 0,
    /// A reply's text, which shows a word at a time.
    reply: []const u8 = "",
    /// Words of the reply shown.
    shown: usize = 0,

    fn text(m: *const Message) []const u8 {
        return if (m.mine) m.buf[0..m.len] else prefix(m.reply, m.shown);
    }
};

/// The first `n` words of `s`, with the spaces after them.
pub fn prefix(s: []const u8, n: usize) []const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (i > 0 and isSpace(s[i - 1]) and !isSpace(s[i])) {
            count += 1;
            if (count == n) return s[0..i];
        }
    }
    return if (n == 0) "" else s;
}

fn words(s: []const u8) usize {
    var n: usize = 1;
    for (1..s.len) |i| {
        if (isSpace(s[i - 1]) and !isSpace(s[i])) n += 1;
    }
    return n;
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\n';
}

fn ease(x: f64) f32 {
    return @floatCast(x * x * (3 - 2 * x));
}

fn rgb(c: ui.Color) [3]f32 {
    return .{ c.r, c.g, c.b };
}

pub const Chat = struct {
    messages: [24]Message = undefined,
    n: usize = 0,
    input: ui.TextBuffer = .{},
    now: f64 = 0,
    last: ?f64 = null,
    asked: f64 = 0,
    writing: f64 = 0,
    busy: bool = false,
    glow: f64 = 0,
    energy: f64 = 0,
    orb_phase: f64 = 0,
    replies: usize = 0,

    pub fn view(a: *Chat, c: *ui.Context) void {
        const dt: f64 = if (a.last) |l| @max(c.time - l, 0) else 0;
        a.last = c.time;
        a.step(dt);
        if (a.busy or a.glow > 0 or a.energy > 0.01 or a.n == 0) c.animationFrame();
        if (c.input.key == .escape and a.busy) a.stop();

        ui.column(c, .{ .width = .fill, .height = .fill, .background = c.theme.background });
        defer ui.end(c);
        if (a.n == 0) a.welcome(c) else a.conversation(c);
        a.composer(c);
        if (a.glow > 0.001) {
            _ = ui.shaderBox(c, &edge, .{ .time = @as(f32, @floatCast(a.now)), .strength = ease(a.glow), .corner = 10 }, .{ .absolute = true, .width = .fill, .height = .fill });
            c.end();
        }
    }

    fn welcome(a: *Chat, c: *ui.Context) void {
        ui.column(c, .{ .grow = 1, .width = .fill, .align_items = .center, .justify = .center, .gap = 10, .padding = .{ .top = 40, .left = 24, .right = 24 } });
        defer ui.end(c);
        _ = ui.shaderBox(c, &orb, .{ .phase = @as(f32, @floatCast(a.orb_phase)), .energy = @as(f32, @floatCast(a.energy)) }, .{ .width = .{ .px = 150 }, .height = .{ .px = 150 } });
        c.end();
        ui.text(c, "How can I help?", .{ .size = 28, .weight = .semibold });
        ui.text(c, "Ask anything, or start with one of these.", .{ .size = 14, .color = c.theme.muted });
        ui.row(c, .{ .gap = 8, .padding = .{ .top = 18 } });
        defer ui.end(c);
        for (suggestions) |s| {
            ui.key(c, s);
            const chip = ui.pressable(c, .{ .padding = .xy(14, 9), .radius = 999, .border = c.theme.border }, c.theme.surface_hover);
            ui.text(c, s, .{ .size = 13 });
            ui.end(c);
            if (chip.clicked) a.send(s);
        }
    }

    fn conversation(a: *Chat, c: *ui.Context) void {
        ui.scroll(c, .{ .grow = 1, .width = .fill, .padding = .{ .top = 52, .left = 24, .right = 24, .bottom = 16 }, .gap = 22, .follow_end = true });
        defer ui.end(c);
        for (a.messages[0..a.n], 0..) |*m, i| {
            ui.row(c, .{ .width = .fill, .justify = .center });
            defer ui.end(c);
            ui.column(c, .{ .grow = 1, .max_width = max_width });
            defer ui.end(c);
            a.message(c, m, i + 1 == a.n);
        }
    }

    fn message(a: *Chat, c: *ui.Context, m: *const Message, last: bool) void {
        const t = c.theme;
        if (m.mine) {
            ui.row(c, .{ .width = .fill });
            defer ui.end(c);
            ui.spacer(c);
            _ = c.open(.{ .padding = .xy(14, 9), .radius = 18, .background = t.surface, .max_width = 460 }, null);
            ui.text(c, m.text(), .{ .wrap = true });
            c.end();
            return;
        }
        ui.row(c, .{ .width = .fill, .gap = 12 });
        defer ui.end(c);
        // The avatar: the orb, still but for the last reply's.
        const phase: f32 = if (last) @floatCast(a.orb_phase) else @floatFromInt(@intFromPtr(m) % 7);
        _ = ui.shaderBox(c, &orb, .{ .phase = phase, .energy = if (last) @as(f32, @floatCast(a.energy)) else 0 }, .{ .width = .{ .px = 30 }, .height = .{ .px = 30 } });
        c.end();
        if (m.shown == 0 and last and a.busy) {
            // The text, and over it the shimmer, which reads it.
            _ = c.open(.{ .padding = .{ .top = 5 } }, null);
            defer c.end();
            ui.text(c, "Thinking…", .{ .size = 15, .color = t.muted });
            _ = ui.shaderBox(c, &shimmer, .{
                .time = @as(f32, @floatCast(a.now)),
                .base = rgb(t.muted),
                .shine = rgb(t.text),
                .background = rgb(t.background),
            }, .{ .absolute = true, .width = .fill, .height = .fill });
            c.end();
            return;
        }
        _ = c.open(.{ .grow = 1, .padding = .{ .top = 5 } }, null);
        ui.text(c, m.text(), .{ .size = 15, .wrap = true, .leading = 1.5 });
        c.end();
    }

    fn composer(a: *Chat, c: *ui.Context) void {
        const t = c.theme;
        ui.row(c, .{ .width = .fill, .justify = .center, .padding = .{ .left = 24 - ring_pad, .right = 24 - ring_pad, .bottom = 22 - ring_pad } });
        defer ui.end(c);
        const strength: f32 = 0.25 + 0.75 * ease(a.glow);
        _ = ui.shaderBox(c, &ring, .{ .time = @as(f32, @floatCast(a.now)), .strength = strength, .pad = ring_pad, .radius = field_radius }, .{ .direction = .row, .grow = 1, .max_width = max_width + 2 * ring_pad, .padding = .all(ring_pad) });
        defer c.end();
        ui.row(c, .{ .grow = 1, .align_items = .center, .gap = 8, .padding = .{ .top = 6, .bottom = 6, .right = 6, .left = 16 }, .radius = field_radius, .background = t.surface });
        defer ui.end(c);
        const in = ui.textField(c, &a.input, .{ .placeholder = "Ask anything", .width = .fill, .bare = true, .label = "Message" });
        const ready = std.mem.trim(u8, a.input.text(), " \n").len > 0;
        const button = ui.pressable(c, .{ .width = .{ .px = 34 }, .height = .{ .px = 34 }, .radius = 17, .align_items = .center, .justify = .center, .background = if (a.busy or ready) t.text else t.border }, null);
        if (a.busy) {
            _ = c.leaf(.{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .radius = 2, .background = t.background }, .none, null);
        } else ui.icon(c, "arrow.up", .{ .size = 16, .color = t.background });
        ui.end(c);
        if (a.busy) {
            if (button.clicked) a.stop();
        } else if ((button.clicked or in.submitted) and ready) {
            a.send(a.input.text());
        }
    }

    pub fn send(a: *Chat, text_in: []const u8) void {
        if (a.n + 2 > a.messages.len) a.n = 0;
        const text = std.mem.trim(u8, text_in, " \n");
        var m: Message = .{ .mine = true };
        m.len = @min(text.len, m.buf.len);
        @memcpy(m.buf[0..m.len], text[0..m.len]);
        a.messages[a.n] = m;
        // A suggestion's own reply, else the next.
        var r = a.replies % replies.len;
        for (suggestions, 0..) |s, i| if (std.mem.eql(u8, s, text)) {
            r = i;
        };
        a.messages[a.n + 1] = .{ .mine = false, .reply = replies[r] };
        a.n += 2;
        a.replies += 1;
        a.input.set("");
        a.asked = a.now;
        a.writing = 0;
        a.busy = true;
    }

    fn stop(a: *Chat) void {
        a.busy = false;
        const m = &a.messages[a.n - 1];
        if (!m.mine and m.shown == 0) {
            m.reply = "Stopped.";
            m.shown = 1;
        }
    }

    /// Time goes by: the reply thinks, then shows a word at a time; the
    /// glow fades in while busy and out after; the orb livens up.
    pub fn step(a: *Chat, dt: f64) void {
        a.now += dt;
        if (a.busy) {
            const m = &a.messages[a.n - 1];
            if (a.writing == 0 and a.now - a.asked >= think_time) a.writing = a.asked + think_time;
            if (a.writing > 0) {
                const total = words(m.reply);
                m.shown = @min(total, @as(usize, @intFromFloat((a.now - a.writing) * words_per_second)) + 1);
                if (m.shown == total) a.busy = false;
            }
        }
        a.glow = if (a.busy) @min(1, a.glow + dt / fade_in) else @max(0, a.glow - dt / fade_out);
        const goal: f64 = if (a.busy) 1 else 0;
        a.energy += (goal - a.energy) * (1 - @exp(-dt / liven));
        a.orb_phase += dt * (0.5 + 1.8 * a.energy);
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Chat Glow" });
    defer app.destroy();
    var state: Chat = .{};
    _ = try app.newWindow(.{
        .title = "Chat Glow",
        .width = 760,
        .height = 560,
        .content = .{ .view = .init(&state, Chat.view) },
    });
    try app.run();
}

test "words show a few at a time" {
    try std.testing.expectEqualStrings("Day 1: ", prefix("Day 1: Higashiyama.", 2));
    try std.testing.expectEqualStrings("", prefix("Day 1", 0));
    try std.testing.expectEqual(@as(usize, 3), words("a b\n\nc"));
}

test "a suggestion asks: the shimmer thinks, the reply streams in, the edge glows and fades" {
    var a: Chat = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&a, Chat.view), .{ .width = 480, .height = 360, .scale = 1 });
    defer t.deinit();
    t.frame();
    try std.testing.expect(t.hasText("How can I help?"));
    try t.clickText("Plan three days in Kyoto");
    t.advance(0.5);
    try std.testing.expect(a.busy and a.glow > 0.9);
    try std.testing.expect(t.hasText("Thinking…"));
    // The shimmer box lies over the text and draws it again, brighter in its band.
    const px = try t.render(std.testing.allocator);
    px.deinit(std.testing.allocator);
    t.advance(1.6);
    try std.testing.expect(!t.hasText("Thinking…"));
    try std.testing.expect(t.containsText("Day 1"));
    t.advance(12);
    try std.testing.expect(!a.busy);
    try std.testing.expect(a.glow == 0);
}
