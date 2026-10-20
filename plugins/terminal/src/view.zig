//! A terminal in an element of native UI: it fills its parent, sizes the
//! terminal in cells of its font, takes the keyboard while focused (a
//! click focuses it), reports the pointer to programs that ask (Shift
//! selects instead), selects text, scrolls the scrollback with the wheel,
//! opens links with Ctrl+click (Command+click on macOS), and draws the
//! frame (`paint.zig`).
//!
//!     fn view(s: *State, c: *ui.Context) void { terminal.view(c, s.term, .{ .autofocus = true }); }
const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");
const ui = myzig.ui;
const vt = @import("vt.zig");
const encode = @import("encode.zig");
const keys = @import("keys.zig");
const paint = @import("paint.zig");
const select = @import("select.zig");
const Theme = @import("theme.zig").Theme;
const Terminal = @import("session.zig").Terminal;

const mac = builtin.os.tag == .macos;
const Input = @FieldType(ui.Context, "input");
const TextOp = @typeInfo(@FieldType(Input, "ops")).pointer.child;
const Command = @FieldType(TextOp, "command");

pub const ViewOptions = struct {
    /// Room around the grid, in points.
    padding: f32 = 4,
    /// Takes the keyboard focus when nothing has it.
    autofocus: bool = false,
};

/// What a terminal's view keeps between frames.
pub const State = struct {
    render: ?vt.Render = null,
    keys: ?encode.KeyEncoder = null,
    mouse: ?encode.MouseEncoder = null,
    focused: bool = false,
    wheel: f32 = 0,
    drag: ?select.Drag = null,
    /// The button a program was told went down.
    reported: encode.Button = .none,
    last_cell: [2]u16 = .{ 0xFFFF, 0xFFFF },
    /// The window's darkness the theme was applied for.
    dark: ?bool = null,
    theme: Theme = Theme.light,
    grid: paint.Grid = .{ .pad = 4, .cell_w = 8, .cell_h = 16, .font_size = 13, .cols = 80, .rows = 24 },

    pub fn deinit(s: *State) void {
        if (s.render) |r| r.deinit();
        if (s.keys) |*k| k.deinit();
        if (s.mouse) |*m| m.deinit();
        s.* = .{};
    }
};

pub const ViewState = State;

pub fn view(c: *ui.Context, t: *Terminal, opts: ViewOptions) void {
    const s = &t.view_state;
    if (s.render == null) s.render = vt.Render.init() catch null;
    if (s.keys == null) s.keys = encode.KeyEncoder.init() catch null;
    if (s.mouse == null) s.mouse = encode.MouseEncoder.init() catch null;
    followTheme(c, t);

    const box = c.open(.{ .width = .fill, .height = .fill, .grow = 1, .clip = true, .background = .hex(s.theme.background) }, "myzig-terminal");
    defer c.end();
    const it = c.interact(box, .{ .focusable = true });
    if (opts.autofocus and c.focus == 0) c.focus = it.id;
    const rect = it.rect orelse {
        // The first frame has no layout yet: the next sizes the grid.
        c.animationFrame();
        return;
    };
    measure(c, t, rect, opts.padding);
    const focused = c.focus == it.id;
    if (focused != s.focused) {
        s.focused = focused;
        focusReport(t, focused);
    }
    if (focused) keyboard(c, t);
    pointer(c, t, it, rect);

    t.lock.lockUncancelable(t.io);
    defer t.lock.unlock(t.io);
    const r = if (s.render) |*e| e else return;
    r.update(t.vt);
    paint.draw(c, r, s.grid, s.theme, focused, t.vt.scrollbar());
}

/// The theme of the window's appearance, while the app gives none for it.
fn followTheme(c: *ui.Context, t: *Terminal) void {
    const s = &t.view_state;
    if (s.dark == c.theme.dark) return;
    s.dark = c.theme.dark;
    const th = if (c.theme.dark) (t.opts.dark_theme orelse t.opts.theme orelse Theme.dark) else (t.opts.theme orelse Theme.light);
    s.theme = th;
    t.lock.lockUncancelable(t.io);
    th.apply(t.vt);
    t.lock.unlock(t.io);
}

