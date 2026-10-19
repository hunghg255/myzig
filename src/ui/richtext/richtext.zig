//! The rich text editor: paragraphs with styles (headings, quotations,
//! code, bulleted, numbered and task lists nested by levels) of text with
//! marks (bold, italics, underline, strikethrough, code, links, colors),
//! edited as in Notes and Google Docs, with undo, the clipboard (its own
//! rich copy, plain text and Markdown), input methods, and only the blocks
//! in view built.
//!
//!     var note = ui.RichText.initMarkdown(gpa, "# Groceries\n\n- [ ] Milk");
//!     defer note.deinit();
//!     // In the view:
//!     _ = ui.richTextToolbar(c, &note, .{});
//!     if (ui.richTextEditor(c, &note, .{ .placeholder = "Write" }).changed) save(&note);
const model = @import("model.zig");

pub const RichText = @import("editor.zig").RichText;
pub const Doc = model.Doc;
pub const Block = model.Block;
pub const BlockStyle = model.BlockStyle;
pub const Kind = model.Kind;
pub const Marks = model.Marks;
pub const Mark = model.Mark;
pub const Toggle = model.Toggle;
pub const Pos = model.Pos;
pub const Sel = model.Sel;
pub const Formatting = @import("commands.zig").Formatting;
pub const FormatState = @import("commands.zig").State;
pub const ClipboardFormat = @import("clipboard.zig").Format;
pub const Options = @import("view.zig").Options;
pub const Result = @import("view.zig").Result;
pub const editor = @import("view.zig").richTextEditor;
pub const editorBase = @import("view.zig").view;
pub const toolbar = @import("toolbar.zig").richTextToolbar;
pub const ToolbarOptions = @import("toolbar.zig").Options;
pub const ToolbarResult = @import("toolbar.zig").Result;
pub const parseMarkdown = @import("markdown_in.zig").parse;
pub const writeMarkdown = @import("markdown_out.zig").write;

test {
    _ = model;
    _ = @import("history.zig");
    _ = @import("layout.zig");
    _ = @import("markdown_in.zig");
    _ = @import("markdown_out.zig");
}
