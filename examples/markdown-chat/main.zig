//! A chat with a pretend language model whose replies stream in as
//! Markdown, a few bytes at a time on the view's clock (no network):
//! `ui.markdown` with `.streaming` shows a reply while it comes, parsing
//! only its end, and the list follows the end as it grows.
//!
//!     zig build run-markdown-chat
//!     zig-out/bin/markdown-chat --myzig-snapshot=chat.png --myzig-script="wait:3"
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

/// Bytes of a reply shown per second, a token of a few bytes at a time.
const rate: f64 = 240;
const token = 5;

const Message = struct {
    mine: bool,
    /// The user's text, or the reply's.
    text: []const u8,
    buf: [512]u8 = undefined,
    md: ui.Markdown,
    /// When the reply started on the view's clock, and how much of it shows.
    start: ?f64 = null,
    shown: usize = 0,
    done: bool = false,
};

const Chat = struct {
    gpa: std.mem.Allocator,
    messages: [32]Message = undefined,
    count: usize = 0,
    input: ui.TextBuffer = .{},
    replies: usize = 0,

    fn add(s: *Chat, mine: bool, text: []const u8) void {
        if (s.count == s.messages.len) s.drop();
        const m = &s.messages[s.count];
        m.* = .{ .mine = mine, .text = text, .md = .init(s.gpa), .done = mine };
        if (mine) {
            const n = @min(text.len, m.buf.len);
            @memcpy(m.buf[0..n], text[0..n]);
            m.text = m.buf[0..n];
        }
        s.count += 1;
    }

    /// Forgets the oldest exchange.
    fn drop(s: *Chat) void {
        for (s.messages[0..2]) |*m| m.md.deinit();
        std.mem.copyForwards(Message, s.messages[0 .. s.count - 2], s.messages[2..s.count]);
        s.count -= 2;
        for (s.messages[0..s.count]) |*m| if (m.mine) {
            m.text = m.buf[0..m.text.len];
        };
    }

    fn send(s: *Chat, question: []const u8) void {
        if (std.mem.trim(u8, question, " ").len == 0 or s.streaming()) return;
        s.add(true, question);
        s.add(false, replies[s.replies % replies.len]);
        s.replies += 1;
    }

    fn streaming(s: *const Chat) bool {
        return s.count > 0 and !s.messages[s.count - 1].done;
    }

    fn deinit(s: *Chat) void {
        for (s.messages[0..s.count]) |*m| m.md.deinit();
    }

    fn view(s: *Chat, c: *ui.Context) void {
        const t = c.theme;
        ui.column(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);

        ui.row(c, .{ .width = .fill, .padding = .xy(20, 10), .align_items = .center, .gap = 8 });
        ui.text(c, "Markdown chat", .{ .size = 15, .weight = .semibold });
        ui.spacer(c);
        if (s.streaming() and ui.button(c, "Stop", .{ .size = 13 }).clicked) s.messages[s.count - 1].done = true;
        ui.end(c);
        ui.divider(c);

        ui.scroll(c, .{ .width = .fill, .grow = 1, .height = .fill, .padding = .all(20), .gap = 18, .follow_end = true });
        if (s.count == 0) ui.text(c, "Ask anything: the replies are canned, streamed as a model streams them.", .{ .color = t.muted, .wrap = true });
        for (s.messages[0..s.count], 0..) |*m, i| {
            c.next_key_int = i;
            s.message(c, m);
        }
        ui.end(c);
        ui.divider(c);

        ui.row(c, .{ .width = .fill, .padding = .all(12), .gap = 8, .align_items = .center });
        const r = ui.textField(c, &s.input, .{ .placeholder = "Message", .width = .fill });
        const clicked = ui.button(c, "Send", .{ .variant = .primary, .disabled = s.streaming() }).clicked;
        if (r.submitted or clicked) {
            s.send(s.input.text());
            s.input.clear();
            c.changed = true;
        }
        ui.end(c);
    }

    fn message(s: *Chat, c: *ui.Context, m: *Message) void {
        _ = s;
        const t = c.theme;
        if (m.mine) {
            ui.row(c, .{ .width = .fill });
            ui.spacer(c);
            _ = c.open(.{ .padding = .xy(12, 8), .radius = 14, .background = t.surface, .max_width = 420, .selectable = true }, null);
            ui.text(c, m.text, .{ .wrap = true });
            ui.end(c);
            ui.end(c);
            return;
        }
        // The reply so far: tokens of a few bytes on the view's clock.
        if (!m.done) {
            const start = m.start orelse blk: {
                m.start = c.time;
                break :blk c.time;
            };
            const tokens: usize = @intFromFloat(@max(0, (c.time - start) * rate / token));
            var n = @min(m.text.len, tokens * token);
            while (n < m.text.len and m.text[n] & 0xC0 == 0x80) n += 1;
            m.shown = n;
            if (n == m.text.len) m.done = true else c.animationFrame();
        } else if (m.shown == 0) m.shown = m.text.len;
        ui.column(c, .{ .width = .fill, .max_width = 700 });
        const res = ui.markdown(c, m.text[0..m.shown], .{ .state = &m.md, .streaming = !m.done });
        if (res.link) |url| _ = myzig.shell.openUrl(url);
        ui.end(c);
    }
};