/// The grid from the box's size and the font's cells; resizes the terminal.
fn measure(c: *ui.Context, t: *Terminal, rect: ui.Rect, pad: f32) void {
    const s = &t.view_state;
    const style: ui.TextStyle = .{ .size = t.opts.font_size, .mono = true, .family = t.opts.font_family, .features = t.opts.font_features, .weight_value = t.opts.font_weight };
    const cw = c.text.width("MMMMMMMMMM", style) / 10;
    const ch = @ceil(c.text.lineHeight(style));
    if (cw <= 0 or ch <= 0) return;
    const cols: u16 = @intFromFloat(std.math.clamp(@floor((rect.w - 2 * pad) / cw), 1, 0xFFFF));
    const rows: u16 = @intFromFloat(std.math.clamp(@floor((rect.h - 2 * pad) / ch), 1, 0xFFFF));
    s.grid = .{ .pad = pad, .cell_w = cw, .cell_h = ch, .font_size = t.opts.font_size, .family = t.opts.font_family, .features = t.opts.font_features, .weight = t.opts.font_weight, .cols = cols, .rows = rows };
    t.resize(cols, rows, @intFromFloat(@round(cw * c.scale)), @intFromFloat(@round(ch * c.scale)));
}

fn focusReport(t: *Terminal, gained: bool) void {
    t.lock.lockUncancelable(t.io);
    const on = t.vt.mode(.focus_event);
    t.lock.unlock(t.io);
    if (!on) return;
    var buf: [8]u8 = undefined;
    t.send(encode.focus(gained, &buf));
}

/// Encodes a key for the program and sends it; typing scrolls back to the
/// bottom and lets go of the selection.
fn sendKey(t: *Terminal, k: encode.KeyEvent) void {
    const s = &t.view_state;
    const enc = if (s.keys) |*e| e else return;
    t.lock.lockUncancelable(t.io);
    enc.sync(t.vt, false);
    const bytes = enc.encode(k);
    var out: [128]u8 = undefined;
    const n = @min(bytes.len, out.len);
    @memcpy(out[0..n], bytes[0..n]);
    if (n > 0) {
        t.vt.scrollToBottom();
        select.clear(t.vt);
    }
    t.lock.unlock(t.io);
    t.send(out[0..n]);
}

fn take(c: *ui.Context) void {
    c.shortcut_taken = true;
    c.input.shortcut = null;
}

fn keyboard(c: *ui.Context, t: *Terminal) void {
    const in = &c.input;
    if (in.shortcut) |sc| {
        if (binding(c, t, sc)) {
            take(c);
        } else if (!(mac and sc.cmd)) {
            // Command shortcuts are the app's on macOS.
            var text: [4]u8 = undefined;
            if (keys.fromShortcut(sc, &text)) |k| {
                sendKey(t, k);
                take(c);
            }
        }
    }
    if (in.key) |k| {
        const mods: encode.Mods = .{ .shift = in.shift, .ctrl = in.ctrl };
        if (in.shift and (k == .page_up or k == .page_down)) {
            scrollRows(t, if (k == .page_up) -@as(i64, t.view_state.grid.rows) else t.view_state.grid.rows);
        } else sendKey(t, keys.fromKey(k, mods));
        in.key = null;
    }
    if (in.chars.len > 0) {
        typed(t, in.chars);
        in.chars = "";
    }
    for (in.ops) |op| switch (op) {
        .insert => |s| typed(t, s),
        .command => |cmd| command(c, t, cmd),
        .set_marked, .unmark => {},
    };
    in.ops = &.{};
}

/// Text typed, a character at a time by its key (so that the Kitty
/// keyboard protocol sees keys), as one string otherwise.
fn typed(t: *Terminal, s: []const u8) void {
    var view_ = std.unicode.Utf8View.init(s) catch return t.send(s);
    var cps = view_.iterator();
    while (cps.nextCodepointSlice()) |bytes| {
        const cp = std.unicode.utf8Decode(bytes) catch continue;
        sendKey(t, keys.fromChar(cp, bytes));
    }
}

/// The editing commands of macOS's key bindings, as the keys they are.
fn command(c: *ui.Context, t: *Terminal, cmd: Command) void {
    const k: ?keys.UiKey = switch (cmd) {
        .delete_backward => .backspace,
        .delete_forward => .delete,
        .move_left, .select_left => .left,
        .move_right, .select_right => .right,
        .move_line_start, .select_line_start => .home,
        .move_line_end, .select_line_end => .end,
        .move_up, .select_up => .up,
        .move_down, .select_down => .down,
        .move_page_up, .select_page_up => .page_up,
        .move_page_down, .select_page_down => .page_down,
        .insert_newline => .enter,
        .insert_tab => .tab,
        .cancel => .escape,
        .copy => {
            _ = copy(c, t);
            return;
        },
        .select_all => {
            selectAll(t);
            return;
        },
        else => null,
    };
    if (k) |key| sendKey(t, keys.fromKey(key, .{}));
}

