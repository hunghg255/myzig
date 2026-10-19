//! A terminal emulator, libghostty-vt's, in Zig's terms: the screen, its
//! scrollback, the cursor and the modes that the output of programs
//! changes (`Vt`), and what a frame draws of it (`Render`). Load the
//! library first (`library.load`). Nothing here is safe for concurrent
//! use: callers serialize the calls on a `Vt` and what is made from it.
const std = @import("std");
const g = @import("ghostty.zig");
const layouts = @import("layouts.zig");

pub const Rgb = g.Rgb;
pub const GridRef = g.GridRef;
pub const Selection = g.Selection;
pub const Scrollbar = g.Scrollbar;

/// What a terminal asks of its embedder while it processes output, all
/// optional; they run during `Vt.write`, which they must not call.
pub const Effects = struct {
    ctx: ?*anyopaque = null,
    /// Answers the program, as to a query of the cursor's position.
    write_pty: ?*const fn (ctx: ?*anyopaque, bytes: []const u8) void = null,
    bell: ?*const fn (ctx: ?*anyopaque) void = null,
    title_changed: ?*const fn (ctx: ?*anyopaque) void = null,
    /// The screen in cells and a cell in pixels: cols, rows, width, height.
    size: ?*const fn (ctx: ?*anyopaque) [4]u32 = null,
};

/// DEC private modes (and ANSI ones with bit 15) by number.
pub const Mode = enum(u16) {
    cursor_keys = 1,
    cursor_visible = 25,
    focus_event = 1004,
    alt_scroll = 1007,
    bracketed_paste = 2004,
    sync_output = 2026,
    graphemes = 2027,
    _,
};

pub const CursorStyle = enum(i32) { bar = 0, block = 1, underline = 2, block_hollow = 3 };

pub const Error = error{ GhosttyNotLoaded, OutOfMemory, GhosttyFailed };

fn ok(r: g.Result) Error!void {
    if (r == g.success) return;
    return if (r == -1) error.OutOfMemory else error.GhosttyFailed;
}

fn clamp16(v: usize) usize {
    return @max(1, @min(v, 0xFFFF));
}

