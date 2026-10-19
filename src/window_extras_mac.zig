//! What windows do beyond showing content on macOS: files dropped on them
//! (the window's delegate is their dragging destination), vibrancy
//! (NSVisualEffectView behind the content), and their remembered state.
const std = @import("std");
const objc = @import("objc.zig");
const window_types = @import("window_types.zig");

/// The delegate methods taking drops, for `objc.defineClass`.
pub fn dropMethods(comptime entered: anytype, comptime perform: anytype) [2]objc.Method {
    return .{
        .{ .name = "draggingEntered:", .imp = entered, .types = "Q@:@" },
        .{ .name = "performDragOperation:", .imp = perform, .types = "c@:@" },
    };
}

/// Makes the window take dragged files.
pub fn acceptDrops(nswindow: objc.Object) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const types = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{objc.nsString("public.file-url")});
    objc.msg(void, nswindow, "registerForDraggedTypes:", .{types});
}

/// NSDragOperationCopy when the drag carries files.
pub fn dragOperation(info: objc.Object) objc.NSUInteger {
    const pb = objc.msg(objc.Object, info, "draggingPasteboard", .{});
    const types = objc.msg(?objc.Object, pb, "types", .{}) orelse return 0;
    const has = objc.msg(objc.BOOL, types, "containsObject:", .{objc.nsString("public.file-url")});
    return if (has) 1 else 0;
}

/// The paths of the files a drag carries (owned), or null.
pub fn droppedFiles(gpa: std.mem.Allocator, info: objc.Object) ?[][]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const pb = objc.msg(objc.Object, info, "draggingPasteboard", .{});
    const classes = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{objc.class("NSURL")});
    const urls = objc.msg(?objc.Object, pb, "readObjectsForClasses:options:", .{ classes, @as(?objc.Object, null) }) orelse return null;
    const n = objc.msg(objc.NSUInteger, urls, "count", .{});
    var out: std.ArrayList([]u8) = .empty;
    for (0..n) |i| {
        const url = objc.msg(objc.Object, urls, "objectAtIndex:", .{i});
        if (!objc.msg(objc.BOOL, url, "isFileURL", .{})) continue;
        const p = gpa.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, url, "path", .{}))) catch break;
        out.append(gpa, p) catch {
            gpa.free(p);
            break;
        };
    }
    return out.toOwnedSlice(gpa) catch null;
}

pub fn freePaths(gpa: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

/// Puts an NSVisualEffectView of `material` behind the window's content
/// (it becomes the content view, the content its subview). Content drawn
/// opaque covers it.
pub fn setMaterial(nswindow: objc.Object, material: window_types.Material) bool {
    if (material == .none) return true;
    const pool = objc.Pool.push();
    defer pool.pop();
    const content = objc.msg(objc.Object, nswindow, "contentView", .{});
    const bounds = objc.msg(objc.CGRect, content, "bounds", .{});
    const effect = objc.msg(objc.Object, objc.alloc("NSVisualEffectView"), "initWithFrame:", .{bounds});
    defer objc.release(effect);
    // NSVisualEffectMaterialSidebar, UnderWindowBackground, Popover.
    const m: objc.NSInteger = switch (material) {
        .sidebar => 7,
        .under_window => 21,
        .popover => 6,
        .none => unreachable,
    };
    objc.msg(void, effect, "setMaterial:", .{m});
    objc.msg(void, effect, "setBlendingMode:", .{@as(objc.NSInteger, 0)}); // behind the window
    objc.msg(void, effect, "setState:", .{@as(objc.NSInteger, 0)}); // follows the window's activity
    _ = objc.retain(content);
    defer objc.release(content);
    objc.msg(void, nswindow, "setContentView:", .{effect});
    objc.msg(void, content, "setFrame:", .{bounds});
    objc.msg(void, content, "setAutoresizingMask:", .{@as(objc.NSUInteger, 18)}); // width and height sizable
    objc.msg(void, effect, "addSubview:", .{content});
    return true;
}
