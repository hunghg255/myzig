//! The example's files: a few languages to edit.
pub const File = struct { name: []const u8, text: []const u8 };

pub const files = [_]File{
    .{ .name = "lru.zig", .text =
    \\//! A small least-recently-used cache: a hash map for lookups and a
    \\//! doubly linked list for the order of use.
    \\const std = @import("std");
    \\
    \\pub fn Lru(comptime V: type) type {
    \\    return struct {
    \\        map: std.StringHashMapUnmanaged(*Node) = .empty,
    \\        order: std.DoublyLinkedList = .{},
    \\        cap: usize,
    \\
    \\        const Node = struct { key: []const u8, value: V, link: std.DoublyLinkedList.Node = .{} };
    \\
    \\        /// Moves the entry to the front: it was just used.
    \\        pub fn get(self: *@This(), key: []const u8) ?V {
    \\            const n = self.map.get(key) orelse return null;
    \\            self.order.remove(&n.link);
    \\            self.order.prepend(&n.link);
    \\            return n.value;
    \\        }
    \\
    \\        pub fn len(self: *const @This()) usize {
    \\            return self.map.count();
    \\        }
    \\    };
    \\}
    \\
    \\test "a cache of two" {
    \\    var cache: Lru(u32) = .{ .cap = 2 };
    \\    try std.testing.expectEqual(@as(usize, 0), cache.len());
    \\}
    \\
    },
    .{ .name = "server.go", .text = "// Package server serves greetings over HTTP.\n" ++
        "package server\n" ++
        "\n" ++
        "import (\n" ++
        "\t\"encoding/json\"\n" ++
        "\t\"net/http\"\n" ++
        "\t\"strings\"\n" ++
        "\t\"sync\"\n" ++
        ")\n" ++
        "\n" ++
        "// Server greets the names it is sent, and counts them.\n" ++
        "type Server struct {\n" ++
        "\tmu     sync.Mutex\n" ++
        "\tcounts map[string]int\n" ++
        "}\n" ++
        "\n" ++
        "/* ServeHTTP greets the name in the query,\n" ++
        "   as JSON. */\n" ++
        "func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {\n" ++
        "\tname := strings.TrimSpace(r.URL.Query().Get(\"name\"))\n" ++
        "\tif name == \"\" {\n" ++
        "\t\thttp.Error(w, \"missing name\", http.StatusBadRequest)\n" ++
        "\t\treturn\n" ++
        "\t}\n" ++
        "\ts.mu.Lock()\n" ++
        "\ts.counts[name]++\n" ++
        "\tn := s.counts[name]\n" ++
        "\ts.mu.Unlock()\n" ++
        "\tjson.NewEncoder(w).Encode(map[string]any{\"greeting\": \"Hello, \" + name, \"count\": n})\n" ++
        "}\n" ++
        "" },
    .{ .name = "stats.py", .text =
    \\"""Summary statistics of a list of numbers."""
    \\
    \\def mean(xs):
    \\    return sum(xs) / len(xs)
    \\
    \\def median(xs):
    \\    s = sorted(xs)
    \\    mid = len(s) // 2
    \\    if len(s) % 2:
    \\        return s[mid]
    \\    return (s[mid - 1] + s[mid]) / 2
    \\
    \\class Summary:
    \\    def __init__(self, xs):
    \\        self.mean = mean(xs)
    \\        self.median = median(xs)  # the middle value
    \\
    },
    .{ .name = "package.json", .text =
    \\{
    \\  "name": "code-editor",
    \\  "version": "1.0.0",
    \\  "private": true,
    \\  "scripts": { "dev": "vite", "build": "vite build" },
    \\  "dependencies": { "myzig-runtime": "^0.5.0" }
    \\}
    \\
    },
};

/// What the example changes in a file before showing it, so that the
/// changes page has changes from the start.
pub const edits = [_]struct { file: usize, find: []const u8, replace: []const u8 }{
    .{ .file = 0, .find = "    return struct {", .replace = "    return struct {\n        /// The entries, from the most recently used." },
    .{ .file = 0, .find = "            return n.value;", .replace = "            return n.value; // used just now" },
    .{ .file = 1, .find = "\ts.mu.Lock()", .replace = "\ts.mu.Lock()\n\tdefer s.mu.Unlock()" },
};
