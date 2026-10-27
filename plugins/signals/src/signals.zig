//! Signals, computeds and effects, a port of
//! [alien-signals](https://github.com/stackblitz/alien-signals) (3.2.1):
//! state an app keeps in one place, values derived from it on demand and
//! cached, and work that runs again when what it read changes.
//!
//!     var count = signals.Signal(i32).init(0);
//!     var doubled = signals.Computed(i32).init(struct {
//!         fn get(_: ?i32) i32 { return count.get() * 2; }
//!     }.get);
//!
//!     const e = signals.effect(struct {
//!         fn run() void { std.debug.print("{d}\n", .{doubled.get()}); }
//!     }.run); // prints 0
//!     count.set(1); // prints 2
//!     e.dispose();
//!
//! The graph is global, as alien-signals' is, and belongs to one thread
//! (the main thread, in an app). Signals and computeds are the caller's
//! values, which must stay put while anything reads them (globals, or
//! fields of state that outlives its effects); effects, scopes and the
//! links between nodes come from `allocator`. A read can't fail, so
//! running out of memory panics.
const std = @import("std");
const builtin = @import("builtin");
const system = @import("system.zig");

pub const Node = system.Node;
pub const Link = system.Link;
pub const Kind = system.Kind;
pub const flags = system.flags;

/// Where effects, scopes and links come from. Set it before the first
/// signal is read or effect made.
pub var allocator: std.mem.Allocator = if (builtin.cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.smp_allocator;

/// Marks a parent (effect, scope or computed) that made child effects, so
/// that it disposes them before running again. Outside `system.zig`'s bits.
const has_child_effect: u8 = 64;

var cycle: u32 = 0;
var run_depth: u32 = 0;
var batch_depth: u32 = 0;
var notify_index: usize = 0;
var queued_len: usize = 0;
var active_sub: ?*Node = null;
var queued: std.ArrayList(?*Node) = .empty;

// What was disposed or unlinked is freed once no call is under way and no
// batch is open, as walks may still hold it until then; effects also wait
// for the queue to be empty (`collect`).
var calls: u32 = 0;
var free_links: ?*Link = null;
var free_effects: ?*Effect = null;

const Hooks = struct {
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
            } else queued.append(allocator, e) catch oom();
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
        return allocator.create(Link) catch oom();
    }

    pub fn freeLink(l: *Link) void {
        l.next_free = free_links;
        free_links = l;
    }

    pub fn gpa() std.mem.Allocator {
        return allocator;
    }
};

const sys = system.System(Hooks);

fn oom() noreturn {
    @panic("signals: out of memory");
}

fn enter() void {
    calls += 1;
}

fn leave() void {
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
            allocator.destroy(e);
        }
    }
    while (free_links) |l| {
        free_links = l.next_free;
        allocator.destroy(l);
    }
}