pub const Vt = struct {
    h: *g.Terminal,

    /// A terminal of `cols` by `rows` cells. `effects` must stay where it
    /// is while the terminal lives: the library calls back with it.
    pub fn init(cols: usize, rows: usize, effects: *const Effects) Error!Vt {
        if (!g.loaded()) return error.GhosttyNotLoaded;
        var h: ?*g.Terminal = null;
        try ok(g.api.ghostty_terminal_new(null, &h, clamp16(cols), clamp16(rows)));
        const t: Vt = .{ .h = h orelse return error.GhosttyFailed };
        _ = g.api.ghostty_terminal_set(t.h, .userdata, effects);
        _ = g.api.ghostty_terminal_set(t.h, .write_pty, @ptrCast(&cbWritePty));
        _ = g.api.ghostty_terminal_set(t.h, .bell, @ptrCast(&cbBell));
        _ = g.api.ghostty_terminal_set(t.h, .title_changed, @ptrCast(&cbTitle));
        _ = g.api.ghostty_terminal_set(t.h, .size, @ptrCast(&cbSize));
        _ = g.api.ghostty_terminal_set(t.h, .device_attributes, @ptrCast(&cbAttributes));
        // Images of the Kitty graphics protocol are not drawn: refuse
        // them, so that programs fall back to something else.
        const limit: u64 = 0;
        _ = g.api.ghostty_terminal_set(t.h, .kitty_image_storage_limit, &limit);
        return t;
    }

    pub fn deinit(t: Vt) void {
        g.api.ghostty_terminal_free(t.h);
    }

    /// Processes output of the program: text and escape sequences.
    pub fn write(t: Vt, bytes: []const u8) void {
        if (bytes.len > 0) g.api.ghostty_terminal_vt_write(t.h, bytes.ptr, bytes.len);
    }

    /// Sets the size of the screen in cells, and of a cell in pixels.
    pub fn resize(t: Vt, cols: usize, rows: usize, cell_w: usize, cell_h: usize) void {
        _ = g.api.ghostty_terminal_resize(t.h, clamp16(cols), clamp16(rows), @max(cell_w, 1), @max(cell_h, 1));
    }

    fn get16(t: Vt, d: g.Data) u16 {
        var v: u16 = 0;
        _ = g.api.ghostty_terminal_get(t.h, d, &v);
        return v;
    }

    /// The size of the screen in cells.
    pub fn size(t: Vt) [2]u16 {
        return .{ t.get16(.cols), t.get16(.rows) };
    }

    /// The cursor's column and row in the active screen.
    pub fn cursor(t: Vt) [2]u16 {
        return .{ t.get16(.cursor_x), t.get16(.cursor_y) };
    }

    /// Resets the terminal fully (RIS).
    pub fn reset(t: Vt) void {
        g.api.ghostty_terminal_reset(t.h);
    }

    /// The default colors, which programs may change: the cursor's takes
    /// the text's when null.
    pub fn setColors(t: Vt, fg: Rgb, bg: Rgb, cursor_color: ?Rgb, palette: *const [256]Rgb) void {
        _ = g.api.ghostty_terminal_set(t.h, .color_foreground, &fg);
        _ = g.api.ghostty_terminal_set(t.h, .color_background, &bg);
        if (cursor_color) |c| {
            _ = g.api.ghostty_terminal_set(t.h, .color_cursor, &c);
        } else _ = g.api.ghostty_terminal_set(t.h, .color_cursor, null);
        _ = g.api.ghostty_terminal_set(t.h, .color_palette, palette);
    }

    /// Keeps about `bytes` of output above the screen.
    pub fn setScrollback(t: Vt, bytes: usize) void {
        const v: usize = bytes;
        _ = g.api.ghostty_terminal_set(t.h, .scrollback_max_bytes, &v);
    }

    /// The name of the terminfo entry the terminal reports (XTGETTCAP TN).
    pub fn setTerminfoName(t: Vt, name: []const u8) void {
        const s: g.String = .{ .ptr = name.ptr, .len = name.len };
        _ = g.api.ghostty_terminal_set(t.h, .terminfo_name, &s);
    }

    /// The cursor programs reset to (DECSCUSR 0).
    pub fn setDefaultCursor(t: Vt, style: CursorStyle, blink: bool) void {
        const s: i32 = @intFromEnum(style);
        _ = g.api.ghostty_terminal_set(t.h, .default_cursor_style, &s);
        _ = g.api.ghostty_terminal_set(t.h, .default_cursor_blink, &blink);
    }

    /// Whether growing the screen pulls rows back from the scrollback,
    /// which ConPTY, keeping a screen of its own, cannot follow.
    pub fn setResizePullBack(t: Vt, on: bool) void {
        _ = g.api.ghostty_terminal_set(t.h, .resize_pull_scrollback, &on);
    }

    fn str(t: Vt, d: g.Data) []const u8 {
        var s: g.String = .{};
        if (g.api.ghostty_terminal_get(t.h, d, &s) != g.success) return "";
        const p = s.ptr orelse return "";
        return p[0..@intCast(s.len)];
    }

    /// The title programs set (OSC 0, OSC 2), until the terminal changes.
    pub fn title(t: Vt) []const u8 {
        return t.str(.title);
    }

    /// The working directory the shell reported (OSC 7), as it did.
    pub fn pwd(t: Vt) []const u8 {
        return t.str(.pwd);
    }

    pub fn mode(t: Vt, m: Mode) bool {
        var c: g.ModeConfig = .{ .mode = @intFromEnum(m) };
        return g.api.ghostty_terminal_get(t.h, .mode, &c) == g.success and c.value;
    }

    pub fn setMode(t: Vt, m: Mode, on: bool) void {
        const c: g.ModeConfig = .{ .mode = @intFromEnum(m), .value = on };
        _ = g.api.ghostty_terminal_set(t.h, .mode, &c);
    }

    /// Sets a mode, and the value a reset restores.
    pub fn setModeDefault(t: Vt, m: Mode, on: bool) void {
        const c: g.ModeConfig = .{ .mode = @intFromEnum(m), .value = on };
        _ = g.api.ghostty_terminal_set(t.h, .mode_default, &c);
    }

    /// Whether a program asked for mouse events.
    pub fn mouseTracking(t: Vt) bool {
        var v: bool = false;
        return g.api.ghostty_terminal_get(t.h, .mouse_tracking, &v) == g.success and v;
    }

    /// Whether the alternate screen shows, as in full-screen programs.
    pub fn altScreen(t: Vt) bool {
        var v: i32 = 0;
        return g.api.ghostty_terminal_get(t.h, .active_screen, &v) == g.success and v == 1;
    }

    /// Where the viewport is in the scrollback.
    pub fn scrollbar(t: Vt) Scrollbar {
        var s: Scrollbar = .{};
        _ = g.api.ghostty_terminal_get(t.h, .scrollbar, &s);
        return s;
    }

    /// Whether the viewport follows the active screen.
    pub fn atBottom(t: Vt) bool {
        var v: bool = true;
        _ = g.api.ghostty_terminal_get(t.h, .viewport_active, &v);
        return v;
    }

    pub fn scrollToTop(t: Vt) void {
        g.api.ghostty_terminal_scroll_viewport(t.h, .{ .tag = g.ScrollViewport.top });
    }

    pub fn scrollToBottom(t: Vt) void {
        g.api.ghostty_terminal_scroll_viewport(t.h, .{ .tag = g.ScrollViewport.bottom });
    }

    /// Moves the viewport by `rows`, negative up.
    pub fn scrollBy(t: Vt, rows: i64) void {
        g.api.ghostty_terminal_scroll_viewport(t.h, .{ .tag = g.ScrollViewport.delta, .value = .{ @bitCast(rows), 0 } });
    }

    fn ref(t: Vt, tag: i32, x: usize, y: usize) ?GridRef {
        var r: GridRef = .{};
        const p: g.Point = .{ .tag = tag, .value = .{ .x = @intCast(@min(x, 0xFFFF)), .y = @intCast(@min(y, 0xFFFF_FFFF)) } };
        return if (g.api.ghostty_terminal_grid_ref(t.h, p, &r) == g.success) r else null;
    }

    /// The cell at column `x` of row `y` of the viewport.
    pub fn cellAt(t: Vt, x: usize, y: usize) ?GridRef {
        return t.ref(g.Point.viewport, x, y);
    }

    /// The cell at column `x` of row `y` of the screen and its scrollback,
    /// from the top of the scrollback (`scrollbar().offset` + a row of the
    /// viewport).
    pub fn screenCell(t: Vt, x: usize, y: usize) ?GridRef {
        return t.ref(g.Point.screen, x, y);
    }

    /// The raw packed cell of a reference.
    pub fn rawCell(_: Vt, r: GridRef) u64 {
        var v: u64 = 0;
        _ = g.api.ghostty_grid_ref_cell(&r, &v);
        return v;
    }

    /// The codepoints of a cell into `buf`: none for an empty cell.
    pub fn graphemes(_: Vt, r: GridRef, buf: []u32) []const u32 {
        var n: usize = 0;
        if (g.api.ghostty_grid_ref_graphemes(&r, buf.ptr, buf.len, &n) != g.success) return buf[0..0];
        return buf[0..@min(n, buf.len)];
    }

    /// The URI of a cell's hyperlink (OSC 8), into `buf`, or null.
    pub fn hyperlink(_: Vt, r: GridRef, buf: []u8) ?[]const u8 {
        var n: usize = 0;
        if (g.api.ghostty_grid_ref_hyperlink_uri(&r, buf.ptr, buf.len, &n) != g.success or n == 0) return null;
        return buf[0..@min(n, buf.len)];
    }

    /// Selects `s`, or nothing.
    pub fn setSelection(t: Vt, s: ?*const Selection) void {
        _ = g.api.ghostty_terminal_set(t.h, .selection, s);
    }

    /// The selection's text, with soft-wrapped lines joined and trailing
    /// spaces trimmed, as Ghostty copies it; null without a selection.
    pub fn selectionText(t: Vt, gpa: std.mem.Allocator) ?[]u8 {
        var p: ?[*]u8 = null;
        var n: usize = 0;
        if (g.api.ghostty_terminal_selection_format_alloc(t.h, null, .{ .unwrap = true, .trim = true }, &p, &n) != g.success) return null;
        return takeString(gpa, p, n);
    }

    /// The text of the screen and its scrollback, soft-wrapped lines
    /// joined and trailing spaces trimmed.
    pub fn text(t: Vt, gpa: std.mem.Allocator) []u8 {
        return t.format(gpa, .{ .unwrap = true, .trim = true }) orelse gpa.alloc(u8, 0) catch &.{};
    }

    /// The terminal's state as escape sequences, which restore it in a
    /// terminal of the same size: scrollback, screen, styles, modes, cursor.
    pub fn snapshot(t: Vt, gpa: std.mem.Allocator) ?[]u8 {
        return t.format(gpa, .{ .emit = 1, .extra = .{
            .modes = true,
            .scrolling_region = true,
            .tabstops = true,
            .pwd = true,
            .keyboard = true,
            .screen = .{ .cursor = true, .style = true, .hyperlink = true, .protection = true, .kitty_keyboard = true, .charsets = true },
        } });
    }

    fn format(t: Vt, gpa: std.mem.Allocator, opts: g.FormatterTerminalOptions) ?[]u8 {
        var f: ?*g.Formatter = null;
        if (g.api.ghostty_formatter_terminal_new(null, &f, t.h, opts) != g.success) return null;
        const fmt = f orelse return null;
        defer g.api.ghostty_formatter_free(fmt);
        var p: ?[*]u8 = null;
        var n: usize = 0;
        if (g.api.ghostty_formatter_format_alloc(fmt, null, &p, &n) != g.success) return null;
        return takeString(gpa, p, n);
    }
};

