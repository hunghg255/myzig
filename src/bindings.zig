//! What pages call and listen to, the same on every platform: the bound
//! services, the typed events, and the client generated from them
//! (`myzig.js`, `myzig.d.ts`).
const std = @import("std");
const ipc = @import("ipc.zig");
const tsgen = @import("tsgen.zig");

pub const Bindings = struct {
    services: std.StringHashMapUnmanaged(ipc.Service) = .empty,
    events: std.ArrayList(tsgen.Service) = .empty,
    /// The generated client, built once on first request.
    client_js: ?[]u8 = null,
    /// The generator, set by the first `bind` or `registerEvent`: apps
    /// that bind nothing link none of it, only the runtime's part.
    gen: ?*const Gen = null,

    const Gen = struct {
        js: *const fn (b: *Bindings, gpa: std.mem.Allocator) anyerror![]const u8,
        dts: *const fn (b: *Bindings, gpa: std.mem.Allocator) anyerror![]u8,
    };
    const generator: Gen = .{ .js = generateJs, .dts = generateDts };

    pub fn deinit(b: *Bindings, gpa: std.mem.Allocator) void {
        b.services.deinit(gpa);
        b.events.deinit(gpa);
        if (b.client_js) |js| gpa.free(js);
    }

    pub fn bind(b: *Bindings, gpa: std.mem.Allocator, service: anytype) !void {
        const T = @typeInfo(@TypeOf(service)).pointer.child;
        const svc = ipc.service(T, service);
        try b.services.put(gpa, svc.name, svc);
        b.gen = &generator;
        b.dropClient(gpa);
    }

    pub fn registerEvent(b: *Bindings, gpa: std.mem.Allocator, comptime E: type) !void {
        try b.events.append(gpa, E.client);
        b.gen = &generator;
        b.dropClient(gpa);
    }

    fn dropClient(b: *Bindings, gpa: std.mem.Allocator) void {
        if (b.client_js) |js| gpa.free(js);
        b.client_js = null;
    }

    /// The generated JavaScript client, served to pages at `/myzig.js`.
    pub fn clientJs(b: *Bindings, gpa: std.mem.Allocator) ![]const u8 {
        const g = b.gen orelse return tsgen.runtime_js;
        return g.js(b, gpa);
    }

    /// The generated declarations of the client (`myzig.d.ts`).
    pub fn clientDts(b: *Bindings, gpa: std.mem.Allocator) ![]u8 {
        const g = b.gen orelse return gpa.dupe(u8, tsgen.runtime_dts);
        return g.dts(b, gpa);
    }

    fn generateJs(b: *Bindings, gpa: std.mem.Allocator) ![]const u8 {
        if (b.client_js) |js| return js;
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try aw.writer.writeAll(tsgen.runtime_js);
        const services = try b.sortedServices(gpa);
        defer gpa.free(services);
        for (services) |svc| try aw.writer.writeAll(svc.js);
        for (b.events.items) |e| try aw.writer.writeAll(e.js);
        b.client_js = try aw.toOwnedSlice();
        return b.client_js.?;
    }

    fn sortedServices(b: *Bindings, gpa: std.mem.Allocator) ![]tsgen.Service {
        var parts: std.ArrayList(tsgen.Service) = .empty;
        var it = b.services.valueIterator();
        while (it.next()) |svc| try parts.append(gpa, svc.client);
        // Sorted, so the output is stable.
        std.mem.sort(tsgen.Service, parts.items, {}, struct {
            fn lt(_: void, x: tsgen.Service, y: tsgen.Service) bool {
                return std.mem.lessThan(u8, x.dts, y.dts);
            }
        }.lt);
        return parts.toOwnedSlice(gpa);
    }

    fn generateDts(b: *Bindings, gpa: std.mem.Allocator) ![]u8 {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try aw.writer.writeAll(tsgen.runtime_dts);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var parts: std.ArrayList(tsgen.Service) = .empty;
        try parts.appendSlice(a, try b.sortedServices(a));
        try parts.appendSlice(a, b.events.items);
        for (parts.items) |p| for (p.decls) |d| {
            if ((try seen.getOrPut(a, d.name)).found_existing) continue;
            try aw.writer.print("\n{s}\n", .{d.source});
        };
        for (parts.items) |p| try aw.writer.print("\n{s}", .{p.dts});
        return aw.toOwnedSlice();
    }

    /// Writes `myzig.js` and `myzig.d.ts` into `dir_path`.
    pub fn writeClient(b: *Bindings, gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, dir_path);
        var dir = try cwd.openDir(io, dir_path, .{});
        defer dir.close(io);
        const dts = try b.clientDts(gpa);
        defer gpa.free(dts);
        try dir.writeFile(io, .{ .sub_path = "myzig.d.ts", .data = dts });
        try dir.writeFile(io, .{ .sub_path = "myzig.js", .data = try b.clientJs(gpa) });
        std.log.info("myzig: wrote {s}/myzig.js and myzig.d.ts", .{dir_path});
    }
};
