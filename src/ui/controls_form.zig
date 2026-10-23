//! Forms: fields labeling their control, with a description and an error
//! below it; forms lining the labels up in a column of their own, as
//! macOS's; fieldsets grouping fields under a legend; and validation.
const std = @import("std");
const types = @import("types.zig");
const widgets = @import("widgets.zig");
const state = @import("controls_state.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

pub const FieldOptions = struct {
    /// A text below the control, in the muted color.
    description: []const u8 = "",
    /// What is wrong with the value: shown below the control in the
    /// danger color, which the control's border takes. Empty is valid.
    err: []const u8 = "",
};

const label_style: types.TextStyle = .{ .size = 13, .weight = .medium };

/// A field being built: its control follows, then `end`.
pub const Field = struct {
    c: *Context,
    /// The first box of the control.
    start: u32,
    label_clicked: bool,
    opts: FieldOptions,
    /// The label, which names the control for assistive technology.
    title: []const u8 = "",

    /// Ends the field: its description and error, and its label's click,
    /// which focuses the control.
    pub fn end(f: Field) void {
        const c = f.c;
        const th = c.theme;
        // Prefer a text editor, then a focusable control: compound inputs
        // can have chrome or buttons before the field. Disabled editors
        // still need their accessible name, but cannot receive focus.
        var control: ?u32 = null;
        var focusable: ?u32 = null;
        var at = f.start;
        while (at < c.nodes.items.len) : (at += 1) if (c.nodes.items[at].interactive) {
            if (control == null) control = at;
            if (focusable == null and std.mem.indexOfScalar(u64, c.focus_order.items, c.nodes.items[at].id) != null) focusable = at;
            if (c.edits.contains(c.nodes.items[at].id)) {
                control = at;
                focusable = at;
                break;
            }
        };
        control = focusable orelse control;
        if (f.opts.err.len > 0) {
            // The error marks the control's frame: its first box with one.
            at = f.start;
            while (at < c.nodes.items.len) : (at += 1) {
                const n = &c.nodes.items[at];
                if (n.style.border != null) {
                    n.style.border = th.danger;
                    break;
                }
            }
        }
        if (control) |ci| c.describe(c.nodes.items[ci].id, .{
            .label = f.title,
            .description = if (f.opts.err.len > 0) f.opts.err else f.opts.description,
            .invalid = f.opts.err.len > 0,
        });
        if (f.label_clicked) if (control) |ci| {
            const id = c.nodes.items[ci].id;
            if (std.mem.indexOfScalar(u64, c.focus_order.items, id) != null) {
                c.focus = id;
                c.changed = true;
            }
        };
        if (f.opts.description.len > 0) widgets.text(c, f.opts.description, .{ .size = 12, .color = th.muted, .wrap = true });
        if (f.opts.err.len > 0) widgets.text(c, f.opts.err, .{ .size = 12, .color = th.danger, .wrap = true });
        // The control's column, and in a form the field's row.
        c.end();
        c.end();
    }
};

fn labelBox(c: *Context, title: []const u8, style: types.Style) bool {
    const i = c.open(style, null);
    const it = c.interact(i, .{});
    // A label is no button: the pointer stays an arrow over it.
    if (it.hovered and c.hot == it.id) c.cursor_hand = false;
    widgets.text(c, title, label_style);
    c.end();
    return it.clicked;
}

/// A field labeling the control built next, the label above it, as on
/// the web: a click on the label focuses the control. End with `end`.
///
///     const f = ui.field(c, "Email", .{ .err = ui.validate.email(s.email.text()) });
///     _ = ui.textField(c, &s.email, .{});
///     f.end();
pub fn field(c: *Context, title: []const u8, opts: FieldOptions) Field {
    _ = c.open(.{ .gap = 4 }, null);
    const clicked = labelBox(c, title, .{});
    _ = c.open(.{ .gap = 4 }, null);
    return .{ .c = c, .start = @intCast(c.nodes.items.len), .label_clicked = clicked, .opts = opts, .title = title };
}

pub const FormOptions = struct {
    gap: f32 = 12,
    /// Between the labels' column and the controls'.
    label_gap: f32 = 12,
};

/// A form: the labels of its fields in a column of their own beside the
/// controls, aligned to the right, as wide as the widest, and level with
/// the first line of their control's text (with the middle of a control
/// without text, as a switch, a description below it or not; in a row,
/// with the text beside a dot or an icon). Keep it in a variable:
///
///     var form = ui.form(c, .{});
///     defer form.end();
///     const f = form.field("Name", .{});
///     _ = ui.textField(c, &s.name, .{});
///     f.end();
pub const Form = struct {
    c: *Context,
    id: u64,
    opts: FormOptions,
    /// The widest label of the last build, and of this one so far.
    label_w: f32,
    widest: f32 = 0,

    pub fn field(fm: *Form, title: []const u8, opts: FieldOptions) Field {
        const c = fm.c;
        const w = @ceil(c.text.width(title, label_style));
        fm.widest = @max(fm.widest, w);
        // Level with the first line of its control's text, or centered on
        // a control without that comes first (a switch), not on a
        // description below it (`Style.baselines`).
        _ = c.open(.{ .direction = .row, .gap = fm.opts.label_gap, .baselines = true }, null);
        const clicked = labelBox(c, title, .{ .width = .{ .px = @max(fm.label_w, w) }, .align_items = .end });
        _ = c.open(.{ .gap = 4, .grow = 1 }, null);
        return .{ .c = c, .start = @intCast(c.nodes.items.len), .label_clicked = clicked, .opts = opts, .title = title };
    }

    pub fn end(fm: *Form) void {
        const c = fm.c;
        c.end();
        // The labels' column takes the widest: built again at once if it
        // changed, so that no frame shows them unaligned.
        if (fm.widest != fm.label_w) {
            state.put(c, fm.id, 0, fm.widest);
            c.changed = true;
        }
    }
};

pub fn form(c: *Context, opts: FormOptions) Form {
    const i = c.open(.{ .gap = opts.gap }, null);
    const id = c.node(i).id;
    return .{ .c = c, .id = id, .opts = opts, .label_w = state.get(c, id, 0, 0) };
}

pub const FieldsetOptions = struct {
    /// Dims the fields and takes their input.
    disabled: bool = false,
    gap: f32 = 12,
};

pub const Fieldset = struct {
    c: *Context,
    index: u32,
    start: u32,
    opts: FieldsetOptions,

    pub fn end(f: Fieldset) void {
        const c = f.c;
        if (f.opts.disabled) {
            // Over its fields, a box taking every press, and no focus left inside.
            var at = f.start;
            while (at < c.nodes.items.len) : (at += 1) if (c.nodes.items[at].id == c.focus) {
                c.focus = 0;
            };
            const shield = c.leaf(.{ .absolute = true, .width = .fill, .height = .fill }, .none, "shield");
            const it = c.interact(shield, .{});
            if (it.hovered) c.cursor_hand = false;
            c.node(f.index).style.opacity = 0.45;
        }
        c.end();
    }
};

/// Fields grouped under a legend, which `disabled` disables together.
pub fn fieldset(c: *Context, legend: []const u8, opts: FieldsetOptions) Fieldset {
    const i = c.open(.{ .gap = opts.gap, .padding = .{ .top = 4 } }, null);
    widgets.text(c, legend, .{ .size = 13, .weight = .semibold, .color = c.theme.muted });
    return .{ .c = c, .index = i, .start = @intCast(c.nodes.items.len), .opts = opts };
}

/// Checks of values, each the error to show (empty when valid), for a
/// field's `err`.
pub const validate = struct {
    pub fn required(s: []const u8) []const u8 {
        return if (std.mem.trim(u8, s, " \t").len == 0) "Required." else "";
    }

    /// Empty is valid: combine with `required` for a value that must be given.
    pub fn email(s: []const u8) []const u8 {
        if (s.len == 0) return "";
        const at = std.mem.indexOfScalar(u8, s, '@') orelse return "Enter an email address.";
        const domain = s[at + 1 ..];
        if (at == 0 or std.mem.indexOfScalar(u8, domain, '.') == null or domain[0] == '.' or domain[domain.len - 1] == '.' or std.mem.indexOfAny(u8, s, " \t") != null)
            return "Enter an email address.";
        return "";
    }

    pub fn minLength(c: *Context, s: []const u8, n: usize) []const u8 {
        const len = std.unicode.utf8CountCodepoints(s) catch s.len;
        if (len == 0 or len >= n) return "";
        return c.print("At least {d} characters.", .{n});
    }

    pub fn number(c: *Context, s: []const u8, lo: f64, hi: f64) []const u8 {
        const t = std.mem.trim(u8, s, " ");
        if (t.len == 0) return "";
        const v = std.fmt.parseFloat(f64, t) catch return "Enter a number.";
        if (v < lo or v > hi) return c.print("Between {d} and {d}.", .{ lo, hi });
        return "";
    }

    /// The first error of several checks.
    pub fn first(errors: []const []const u8) []const u8 {
        for (errors) |e| if (e.len > 0) return e;
        return "";
    }
};

/// Counts the errors of a form's fields, to enable its submit button.
pub const Validation = struct {
    errors: u32 = 0,

    /// Passes `err` through, counting it.
    pub fn check(v: *Validation, err: []const u8) []const u8 {
        if (err.len > 0) v.errors += 1;
        return err;
    }

    pub fn ok(v: Validation) bool {
        return v.errors == 0;
    }
};