/// Copies a string the library allocated into `gpa`'s memory, and frees it.
fn takeString(gpa: std.mem.Allocator, p: ?[*]u8, n: usize) ?[]u8 {
    const ptr = p orelse return gpa.alloc(u8, 0) catch null;
    defer g.api.ghostty_free(null, ptr, n);
    return gpa.dupe(u8, ptr[0..n]) catch null;
}

fn effectsOf(ud: ?*anyopaque) ?*const Effects {
    return @ptrCast(@alignCast(ud orelse return null));
}

fn cbWritePty(_: *g.Terminal, ud: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) void {
    const e = effectsOf(ud) orelse return;
    if (e.write_pty) |f| if (len > 0) f(e.ctx, data[0..len]);
}

fn cbBell(_: *g.Terminal, ud: ?*anyopaque) callconv(.c) void {
    const e = effectsOf(ud) orelse return;
    if (e.bell) |f| f(e.ctx);
}

fn cbTitle(_: *g.Terminal, ud: ?*anyopaque) callconv(.c) void {
    const e = effectsOf(ud) orelse return;
    if (e.title_changed) |f| f(e.ctx);
}

fn cbSize(_: *g.Terminal, ud: ?*anyopaque, out: *g.SizeReportSize) callconv(.c) bool {
    const e = effectsOf(ud) orelse return false;
    const f = e.size orelse return false;
    const s = f(e.ctx);
    out.* = .{ .columns = @intCast(clamp16(s[0])), .rows = @intCast(clamp16(s[1])), .cell_width = @max(s[2], 1), .cell_height = @max(s[3], 1) };
    return true;
}