/// A function and its context, called with no arguments.
const Callback = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque) void,

    var no_ctx: u8 = 0;

    fn plain(comptime f: fn () void) Callback {
        return .{ .ctx = &no_ctx, .func = &struct {
            fn call(_: *anyopaque) void {
                f();
            }
        }.call };
    }

    fn with(ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) Callback {
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

/// A value that what reads it depends on. Values are compared with
/// `std.meta.eql` (slices and pointers by address, as JavaScript compares
/// objects); a `set` to an equal value changes nothing.
pub fn Signal(comptime T: type) type {
    return struct {
        node: Node = .{ .flags = flags.mutable, .kind = .signal, .update = &update },
        current: T,
        pending: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .current = value, .pending = value };
        }

        /// The value, making the effect or computed reading it depend on it.
        pub fn get(s: *Self) T {
            if (s.node.flags & flags.dirty != 0) {
                if (updateSignal(s)) {
                    if (s.node.subs) |subs| sys.shallowPropagate(subs);
                }
            }
            if (active_sub) |sub| sys.link(&s.node, sub, cycle);
            return s.current;
        }

        /// The value, without depending on it.
        pub fn peek(s: *Self) T {
            const prev = setActiveSub(null);
            defer active_sub = prev;
            return s.get();
        }

        /// Changes the value: effects that read it run again now, or when
        /// the outermost batch ends.
        pub fn set(s: *Self, value: T) void {
            if (std.meta.eql(s.pending, value)) return;
            s.pending = value;
            s.node.flags = flags.mutable | flags.dirty;
            if (s.node.subs) |subs| {
                enter();
                defer leave();
                sys.propagate(subs, run_depth != 0);
                if (batch_depth == 0) flush();
            }
        }

        /// The value to change in place (a list's items, a struct's
        /// field); `trigger` then tells what reads it. Doesn't depend on it.
        pub fn mutate(s: *Self) *T {
            _ = s.peek();
            return &s.current;
        }

        /// Runs what reads the signal again, as after a `set`, for a value
        /// changed in place through `mutate`.
        pub fn trigger(s: *Self) void {
            if (s.node.flags & flags.dirty == 0) s.pending = s.current;
            triggerWith(s, struct {
                fn read(x: *Self) void {
                    _ = x.get();
                }
            }.read);
        }

        fn updateSignal(s: *Self) bool {
            s.node.flags = flags.mutable;
            const changed = !std.meta.eql(s.current, s.pending);
            s.current = s.pending;
            return changed;
        }

        fn update(n: *Node) bool {
            return updateSignal(@fieldParentPtr("node", n));
        }
    };
}

/// A value derived from signals and other computeds, computed when read
/// and cached until one of them changes. The getter gets its previous
/// value (null the first time).
pub fn Computed(comptime T: type) type {
    return struct {
        node: Node = .{ .flags = flags.none, .kind = .computed, .update = &update },
        value: T = undefined,
        has_value: bool = false,
        ctx: *anyopaque,
        getter: *const fn (*anyopaque, ?T) T,

        const Self = @This();

        pub fn init(comptime getter: fn (?T) T) Self {
            return .{ .ctx = &Callback.no_ctx, .getter = &struct {
                fn call(_: *anyopaque, prev: ?T) T {
                    return getter(prev);
                }
            }.call };
        }

        /// A getter of `ctx` (a pointer): `getter(ctx, previous)`.
        pub fn initWith(ctx: anytype, comptime getter: fn (@TypeOf(ctx), ?T) T) Self {
            const P = @TypeOf(ctx);
            return .{ .ctx = @ptrCast(@constCast(ctx)), .getter = &struct {
                fn call(p: *anyopaque, prev: ?T) T {
                    return getter(@as(P, @ptrCast(@alignCast(p))), prev);
                }
            }.call };
        }

        /// The value, brought up to date, making the effect or computed
        /// reading it depend on it.
        pub fn get(c: *Self) T {
            enter();
            defer leave();
            const n = &c.node;
            const fl = n.flags;
            if (fl & flags.dirty != 0 or
                (fl & flags.pending != 0 and (sys.checkDirty(n.deps.?, n) or clearPending(n, fl))))
            {
                if (updateComputed(c)) {
                    if (n.subs) |subs| sys.shallowPropagate(subs);
                }
            } else if (fl == 0) {
                n.flags = flags.mutable | flags.recursed_check;
                const prev = setActiveSub(n);
                c.value = c.getter(c.ctx, null);
                c.has_value = true;
                active_sub = prev;
                n.flags &= ~flags.recursed_check;
            }
            if (active_sub) |sub| sys.link(n, sub, cycle);
            return c.value;
        }

        /// The value, brought up to date, without depending on it.
        pub fn peek(c: *Self) T {
            const prev = setActiveSub(null);
            defer active_sub = prev;
            return c.get();
        }

        /// Lets go of what it read. A computed read by effects lets go
        /// when they stop; one read outside effects keeps its links until
        /// this (it is computed again if read after).
        pub fn deinit(c: *Self) void {
            enter();
            defer leave();
            std.debug.assert(c.node.subs == null);
            Hooks.unwatched(&c.node);
        }

        fn clearPending(n: *Node, fl: u8) bool {
            n.flags = fl & ~flags.pending;
            return false;
        }

        fn updateComputed(c: *Self) bool {
            const n = &c.node;
            if (n.flags & has_child_effect != 0) unlinkChildEffects(n);
            n.deps_tail = null;
            n.flags = flags.mutable | flags.recursed_check;
            const prev = setActiveSub(n);
            cycle +%= 1;
            const old: ?T = if (c.has_value) c.value else null;
            c.value = c.getter(c.ctx, old);
            c.has_value = true;
            active_sub = prev;
            n.flags &= ~flags.recursed_check;
            purgeDeps(n);
            return if (old) |o| !std.meta.eql(o, c.value) else true;
        }

        fn update(n: *Node) bool {
            return updateComputed(@fieldParentPtr("node", n));
        }
    };
}

