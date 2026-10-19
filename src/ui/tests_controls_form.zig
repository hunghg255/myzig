//! Fields, forms, fieldsets and validation through `Tester`.
const std = @import("std");
const ui = @import("ui.zig");
const form = @import("controls_form.zig");
const testing = std.testing;

const SignUp = struct {
    email: ui.TextBuffer = .{},
    name: ui.TextBuffer = .{},
    sound: bool = false,
    signed_in: bool = true,
    valid: bool = false,
    fn view(s: *SignUp, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 16 });
        defer ui.end(c);
        var v: form.Validation = .{};
        const f = form.field(c, "Email", .{ .description = "For receipts.", .err = v.check(form.validate.email(s.email.text())) });
        _ = ui.textField(c, &s.email, .{});
        f.end();
        var fm = form.form(c, .{});
        {
            const n = fm.field("Name", .{ .err = v.check(form.validate.required(s.name.text())) });
            _ = ui.textField(c, &s.name, .{ .placeholder = "Your name" });
            n.end();
            const set = form.fieldset(c, "Notifications", .{ .disabled = !s.signed_in });
            const snd = fm.field("Sound effects", .{});
            _ = ui.toggle(c, "On", &s.sound);
            snd.end();
            set.end();
        }
        fm.end();
        s.valid = v.ok();
        ui.text(c, "Elsewhere", .{});
    }
};

test "validation checks" {
    try testing.expectEqualStrings("", form.validate.email(""));
    try testing.expectEqualStrings("", form.validate.email("ada@example.com"));
    try testing.expect(form.validate.email("ada").len > 0);
    try testing.expect(form.validate.email("@example.com").len > 0);
    try testing.expect(form.validate.email("ada@example").len > 0);
    try testing.expect(form.validate.email("ada@example.com.").len > 0);
    try testing.expect(form.validate.email("a da@example.com").len > 0);
    try testing.expect(form.validate.required("  ").len > 0);
    try testing.expectEqualStrings("", form.validate.required("x"));
    try testing.expectEqualStrings("Required.", form.validate.first(&.{ "", "Required.", "Other" }));
    try testing.expectEqualStrings("", form.validate.first(&.{ "", "" }));
    var v: form.Validation = .{};
    _ = v.check("");
    try testing.expect(v.ok());
    _ = v.check("bad");
    try testing.expect(!v.ok());
}

test "a field shows its description and its error, and marks the control" {
    var s: SignUp = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, SignUp.view), .{});
    defer t.deinit();
    try testing.expect(t.hasText("For receipts."));
    try testing.expect(!t.hasText("Enter an email address."));
    // The name is required.
    try testing.expect(t.hasText("Required."));
    try testing.expect(!s.valid);
    // A click on the label focuses the control.
    try t.clickText("Email");
    t.typeText("ada");
    try testing.expectEqualStrings("ada", s.email.text());
    try testing.expect(t.hasText("Enter an email address."));
    // The field's border takes the danger color.
    var red = false;
    const field = t.findText("ada").?;
    for (t.ctx.nodes.items) |n| if (n.style.border) |b| {
        if (std.meta.eql(b, t.theme.danger) and n.rect.contains(.{ .x = field.x, .y = field.y + 2 })) red = true;
    };
    try testing.expect(red);
    t.typeText("@example.com");
    try testing.expect(!t.hasText("Enter an email address."));
    try t.clickText("Name");
    t.typeText("Ada");
    try testing.expectEqualStrings("Ada", s.name.text());
    try testing.expect(!t.hasText("Required."));
    try testing.expect(s.valid);
}

test "a form's labels line up in a column, right-aligned, as wide as the widest" {
    var s: SignUp = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, SignUp.view), .{});
    defer t.deinit();
    const name = t.findText("Name").?;
    const sound = t.findText("Sound effects").?;
    // Right edges level, from the first frame.
    try testing.expectApproxEqAbs(name.x + name.w, sound.x + sound.w, 1);
    try testing.expect(name.x > sound.x);
    // The controls start at the same x.
    const placeholder = t.findText("Your name").?;
    const on = t.findText("On").?;
    try testing.expect(placeholder.x > sound.x + sound.w);
    try testing.expect(on.x > sound.x + sound.w);
    // The label is level with the first line of its control's text.
    try testing.expectApproxEqAbs(placeholder.y + placeholder.h / 2, name.y + name.h / 2, 3);
}

test "a disabled fieldset dims its fields and takes their clicks" {
    var s: SignUp = .{ .signed_in = false };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, SignUp.view), .{});
    defer t.deinit();
    try t.clickText("On");
    try testing.expect(!s.sound);
    s.signed_in = true;
    t.frame();
    try t.clickText("On");
    try testing.expect(s.sound);
    try testing.expect(t.hasText("Notifications"));
}
