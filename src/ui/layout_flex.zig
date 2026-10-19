//! The main sizes of a flex line's items, as CSS flexbox resolves them
//! (§9.7, as Chrome lays them out): each from its flex base size, the
//! free room shared by the items that grow, or the room lacking taken
//! from those that shrink in proportion to their base sizes less their
//! padding; an item that its minimum or maximum stops is frozen there and
//! the others share the rest, the minimum winning over the maximum.
const std = @import("std");

pub const Item = struct {
    /// The flex base size, and its hypothetical size: the base clamped
    /// by `min` and `max`. None of them below `pad`, its padding along
    /// the axis.
    base: f32,
    hyp: f32 = 0,
    min: f32 = 0,
    max: f32 = std.math.inf(f32),
    pad: f32 = 0,
    grow: f32 = 0,
    shrink: f32 = 0,
    /// The size resolved.
    main: f32 = 0,
    frozen: bool = false,
    violation: f32 = 0,

    /// Sets the hypothetical size from the base, the minimum and the
    /// maximum, none below the padding.
    pub fn init(it: Item) Item {
        var out = it;
        out.base = @max(it.base, it.pad);
        out.min = @max(it.min, it.pad);
        out.max = @max(it.max, it.pad);
        out.hyp = @max(out.min, @min(out.base, out.max));
        out.main = out.hyp;
        return out;
    }

    /// The base less the padding, which scales how much it shrinks.
    fn inner(it: Item) f32 {
        return @max(it.base - it.pad, 0);
    }

    fn factor(it: Item, growing: bool) f32 {
        return if (growing) it.grow else it.shrink * it.inner();
    }
};

/// Resolves the main sizes of `items` sharing `space` (the line's room
/// less its gaps).
pub fn resolve(items: []Item, space: f32) void {
    var sum_hyp: f32 = 0;
    for (items) |it| sum_hyp += it.hyp;
    const growing = sum_hyp < space;
    var any = false;
    var grow_sum: f32 = 0;
    for (items) |*it| {
        const f = it.factor(growing);
        it.frozen = f == 0 or (growing and it.base > it.hyp) or (!growing and it.base < it.hyp);
        it.main = if (it.frozen) it.hyp else it.base;
        if (!it.frozen) {
            any = true;
            if (growing) grow_sum += it.grow;
        }
    }
    if (!any) return;
    var initial_free = space;
    for (items) |it| initial_free -= if (it.frozen) it.hyp else it.base;
    var rounds: usize = 0;
    while (rounds <= items.len) : (rounds += 1) {
        var free = space;
        var sum: f32 = 0;
        var left = false;
        for (items) |it| {
            free -= if (it.frozen) it.main else it.base;
            if (!it.frozen) {
                left = true;
                sum += it.factor(growing);
            }
        }
        if (!left) return;
        // Factors summing to less than 1 share as much of the room.
        if (growing and sum < 1) {
            const capped = initial_free * sum;
            if (@abs(capped) < @abs(free)) free = capped;
        }
        var violation: f32 = 0;
        for (items) |*it| {
            if (it.frozen) continue;
            it.main = if (sum > 0) it.base + free * it.factor(growing) / sum else it.base;
            const clamped = @max(it.min, @min(it.main, it.max));
            it.violation = clamped - it.main;
            violation += it.violation;
            it.main = clamped;
        }
        if (violation == 0) return;
        // Those clamped the way the total moved freeze: by their minimums
        // or by their maximums.
        for (items) |*it| {
            if (!it.frozen and ((violation > 0 and it.violation > 0) or (violation < 0 and it.violation < 0))) it.frozen = true;
        }
    }
}

test "items grow from their bases, a minimum not counted in what is shared" {
    var items = [_]Item{ (Item{ .base = 0, .grow = 1 }).init(), (Item{ .base = 0, .min = 166, .grow = 1 }).init() };
    resolve(&items, 500);
    try std.testing.expectEqual(@as(f32, 250), items[0].main);
    try std.testing.expectEqual(@as(f32, 250), items[1].main);
}

test "items shrink by their bases less their padding" {
    var items = [_]Item{ (Item{ .base = 200, .shrink = 1 }).init(), (Item{ .base = 200, .pad = 100, .shrink = 1 }).init() };
    resolve(&items, 300);
    try std.testing.expectApproxEqAbs(@as(f32, 133.33), items[0].main, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 166.67), items[1].main, 0.01);
}

test "an item stopped by its maximum freezes, the others share the rest" {
    var items = [_]Item{ (Item{ .base = 0, .max = 50, .grow = 1 }).init(), (Item{ .base = 0, .grow = 1 }).init() };
    resolve(&items, 300);
    try std.testing.expectEqual(@as(f32, 50), items[0].main);
    try std.testing.expectEqual(@as(f32, 250), items[1].main);
    // A minimum over the maximum wins, and freezes.
    var two = [_]Item{ (Item{ .base = 163, .min = 42, .max = 14 }).init(), (Item{ .base = 8, .grow = 1 }).init() };
    resolve(&two, 50);
    try std.testing.expectEqual(@as(f32, 42), two[0].main);
    try std.testing.expectEqual(@as(f32, 8), two[1].main);
}
