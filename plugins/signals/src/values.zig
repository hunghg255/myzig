//! Signals and computeds, alien-signals' `signalOper` and `computedOper`:
//! nodes the caller keeps, read and written through `core.zig`.
const std = @import("std");
const system = @import("system.zig");
const core = @import("core.zig");

const Node = system.Node;
const flags = system.flags;
const sys = core.sys;

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
            if (core.active_sub) |sub| sys.link(&s.node, sub, core.cycle);
            return s.current;
        }

        /// The value, without depending on it.
        pub fn peek(s: *Self) T {
            const prev = core.setActiveSub(null);
            defer core.active_sub = prev;
            return s.get();
        }

        /// Changes the value: effects that read it run again now, or when
        /// the outermost batch ends.
        pub fn set(s: *Self, value: T) void {
            if (std.meta.eql(s.pending, value)) return;
            s.pending = value;
            s.node.flags = flags.mutable | flags.dirty;
            if (s.node.subs) |subs| {
                core.enter();
                defer core.leave();
                sys.propagate(subs, core.run_depth != 0);
                if (core.batch_depth == 0) core.flush();
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
            core.triggerCallback(.with(s, struct {
                fn read(x: *Self) void {
                    _ = x.get();
                }
            }.read));
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
            return .{ .ctx = &core.Callback.no_ctx, .getter = &struct {
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
            core.enter();
            defer core.leave();
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
                const prev = core.setActiveSub(n);
                c.value = c.getter(c.ctx, null);
                c.has_value = true;
                core.active_sub = prev;
                n.flags &= ~flags.recursed_check;
            }
            if (core.active_sub) |sub| sys.link(n, sub, core.cycle);
            return c.value;
        }

        /// The value, brought up to date, without depending on it.
        pub fn peek(c: *Self) T {
            const prev = core.setActiveSub(null);
            defer core.active_sub = prev;
            return c.get();
        }

        /// Lets go of what it read. A computed read by effects lets go
        /// when they stop; one read outside effects keeps its links until
        /// this (it is computed again if read after). What reads it must
        /// let go first.
        pub fn deinit(c: *Self) void {
            core.enter();
            defer core.leave();
            std.debug.assert(c.node.subs == null);
            core.Hooks.unwatched(&c.node);
        }

        fn clearPending(n: *Node, fl: u8) bool {
            n.flags = fl & ~flags.pending;
            return false;
        }

        fn updateComputed(c: *Self) bool {
            const n = &c.node;
            if (n.flags & core.has_child_effect != 0) core.unlinkChildEffects(n);
            n.deps_tail = null;
            n.flags = flags.mutable | flags.recursed_check;
            const prev = core.setActiveSub(n);
            core.cycle +%= 1;
            const old: ?T = if (c.has_value) c.value else null;
            c.value = c.getter(c.ctx, old);
            c.has_value = true;
            core.active_sub = prev;
            n.flags &= ~flags.recursed_check;
            core.purgeDeps(n);
            return if (old) |o| !std.meta.eql(o, c.value) else true;
        }

        fn update(n: *Node) bool {
            return updateComputed(@fieldParentPtr("node", n));
        }
    };
}