/// An effect or a scope. An effect runs its function now, and again
/// whenever what it read changes; a scope runs its function once. Effects
/// and scopes made while one runs belong to it: they are disposed when it
/// runs again or is disposed, and must not be disposed again after that.
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
    /// innermost and latest first); its memory is freed once no signal
    /// call is under way, no batch is open and no effect waits to run.
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

pub fn effect(comptime f: fn () void) *Effect {
    return startEffect(.plain(f));
}

/// An effect of `ctx` (a pointer): `f(ctx)`.
pub fn effectWith(ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) *Effect {
    return startEffect(.with(ctx, f));
}

pub fn effectScope(comptime f: fn () void) *Effect {
    return startScope(.plain(f));
}

pub fn effectScopeWith(ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) *Effect {
    return startScope(.with(ctx, f));
}

/// Gives the effect running now a cleanup, called before it runs again
/// and when it is disposed (alien-signals' effect returning a function).
/// One per run; outside an effect's own function it does nothing.
pub fn onCleanup(comptime f: fn () void) void {
    setCleanup(.plain(f));
}

pub fn onCleanupWith(ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) void {
    setCleanup(.with(ctx, f));
}

/// Runs `f`, then runs again what reads the signals and computeds it
/// read, as if they had changed (for values changed in place).
pub fn trigger(comptime f: fn () void) void {
    triggerCallback(.plain(f));
}

pub fn triggerWith(ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) void {
    triggerCallback(.with(ctx, f));
}

/// Holds effects back until the matching `endBatch`, so that several
/// writes run them once.
pub fn startBatch() void {
    batch_depth += 1;
}

pub fn endBatch() void {
    enter();
    defer leave();
    batch_depth -= 1;
    if (batch_depth == 0) flush();
}

pub fn getBatchDepth() u32 {
    return batch_depth;
}

/// The node reads are linked to; `setActiveSub(null)` reads untracked,
/// and returns the previous one to put back.
pub fn getActiveSub() ?*Node {
    return active_sub;
}

pub fn setActiveSub(sub: ?*Node) ?*Node {
    const prev = active_sub;
    active_sub = sub;
    return prev;
}

/// Drops the effects waiting to run and frees the queue and what was
/// disposed, which are otherwise kept for the next write (for leak checks
/// in tests). No effect may be running.
pub fn deinit() void {
    std.debug.assert(calls == 0 and batch_depth == 0);
    @memset(queued.items, null);
    notify_index = 0;
    queued_len = 0;
    collect();
    queued.deinit(allocator);
    queued = .empty;
}

fn startEffect(cb: Callback) *Effect {
    enter();
    defer leave();
    const e = allocator.create(Effect) catch oom();
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

fn startScope(cb: Callback) *Effect {
    enter();
    defer leave();
    const e = allocator.create(Effect) catch oom();
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

fn setCleanup(cb: Callback) void {
    const n = active_sub orelse return;
    if (n.kind == .effect) Effect.of(n).cleanup = cb;
}

fn triggerCallback(cb: Callback) void {
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

fn flush() void {
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
fn unlinkChildEffects(n: *Node) void {
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
fn purgeDeps(n: *Node) void {
    var it = if (n.deps_tail) |t| t.next_dep else n.deps;
    while (it) |l| it = sys.unlink(l, n);
}

test {
    _ = @import("tests.zig");
}
