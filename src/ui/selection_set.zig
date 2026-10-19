//! The rows chosen in a list or a table that lets the user choose several
//! (`ui.Selection`), after mygo's `Selection`: held by the keys of their
//! items (the list's `key`, else their rows), so the choice stays with
//! its items as rows come, go and move. The keys of items gone stay until
//! removed.
//!
//! Choosing, as Finder and the system's lists do: a click chooses its row
//! alone (a press on a row not chosen as the pointer goes down, on one
//! chosen at the release, so a drag of the choice keeps it), Shift
//! extends the choice from the row it began on (`anchor`), Cmd (Ctrl off
//! the Mac) adds a row or takes it out. A right-click on a row not chosen
//! chooses it before its menu opens, so the menu acts on the row it was
//! opened on; on a chosen row the choice stays (`menu_keeps_selection`
//! leaves it as it is either way).
const std = @import("std");

pub const Selection = struct {
    keys: std.AutoHashMapUnmanaged(u64, void) = .empty,
    gpa: std.mem.Allocator = std.heap.page_allocator,

    pub fn init(gpa: std.mem.Allocator) Selection {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Selection) void {
        s.keys.deinit(s.gpa);
    }

    /// Whether the row of key `k` is chosen.
    pub fn has(s: *const Selection, k: u64) bool {
        return s.keys.contains(k);
    }

    pub fn add(s: *Selection, k: u64) void {
        s.keys.put(s.gpa, k, {}) catch {};
    }

    pub fn remove(s: *Selection, k: u64) void {
        _ = s.keys.remove(k);
    }

    pub fn clear(s: *Selection) void {
        s.keys.clearRetainingCapacity();
    }

    /// How many rows are chosen.
    pub fn count(s: *const Selection) usize {
        return s.keys.count();
    }

    /// The keys chosen, in no order.
    pub fn iterator(s: *const Selection) std.AutoHashMapUnmanaged(u64, void).KeyIterator {
        return s.keys.keyIterator();
    }
};

/// The key of a row's item, as the app gives it.
pub const Key = struct {
    ctx: *const anyopaque,
    f: *const fn (ctx: *const anyopaque, row: usize) u64,

    /// `f(ctx, row)` as a key: `.of(s, S.keyOf)`.
    pub fn of(ctx: anytype, comptime f: fn (@TypeOf(ctx), usize) u64) Key {
        return .{ .ctx = @ptrCast(ctx), .f = struct {
            fn call(p: *const anyopaque, row: usize) u64 {
                return f(@ptrCast(@alignCast(p)), row);
            }
        }.call };
    }

    pub fn at(k: Key, row: usize) u64 {
        return k.f(k.ctx, row);
    }
};