const replies = [_][]const u8{
    \\Here is a small **LRU cache** in Zig: a hash map for lookups and a
    \\doubly linked list for the order of use.
    \\
    \\```zig
    \\const std = @import("std");
    \\
    \\pub fn Lru(comptime V: type) type {
    \\    return struct {
    \\        map: std.StringHashMapUnmanaged(*Node) = .empty,
    \\        order: std.DoublyLinkedList = .{},
    \\        cap: usize,
    \\
    \\        const Node = struct { key: []const u8, value: V, link: std.DoublyLinkedList.Node = .{} };
    \\
    \\        // Moves the entry to the front: it was just used.
    \\        pub fn get(self: *@This(), key: []const u8) ?V {
    \\            const n = self.map.get(key) orelse return null;
    \\            self.order.remove(&n.link);
    \\            self.order.prepend(&n.link);
    \\            return n.value;
    \\        }
    \\    };
    \\}
    \\```
    \\
    \\A few things to note:
    \\
    \\1. `get` changes the order, so it needs `*@This()`, not `*const`.
    \\2. Evict from the **back** of the list once `map.count() > cap`.
    \\3. For heavy read traffic, consider *sharding* by the key's hash.
    \\
,
    \\## Comparing the options
    \\
    \\| Strategy | Read latency | Staleness | Complexity |
    \\|---|--:|:-:|---|
    \\| No cache | ~41 ms | none | trivial |
    \\| Cache-aside | ~0.2 ms | medium | low |
    \\| Write-through | ~0.2 ms | low | medium |
    \\
    \\> **Tip:** start with *cache-aside*; move to write-through once
    \\> staleness bites.
    \\
    \\See [Zig's documentation](https://ziglang.org/documentation/master/) for the
    \\standard library's hash maps, or www.ziglang.org for the rest.
    \\
,
    \\Sure, here is the plan:
    \\
    \\- [x] Measure the radius
    \\- [x] Square it
    \\- [ ] Multiply by `std.math.pi`
    \\  - in `f64`, ~~not `f16`~~
    \\  - or with `@as(f32, ...)` when a float of 32 bits is enough
    \\
    \\```sh
    \\zig build run-markdown-chat
    \\```
    \\
    \\That's all there is to it.
    \\
,
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "Markdown chat" });
    defer app.destroy();
    var chat: Chat = .{ .gpa = init.gpa };
    defer chat.deinit();
    chat.send("How do I write an LRU cache in Zig?");
    _ = try app.newWindow(.{
        .title = "Markdown chat",
        .width = 720,
        .height = 820,
        .min_width = 420,
        .min_height = 360,
        .content = .{ .view = .init(&chat, Chat.view) },
    });
    try app.run();
}
