//! The reactive graph, after alien-signals' `system.ts`: nodes joined by
//! links, each link at once in its subscriber's list of dependencies and
//! in its dependency's list of subscribers. A write marks what depends on
//! it (`propagate`); a read brings it up to date, checking only what may
//! have changed (`checkDirty`). `System` takes the hooks the node kinds
//! answer (`signals.zig`), as `createReactiveSystem` does.
const std = @import("std");

/// A node's state, bits of `Node.flags`.
pub const flags = struct {
    pub const none: u8 = 0;
    pub const mutable: u8 = 1;
    pub const watching: u8 = 2;
    pub const recursed_check: u8 = 4;
    pub const recursed: u8 = 8;
    pub const dirty: u8 = 16;
    pub const pending: u8 = 32;
};

pub const Kind = enum(u8) { signal, computed, effect, scope, trigger };

pub const Node = struct {
    deps: ?*Link = null,
    deps_tail: ?*Link = null,
    subs: ?*Link = null,
    subs_tail: ?*Link = null,
    flags: u8,
    kind: Kind,
    /// Signals and computeds: brings the value up to date, true when it
    /// changed.
    update: ?*const fn (*Node) bool = null,
};

pub const Link = struct {
    version: u32,
    dep: *Node,
    sub: *Node,
    prev_sub: ?*Link,
    next_sub: ?*Link,
    prev_dep: ?*Link,
    next_dep: ?*Link,
    /// Unlinked links wait here to be freed (`signals.zig`), their other
    /// fields left as they were for walks still holding them.
    next_free: ?*Link = null,
};

/// A stack for the graph's walks, on the machine stack until it is deep.
fn Stack(comptime T: type, comptime gpa: fn () std.mem.Allocator) type {
    return struct {
        buf: [16]T = undefined,
        len: usize = 0,
        more: std.ArrayList(T) = .empty,

        const Self = @This();

        fn push(s: *Self, v: T) void {
            if (s.len < s.buf.len) {
                s.buf[s.len] = v;
                s.len += 1;
            } else s.more.append(gpa(), v) catch @panic("signals: out of memory");
        }

        fn pop(s: *Self) ?T {
            if (s.more.pop()) |v| return v;
            if (s.len == 0) return null;
            s.len -= 1;
            return s.buf[s.len];
        }

        fn deinit(s: *Self) void {
            s.more.deinit(gpa());
        }
    };
}

