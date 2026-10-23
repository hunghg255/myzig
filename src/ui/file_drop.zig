//! Local file paths, owned independently of the lifetime of a system drop.
const std = @import("std");
const Context = @import("context.zig").Context;
const DragDrop = @import("dragdrop.zig").DragDrop;
const transfer = @import("../transfer.zig");
const widgets = @import("widgets.zig");
const types = @import("types.zig");

pub const Files = struct {
    allocator: std.mem.Allocator,
    paths: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Files {
        return .{ .allocator = allocator };
    }

    pub fn deinit(s: *Files) void {
        for (s.paths.items) |path| s.allocator.free(path);
        s.paths.deinit(s.allocator);
    }

    /// Copies a path; duplicates are ignored. Does not open the file.
    pub fn add(s: *Files, path: []const u8) !bool {
        if (path.len == 0) return false;
        for (s.paths.items) |existing| if (std.mem.eql(u8, path, existing)) return false;
        const copy = try s.allocator.dupe(u8, path);
        errdefer s.allocator.free(copy);
        try s.paths.append(s.allocator, copy);
        return true;
    }

    pub fn remove(s: *Files, index: usize) void {
        s.allocator.free(s.paths.orderedRemove(index));
    }
};

pub const Options = struct {
    title: []const u8 = "Drop files here",
    description: []const u8 = "Or choose files from your device.",
    browse_label: []const u8 = "Browse files",
    width: types.Length = .fill,
    disabled: bool = false,
    max_files: usize = std.math.maxInt(usize),
};

pub const Result = struct {
    changed: bool = false,
    /// The app can open its own file dialog and add the returned paths.
    browse: bool = false,
    over: bool = false,
    rejected: usize = 0,
    /// Allocation or file-list decoding failed. Accepted paths are retained.
    err: ?anyerror = null,
};

pub fn fileDropZone(c: *Context, dd: *DragDrop, files: *Files, opts: Options) Result {
    const outer = c.open(.{ .width = opts.width, .gap = 8, .opacity = if (opts.disabled) 0.45 else 1 }, null);
    defer c.end();
    c.describe(c.node(outer).id, .{ .role = .group, .label = opts.title, .disabled = opts.disabled });
    const zone = c.open(.{ .width = .fill, .padding = .all(20), .gap = 8, .align_items = .center, .radius = 10, .border = c.theme.border, .background = c.theme.surface }, "drop");
    const target = dd.target(c, zone, .{ .formats = &.{ transfer.file_list, transfer.uri_list }, .disabled = opts.disabled });
    var result: Result = .{ .over = target.over };
    if (target.over) {
        c.node(zone).style.border = c.theme.accent;
        c.node(zone).style.background = c.theme.accent.alpha(0.1);
    }
    widgets.icon(c, "doc", .{ .size = 24, .color = c.theme.muted });
    widgets.text(c, opts.title, .{ .weight = .semibold });
    widgets.text(c, opts.description, .{ .size = 12, .color = c.theme.muted, .wrap = true });
    result.browse = widgets.button(c, opts.browse_label, .{ .size = 12, .disabled = opts.disabled }).clicked;
    c.end();
    if (!opts.disabled) if (target.dropped) |drop| {
        const paths = drop.data.files(c.alloc()) catch |err| blk: {
            result.err = err;
            break :blk &.{};
        };
        for (paths) |path| {
            // Duplicates do not consume capacity or count as rejection.
            var duplicate = false;
            for (files.paths.items) |existing| if (std.mem.eql(u8, path, existing)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            if (files.paths.items.len >= opts.max_files) {
                result.rejected += 1;
                continue;
            }
            const added = files.add(path) catch |err| {
                result.err = err;
                break;
            };
            result.changed = result.changed or added;
        }
    };
    var remove: ?usize = null;
    for (files.paths.items, 0..) |path, index| {
        c.next_key = path;
        _ = c.open(.{ .direction = .row, .width = .fill, .gap = 8, .align_items = .center }, null);
        widgets.icon(c, "doc.text", .{ .size = 14 });
        widgets.text(c, std.fs.path.basename(path), .{ .wrap = true });
        widgets.spacer(c);
        const it = widgets.button(c, "Remove", .{ .variant = .ghost, .size = 12, .disabled = opts.disabled });
        c.describe(it.id, .{ .label = c.print("Remove {s}", .{std.fs.path.basename(path)}) });
        if (it.clicked) remove = index;
        c.end();
    }
    if (remove) |index| {
        files.remove(index);
        result.changed = true;
    }
    if (result.changed) c.changed = true;
    return result;
}