fn cbAttributes(_: *g.Terminal, _: ?*anyopaque, out: *g.DeviceAttributes) callconv(.c) bool {
    // As Ghostty answers: a VT220 with ANSI colors (DA1), of type 1 and
    // version 10 (DA2).
    out.* = .{ .primary = .{ .conformance_level = 62, .num_features = 1 }, .secondary = .{ .device_type = 1, .firmware_version = 10 } };
    out.primary.features[0] = 22;
    return true;
}

/// How wide a cell's character is.
pub const Wide = enum(u2) { narrow = 0, wide = 1, spacer_tail = 2, spacer_head = 3 };

/// A cell of a row of a frame.
pub const Cell = struct {
    /// The character, 0 for none; `grapheme` tells more codepoints follow.
    codepoint: u21 = 0,
    grapheme: bool = false,
    /// The cell's style among the row's: 0 is the default.
    style_id: u16 = 0,
    wide: Wide = .narrow,
    hyperlink: bool = false,
    /// The background of a cell without text whose background a program
    /// filled: a palette index when `bg_palette`.
    bg: ?Rgb = null,
    bg_palette: bool = false,
};

/// Decodes a packed GhosttyCell, by the bits the library reported.
pub fn decodeCell(raw: u64) Cell {
    const b = &layouts.cell;
    var out: Cell = .{};
    switch (b.tag.of(raw)) {
        0, 1 => |tag| {
            out.codepoint = @intCast(b.codepoint.of(raw) & 0x1FFFFF);
            out.grapheme = tag == 1;
        },
        2 => {
            out.bg = .{ .r = @intCast(b.palette_index.of(raw)) };
            out.bg_palette = true;
        },
        else => out.bg = .{ .r = @intCast(b.r.of(raw)), .g = @intCast(b.g.of(raw)), .b = @intCast(b.b.of(raw)) },
    }
    out.style_id = @intCast(b.style_id.of(raw));
    out.wide = @enumFromInt(@as(u2, @intCast(b.wide.of(raw))));
    out.hyperlink = b.hyperlink.of(raw) != 0;
    return out;
}