/// What a list's or a table's choice keeps across frames, with a
/// `Selection` or without (the cursor's row alone). Its functions take
/// any state with its fields (a `ui.TableState` too).
pub const Choice = struct {
    /// The cursor's row: what the keys move, Enter submits.
    selected: ?usize = null,
    /// With a selection: the rows chosen, by their keys.
    selection: ?*Selection = null,
    /// The keys of the rows' items; the rows themselves without.
    key: ?Key = null,
    /// A right-click leaves the choice as it is.
    menu_keeps_selection: bool = false,
    /// The row Shift extends from.
    anchor: ?usize = null,
    /// The cursor's row and its item's key as the last frame left them.
    seen_row: ?usize = null,
    seen_key: ?u64 = null,
    anchor_key: ?u64 = null,

    pub fn keyOf(ch: anytype, row: usize) u64 {
        return if (ch.key) |k| k.at(row) else row;
    }

    /// Whether row `row` is chosen.
    pub fn chosen(ch: anytype, row: usize) bool {
        if (ch.selection) |s| return s.has(keyOf(ch, row));
        return ch.selected == row;
    }

    /// Follows the items of the cursor and the anchor to their rows, of
    /// `count`: with a key, the cursor's item moves with it, and is gone
    /// with it. With a selection, only while the selection holds the item
    /// (mygo's a6937a0): the app took it out of the selection, choosing
    /// another, at the row the item had (a file pasted, sorted there; an
    /// item renamed in its place), is the app moving the choice.
    pub fn sync(ch: anytype, count: usize) void {
        if (ch.selected) |s| if (s >= count) {
            ch.selected = if (count > 0) count - 1 else null;
        };
        if (ch.anchor) |a| if (a >= count) {
            ch.anchor = ch.selected;
        };
        const k = ch.key orelse return;
        if (ch.selected != null and ch.selected == ch.seen_row) if (ch.seen_key) |sk| {
            const holds = if (ch.selection) |s| s.has(sk) else true;
            if (holds) ch.selected = find(k, sk, ch.selected.?, count);
            if (ch.anchor) |_| if (ch.anchor_key) |ak| {
                ch.anchor = find(k, ak, ch.anchor.?, count) orelse ch.selected;
            };
        };
    }

    /// Remembers the cursor's item, for the next frame's `sync`.
    pub fn remember(ch: anytype) void {
        ch.seen_row = ch.selected;
        ch.seen_key = if (ch.selected) |s| keyOf(ch, s) else null;
        ch.anchor_key = if (ch.anchor) |a| keyOf(ch, a) else null;
    }

    /// Chooses row `row` alone, the cursor on it.
    pub fn only(ch: anytype, row: usize) bool {
        var changed = ch.selected != row or ch.anchor != row;
        ch.selected = row;
        ch.anchor = row;
        if (ch.selection) |s| {
            const k = keyOf(ch, row);
            changed = changed or s.count() != 1 or !s.has(k);
            s.clear();
            s.add(k);
        }
        return changed;
    }

    /// Chooses the rows from the anchor to `row` (besides those chosen,
    /// when `adding`), the cursor on `row`.
    pub fn extend(ch: anytype, row: usize, adding: bool) bool {
        const from = ch.anchor orelse ch.selected orelse row;
        ch.anchor = from;
        ch.selected = row;
        const s = ch.selection orelse return true;
        if (!adding) s.clear();
        var i = @min(from, row);
        while (i <= @max(from, row)) : (i += 1) s.add(keyOf(ch, i));
        return true;
    }

    /// Adds row `row` to the choice, or takes it out: the cursor and the
    /// anchor go to it.
    pub fn toggle(ch: anytype, row: usize) bool {
        ch.selected = row;
        ch.anchor = row;
        const s = ch.selection orelse return true;
        const k = keyOf(ch, row);
        if (s.has(k)) s.remove(k) else s.add(k);
        return true;
    }

    /// Every row of `count`.
    pub fn all(ch: anytype, count: usize) bool {
        const s = ch.selection orelse return false;
        if (count == 0) return false;
        for (0..count) |i| s.add(keyOf(ch, i));
        ch.anchor = 0;
        ch.selected = count - 1;
        return true;
    }

    /// A right-click on row `row`: chooses it alone when it is not chosen,
    /// with a selection (not with `menu_keeps_selection`).
    pub fn rightClick(ch: anytype, row: usize) bool {
        if (ch.selection == null or ch.menu_keeps_selection or chosen(ch, row)) return false;
        return only(ch, row);
    }
};

/// The row of key `k`, from `near` out, or null when no row has it.
fn find(key: Key, k: u64, near: usize, count: usize) ?usize {
    if (count == 0) return null;
    const at = @min(near, count - 1);
    if (key.at(at) == k) return at;
    var d: usize = 1;
    while (d < count) : (d += 1) {
        if (at + d < count and key.at(at + d) == k) return at + d;
        if (d <= at and key.at(at - d) == k) return at - d;
        if (at + d >= count and d > at) break;
    }
    return null;
}

test "the choice follows its item as rows come above it, and the app moving it" {
    const S = struct {
        ids: []const u64,
        fn keyOf(s: *const @This(), row: usize) u64 {
            return s.ids[row];
        }
    };
    var data: S = .{ .ids = &.{ 10, 20 } };
    const p: *const S = &data;
    var sel: Selection = .init(std.testing.allocator);
    defer sel.deinit();
    var ch: Choice = .{ .selected = 0, .selection = &sel, .key = .of(p, S.keyOf) };
    sel.add(10);
    ch.remember();
    // Rows come above: the cursor follows its item.
    data.ids = &.{ 1, 2, 10, 20 };
    ch.sync(4);
    try std.testing.expectEqual(@as(?usize, 2), ch.selected);
    ch.remember();
    // The app chooses another item at the row: the cursor stays there.
    data.ids = &.{ 1, 2, 5, 10, 20 };
    sel.clear();
    sel.add(5);
    ch.sync(5);
    try std.testing.expectEqual(@as(?usize, 2), ch.selected);
}
