//! The global state of `signals.zig` and what runs effects: alien-signals'
//! `index.ts` less its values (`values.zig`), with the freeing that its
//! garbage collector does for it.
const std = @import("std");
const api = @import("signals.zig");
const system = @import("system.zig");

const Node = system.Node;
const Link = system.Link;
const flags = system.flags;

/// Marks a parent (effect, scope or computed) that made child effects, so
/// that it disposes them before running again. Outside `system.zig`'s bits.
pub const has_child_effect: u8 = 64;

pub var cycle: u32 = 0;
pub var run_depth: u32 = 0;
pub var batch_depth: u32 = 0;
pub var active_sub: ?*Node = null;
var notify_index: usize = 0;
var queued_len: usize = 0;
var queued: std.ArrayList(?*Node) = .empty;

// What was disposed or unlinked is freed once no call is under way and no
// batch is open, as walks may still hold it until then; effects also wait
// for the queue to be empty (`collect`).
var calls: u32 = 0;
var free_links: ?*Link = null;
var free_effects: ?*Effect = null;

pub const Hooks = struct {
    pub fn update(n: *Node) bool {
        switch (n.kind) {
            .signal, .computed => return n.update.?(n),
            else => {
                n.flags = flags.mutable;
                return true;
            },
        }
    }

    pub fn notify(first: *Node) void {
        var e = first;
        var insert = queued_len;
        const first_inserted = insert;
        while (true) {
            if (insert < queued.items.len) {
                queued.items[insert] = e;
            } else queued.append(api.allocator, e) catch oom();
            insert += 1;
            e.flags &= ~flags.watching;
            const parent = (e.subs orelse break).sub;
            if (parent.flags & flags.watching == 0) break;
            e = parent;
        }
        queued_len = insert;
        // Outer effects run before the inner ones they make.
        var lo = first_inserted;
        var hi = insert - 1;
        while (lo < hi) : ({
            lo += 1;
            hi -= 1;
        }) std.mem.swap(?*Node, &queued.items[lo], &queued.items[hi]);
    }

    pub fn unwatched(n: *Node) void {
        switch (n.kind) {
            .computed => if (n.deps_tail != null) {
                n.flags = flags.mutable | flags.dirty;
                disposeAllDepsInReverse(n);
            },
            // Signals stay as they are; a trigger's node is never a dependency.
            .signal, .trigger => {},
            .effect, .scope => Effect.of(n).release(),
        }
    }

    pub fn newLink() *Link {
        return api.allocator.create(Link) catch oom();
    }

    pub fn freeLink(l: *Link) void {
        l.next_free = free_links;
        free_links = l;
    }

    pub fn gpa() std.mem.Allocator {
        return api.allocator;
    }
};

pub const sys = system.System(Hooks);

pub fn oom() noreturn {
    @panic("signals: out of memory");
}

pub fn enter() void {
    calls += 1;
}

pub fn leave() void {
    calls -= 1;
    if (calls == 0 and batch_depth == 0) collect();
}

fn collect() void {
    // A read can queue an effect (a computed found dirty) with no flush to
    // run it, so the queue may still hold a disposed effect: those wait for
    // the next flush to empty it.
    if (queued_len == 0) {
        while (free_effects) |e| {
            free_effects = e.next_free;
            api.allocator.destroy(e);
        }
    }
    while (free_links) |l| {
        free_links = l.next_free;
        api.allocator.destroy(l);
    }
}

pub fn deinit() void {
    std.debug.assert(calls == 0 and batch_depth == 0);
    @memset(queued.items, null);
    notify_index = 0;
    queued_len = 0;
    collect();
    queued.deinit(api.allocator);
    queued = .empty;
}

/// A function and its context, called with no arguments.
pub const Callback = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque) void,

    pub var no_ctx: u8 = 0;

    pub fn plain(comptime f: fn () void) Callback {
        return .{ .ctx = &no_ctx, .func = &struct {
            fn call(_: *anyopaque) void {
                f();
            }
        }.call };
    }

    pub fn with(ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) Callback {
        const P = @TypeOf(ctx);
        return .{ .ctx = @ptrCast(@constCast(ctx)), .func = &struct {
            fn call(p: *anyopaque) void {
                f(@as(P, @ptrCast(@alignCast(p))));
            }
        }.call };
    }

    fn call(cb: Callback) void {
        cb.func(cb.ctx);
    }
};