pub const Style = g.Style;
pub const StyleColor = g.StyleColor;
pub const Colors = g.RenderColors;
pub const Cursor = g.RenderCursor;

/// What a frame draws of a terminal, copied from it by `update`: rows,
/// their cells and styles, the cursor and the colors.
pub const Render = struct {
    h: *g.RenderState,
    rows: *g.RowIterator,
    cells: *g.RowCells,

    pub fn init() Error!Render {
        if (!g.loaded()) return error.GhosttyNotLoaded;
        var h: ?*g.RenderState = null;
        try ok(g.api.ghostty_render_state_new(null, &h));
        errdefer g.api.ghostty_render_state_free(h.?);
        var it: ?*g.RowIterator = null;
        try ok(g.api.ghostty_render_state_row_iterator_new(null, &it));
        errdefer g.api.ghostty_render_state_row_iterator_free(it.?);
        var cells: ?*g.RowCells = null;
        try ok(g.api.ghostty_render_state_row_cells_new(null, &cells));
        return .{ .h = h.?, .rows = it.?, .cells = cells.? };
    }

    pub fn deinit(r: Render) void {
        g.api.ghostty_render_state_row_cells_free(r.cells);
        g.api.ghostty_render_state_row_iterator_free(r.rows);
        g.api.ghostty_render_state_free(r.h);
    }

    /// Copies the terminal's state: the only call that needs the terminal.
    pub fn update(r: Render, t: Vt) void {
        if (g.api.ghostty_render_state_begin_update(r.h, t.h) == g.success) g.api.ghostty_render_state_end_update(r.h);
    }

    pub fn colors(r: Render) Colors {
        var c: Colors = .{};
        _ = g.api.ghostty_render_state_get(r.h, g.rs_colors, &c);
        return c;
    }

    pub fn cursor(r: Render) Cursor {
        var c: Cursor = .{};
        _ = g.api.ghostty_render_state_get(r.h, g.rs_cursor, &c);
        return c;
    }

    /// Starts going through the rows, top to bottom, with `nextRow`.
    pub fn beginRows(r: *Render) void {
        var it: ?*g.RowIterator = r.rows;
        _ = g.api.ghostty_render_state_get(r.h, g.rs_row_iterator, @ptrCast(&it));
        if (it) |p| r.rows = p;
    }

    pub fn nextRow(r: Render) bool {
        return g.api.ghostty_render_state_row_iterator_next(r.rows);
    }

    /// The raw cells of the current row, valid until the next update;
    /// selects the row for `style` and `graphemes`.
    pub fn rowCells(r: *Render) []const u64 {
        var v: g.CellsView = .{};
        if (g.api.ghostty_render_state_row_get(r.rows, g.row_cells_raw, &v) != g.success) return &.{};
        var cells: ?*g.RowCells = r.cells;
        _ = g.api.ghostty_render_state_row_get(r.rows, g.row_cells, @ptrCast(&cells));
        if (cells) |c| r.cells = c;
        const p = v.ptr orelse return &.{};
        return p[0..@intCast(v.len)];
    }

    /// The selected columns of the current row, inclusive.
    pub fn rowSelection(r: Render) ?[2]u16 {
        var s: g.RowSelection = .{};
        if (g.api.ghostty_render_state_row_get(r.rows, g.row_selection, &s) != g.success) return null;
        return .{ s.start_x, s.end_x };
    }

    /// The style of cell `x` of the row `rowCells` read.
    pub fn style(r: Render, x: usize) Style {
        var s: Style = .{};
        if (g.api.ghostty_render_state_row_cells_select(r.cells, x) == g.success)
            _ = g.api.ghostty_render_state_row_cells_get(r.cells, g.cell_style, &s);
        return s;
    }

    /// The codepoints of cell `x` of the current row, into `buf`.
    pub fn graphemes(r: Render, x: usize, buf: []u32) []const u32 {
        if (g.api.ghostty_render_state_row_cells_select(r.cells, x) != g.success) return buf[0..0];
        var n: u32 = 0;
        _ = g.api.ghostty_render_state_row_cells_get(r.cells, g.cell_graphemes_len, &n);
        if (n == 0 or n > buf.len) return buf[0..0];
        _ = g.api.ghostty_render_state_row_cells_get(r.cells, g.cell_graphemes_buf, buf.ptr);
        return buf[0..n];
    }
};