/// `H` declares `update(*Node) bool`, `notify(*Node) void`,
/// `unwatched(*Node) void`, `newLink() *Link`, `freeLink(*Link) void` and
/// `gpa() Allocator`.
pub fn System(comptime H: type) type {
    const f = flags;
    return struct {
        pub fn link(dep: *Node, sub: *Node, version: u32) void {
            const prev_dep = sub.deps_tail;
            if (prev_dep != null and prev_dep.?.dep == dep) return;
            const next_dep = if (prev_dep) |p| p.next_dep else sub.deps;
            if (next_dep != null and next_dep.?.dep == dep) {
                next_dep.?.version = version;
                sub.deps_tail = next_dep;
                return;
            }
            const prev_sub = dep.subs_tail;
            if (prev_sub != null and prev_sub.?.version == version and prev_sub.?.sub == sub) return;
            const l = H.newLink();
            l.* = .{
                .version = version,
                .dep = dep,
                .sub = sub,
                .prev_dep = prev_dep,
                .next_dep = next_dep,
                .prev_sub = prev_sub,
                .next_sub = null,
            };
            sub.deps_tail = l;
            dep.subs_tail = l;
            if (next_dep) |n| n.prev_dep = l;
            if (prev_dep) |p| p.next_dep = l else sub.deps = l;
            if (prev_sub) |p| p.next_sub = l else dep.subs = l;
        }

        /// Takes `l` out of both lists; returns the dependency after it.
        pub fn unlink(l: *Link, sub: *Node) ?*Link {
            const dep = l.dep;
            const prev_dep = l.prev_dep;
            const next_dep = l.next_dep;
            const next_sub = l.next_sub;
            const prev_sub = l.prev_sub;
            if (next_dep) |n| n.prev_dep = prev_dep else sub.deps_tail = prev_dep;
            if (prev_dep) |p| p.next_dep = next_dep else sub.deps = next_dep;
            if (next_sub) |n| n.prev_sub = prev_sub else dep.subs_tail = prev_sub;
            H.freeLink(l);
            if (prev_sub) |p| {
                p.next_sub = next_sub;
            } else {
                dep.subs = next_sub;
                if (next_sub == null) H.unwatched(dep);
            }
            return next_dep;
        }

        /// Marks the subscribers of a written node, and theirs, pending,
        /// queuing the effects among them (`notify`).
        pub fn propagate(start: *Link, inner_write: bool) void {
            var l = start;
            var next = l.next_sub;
            var stack: Stack(?*Link, H.gpa) = .{};
            defer stack.deinit();

            top: while (true) {
                const sub = l.sub;
                var fl = sub.flags;

                if (fl & (f.recursed_check | f.recursed | f.dirty | f.pending) == 0) {
                    sub.flags = fl | f.pending;
                    if (inner_write) sub.flags |= f.recursed;
                } else if (fl & (f.recursed_check | f.recursed) == 0) {
                    fl = f.none;
                } else if (fl & f.recursed_check == 0) {
                    sub.flags = (fl & ~f.recursed) | f.pending;
                } else if (fl & (f.dirty | f.pending) == 0 and isValidLink(l, sub)) {
                    sub.flags = fl | (f.recursed | f.pending);
                    fl &= f.mutable;
                } else {
                    fl = f.none;
                }

                if (fl & f.watching != 0) H.notify(sub);

                if (fl & f.mutable != 0) {
                    if (sub.subs) |subs| {
                        l = subs;
                        if (subs.next_sub) |n| {
                            stack.push(next);
                            next = n;
                        }
                        continue;
                    }
                }

                if (next) |n| {
                    l = n;
                    next = n.next_sub;
                    continue;
                }

                while (stack.pop()) |v| {
                    if (v) |n| {
                        l = n;
                        next = n.next_sub;
                        continue :top;
                    }
                }
                break;
            }
        }

        /// Whether a pending `sub` must run again: walks its dependencies,
        /// bringing pending computeds up to date on the way.
        pub fn checkDirty(start: *Link, start_sub: *Node) bool {
            var l = start;
            var sub = start_sub;
            var stack: Stack(*Link, H.gpa) = .{};
            defer stack.deinit();
            var depth: usize = 0;
            var dirty = false;

            top: while (true) {
                const dep = l.dep;
                const fl = dep.flags;

                if (sub.flags & f.dirty != 0) {
                    dirty = true;
                } else if (fl & (f.mutable | f.dirty) == f.mutable | f.dirty) {
                    const subs = dep.subs.?;
                    if (H.update(dep)) {
                        if (subs.next_sub != null) shallowPropagate(subs);
                        dirty = true;
                    }
                } else if (fl & (f.mutable | f.pending) == f.mutable | f.pending) {
                    stack.push(l);
                    l = dep.deps.?;
                    sub = dep;
                    depth += 1;
                    continue;
                }

                if (!dirty) {
                    if (l.next_dep) |n| {
                        l = n;
                        continue;
                    }
                }

                while (depth > 0) {
                    depth -= 1;
                    l = stack.pop().?;
                    if (dirty) {
                        const subs = sub.subs.?;
                        if (H.update(sub)) {
                            if (subs.next_sub != null) shallowPropagate(subs);
                            sub = l.sub;
                            continue;
                        }
                        dirty = false;
                    } else {
                        sub.flags &= ~f.pending;
                    }
                    sub = l.sub;
                    if (l.next_dep) |n| {
                        l = n;
                        continue :top;
                    }
                }

                return dirty and sub.flags != 0;
            }
        }

        /// Marks the pending subscribers of a node that changed dirty.
        pub fn shallowPropagate(start: *Link) void {
            var it: ?*Link = start;
            while (it) |l| : (it = l.next_sub) {
                const sub = l.sub;
                const fl = sub.flags;
                if (fl & (f.pending | f.dirty) == f.pending) {
                    sub.flags = fl | f.dirty;
                    if (fl & (f.watching | f.recursed_check) == f.watching) H.notify(sub);
                }
            }
        }

        fn isValidLink(check: *Link, sub: *Node) bool {
            var it = sub.deps_tail;
            while (it) |l| : (it = l.prev_dep) {
                if (l == check) return true;
            }
            return false;
        }
    };
}