/// The terminal's own keys, as Ghostty's defaults: copy, paste, select
/// all, scrolling; on Windows Control+C copies a selection and Control+V
/// pastes, as in Windows Terminal. True if one took the key.
fn binding(c: *ui.Context, t: *Terminal, sc: ui.Shortcut) bool {
    const primary = if (mac) sc.cmd and !sc.ctrl and !sc.alt else sc.ctrl and sc.shift and !sc.alt and !sc.cmd;
    if (primary) switch (sc.key) {
        'c' => return copy(c, t) or true,
        'v' => return paste(t) or true,
        'a' => {
            selectAll(t);
            return true;
        },
        else => {},
    };
    if (builtin.os.tag == .windows and sc.ctrl and !sc.shift and !sc.alt) switch (sc.key) {
        'c' => return copy(c, t), // with a selection only: Control+C interrupts otherwise
        'v' => return paste(t),
        else => {},
    };
    return false;
}

/// Copies the selection to the clipboard and lets go of it; false
/// without one.
fn copy(c: *ui.Context, t: *Terminal) bool {
    t.lock.lockUncancelable(t.io);
    const text = t.vt.selectionText(t.gpa);
    if (text != null) select.clear(t.vt);
    t.lock.unlock(t.io);
    const s = text orelse return false;
    defer t.gpa.free(s);
    if (s.len == 0) return false;
    c.clipboard.write(c.clipboard.ctx, s);
    return true;
}

/// Copies the selection to the clipboard, keeping it.
fn copySelection(c: *ui.Context, t: *Terminal) void {
    t.lock.lockUncancelable(t.io);
    const text = t.vt.selectionText(t.gpa);
    t.lock.unlock(t.io);
    const s = text orelse return;
    defer t.gpa.free(s);
    if (s.len > 0) c.clipboard.write(c.clipboard.ctx, s);
}

fn selectAll(t: *Terminal) void {
    t.lock.lockUncancelable(t.io);
    defer t.lock.unlock(t.io);
    const sb = t.vt.scrollbar();
    const cols = t.vt.size()[0];
    const start = t.vt.screenCell(0, 0) orelse return;
    const end = t.vt.screenCell(cols -| 1, @intCast(sb.total -| 1)) orelse return;
    const s: vt.Selection = .{ .start = start, .end = end };
    t.vt.setSelection(&s);
}

/// Pastes the clipboard's text; false when it holds none.
fn paste(t: *Terminal) bool {
    const text = (if (t.opts.read_clipboard) |f| f(t.opts.read_clipboard_ctx, t.gpa) else myzig.clipboard.readText(t.gpa) catch null) orelse return false;
    defer t.gpa.free(text);
    if (text.len == 0) return false;
    t.paste(text);
    return true;
}

fn scrollRows(t: *Terminal, rows: i64) void {
    t.lock.lockUncancelable(t.io);
    t.vt.scrollBy(rows);
    t.lock.unlock(t.io);
}

/// The cell under the pointer, clamped to the grid.
fn cellAt(g: paint.Grid, rect: ui.Rect, p: ui.Point) [2]u16 {
    const fx = (p.x - rect.x - g.pad) / g.cell_w;
    const fy = (p.y - rect.y - g.pad) / g.cell_h;
    return .{
        @intFromFloat(std.math.clamp(@floor(fx), 0, @as(f32, @floatFromInt(g.cols -| 1)))),
        @intFromFloat(std.math.clamp(@floor(fy), 0, @as(f32, @floatFromInt(g.rows -| 1)))),
    };
}

