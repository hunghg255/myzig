//! The gallery's text: a text area, the code editor and the diff viewer,
//! rich text with its toolbar, and Markdown, rendered as it streams in.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const card = @import("basics.zig").card;

const before =
    \\const std = @import("std");
    \\
    \\pub fn main() void {
    \\    std.debug.print("Hello, {s}!\n", .{"world"});
    \\}
    \\
;

const after =
    \\const std = @import("std");
    \\
    \\/// Greets whoever is named on the command line.
    \\pub fn main(init: std.process.Init) !void {
    \\    const name = "myzig";
    \\    std.debug.print("Hello, {s}!\n", .{name});
    \\}
    \\
;

const rich =
    \\# Rich text
    \\
    \\Paragraphs with **bold**, *italic*, `code` and [links](https://ziglang.org), edited in place. Type `## ` for a heading, `- ` for a list.
    \\
    \\- Lists
    \\- [x] Checked tasks
    \\
    \\> Quotes, too.
;

pub const markdown_source =
    \\# Markdown
    \\
    \\CommonMark with GitHub's extensions: **strong**, *emphasis*, ~~strikethrough~~, `code`, and autolinks like https://ziglang.org.
    \\
    \\## Lists
    \\
    \\1. Ordered
    \\2. And nested:
    \\   - bullets
    \\   - [x] task lists
    \\   - [ ] not yet
    \\
    \\> A quote, with a [link](https://github.com/egoist/mygo).
    \\
    \\| Widget | Ported |
    \\|:-------|:------:|
    \\| Markdown | ✓ |
    \\| Charts | ✓ |
    \\
    \\```zig
    \\pub fn main() void {
    \\    const x: u32 = 42; // highlighted
    \\    _ = x;
    \\}
    \\```
    \\
    \\---
    \\
    \\Streaming shows a reply while it comes, healing what isn't closed yet: **like th
;

pub const TextPages = struct {
    gpa: std.mem.Allocator,
    area: ui.TextArea,
    editor: ui.CodeEditor,
    diff: ui.DiffView,
    rt: ui.RichText,
    md: ui.Markdown,
    stream: ui.Markdown,
    /// How much of the source the streaming copy shows.
    shown: usize = 0,
    streaming: bool = false,

    pub fn init(gpa: std.mem.Allocator) !TextPages {
        return .{
            .gpa = gpa,
            .area = .init(gpa, "A text area: several lines, wrapped, with undo, the clipboard and input methods."),
            .editor = .init(gpa, after, "main.zig"),
            .diff = try .init(gpa, before, after, "main.zig"),
            .rt = .initMarkdown(gpa, rich),
            .md = .init(gpa),
            .stream = .init(gpa),
        };
    }

    pub fn deinit(t: *TextPages) void {
        t.area.deinit();
        t.editor.deinit();
        t.diff.deinit();
        t.rt.deinit();
        t.md.deinit();
        t.stream.deinit();
    }

    pub fn editing(t: *TextPages, c: *ui.Context) void {
        const th = c.theme;
        ui.heading(c, "Text editing");
        {
            card(c, "Text area");
            defer ui.end(c);
            _ = ui.textArea(c, &t.area, .{ .lines = .{ 3, 8 }, .placeholder = "Write something" });
            ui.text(c, c.print("{d} bytes, line {d}", .{ t.area.len(), t.area.caretLine() + 1 }), .{ .size = 12, .color = th.muted });
        }
        {
            card(c, "Code editor");
            defer ui.end(c);
            ui.column(c, .{ .width = .fill, .height = .{ .px = 200 }, .border = th.border, .radius = 8, .clip = true });
            _ = ui.codeEditor(c, &t.editor, .{});
            ui.end(c);
        }
        {
            card(c, "Diff");
            defer ui.end(c);
            ui.column(c, .{ .width = .fill, .height = .{ .px = 220 }, .border = th.border, .radius = 8, .clip = true });
            ui.diffView(c, &t.diff, .{});
            ui.end(c);
        }
        {
            card(c, "Rich text");
            defer ui.end(c);
            ui.column(c, .{ .width = .fill, .border = th.border, .radius = 8, .clip = true });
            defer ui.end(c);
            _ = ui.richTextToolbar(c, &t.rt, .{});
            _ = ui.richTextEditor(c, &t.rt, .{ .bare = true, .padding = .xy(16, 12) });
        }
    }

    pub fn markdownPage(t: *TextPages, c: *ui.Context) void {
        const th = c.theme;
        ui.heading(c, "Markdown");
        {
            card(c, "Rendered");
            defer ui.end(c);
            _ = ui.markdown(c, markdown_source, .{ .state = &t.md });
        }
        {
            card(c, "Streaming");
            defer ui.end(c);
            ui.row(c, .{ .gap = 8, .align_items = .center });
            if (ui.button(c, if (t.streaming) "Streaming…" else "Stream it", .{ .disabled = t.streaming }).clicked) {
                t.shown = 0;
                t.streaming = true;
            }
            ui.text(c, c.print("{d} of {d} bytes", .{ t.shown, markdown_source.len }), .{ .size = 12, .color = th.muted });
            ui.end(c);
            if (t.streaming) {
                // A few bytes a frame, as a model's reply comes.
                t.shown = @min(markdown_source.len, t.shown + 6);
                while (t.shown < markdown_source.len and (markdown_source[t.shown] & 0xc0) == 0x80) t.shown += 1;
                if (t.shown == markdown_source.len) t.streaming = false else c.animationFrame();
            }
            if (t.shown > 0) _ = ui.markdown(c, markdown_source[0..t.shown], .{ .state = &t.stream, .streaming = t.streaming });
        }
    }
};