/// An effect or a scope. An effect runs its function now, and again
/// whenever what it read changes; a scope runs its function once. Each is
/// disposed once: one made outside any other by the caller (or by its own
/// function), one made while another runs by that one when it runs again
/// or is disposed, unless the caller disposed it first. Without a garbage
/// collector, its pointer is not to be used after that.
pub const Effect = struct {
    node: Node,
    run: ?Callback,
    cleanup: ?Callback = null,
    disposed: bool = false,
    next_free: ?*Effect = null,

    fn of(n: *Node) *Effect {
        return @fieldParentPtr("node", n);
    }

    /// Stops it and the effects it made, running their cleanups (the
    /// innermost and latest first), and frees it once no signal call is
    /// under way, no batch is open and no effect waits to run. The pointer
    /// is not to be used after.
    pub fn dispose(e: *Effect) void {
        enter();
        defer leave();
        e.release();
    }

    fn release(e: *Effect) void {
        if (e.disposed) return;
        e.disposed = true;
        e.node.flags = flags.none;
        disposeAllDepsInReverse(&e.node);
        if (e.node.subs) |s| _ = sys.unlink(s, s.sub);
        if (e.cleanup != null) runCleanup(e);
        e.next_free = free_effects;
        free_effects = e;
    }
};

pub fn startEffect(cb: Callback) *Effect {
    enter();
    defer leave();
    const e = api.allocator.create(Effect) catch oom();
    e.* = .{ .node = .{ .flags = flags.watching | flags.recursed_check, .kind = .effect }, .run = cb };
    const prev = setActiveSub(&e.node);
    if (prev) |p| {
        sys.link(&e.node, p, 0);
        p.flags |= has_child_effect;
    }
    run_depth += 1;
    cb.call();
    run_depth -= 1;
    active_sub = prev;
    e.node.flags &= ~flags.recursed_check;
    return e;
}

pub fn startScope(cb: Callback) *Effect {
    enter();
    defer leave();
    const e = api.allocator.create(Effect) catch oom();
    e.* = .{ .node = .{ .flags = flags.mutable, .kind = .scope }, .run = null };
    const prev = setActiveSub(&e.node);
    if (prev) |p| {
        sys.link(&e.node, p, 0);
        p.flags |= has_child_effect;
    }
    cb.call();
    active_sub = prev;
    return e;
}

pub fn setCleanup(cb: Callback) void {
    const n = active_sub orelse return;
    if (n.kind == .effect) Effect.of(n).cleanup = cb;
}

pub fn setActiveSub(sub: ?*Node) ?*Node {
    const prev = active_sub;
    active_sub = sub;
    return prev;
}

pub fn triggerCallback(cb: Callback) void {
    enter();
    defer leave();
    var sub: Node = .{ .flags = flags.watching | flags.recursed_check, .kind = .trigger };
    const prev = setActiveSub(&sub);
    batch_depth += 1;
    cb.call();
    active_sub = prev;
    sub.flags = flags.none;
    var it = sub.deps;
    while (it) |l| {
        const dep = l.dep;
        it = sys.unlink(l, &sub);
        if (dep.subs) |subs| {
            sys.propagate(subs, run_depth != 0);
            sys.shallowPropagate(subs);
        }
    }
    batch_depth -= 1;
    if (batch_depth == 0) flush();
}

fn run(e: *Effect) void {
    const n = &e.node;
    const fl = n.flags;
    if (fl & flags.dirty != 0 or (fl & flags.pending != 0 and sys.checkDirty(n.deps.?, n))) {
        if (fl & has_child_effect != 0) unlinkChildEffects(n);
        if (e.cleanup != null) {
            runCleanup(e);
            if (n.flags == 0) return;
        }
        n.deps_tail = null;
        n.flags = flags.watching | flags.recursed_check;
        const prev = setActiveSub(n);
        cycle +%= 1;
        run_depth += 1;
        e.run.?.call();
        run_depth -= 1;
        active_sub = prev;
        n.flags &= ~flags.recursed_check;
        purgeDeps(n);
    } else if (n.deps != null) {
        n.flags = flags.watching | (fl & has_child_effect);
    }
}

pub fn flush() void {
    while (notify_index < queued_len) {
        const n = queued.items[notify_index].?;
        queued.items[notify_index] = null;
        notify_index += 1;
        run(Effect.of(n));
    }
    notify_index = 0;
    queued_len = 0;
}

fn runCleanup(e: *Effect) void {
    const cb = e.cleanup.?;
    e.cleanup = null;
    const prev = setActiveSub(null);
    cb.call();
    active_sub = prev;
}

/// Unlinks the effects and scopes `n` made, latest first (which disposes
/// them), before it runs again.
pub fn unlinkChildEffects(n: *Node) void {
    var it = n.deps_tail;
    while (it) |l| {
        it = l.prev_dep;
        if (l.dep.kind == .effect or l.dep.kind == .scope) _ = sys.unlink(l, n);
    }
}

fn disposeAllDepsInReverse(n: *Node) void {
    var it = n.deps_tail;
    while (it) |l| {
        it = l.prev_dep;
        _ = sys.unlink(l, n);
    }
}

/// Unlinks what `n` read last time and not this time.
pub fn purgeDeps(n: *Node) void {
    var it = if (n.deps_tail) |t| t.next_dep else n.deps;
    while (it) |l| it = sys.unlink(l, n);
}
