//! Flyouts as the system's popovers on macOS (NSPopover): the flyout's
//! content view shown in a popover, which draws the system's material,
//! rounded corners and arrow, and animates. AppKit places it against
//! the anchor: the arrow points at the anchor's middle, on the side the
//! flyout asks for, flipped where the screen has no room. A focusable
//! flyout's popover is transient: a click elsewhere asks `should_close`
//! before it closes. The popover makes its window as it shows
//! (`window`). As mygo's `Flyout.Popover`.
const std = @import("std");
const objc = @import("objc.zig");
const fly = @import("flyout.zig");

pub const Hooks = struct {
    ctx: *anyopaque,
    /// A click elsewhere: true lets the popover close.
    should_close: ?*const fn (ctx: *anyopaque) bool = null,
    /// The user closed it (not `hide` or `destroy`).
    closed: ?*const fn (ctx: *anyopaque) void = null,
};

/// NSRectEdge of the side a flyout goes to, in a view whose y goes up.
pub fn edge(side: fly.Placement.Side) objc.NSUInteger {
    return switch (side) {
        .left => 0, // NSRectEdgeMinX
        .bottom => 1, // NSRectEdgeMinY
        .right => 2, // NSRectEdgeMaxX
        .top => 3, // NSRectEdgeMaxY
    };
}

/// `anchor` (from the top left of a view `height` points tall) in the
/// view's own coordinates, whose y goes up; at least a point each way.
pub fn anchorIn(height: f64, anchor: fly.Rect) objc.CGRect {
    const w = @max(anchor.width, 1);
    const h = @max(anchor.height, 1);
    return .{ .origin = .{ .x = anchor.x, .y = height - anchor.y - h }, .size = .{ .width = w, .height = h } };
}

pub const Popover = struct {
    popover: objc.Object,
    controller: objc.Object,
    delegate: objc.Object,
    hooks: Hooks,
    /// Closing for `hide`: the delegate's close is not the user's.
    closing: bool = false,

    /// A popover of `content` (an NSView, which it keeps), `size` points.
    pub fn create(content: objc.Object, size: objc.CGSize, focusable: bool, hooks: Hooks) !*Popover {
        const p = try std.heap.c_allocator.create(Popover);
        errdefer std.heap.c_allocator.destroy(p);
        const controller = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSViewController"), "alloc", .{}), "init", .{});
        objc.msg(void, content, "setAutoresizingMask:", .{@as(objc.NSUInteger, 18)}); // width and height sizable
        objc.msg(void, controller, "setView:", .{content});
        const popover = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSPopover"), "alloc", .{}), "init", .{});
        objc.msg(void, popover, "setContentViewController:", .{controller});
        objc.msg(void, popover, "setContentSize:", .{size});
        // NSPopoverBehaviorTransient, or ApplicationDefined.
        objc.msg(void, popover, "setBehavior:", .{@as(objc.NSInteger, if (focusable) 1 else 0)});
        const delegate = objc.msg(objc.Object, objc.msg(objc.Object, delegateClass(), "alloc", .{}), "init", .{});
        objc.setZig(delegate, p);
        objc.msg(void, popover, "setDelegate:", .{delegate});
        p.* = .{ .popover = popover, .controller = controller, .delegate = delegate, .hooks = hooks };
        return p;
    }

    pub fn isShown(p: *Popover) bool {
        return objc.msg(objc.BOOL, p.popover, "isShown", .{});
    }

    /// Shows it from `rect` of `view` (an NSView: the parent's content,
    /// or a status item's button), on `side`.
    pub fn show(p: *Popover, view: objc.Object, rect: objc.CGRect, side: fly.Placement.Side, size: objc.CGSize) void {
        if (p.isShown()) return;
        p.closing = false;
        objc.msg(void, p.popover, "setContentSize:", .{size});
        objc.msg(void, p.popover, "showRelativeToRect:ofView:preferredEdge:", .{ rect, view, edge(side) });
    }

    /// The window the popover shows in, while it shows.
    pub fn window(p: *Popover) ?objc.Object {
        const view = objc.msg(objc.Object, p.controller, "view", .{});
        return objc.msg(?objc.Object, view, "window", .{});
    }

    /// Moves a popover that shows to `rect`, at `size`.
    pub fn place(p: *Popover, rect: ?objc.CGRect, size: objc.CGSize) void {
        if (!p.isShown()) return;
        objc.msg(void, p.popover, "setContentSize:", .{size});
        if (rect) |r| objc.msg(void, p.popover, "setPositioningRect:", .{r});
    }

    /// Closes it, to show again.
    pub fn hide(p: *Popover) void {
        if (!p.isShown()) return;
        p.closing = true;
        objc.msg(void, p.popover, "close", .{});
    }

    pub fn destroy(p: *Popover) void {
        objc.setZig(p.delegate, null);
        objc.msg(void, p.popover, "setDelegate:", .{@as(?objc.Object, null)});
        if (p.isShown()) {
            objc.msg(void, p.popover, "setAnimates:", .{objc.NO});
            objc.msg(void, p.popover, "close", .{});
        }
        objc.msg(void, p.popover, "setContentViewController:", .{@as(?objc.Object, null)});
        objc.release(p.popover);
        objc.release(p.controller);
        objc.release(p.delegate);
        std.heap.c_allocator.destroy(p);
    }
};

fn shouldClose(self: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.BOOL {
    const p = objc.getZig(Popover, self) orelse return true;
    const f = p.hooks.should_close orelse return true;
    return f(p.hooks.ctx);
}

fn didClose(self: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const p = objc.getZig(Popover, self) orelse return;
    if (p.closing) {
        p.closing = false;
        return;
    }
    if (p.hooks.closed) |f| f(p.hooks.ctx);
}

fn delegateClass() objc.Class {
    return objc.defineClass(.{
        .name = "MyZigPopoverDelegate",
        .protocols = &.{"NSPopoverDelegate"},
        .methods = &.{
            .{ .name = "popoverShouldClose:", .imp = &shouldClose, .types = "c@:@" },
            .{ .name = "popoverDidClose:", .imp = &didClose, .types = "v@:@" },
        },
    });
}

test "a popover's edge and anchor, in AppKit's terms" {
    try std.testing.expectEqual(@as(objc.NSUInteger, 1), edge(.bottom));
    try std.testing.expectEqual(@as(objc.NSUInteger, 3), edge(.top));
    const r = anchorIn(300, .{ .x = 10, .y = 20, .width = 40, .height = 30 });
    try std.testing.expectEqual(@as(f64, 250), r.origin.y);
    try std.testing.expectEqual(@as(f64, 1), anchorIn(300, .{ .x = 5, .y = 5 }).size.width);
}
