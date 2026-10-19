//! Find in page, the same on every platform: the bridge highlights the
//! matches (`__myzig.find`), and its answer is decoded for the app.
const std = @import("std");
const types = @import("page_types.zig");

const Pending = struct { gpa: std.mem.Allocator, cb: types.FindCallback };

/// Highlights `text` in `page`'s document and passes how many matches
/// there are, and which is current, to `cb` (null when it failed).
pub fn find(page: anytype, text: []const u8, opts: types.FindOptions, cb: types.FindCallback) void {
    const gpa = page.gpa;
    const p = gpa.create(Pending) catch return cb.func(cb.ctx, null);
    p.* = .{ .gpa = gpa, .cb = cb };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    script(&aw.writer, text, opts) catch {
        gpa.destroy(p);
        return cb.func(cb.ctx, null);
    };
    page.evalResult(aw.written(), .{ .ctx = p, .func = done });
}

fn script(out: *std.Io.Writer, text: []const u8, opts: types.FindOptions) !void {
    try out.writeAll("__myzig.find(");
    try std.json.Stringify.encodeJsonString(text, .{}, out);
    try out.print(",{{\"matchCase\":{},\"backward\":{},\"next\":{}}})", .{ opts.match_case, opts.backward, opts.find_next });
}

fn done(ctx: ?*anyopaque, result: types.EvalResult) void {
    const p: *Pending = @ptrCast(@alignCast(ctx));
    const gpa = p.gpa;
    const cb = p.cb;
    gpa.destroy(p);
    const json = switch (result) {
        .ok => |v| v,
        .err => return cb.func(cb.ctx, null),
    };
    const parsed = std.json.parseFromSlice(types.FindResult, gpa, json, .{ .ignore_unknown_fields = true }) catch return cb.func(cb.ctx, null);
    defer parsed.deinit();
    cb.func(cb.ctx, parsed.value);
}

test "the script asks the bridge" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try script(&aw.writer, "a \"b\"", .{ .find_next = true });
    try std.testing.expectEqualStrings("__myzig.find(\"a \\\"b\\\"\",{\"matchCase\":false,\"backward\":false,\"next\":true})", aw.written());
}