fn pointer(c: *ui.Context, t: *Terminal, it: ui.Interaction, rect: ui.Rect) void {
    const s = &t.view_state;
    const in = &c.input;
    const g = s.grid;
    const cell = cellAt(g, rect, in.mouse);
    t.lock.lockUncancelable(t.io);
    const tracking = t.vt.mouseTracking();
    const alt_screen = t.vt.altScreen();
    const alt_scroll = t.vt.mode(.alt_scroll);
    t.lock.unlock(t.io);
    const report = tracking and !in.shift;
    const over = it.hovered or rect.contains(in.mouse);
    if (over) {
        c.wants_wheel = true;
        c.cursor = .text;
    }
    if (report) c.wants_moves = true;
    const mods: encode.Mods = .{ .shift = in.shift, .ctrl = in.ctrl, .super = in.cmd };

    // The wheel: to the program, as arrows on a full-screen program's
    // screen, else through the scrollback; a row per cell of travel.
    if (over and in.scroll.y != 0) {
        s.wheel += in.scroll.y;
        const rows: i64 = @intFromFloat(@trunc(s.wheel / g.cell_h));
        if (rows != 0) {
            s.wheel -= @as(f32, @floatFromInt(rows)) * g.cell_h;
            const n: usize = @min(@abs(rows), 50);
            if (report) {
                for (0..n) |_| mouseReport(c, t, rect, .press, if (rows > 0) .wheel_up else .wheel_down, mods);
            } else if (alt_screen and alt_scroll) {
                for (0..n) |_| sendKey(t, keys.fromKey(if (rows > 0) .up else .down, .{}));
            } else scrollRows(t, -rows);
        }
    }

    const link_key = if (mac) in.cmd else in.ctrl;
    if (it.hovered and in.pressed and c.active == it.id) {
        if (link_key) {
            openLink(t, cell);
        } else if (report) {
            s.reported = .left;
            mouseReport(c, t, rect, .press, .left, mods);
        } else {
            const unit: select.Unit = if (in.click_count >= 3) .line else if (in.click_count == 2) .word else .cell;
            t.lock.lockUncancelable(t.io);
            const d: select.Drag = .{ .x = cell[0], .y = select.screenRow(t.vt, cell[1]), .unit = unit };
            s.drag = d;
            if (unit == .cell) select.clear(t.vt) else select.extend(t.vt, d, cell[0], cell[1], g.cols);
            t.lock.unlock(t.io);
        }
    } else if (it.pressed and !in.pressed) {
        if (s.reported != .none) {
            if (cell[0] != s.last_cell[0] or cell[1] != s.last_cell[1]) mouseReport(c, t, rect, .motion, s.reported, mods);
        } else if (s.drag) |d| {
            t.lock.lockUncancelable(t.io);
            if (d.unit != .cell or cell[0] != d.x or select.screenRow(t.vt, cell[1]) != d.y) select.extend(t.vt, d, cell[0], cell[1], g.cols);
            t.lock.unlock(t.io);
        }
    } else if (report and it.hovered and !in.down and (cell[0] != s.last_cell[0] or cell[1] != s.last_cell[1])) {
        mouseReport(c, t, rect, .motion, .none, mods);
    }
    if (in.released) {
        if (s.reported != .none) mouseReport(c, t, rect, .release, s.reported, mods);
        // What a drag, a double or a triple click chose goes to the
        // clipboard as the pointer lets go, as Ghostty and iTerm2 do.
        if (s.drag != null and t.opts.copy_on_select) copySelection(c, t);
        s.reported = .none;
        s.drag = null;
    }
    if (it.hovered and in.right_pressed and report) {
        mouseReport(c, t, rect, .press, .right, mods);
        mouseReport(c, t, rect, .release, .right, mods);
    }
    s.last_cell = cell;
}

fn mouseReport(c: *ui.Context, t: *Terminal, rect: ui.Rect, action: encode.MouseAction, button: encode.Button, mods: encode.Mods) void {
    const s = &t.view_state;
    const m = if (s.mouse) |*e| e else return;
    const g = s.grid;
    const sc = c.scale;
    var out: [64]u8 = undefined;
    t.lock.lockUncancelable(t.io);
    m.sync(t.vt, .{
        .screen_width = @intFromFloat(@max(1, rect.w * sc)),
        .screen_height = @intFromFloat(@max(1, rect.h * sc)),
        .cell_width = @intFromFloat(@max(1, @round(g.cell_w * sc))),
        .cell_height = @intFromFloat(@max(1, @round(g.cell_h * sc))),
        .padding_top = @intFromFloat(@round(g.pad * sc)),
        .padding_left = @intFromFloat(@round(g.pad * sc)),
    }, s.reported != .none and action != .release);
    const bytes = m.encode(action, button, mods, (c.input.mouse.x - rect.x) * sc, (c.input.mouse.y - rect.y) * sc);
    const n = @min(bytes.len, out.len);
    @memcpy(out[0..n], bytes[0..n]);
    t.lock.unlock(t.io);
    t.send(out[0..n]);
}

fn openLink(t: *Terminal, cell: [2]u16) void {
    var buf: [2048]u8 = undefined;
    t.lock.lockUncancelable(t.io);
    const found = select.linkAt(t.vt, cell[0], cell[1], t.view_state.grid.cols, @import("links.zig").native, &buf);
    t.lock.unlock(t.io);
    const l = found orelse return;
    if (t.opts.open_link) |f| if (f(t.opts.open_link_ctx, l[0], l[1])) return;
    if (l[1]) {
        if (std.fs.path.isAbsolute(l[0])) _ = myzig.shell.openPath(l[0]);
    } else _ = myzig.shell.openUrl(l[0]);
}
