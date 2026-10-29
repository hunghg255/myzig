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
            core.checkThread();
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
            core.checkThread();
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
        eql: *const fn (T, T) bool = &metaEql,
        free: ?*const fn (T) void = null,

        const Self = @This();

        pub const Options = struct {
            /// Whether a new value is the same as the previous one, so that
            /// what reads it doesn't run again: `std.meta.eql` (slices by
            /// address) unless given; compare slices with `std.mem.eql`.
            eql: *const fn (T, T) bool = &metaEql,
            /// Frees a value the computed owns once it is replaced (by
            /// anything but itself) or the computed `deinit`s, and only when
            /// no signal call is under way and no batch is open: a value read
            /// stays valid until the write that changes it has returned. The
            /// getter must not free its previous value itself.
            free: ?*const fn (T) void = null,
        };

        /// The same computed with `options`:
        /// `Computed([]u8).init(format).withOptions(.{ .free = freeText })`.
        pub fn withOptions(c: Self, options: Options) Self {
            var o = c;
            o.eql = options.eql;
            o.free = options.free;
            return o;
        }

        fn metaEql(a: T, b: T) bool {
            return std.meta.eql(a, b);
        }

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
        /// this (it is computed again if read after), and frees its value
        /// if it owns one. What reads it must let go first.
        pub fn deinit(c: *Self) void {
            core.enter();
            defer core.leave();
            std.debug.assert(c.node.subs == null);
            core.Hooks.unwatched(&c.node);
            if (c.free) |f| if (c.has_value) {
                core.retire(T, c.value, f);
                c.has_value = false;
                c.node.flags = flags.none;
            };
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
            const o = old orelse return true;
            if (c.free) |f| if (!std.meta.eql(o, c.value)) core.retire(T, o, f);
            return !c.eql(o, c.value);
        }

        fn update(n: *Node) bool {
            return updateComputed(@fieldParentPtr("node", n));
        }
    };
}
