---
name: zig-best-practice
description: Zig 0.16.0 best practices for memory safety, error handling, comptime patterns, memory layout, and concurrency. Use when writing, modifying, or reviewing Zig 0.16.0 code, including std.Io and task-based concurrency.
---

# Zig Best Practices

Patterns for writing safe, performant, and maintainable Zig code. Derived from production
systems programming and the Zig standard library design.

## Version and API Verification

This skill targets **Zig 0.16.0**. Before recommending a standard-library API, run `zig env`
and verify its signature in the installed `.std_dir`; do not carry forward an older API just
because the name still appears in an earlier codebase. In particular, use the 0.16 `std.Io`
file/runtime interfaces, the allocator-explicit `std.ArrayList`, and the replacement type
construction builtins such as `@Enum` and `@Struct`.

## 1. Memory Safety

### errdefer Chains: Protect Every Acquired Resource

When initializing multiple owned resources, protect each successful acquisition with an
immediate `errdefer` before the next fallible operation. A `try` that acquires no resource
does not need cleanup.

```zig
pub fn init(allocator: Allocator) error{OutOfMemory}!Self {
    var index = try Index.init(allocator, .{ ... });
    errdefer index.deinit(allocator);

    var cache = try Cache.init(allocator, .{ ... });
    errdefer cache.deinit(allocator);

    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    return Self{
        .index = index,
        .cache = cache,
        .buffer = buffer,
    };
}
```

If `Cache.init` fails, `index.deinit` runs. If `allocator.alloc` fails, both
`cache.deinit` and `index.deinit` run. No leaks in any failure path. *[TigerBeetle]*

### Commit Barriers: Keep the Rest of the Scope Infallible

After ownership or initialized state is committed, earlier `errdefer` cleanup may
become invalid. Mark that boundary with `errdefer comptime unreachable;` when all
remaining work must stay infallible:

```zig
try globals.pool.init(allocator);
errdefer globals.pool.deinit(allocator);

try globals.index.init(allocator);
errdefer globals.index.deinit(allocator);

globals.ready = true; // The initialized state is now published.
errdefer comptime unreachable;

finishInitializationInfallible();
```

This is a compile-time tripwire, not cleanup. A later `try`, `return error.X`, or
other reachable error return makes compilation fail, forcing the ownership and
rollback design to be reconsidered instead of silently running stale cleanup and
risking a double-free or rollback of committed state. Keep the barrier immediately
after the commit point. *[Mitchell Hashimoto](https://x.com/mitchellh/status/1998119357793403118)*

### Loop errdefer: Partial Array Cleanup

When initializing array elements one by one, `errdefer` must clean up `[0..i]`:

```zig
const blocks = try allocator.alloc(BlockPtr, count);
errdefer allocator.free(blocks);

for (blocks, 0..) |*block, i| {
    errdefer for (blocks[0..i]) |b| allocator.free(b);
    block.* = try allocate_block(allocator);
}
errdefer for (blocks) |b| allocator.free(b);
```

Two errdefers: the inner handles failure mid-loop (`[0..i]`), the outer handles
failure after the loop (all elements). *[TigerBeetle]*

### Two-Phase Create-Then-Init

When a struct must live on the heap (e.g., for pointer stability or self-references),
separate allocation from initialization:

```zig
const pool = try allocator.create(MessagePool);
errdefer allocator.destroy(pool);

pool.* = try MessagePool.init(allocator, options);
errdefer pool.deinit(allocator);
```

Each phase has its own errdefer: `destroy` for the allocation, `deinit` for the
initialized state. If `init` fails, only `destroy` runs (correct). If later code
fails, both `deinit` and `destroy` run (correct). *[TigerBeetle]*

### `defer if`: Conditional Cleanup for Optionals

When a resource is conditionally acquired, declare it as `null` with an immediate
`defer if`:

```zig
fn run(io: std.Io, options: Options, allocator: Allocator) !void {
    var trace_file: ?std.Io.File = null;
    defer if (trace_file) |file| file.close(io);

    var exe_path: ?[:0]const u8 = null;
    defer if (exe_path) |path| allocator.free(path);

    // Later, conditionally assign:
    if (options.trace) |trace_path| {
        trace_file = try std.Io.Dir.cwd().createFile(io, trace_path, .{});
    }
}
```

The `defer` captures the variable by reference and evaluates at scope exit. It
sees the final value, so cleanup runs only if the resource was actually acquired.
*[TigerBeetle]*

### Deinit Reversal and Poisoning

Deinitialization must reverse initialization order. Assigning `undefined` after cleanup can help
safe builds expose accidental reuse, but it is not a runtime guarantee in optimized builds:

```zig
pub fn deinit(self: *Self, allocator: Allocator) void {
    // Reverse order of init
    allocator.free(self.buffer);
    self.cache.deinit(allocator);
    self.index.deinit(allocator);
    self.* = undefined;  // Poison: any access after deinit is caught
}
```

For large buffers, conditional poisoning avoids performance cost:

```zig
if (build_options.verify) {
    @memset(message.buffer, undefined);
}
```
*[TigerBeetle]*

### Resource Grouping

Visually pair allocation with its cleanup. A blank line before + `defer` immediately
after makes leaks obvious in review:

```zig
var io = try IO.init(128, 0);
defer io.deinit();

var pool = try MessagePool.init(allocator, .client);
defer pool.deinit(allocator);
```

If you see allocation without a `defer` on the next line, investigate.
*[TigerBeetle]*

### errdefer for Diagnostics

Use `errdefer` to log context before an error propagates:

```zig
errdefer log.err("failed to parse config at line {}", .{line_number});
const value = try parseValue(input);
```
*[TigerBeetle]*

### Allocator Passing

Pass allocators explicitly as parameters. Don't store them in structs unless
enforcing a lifecycle:

```zig
// GOOD: caller controls allocator lifetime
pub fn init(allocator: Allocator, options: Options) !Self { ... }
pub fn deinit(self: *Self, allocator: Allocator) void { ... }
```
*[TigerBeetle]*

### Arena Allocator for Temporary Work

Use `ArenaAllocator` when many temporary allocations share a single lifetime.
One `deinit` frees everything — no need to track individual allocations:

```zig
var arena = std.heap.ArenaAllocator.init(gpa);
defer arena.deinit();
const alloc = arena.allocator();

// All allocations below are freed at once by arena.deinit()
var seen = std.AutoHashMap(u64, void).init(alloc);
var buffer = try alloc.alloc(u8, 4096);
// No individual defer/free needed
```

Ideal for validation passes, serialization, and any scope with many short-lived
allocations. *[Ghostty]*

## 2. Infallible Runtime Operations

### The Principle

**Runtime state-changing operations must not fail.** If an operation partially modifies
state then fails (e.g., OOM), you need to revert — which is complex and error-prone.
Instead: pre-allocate capacity at init where errors can be handled, then operate
infallibly at runtime where rollback would be dangerous. *[TigerBeetle]*

### HashMap

```zig
// At init: pre-allocate, can fail here
try map.ensureTotalCapacity(allocator, max_entries);

// At runtime: infallible
map.putAssumeCapacityNoClobber(key, value);   // assert key is new
map.putAssumeCapacity(key, value);            // allows overwrite
map.fetchPutAssumeCapacity(key, value);       // returns old value

// CRITICAL: putAssumeCapacity on HashMaps with no Value will NOT clobber.
// Use getOrPutAssumeCapacity instead:
const gop = map.getOrPutAssumeCapacity(key);
if (!gop.found_existing) {
    gop.key_ptr.* = key;
}
gop.value_ptr.* = value;
```
*[TigerBeetle, Zig stdlib]*

### ArrayList

```zig
// addOneAssumeCapacity: get pointer to uninitialized slot, then write
const entry = list.addOneAssumeCapacity();
entry.* = .{ .id = id, .data = data };

// appendAssumeCapacity: append a value
list.appendAssumeCapacity(value);

// appendSliceAssumeCapacity: bulk append
list.appendSliceAssumeCapacity(items);
```
*[TigerBeetle, Zig stdlib]*

### BoundedArray (Comptime Capacity)

For arrays with compile-time-known capacity, use assert-based bounds (no errors):

```zig
pub fn BoundedArrayType(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T = undefined,
        count: u32 = 0,

        pub fn push(array: *@This(), item: T) void {
            assert(!array.full());   // Panic, not error
            array.buffer[array.count] = item;
            array.count += 1;
        }
    };
}
```
*[TigerBeetle]*

### RingBuffer

```zig
ring.push_assume_capacity(item);       // assert space, no error
ring.push_head_assume_capacity(item);  // same, prepend
```
*[TigerBeetle]*

### Rollback Log Pattern

When operations need to be reversible by design (not due to OOM), use a pre-allocated
rollback log:

```zig
if (scope_is_active) {
    if (old_value) |old| {
        // Infallible: log is pre-allocated
        rollback_log.appendAssumeCapacity(old);
    } else {
        rollback_log.appendAssumeCapacity(tombstone_from_key(key));
    }
}
```
*[TigerBeetle]*

## 3. Error Handling

### Narrow Error Sets

Each function declares the narrowest possible error set:

```zig
pub fn push(self: *RingBuffer, item: T) error{NoSpaceLeft}!void { ... }
pub fn parse(string: []const u8) error{InvalidRelease}!Result { ... }
pub fn init(allocator: Allocator) error{OutOfMemory}!Self { ... }
```
*[TigerBeetle]*

### Error Set Composition with `||`

Combine error sets from different sources into a single union:

```zig
// Merge related error sets
const IoError = std.Io.Reader.Error || std.Io.Writer.Error;

// Compose domain errors with system errors
const WatcherError = std.mem.Allocator.Error ||
    std.Io.ConcurrentError ||
    std.Thread.SpawnError;

// Merge across backend implementations
fn BackendErrorSet(comptime backends: []const Backend) type {
    var Set: type = error{};
    for (backends) |be| {
        Set = Set || be.Api().AcceptError;
    }
    return Set;
}
```

Use `||` when a function can fail with errors from multiple subsystems, or when
building a unified error type across compile-time-selected backends. *[Bun, libxev]*

### `catch |err| switch`: Exhaustive Error Recovery

The primary pattern for non-trivial error handling. List every error explicitly:

```zig
const bytes_read = result catch |err| switch (err) {
    error.InputOutput => {
        // Specific recovery logic
        log.warn("sector error: offset={}, subdividing...", .{offset});
        self.start_read(read, 0);
        return;
    },
    error.WouldBlock,
    error.ConnectionResetByPeer,
    error.SystemResources,
    => {
        log.err("fatal read: error={s}", .{@errorName(err)});
        @panic("unrecoverable read error");
    },
};
```
*[TigerBeetle]*

### `catch unreachable`: Proven Invariants

Use when prior validation guarantees the operation cannot fail. **Always comment why:**

```zig
var decoder = Decoder.init(body, .{
    .element_size = operation.event_size(),
}) catch unreachable; // Already validated by `input_valid()`.

const ts = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch unreachable;
```
*[TigerBeetle]*

### `orelse` Patterns

```zig
// Propagate "not found" as domain result
const item = self.get(id) orelse return .not_found;

// Convert optional to specific error
const value = parts.next() orelse return error.InvalidFormat;

// Silently skip if not available
const writer = options.writer orelse return;

// Guaranteed to exist by invariant
const top = stack.peek() orelse unreachable;
```
*[TigerBeetle]*

### Exhaustive Switches

List all cases explicitly. Avoid bare `else =>` which hides missing cases when
new variants are added:

```zig
// GOOD: compiler catches new variants
switch (status) {
    .none, .pending => assert(pending_id == 0),
    .posted, .voided, .expired => assert(pending_id != 0),
}

// For comptime-impossible cases
.pulse => comptime unreachable,
```
*[TigerBeetle]*

### Return Type Precision

Use the simplest return type. Simpler types reduce call-site complexity:

`void` > `bool` > `u64` > `?u64` > `!u64` > `error{X}!T`

```zig
fn on_callback(grid: *Grid) void { ... }        // No failure possible
pub fn empty(self: *const Queue) bool { ... }    // Simple predicate
pub fn pop(self: *RingBuffer) ?T { ... }         // May have nothing
pub fn init(alloc: Allocator) error{OutOfMemory}!Self { ... }  // Specific error
```
*[TigerBeetle]*

### `@panic` Messages

Use for unrecoverable invariant violations. Messages must be specific:

```zig
@panic("impossible read");
@panic("latent sector error: no spare sectors to reallocate");
@panic("timeout was not reset correctly");
```
*[TigerBeetle]*

### `error.SkipZigTest` for Platform-Specific Tests

Return `error.SkipZigTest` to skip tests on unsupported platforms:

```zig
test "pty read/write" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }
    // Platform-specific test body...
}

test "io_uring completion" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Linux-only test...
}
```

The Zig test runner recognizes this error and reports the test as skipped
rather than failed. *[libxev]*

### Comptime Error Type Assertions

Verify error types at compile time to guard exhaustive handling:

```zig
comptime assert(@TypeOf(err) == error{OutOfMemory});
```

Ensures that a `catch` block handles exactly the expected error set, catching
drift when upstream functions change their error types. *[Ghostty]*

## 4. Comptime & Generics

### Type Functions

Return `type` from comptime-parameterized functions:

```zig
pub fn QueueType(comptime T: type) type {
    return struct {
        head: ?*T = null,
        tail: ?*T = null,
        count: u32 = 0,

        pub fn push(self: *@This(), node: *T) void { ... }
        pub fn pop(self: *@This()) ?*T { ... }
    };
}
```
*[TigerBeetle]*

### Comptime Assertions in Structs

Validate layout and invariants at compile time:

```zig
pub const Header = extern struct {
    checksum: u128,
    command: Command,
    size: u32,
    padding: [7]u8 = @splat(0),

    comptime {
        assert(@sizeOf(Header) == 64);
        assert(@sizeOf(Header) % @alignOf(u128) == 0);
        // Verify no compiler-inserted padding
        assert(no_padding(Header));
    }
};
```
*[TigerBeetle]*

### Interface via `@fieldParentPtr`

Implement interfaces by embedding subsystems as named fields. Callbacks receive
the subsystem pointer and recover the parent:

```zig
const Server = struct {
    grid: Grid,
    journal: Journal,
    state_machine: StateMachine,

    fn grid_callback(grid: *Grid) void {
        // Recover Server from its grid field
        const self: *Server = @alignCast(@fieldParentPtr("grid", grid));
        // Now has full access to Server
        self.state_machine.open(sm_callback);
    }

    fn sm_callback(sm: *StateMachine) void {
        const self: *Server = @alignCast(
            @fieldParentPtr("state_machine", sm),
        );
    }
};
```

Zero-cost polymorphism — no vtable indirection. Works because structs have
stable addresses (statically allocated). *[TigerBeetle]*

### Type Erasure for Callbacks

Store typed callbacks as untyped function pointers:

```zig
pub fn read(
    self: *IO,
    comptime Context: type,
    context: Context,
    comptime callback: fn (Context, *Completion, ReadError!usize) void,
    completion: *Completion,
) void {
    completion.* = .{
        .context = context,
        .callback = struct {
            fn erased(ctx: ?*anyopaque, comp: *Completion, res: *const anyopaque) void {
                callback(
                    @ptrCast(@alignCast(ctx)),
                    comp,
                    @as(*const ReadError!usize, @ptrCast(@alignCast(res))).*,
                );
            }
        }.erased,
    };
}
```
*[TigerBeetle]*

### Tagged Unions for State Machines

```zig
const Phase = union(enum) {
    idle: void,
    loading: struct { offset: u64, remaining: u32 },
    processing: struct { operation: Op, timestamp: u64 },
    done: void,
};

// Dispatch — always exhaustive
switch (self.phase) {
    .idle => { ... },
    .loading => |l| { ... },
    .processing => |p| { ... },
    .done => { ... },
}
```
*[TigerBeetle]*

### Labeled Blocks for Computed Values

Multi-statement value computation with `blk:` / `break :blk`:

```zig
// Comptime constant with complex initialization
pub const slot_bases = bases: {
    var array = std.enums.EnumArray(Tag, u32).initFill(0);
    var next: u32 = 0;
    for (std.enums.values(Tag)) |tag| {
        array.set(tag, next);
        next += slot_limits.get(tag);
    }
    break :bases array;
};

// Runtime conditional computation
const timeout: u64 = timeout: {
    if (options.timeout_ms) |ms| {
        break :timeout ms * std.time.ns_per_ms;
    }
    break :timeout default_timeout_ns;
};
```
*[TigerBeetle]*

### Dynamic Type Construction with Dedicated Builtins

Build types from comptime data:

```zig
const MyEnum = blk: {
    var field_names: [config.items.len][:0]const u8 = undefined;
    var field_values: [config.items.len]u32 = undefined;
    for (config.items, 0..) |item, i| {
        field_names[i] = item.name;
        field_values[i] = @intCast(i);
    }
    break :blk @Enum(u32, .exhaustive, &field_names, &field_values);
};
```

`@Type` was removed in Zig 0.16.0. Use the dedicated builtin matching the type being
constructed: `@Enum`, `@Struct`, `@Union`, `@Pointer`, `@Fn`, `@Int`, or `@Tuple`.
*[TigerBeetle, libxev]*

### `@hasDecl` / `@hasField` for Compile-Time Interface Checking

Verify that a type implements required methods or fields at compile time:

```zig
pub fn Cow(comptime T: type, comptime VTable: type) type {
    return union(enum) {
        borrowed: *const T,
        owned: T,

        fn copy(this: *const T, allocator: Allocator) Allocator.Error!T {
            if (!@hasDecl(VTable, "copy"))
                @compileError(@typeName(VTable) ++ " needs `copy()` function");
            return try VTable.copy(this, allocator);
        }
    };
}

// Optional method dispatch
if (comptime std.meta.hasFn(Type, "reset")) {
    node.data.reset();
}
```

Use `@hasDecl` for hard interface requirements (emit `@compileError` if missing).
Use `std.meta.hasFn` / `@hasDecl` with `if` for optional capabilities. *[Bun]*

### Compile-Time Platform / Backend Selection

Use `switch` on `builtin.os.tag` or config enums to select implementations:

```zig
pub const Backend = enum {
    io_uring, epoll, kqueue, wasi_poll, iocp,

    pub fn default() Backend {
        return switch (builtin.os.tag) {
            .linux => .io_uring,
            .ios, .macos, .freebsd => .kqueue,
            .wasi => .wasi_poll,
            .windows => .iocp,
            else => @compileError("no default backend"),
        };
    }
};

// Select implementation type at compile time
pub fn Loop(comptime backend: Backend) type {
    return switch (backend) {
        .io_uring => @import("backend/io_uring.zig").Loop,
        .epoll => @import("backend/epoll.zig").Loop,
        .kqueue => @import("backend/kqueue.zig").Loop,
    };
}
```
*[libxev]*

### Compile-Time Configuration-Driven Behavior

Use comptime options to specialize behavior. `usingnamespace` was removed in Zig 0.16.0;
keep the method declaration explicit and reject disabled operations at comptime:

```zig
pub const StreamOptions = struct {
    read: ReadMethod = .none,
    write: WriteMethod = .none,
    close: bool = false,

    pub const ReadMethod = enum { none, read, recv };
    pub const WriteMethod = enum { none, write, send };
};

pub fn GenericStream(comptime xev: type, comptime options: StreamOptions) type {
    return struct {
        pub fn read(self: *@This(), buf: []u8) !usize {
            if (comptime options.read == .none) {
                @compileError("read support is disabled");
            }
            return xev.read(options.read, self, buf);
        }
    };
}
```
*[libxev]*

### `@setEvalBranchQuota`

Increase comptime evaluation budget for complex reflection:

```zig
@setEvalBranchQuota(32_000);
inline for (std.meta.fields(LargeStruct)) |field| {
    // Process each field
}
```
*[TigerBeetle]*

### `void` as Type-Level Feature Flag

Replace unavailable platform types with `void` to eliminate dead code at comptime:

```zig
const macos = switch (builtin.os.tag) {
    .macos => @import("macos"),
    else => void,
};

const DisplayLink = switch (builtin.os.tag) {
    .macos => *macos.video.DisplayLink,
    else => void,
};

// Usage: comptime check removes entire code path on non-macOS
if (comptime DisplayLink != void) {
    // macOS-specific display link setup
}
```

The compiler completely eliminates branches on `void` types. No runtime cost,
no `#ifdef`-style preprocessor. *[Ghostty]*

### Comptime String Processing with `@embedFile`

Process embedded files (e.g., shader includes) at compile time:

```zig
fn loadShader(comptime path: []const u8) [:0]const u8 {
    return comptime processIncludes(
        @embedFile(path),
        std.Io.Dir.path.dirname(path).?,
    );
}

fn processIncludes(
    comptime contents: [:0]const u8,
    comptime basedir: []const u8,
) [:0]const u8 {
    @setEvalBranchQuota(100_000);
    var i: usize = 0;
    while (i < contents.len) : (i += 1) {
        if (std.mem.startsWith(u8, contents[i..], "#include")) {
            // Extract filename, recursively embed
            return std.fmt.comptimePrint("{s}{s}{s}", .{
                contents[0..i],
                @embedFile(basedir ++ "/" ++ filename),
                processIncludes(contents[end..], basedir),
            });
        }
    }
    return contents;
}
```

Recursive comptime preprocessor — resolves `#include` directives by embedding
files during compilation. Zero runtime I/O. *[Ghostty]*

### Structural Equality via Type Introspection

Zig 0.16's `std.meta.eql` already handles structs, optionals, error unions, arrays, vectors,
and tagged unions. Add a domain hook only where a type defines different semantics:

```zig
pub fn structuralEqual(comptime T: type, old: T, new: T) bool {
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (@hasDecl(T, "equal")) return old.equal(new);
        },
        else => {},
    }
    return std.meta.eql(old, new);
}
```

`std.meta.eql` compares pointers and slices by identity, not slice contents. If content equality
is part of a domain contract, implement that type's `equal` method explicitly. *[Zig stdlib, Ghostty]*

## 5. Memory Layout & Copy Safety

### Extern Struct with Layout Assertions

For wire formats, disk formats, or FFI types:

```zig
pub const Record = extern struct {
    id: u128,
    timestamp: u64,
    flags: u32,
    padding: [4]u8 = @splat(0),  // Deterministic zero padding

    comptime {
        assert(@sizeOf(Record) == 32);
        assert(@offsetOf(Record, "id") == 0);
        assert(@offsetOf(Record, "timestamp") == 16);
        assert(no_padding(Record));  // No hidden compiler padding
    }
};
```
*[TigerBeetle]*

### `@splat(0)` for Deterministic Padding

All padding and reserved fields must be zero-initialized. This prevents information
leakage and ensures deterministic checksums:

```zig
reserved: [88]u8 = @splat(0),
padding: [7]u8 = @splat(0),
```
*[TigerBeetle]*

### Safe Copy Functions

Wrap `@memcpy` with directional and size safety:

```zig
// copy_disjoint: ASSERTS regions don't overlap
copy_disjoint(.exact, T, target, source);   // target.len == source.len
copy_disjoint(.inexact, T, target, source); // target.len >= source.len

// copy_left: overlapping, target before source (forward copy)
copy_left(.exact, T, target, source);

// copy_right: overlapping, target after source (backward copy)
copy_right(.exact, T, target, source);
```

The precision enum (`.exact` vs `.inexact`) asserts the length relationship,
catching size mismatches at runtime. *[TigerBeetle]*

### Safe Byte-to-Type Reinterpretation

```zig
// .exact: byte length must be exact multiple of element size
const items = bytes_as_slice(.exact, Item, raw_bytes);

// .inexact: truncate to largest whole number of elements
const headers = bytes_as_slice(.inexact, Header, raw_bytes);
```
*[TigerBeetle]*

### Aligned Allocation for Direct I/O

```zig
const buffers = try allocator.alignedAlloc(
    [message_size_max]u8,
    .fromByteUnits(sector_size), // std.mem.Alignment for Direct I/O
    count,
);

comptime {
    assert(message_size_max % sector_size == 0);
}
```
*[TigerBeetle]*

### Packed Struct Bitfields

Use `packed struct` for bit-level memory layout control:

```zig
const Sync = packed struct {
    idle: u14 = 0,
    spawned: u14 = 0,
    unused: bool = false,
    notified: bool = false,
    state: enum(u2) {
        pending = 0,
        signaled,
        waking,
        shutdown,
    } = .pending,
};

// With explicit backing type
pub const Flags = packed struct(u8) {
    allow_variance: bool = false,
    allow_const: bool = false,
    allow_empty: bool = false,
    _: u5 = 0,  // Explicit padding bits
};
```

Packed structs fit into a single integer, enabling atomic load/store of the
entire struct. Useful for thread-safe status words and protocol flags. *[Bun]*

### Sentinel Values

Use `maxInt` for boundary markers in sorted structures:

```zig
pub const sentinel_key: Key = .{
    .field = math.maxInt(Field),
    .timestamp = math.maxInt(u64),
};
```
*[TigerBeetle]*

### Explicit Division Intent

Show the reader you've considered rounding:

```zig
@divExact(total_size, block_size);           // Must divide evenly
@divFloor(numerator, denominator);           // Round toward negative infinity
@divTrunc(numerator, denominator);           // Round toward zero
div_ceil(numerator, denominator);            // Round up
```
*[TigerBeetle]*

### Branch Hints for Hot Paths

```zig
pub inline fn select_unpredictable(comptime T: type, flag: bool, a: T, b: T) T {
    @branchHint(.unpredictable);
    return if (flag) a else b;
}
```

`@branchHint` communicates an expectation to the optimizer; it does not guarantee branchless
machine code. Check the generated code or benchmark before describing a path as branchless.
*[TigerBeetle]*

### SIMD with `@Vector`

Use `@Vector` for data-parallel operations that map to hardware SIMD:

```zig
pub const F32x4 = @Vector(4, f32);
pub const Mat = [4]F32x4;

pub fn ortho2d(left: f32, right: f32, bottom: f32, top: f32) Mat {
    const w = right - left;
    const h = top - bottom;
    return .{
        .{ 2 / w, 0, 0, 0 },
        .{ 0, 2 / h, 0, 0 },
        .{ 0, 0, -1, 0 },
        .{ -(right + left) / w, -(top + bottom) / h, 0, 1 },
    };
}
```

`@Vector` operations compile to SIMD instructions (SSE, AVX, NEON) when
available. Use for math-heavy hot paths like matrix transforms, color
operations, and batch processing. *[Ghostty]*

### Memory-Mapped I/O

Use `mmap` for large, page-aligned allocations with OS-level lifecycle:

```zig
pub fn init(cap: Capacity) !Page {
    const l = layout(cap);
    assert(l.total_size % std.heap.page_size_min == 0);
    const backing = try std.posix.mmap(
        null,
        l.total_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    errdefer std.posix.munmap(backing);
    // ...
}
```

Anonymous mmap is guaranteed zero-initialized by the OS. Useful for terminal
page buffers, large lookup tables, and any allocation that benefits from
page-granularity lifecycle control. *[Ghostty]*

### Cache-Line Aligned Buffers

Align buffers to cache line boundaries to prevent false sharing:

```zig
var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
```

Critical for buffers accessed from multiple threads. `std.atomic.cache_line`
is the platform's cache line size (typically 64 bytes). *[Ghostty]*

## 6. Naming & Style

### Naming Rules

- **`snake_case`** for functions, variables, file names.
- **`PascalCase`** for types and structs.
- **Units/qualifiers last**, sorted by descending significance:

```zig
latency_ms_max    // not: max_latency_ms
latency_ms_min    // lines up with latency_ms_max
offset_bytes      // unit last
accounts_count    // qualifier last
```

- **No abbreviations**: `source`/`target` not `src`/`dest`.
- **Proper acronym capitalization**: `VSRState`, `IOCompletion`.
- **Related names with same character count** for visual alignment.
- **Callbacks go last** in parameter lists.

*[TigerBeetle]*

### Ownership in Method Names

Encode ownership transfer in the **verb**, matching the std library — don't invent `Owned`/`take` affixes:

- **Insert (the container takes the value):** `put` / `add` / `append`. Handing a value in already
  *implies* the container now holds it — never `putOwned`.
- **`Owned` means the CALLER owns the RESULT.** `std.ArrayList.toOwnedSlice()` hands the slice to the
  caller. So naming an *insert* `addOwned` **inverts** the convention (it reads as "returns something I
  own"). Reserve `*Owned` for "the returned value is now yours."
- **Read / borrow:** `get` (returns the value) / `getPtr` (returns a pointer *into* the container — a borrow).
- **Remove + return ownership:** `pop` (last), `swapRemove` / `orderedRemove` (by index); for maps the
  **`fetch*`** prefix = "do the op AND return the displaced/removed item" so the caller can free it:
  `fetchRemove`, `fetchPut`.

```zig
map.put(key, value);                          // container takes value (transfer implied — not putOwned)
const v = map.get(key);                       // borrow / copy out
const kv = map.fetchRemove(key);              // remove AND hand the entry back (you free it)
const last = list.pop();                      // remove + return (you own it now)
const owned = list.toOwnedSlice(allocator);   // caller now owns the returned slice
```

Anti-examples: `addOwned(x)` → `add(x)` / `put(x)`; `takeHeadState()` → `popHead()` / `fetchRemoveHead()`.
`take`/`Owned`-on-insert are non-idiomatic, and `Owned`-on-insert inverts std's meaning. *[Zig stdlib]*

### Named Arguments via Struct

Use `options: struct` when arguments can be mixed up (e.g., two `u64` params):

```zig
fn memcpy(options: struct {
    source: [*]const u8,
    target: [*]u8,
    count: usize,
}) void { ... }
```
*[TigerBeetle]*

### Choose Sizes by Boundary

Use `usize` for slice indexes, lengths, and allocator sizes. Use fixed-width integers when the
width belongs to a wire, disk, protocol, or bounded-domain contract:

```zig
const item = items[index];       // index: usize
const bytes = try allocator.alloc(u8, byte_count); // byte_count: usize

record_count: u32,               // fixed-width on-disk field
file_offset: u64,                // fixed-width format contract
```
*[TigerBeetle]*

### Inline Functions

Plain `fn` lets the optimizer choose inlining. Use `inline fn` when call-site comptime semantics
require it, or when measurement demonstrates that forced inlining is worth the code-size cost:

```zig
fn hash(value: Value) u64 { ... }
inline fn dispatch(comptime backend: Backend, value: Value) Result { ... }
```
*[TigerBeetle]*

## 7. Code Organization

### Import Order

1. Zig builtins: `builtin`, `std`
2. Extended stdlib utilities
3. Commonly used members: `assert`, `mem`
4. Project modules
5. Type aliases

```zig
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const constants = @import("constants.zig");
const log = std.log.scoped(.module_name);

const MyType = @import("my_module.zig").MyType;
```
*[TigerBeetle]*

### Scoped Logging

Every module that logs should create a scoped logger:

```zig
const log = std.log.scoped(.storage);
```
*[TigerBeetle]*

### Struct Member Ordering

Fields first, then types, then methods:

```zig
const Tracer = struct {
    time: Time,
    process_id: ProcessID,

    const ProcessID = struct { cluster: u128, replica: u8 };

    pub fn init(allocator: Allocator) !Tracer { ... }
    pub fn deinit(self: *Tracer) void { ... }
};
```
*[TigerBeetle]*

### Assertions as Documentation

- Assert actual invariants; do not impose an assertion quota on every function.
- Split compound assertions: `assert(a); assert(b);` not `assert(a and b);`.
- Single-line implication: `if (a) assert(b);`
- State invariants positively: `if (index < length)` not `if (index >= length)`.
- Comptime assertions for constant relationships.

*[TigerBeetle]*

### Intrusive Data Structures

Embed link fields in nodes instead of allocating separate containers:

```zig
const Node = struct {
    data: Data,
    back: ?*@This() = null,
    next: ?*@This() = null,
};

const List = DoublyLinkedListType(Node, .back, .next);
```

Benefits: zero allocation, O(1) insert/remove, nodes can be in multiple lists
via distinct field pairs. *[TigerBeetle]*

**Intrusive priority queue (pairing heap):**

```zig
pub fn IntrusiveHeap(
    comptime T: type,
    comptime Context: type,
    comptime less: *const fn (ctx: Context, a: *T, b: *T) bool,
) type {
    return struct {
        root: ?*T = null,
        context: Context,

        pub fn insert(self: *Self, v: *T) void {
            self.root = if (self.root) |root| self.meld(v, root) else v;
        }

        pub fn deleteMin(self: *Self) ?*T {
            const root = self.root orelse return null;
            self.root = if (root.heap.child) |child|
                self.combine_siblings(child) else null;
            root.heap = .{};
            return root;
        }
    };
}

// Embed heap metadata in nodes
const Timer = struct {
    deadline: u64,
    callback: *const fn () void,
    heap: IntrusiveHeap(Timer, void, lessThan).Field = .{},
};
```

Pairing heaps give O(1) insert and amortized O(log n) deleteMin with zero
allocation. Ideal for timer wheels and priority scheduling. *[libxev]*

### Reference Counting for Shared Resources

When resources are shared across subsystems, use explicit ref counting:

```zig
pub fn ref(message: *Message) *Message {
    assert(message.references > 0);
    message.references += 1;
    return message;
}

pub fn unref(pool: *Pool, message: *Message) void {
    message.references -= 1;
    if (message.references == 0) {
        message.header = undefined;
        pool.free_list.push(message);
    }
}
```

Every `ref()` must have a matching `unref()`. Assert reference counts at
critical ownership transitions. *[TigerBeetle]*

### Object Pool with Free List

Reuse allocations via a singly-linked free list:

```zig
pub fn ObjectPool(comptime T: type, comptime max_count: comptime_int) type {
    return struct {
        const Self = @This();
        const Node = struct { data: T, next: ?*Node = null };

        list: ?*Node = null,
        count: u32 = 0,

        pub fn get(self: *Self, allocator: Allocator) Allocator.Error!*Node {
            if (self.list) |node| {
                self.list = node.next;
                self.count -= 1;
                if (comptime std.meta.hasFn(T, "reset")) node.data.reset();
                return node;
            }
            const node = try allocator.create(Node);
            node.* = .{ .data = undefined };
            return node;
        }

        pub fn release(self: *Self, allocator: Allocator, node: *Node) void {
            if (max_count > 0 and self.count >= max_count) {
                allocator.destroy(node);
                return;
            }
            node.next = self.list;
            self.list = node;
            self.count += 1;
        }
    };
}
```

Optional `reset()` clears reused objects. `max_count` bounds retained free nodes, not total
allocation, so `get` must propagate `error.OutOfMemory` unless the pool is separately
preallocated by contract. *[Bun]*

## 8. Thread Safety & Concurrency

### `threadlocal var`

Per-thread state without synchronization:

```zig
// Simple thread-local flag
pub threadlocal var is_main_thread: bool = false;

// Conditional threadlocal based on compile-time config
const Storage = if (threadsafe) DataStruct else void;
threadlocal var tls_data: Storage = .{};

inline fn data() *DataStruct {
    if (comptime threadsafe) return &tls_data;
    return &global_data;
}
```

Use `threadlocal` for per-thread caches, allocator state, or thread identity.
Combine with comptime booleans to compile away thread-local storage when
single-threaded. *[Bun]*

### Lock-Free Queues Require a Complete Proven Algorithm

Do not derive an MPSC queue from only its exchange-and-link producer path. A correct intrusive
Vyukov queue also needs stub-node initialization, the consumer's head/tail race handling, and the
stub reinsertion path; omitting those pieces can make a one-item queue appear empty. Reuse a
project-vetted implementation and preserve its memory orders and single-consumer contract as a
unit. For task-oriented producer/consumer work under Zig 0.16 `std.Io`, prefer `std.Io.Queue(T)`
unless lock-free cross-thread behavior is itself a requirement.

### Atomic Operations Summary

```zig
// Atomic load/store with ordering
const val = @atomicLoad(u32, &shared, .acquire);
@atomicStore(u32, &shared, new_val, .release);

// Atomic read-modify-write
const old = @atomicRmw(u32, &counter, .Add, 1, .seq_cst);
const prev = @atomicRmw(*Node, &head, .Xchg, new_node, .acq_rel);

// Compare-and-swap
const result = @cmpxchgStrong(
    u32, &value, expected, desired, .seq_cst, .monotonic,
);
```

Memory ordering from weakest to strongest:
`.unordered` < `.monotonic` < `.acquire`/`.release` < `.acq_rel` < `.seq_cst`.
Use the weakest ordering that maintains correctness. *[libxev, Bun]*

## 9. Smart Pointer Patterns

### Copy-on-Write (Cow)

Tagged union that borrows or owns data, copying only when mutation is needed:

```zig
pub fn Cow(comptime T: type, comptime VTable: type) type {
    return union(enum) {
        borrowed: *const T,
        owned: T,

        pub fn borrow(val: *const T) @This() {
            return .{ .borrowed = val };
        }

        pub fn own(val: T) @This() {
            return .{ .owned = val };
        }

        pub fn toOwned(this: *@This(), allocator: Allocator) Allocator.Error!*T {
            switch (this.*) {
                .borrowed => |b| {
                    this.* = .{ .owned = try VTable.copy(b, allocator) };
                },
                .owned => {},
            }
            return &this.owned;
        }

        pub fn deinit(this: *@This(), allocator: Allocator) void {
            if (this.* == .owned) VTable.deinit(&this.owned, allocator);
        }
    };
}
```

Avoids copies when only reading. The VTable pattern (with `@hasDecl` checks)
ensures `copy` and `deinit` are implemented. *[Bun]*

### Reference Counting Mixin

Embed reference counting in any struct via a comptime mixin:

```zig
pub fn RefCount(
    comptime T: type,
    comptime field_name: []const u8,
    comptime destructor: anytype,
) type {
    return struct {
        raw_count: u32 = 1,

        pub fn ref(self: *T) *T {
            const rc = &@field(self, field_name);
            assert(rc.raw_count > 0);
            rc.raw_count += 1;
            return self;
        }

        pub fn deref(self: *T) void {
            const rc = &@field(self, field_name);
            rc.raw_count -= 1;
            if (rc.raw_count == 0) {
                destructor(self);
            }
        }
    };
}

// Usage: embed in struct
const Resource = struct {
    data: []u8,
    rc: RefCount(Resource, "rc", destroy) = .{},

    fn destroy(self: *Resource) void {
        allocator.free(self.data);
        allocator.destroy(self);
    }
};
```

The mixin uses `@field` with `field_name` to access itself within the parent
struct — same `@fieldParentPtr` philosophy but for reference counting. *[Bun]*

## 10. C Interop

### `export fn` for C API

Expose Zig functions to C with `export`:

```zig
export fn xev_loop_init(loop: *xev.Loop) c_int {
    loop.* = xev.Loop.init(.{}) catch |err| return errorCode(err);
    return 0;
}

export fn xev_timer_run(
    v: *xev.Timer,
    loop: *xev.Loop,
    next_ms: u64,
    userdata: ?*anyopaque,
    cb: *const fn (*xev.Loop, c_int, ?*anyopaque) callconv(.c) void,
) void {
    // Bridge C callback to Zig callback
}
```
*[libxev]*

### `callconv(.c)` for Callbacks

Use C calling convention for functions passed to C libraries:

```zig
pub fn alloc(_: ?*anyopaque, len: usize) callconv(.c) ?*anyopaque {
    return mimalloc.mi_malloc(len);
}

pub fn free(_: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
    mimalloc.mi_free(ptr);
}
```
*[Bun]*

### Security-Conscious Memory Deallocation

Zero memory before freeing to prevent sensitive data leaks:

```zig
fn secureFree(allocator: Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}
```

Critical for cryptographic keys, passwords, and authentication tokens.
The allocator API cannot recover an allocation's length from a bare pointer: preserve the original
slice (or carry its exact length in the C ABI contract). Use `std.crypto.secureZero`, which prevents
the wipe from being optimized away, before freeing with the same allocator. *[Bun, Zig stdlib]*

### Platform-Specific Type Selection

Select C-compatible types based on the target. For libc types that Zig 0.16 does not expose
through `std.c`, import a module produced by `addTranslateC` from the relevant system header:

```zig
const c = @import("c"); // build.zig translates ucontext.h for supported POSIX targets.

const Context = if (builtin.os.tag == .windows)
    std.os.windows.CONTEXT
else if (builtin.os.tag == .linux or builtin.os.tag == .macos)
    c.ucontext_t
else
    void;
```

Do not use the pre-0.16 `std.c.ucontext_t`; it is no longer present.
*[Bun]*

### Context Pointer Smuggling

Encode small values (enums, indices) inside the context pointer itself:

```zig
pub fn taggedPageAllocator(tag: VMTag) Allocator {
    const encoded = @as(usize, @intCast(@intFromEnum(tag))) + 1;
    return .{
        .ptr = @ptrFromInt(encoded),
        .vtable = &TaggedPageAllocator.vtable,
    };
}

fn alloc(context: *anyopaque, n: usize, ...) ?[*]u8 {
    const encoded = @intFromPtr(context);
    assert(encoded > 0);
    const tag: VMTag = @enumFromInt(
        @as(u8, @truncate(encoded - 1)),
    );
    return map(n, alignment, tag);
}
```

Avoids an extra heap allocation for context by encoding the value directly
in the pointer. Reserve integer zero for null and offset the encoded value by one; a non-optional
`*anyopaque` must never contain address zero. Only safe for values that fit in a pointer. *[Ghostty]*

### Anonymous Struct C Callback Wrapper

Wrap inline functions as C callbacks via anonymous struct:

```zig
c.spvc_context_set_error_callback(
    ctx,
    @ptrCast(&(struct {
        fn callback(_: ?*anyopaque, msg: [*c]const u8) callconv(.c) void {
            log.err("SPIR-V error: {s}", .{msg});
        }
    }).callback),
    null,
);
```

Creates a function pointer to a static function defined inline. The anonymous
struct exists only at comptime — no runtime overhead. *[Ghostty]*

### Bidirectional Allocator Wrapper

Bridge between C and Zig allocator interfaces:

```zig
pub const Allocator = extern struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Wrap a Zig allocator for C consumption
    pub fn fromZig(zig_alloc: *const std.mem.Allocator) Allocator {
        return .{
            .ctx = @ptrCast(@constCast(zig_alloc)),
            .vtable = &ZigAllocator.vtable,
        };
    }

    /// Wrap this C allocator for Zig consumption
    pub fn zig(self: *const Allocator) std.mem.Allocator {
        return .{
            .ptr = @ptrCast(@constCast(self)),
            .vtable = &zig_vtable,
        };
    }
};
```

Enables passing allocators across the C/Zig boundary in either direction.
*[Ghostty]*

## 11. Async Concurrency (Runtime / Coroutine Tasks)

Patterns for **structured concurrency** on a coroutine runtime — stackful coroutines (fibers) that
*suspend* on I/O so you write concurrent code in straight-line, sequential style. Thousands run on one
OS thread (concurrent, not parallel unless the runtime is multi-threaded). This is a different layer
from §8 (low-level atomics / lock-free) — here the unit is a *task*, not an atomic word.

### Structured spawn → join, with `defer cancel`

Every spawned task must be **`join`ed** (waits, then releases the task's resources) or **`detach`ed**.
Pair a `spawn` with `defer task.cancel(rt)` so any early return tears the task down — `cancel` after a
successful `join` is a safe no-op, which makes this the clean structured-cleanup idiom:

```zig
var task = try rt.spawn(myTask, .{ rt, stream }, .{});
defer task.cancel(rt);             // torn down on any early return; safe even after join

const result = try task.join(rt);  // wait, release resources, propagate the task's error
```
*[zio]*

### Cancellation: handle AND *always* propagate `error.Canceled`

A canceled task's in-flight operation returns `error.Canceled` at its next suspension point. **Never
swallow it** — let it propagate so the cancellation actually unwinds the task. Pair with
`defer resource.close(rt)` so cleanup runs on the cancel path too (the suspension point throws, which
unwinds the `defer`s):

```zig
fn handler(rt: *zio.Runtime, stream: zio.net.Stream) !void {
    defer stream.close(rt);                    // runs on normal exit AND on cancellation
    var buf: [256]u8 = undefined;
    while (true) {
        const n = try stream.read(rt, &buf);   // returns error.Canceled when canceled → `try` propagates it
        try process(buf[0..n]);
    }
}
```
*[zio]*

### Tasks have a FIXED stack — keep big buffers off it

Unlike Go goroutines or Java virtual threads (which grow their stacks), a stackful-coroutine task has a
**fixed** stack (e.g. 256 KiB by default); overflowing it **crashes the process**, not a catchable
error. Heap large buffers, bound recursion (see "no recursion" in TigerStyle), and raise `.stack_size`
only for genuinely deep tasks:

```zig
var task = try rt.spawn(deepWork, .{}, .{ .stack_size = 1024 * 1024 });
```
*[zio]*

### Get concurrency by spawning, not by nesting callbacks

The point of coroutine tasks is to write I/O as sequential code (`try stream.read(rt, buf)`), not
callback chains. Add concurrency by spawning *more tasks* (e.g. one per connection), not by deepening
callback nesting — the runtime multiplexes them on the thread(s) and the code stays readable. *[zio]*

### Use task-aware sync primitives — never block the OS thread inside a task

Inside a task, synchronize with the runtime's primitives (`Channel`, `Mutex`, `Semaphore`, `ResetEvent`,
`Condition`, `Notify`) — they **suspend the task** and yield the thread to other tasks. Never do an OS
block inside a task (`std.Thread.Mutex`, a blocking syscall, a busy `sleep`): it stalls **every** task
multiplexed on that thread, not just yours — the classic coroutine-runtime footgun. *[zio]*

### Detach for fire-and-forget; the handle is dead after

For a server, spawn a handler per connection and `detach(rt)` to run it in the background — but after
`detach`, the handle is invalid; don't touch it. If you care about the result or need to bound the
lifetime, `join` (with the `defer cancel` idiom above) instead:

```zig
var task = try rt.spawn(connectionHandler, .{ rt, stream }, .{});
task.detach(rt);   // runs in background; `task` is now off-limits
```
*[zio]*

### `std.Io`: `async` vs `concurrent` — choose by whether correctness *requires* concurrency

Below the task API sits the `std.Io` primitive pair. Both call `function` and return a `Future` you
`await` later (`future.await(io)` / `future.cancel(io)`) — the difference is the **guarantee**, and it's
a correctness decision, not a style one:

- **`io.async(f, args) → Future(R)` — cannot fail.** *Weaker* guarantee: the function *may* run inline
  (synchronously, before `async` returns) **or** be assigned a unit of concurrency. This is **portable** —
  it works even on a single-threaded blocking `Io`. Use it when the result is correct either way and
  concurrency is only an optimization. If the runtime can't spawn (resource exhaustion / shutdown), it
  just runs the function inline — no error.
- **`io.concurrent(f, args) → ConcurrentError!Future(R)` — can fail with `error.ConcurrencyUnavailable`.**
  *Stronger* guarantee: the function makes progress **concurrently while the caller does other work /
  awaits**. This **restricts** which `Io` implementations work (a single-threaded blocking `Io` cannot
  provide it → the error). Use it **only when correctness requires** concurrency.

The deadlock test decides it: if the caller `await`s something the spawned function must *produce while
the caller is waiting*, you need `concurrent` — `async` could legally run it inline and deadlock.

```zig
// async — "run this too, I'll await it later"; may run inline; infallible
var fut = io.async(fetch, .{ io, url });
const local = computeLocally();
const data = fut.await(io);

// concurrent — "this MUST run while I await it"; you must handle the failure
var producer = io.concurrent(produce, .{ io, queue }) catch |err| switch (err) {
    error.ConcurrencyUnavailable => return err, // a single-threaded blocking Io can't run this pattern
};
const item = queue.getOne(io);  // would DEADLOCK if `produce` were allowed to run inline
_ = producer.await(io);
```

**Rule of thumb:** default to `async` (portable, infallible); reach for `concurrent` *only* when you'd
deadlock without real concurrency — and then you must handle `error.ConcurrencyUnavailable`.
`error.ConcurrencyUnavailable` itself means resource exhaustion **or** the `Io` impl doesn't support
concurrency. *[Zig stdlib]*

(On a multi-task runtime like zio, both normally enqueue a task and return immediately; `async`'s inline
fallback only kicks in when a task can't be spawned — resource exhaustion or shutdown.) *[zio]*

### Cancelable vs cancellation-shielded blocking — `lock` vs `lockUncancelable`

Blocking sync ops come in two forms. Note the pair is `lock` / **`lockUncancelable`** — the base `lock`
is *already* the cancelable one, the suffix marks the shielded exception (there is no `lockCancelable`):

- **`mutex.lock(rt) Cancelable!void` — a cancellation point.** If the task is canceled while waiting for
  the lock, it cleanly leaves the wait queue and returns `error.Canceled`. This is the default: a task
  blocked on a lock should stay cancelable. Propagate it: `try mutex.lock(rt)`.
- **`mutex.lockUncancelable(rt) void` — cancellation-shielded, infallible.** It ignores cancellation
  *during acquisition* and is guaranteed to return holding the lock. Use it in **critical / cleanup
  sections that must complete regardless of cancellation** — exactly the paths that run *because* you're
  being torn down (`defer …close(rt)`, releasing/posting). If you still need to react to a pending cancel
  afterward, call `runtime.checkCanceled()`.

Rule: **acquire-to-do-work → `lock` (cancelable); acquire-to-clean-up → `lockUncancelable`.** On a
teardown path, `lock`'s `error.Canceled` has nowhere to go, and you must not bail out mid-cleanup.

```zig
// normal work — a task blocked here can still be canceled
try mutex.lock(rt);
defer mutex.unlock(rt);
doWork();

// cleanup path — must complete even though we're being canceled; don't reintroduce a cancel point
fn close(self: *Conn, rt: *Runtime) void {
    self.mutex.lockUncancelable(rt);  // shielded: cannot return error.Canceled
    defer self.mutex.unlock(rt);
    self.releaseResources();
}
```
*[zio]* (std.Io mirrors this: `Mutex.lock` is `Cancelable!void`; `Mutex.lockUncancelable` is infallible.
Same split shows up elsewhere as the `*Uncancelable` suffix, e.g. `Queue.getOneUncancelable`.)

## 12. Container Mutation & Pointer Invalidation

The single most common Zig aliasing bug: iterating a container (or holding a `getPtr` value pointer
/ an `.items` slice) while an operation **grows, rehashes, or removes** — which invalidates what you
still hold. The contract is written into the std docs, per container:

- `HashMap` / `AutoHashMap`: **"any modification invalidates live iterators"**, and every iterator
  constructor repeats **"The iterator is invalidated if the map is modified."** There is no safe
  in-place mutate-while-iterate. *[Zig 0.16 stdlib — hash_map.zig:112, :239/:245/:251]*
- `ArrayHashMap`: **"Modifying the hash map while iterating is allowed, however, one must understand
  the (well defined) behavior when mixing insertions and deletions."** Its `Iterator` caches raw
  `keys`/`values` pointers and the original length, so a reallocating insertion invalidates it and a
  removal changes what those indexes mean. For filtered deletion, use an **index walk** over `.keys()`
  and re-read `.count()` each step; `swapRemoveAt` moves the **last** element into the freed slot.
  *[Zig 0.16 stdlib — array_hash_map.zig:60, :265, :781]*
- `ArrayList`: each method's doc says either **"Invalidates element pointers if additional memory is
  needed"** (`append`) or **"Never invalidates element pointers"** (`appendAssumeCapacity`). Read that
  line before holding a pointer across a call. *[Zig 0.16 stdlib — array_list.zig:903, :913]*

**Optional runtime guardrail:** both maps provide `lockPointers()` / `unlockPointers()` around a
`std.debug.SafetyLock`. In safe builds, explicitly lock pointers while a key/value pointer is live;
an operation that could invalidate it then asserts. Merely calling `getPtr()` does **not** lock the
map automatically, and the guard is a no-op in release builds.
*[Zig 0.16 stdlib — hash_map.zig:536, array_hash_map.zig:100, debug.zig:1816]*

### Decision guide (in order)

1. **Design it away** — make invalidation impossible, then no loop discipline is needed (below).
2. **Index-walk + `swapRemove` (no advance)** — filtered in-place delete on a contiguous/indexable
   container (`ArrayList`, `ArrayHashMap`).
3. **Drain loop** — when the mutation *is* the iteration (consume the container to empty).
4. **Detach / snapshot copy** — general fallback: iterate a copy that aliases none of the mutated
   structure. Mandatory when the per-item op can **fail mid-loop** or when you delete a set *selected
   from* the container being deleted from.
5. **Two-phase mark-then-sweep** — when the delete *decision* must inspect **other** entries, or you
   remove from container B while iterating container A.

### 1. Design it away (preferred)

**Static capacity → no rehash/realloc → existing element pointers stay at the same address across
non-removing `*AssumeCapacity` inserts.** Reserve once at init (where OOM is handled), then use the
`*AssumeCapacity` ops at runtime (see §2 for the mechanics). This does **not** relax the `HashMap`
iterator contract: any modification still invalidates a live iterator.

```zig
// init: reserve for the whole lifetime
try stash.ensureTotalCapacity(allocator, options.stash_value_count_max);
// hot path: cannot rehash → cannot invalidate. (getOrPutAssumeCapacity, not
// putAssumeCapacity, because a Value-less HashMap's putAssumeCapacity won't clobber.)
const gop = self.stash.getOrPutAssumeCapacity(value.*);
```
TigerBeetle reserves at init and `*AssumeCapacity`s in the hot path pervasively — `cache_map.zig`,
`client_sessions.zig` (`ensureTotalCapacity(clients_max)` then `getOrPutAssumeCapacity`),
`manifest_log.zig` (reserves `+1` *specifically* so the code can always use `getOrPutAssumeCapacity`).
*[TigerBeetle — src/lsm/cache_map.zig:110 & :269, src/vsr/client_sessions.zig:54 & :239, src/lsm/manifest_log.zig:190]*

**Pointer-stable containers** side-step the whole problem — elements never move on growth:
- **Intrusive linked lists** (nodes externally owned, linked by an embedded `next`): grow/shrink is
  O(1) and never relocates. *[TigerBeetle — src/stack.zig:13, src/queue.zig:6]* (see also §7)
- **Object pools / free lists** hand out stable addresses reused via `create`/`destroy`.
  Ghostty's `SegmentedPool` doc states the motivation outright: *"stable (never copied) pointers to a
  type that automatically grows."* *[Ghostty — src/datastruct/segmented_pool.zig:6; src/terminal/PageList.zig:51 (MemoryPool nodes/pages/pins)]*
- **Offset-based containers**: store offsets, not pointers, so the backing memory can move without
  invalidating anything — Ghostty's `OffsetHashMap` exists solely for this. *[Ghostty — src/terminal/hash_map.zig:60]*

(Note: `std.SegmentedList` — historically the go-to for stable element pointers across growth — is **not
present** in this std (0.16). Reach for the pool / intrusive-list / offset options above instead.)

### 2. Index-walk + `swapRemove` (no advance on removal)

Delete-in-place by a predicate. Walk an index; on a match `swapRemove(i)` (moves the last element into
slot `i`) and **do not advance** — the swapped-in element must be re-examined; advance only on a keep:

```zig
var i: usize = 0;
while (i < p.labels.items.len) {
    if (p.labels.items[i] == .unresolved_goto and mem.eql(u8, ..., str)) {
        _ = p.labels.swapRemove(i);   // last elem moves into i; DON'T advance
    } else i += 1;
}
```
This is the canonical form in the Zig compiler's aro parser, in TigerBeetle production (the repair-budget
expiry reaper walks `requested_prepares.entries.len` and `swapRemoveAt(i)` with `i += 1` only in the
`else`), and in Ghostty (`swapRemove(i); continue;` with a trailing `i += 1`). Use `orderedRemove` +
`i -= 1` instead when insertion order must be preserved (Ghostty's `Atlas`).
*[Zig stdlib — compiler/aro/aro/Parser.zig:5331; TigerBeetle — src/vsr/repair_budget.zig:220; Ghostty — src/App.zig:198, src/font/Atlas.zig:194]*

### 3. Drain loop (the mutation *is* the iteration)

When you want to consume the container to empty, let the removal drive the loop — there is no surviving
iterator to invalidate:

```zig
while (queue.pop()) |item| { ...; message_pool.unref(item.message); }   // consume to empty
while (map.count() > 0) try context.release();                          // take-first-then-remove
```
Widely used: TigerBeetle drains intrusive queues/stacks in `deinit` and checkpoint paths; the Zig
compiler drains stacks with `while (stack.pop()) |s|`. Prefer this over a re-scan-for-the-next-victim
loop: if a delete can be *swallowed*, a re-scan re-selects the same victim and **spins forever** — a
drain (or the index-walk in #2) makes guaranteed forward progress.
*[TigerBeetle — src/vsr/replica.zig:12128, src/vsr/free_set.zig:613, src/lsm/node_pool.zig:199; Zig stdlib — compiler/build_runner.zig:1458, compiler/aro/aro/Preprocessor.zig:2873]*

### 4. Detach / snapshot copy (general fallback)

Iterate a copy that aliases none of the structure you mutate. The minimal form copies **one element**
by value before an op that invalidates the live one; the general form `dupe`s the driving list:

```zig
// minimal: copy the element, THEN remove (remove_table would invalidate level_table)
while (it.next()) |level_table| {
    var level_table_copy = level_table.*;
    env.level.remove_table(&env.pool, &level_table_copy);
}

// general: snapshot the keys, then the loop body may freely mutate index + map
const snapshot = try allocator.dupe(Root, list.items);
defer allocator.free(snapshot);
for (snapshot) |root| { ...; self.removeEntry(.{ .root = root, .epoch = epoch }); }
```
Choose this when the per-item op **can throw** (a mid-loop failure leaves the not-yet-processed entries
still tracked in the live container, so a retry loses nothing) or when the delete set is *selected from*
the container. Cost is one small alloc — negligible off the hot path.
*[TigerBeetle — src/lsm/manifest_level_fuzz.zig:448]*

### 5. Two-phase mark-then-sweep

When the delete *decision* must look at **other** entries (so you can't remove during the scan), or you
mutate container B while iterating container A: collect victims into a temp list in phase 1, apply in
phase 2 after the iterator is done.

```zig
// phase 1 — MARK: scan, collect, mutate nothing
var candidates: std.ArrayList(Candidate) = .empty;
defer candidates.deinit(alloc);
var it = self.images.iterator();
while (it.next()) |kv| try candidates.append(alloc, .{ .id = kv.value_ptr.id, ... });

// phase 2 — SWEEP: now safe to remove
for (candidates.items) |c| {
    if (self.images.getEntry(c.id)) |entry| self.images.removeByPtr(entry.key_ptr);
}
```
Ghostty uses exactly this for image eviction and env-var filtering. When a single removal *doesn't* need
cross-entry context, use a key copied by value and remove it only after ending the iterator; Zig 0.16's
`HashMap` contract says any modification invalidates live iterators. A plain comment can carry the
intent — Ghostty picks `while` over `for` "because we may add items to the list while iterating," and
notes "getOrPut invalidates pointers" right where it nulls a cached pointer.
*[Ghostty — src/terminal/kitty/graphics_storage.zig:529 & :586, src/apprt/gtk/class/surface.zig:1595, src/config/Config.zig:4165, src/input/Binding.zig:2475]*

## 13. State Across Suspension Points (async re-lookup)

The async analog of §12: a **suspension point** — any call taking `std.Io` (or a zio fiber op) that
can park the fiber — is a point where *other tasks run*. Single-threaded async removes data races,
not suspension races: a pointer into shared state (`getPtr` result, `.items` slice, an entry you
"checked" before the call) may be stale or dangling when the fiber resumes, because a racing task
mutated, pruned, or replaced it while you were parked. The danger is not "simultaneously" — it is
"the world moved while I was suspended, and my pointer + ownership assumptions didn't".

**The criterion (judge every suspending call):** does a live borrow into shared mutable state, or a
multi-step mutation sequence, **cross** the suspension point? Not "is this an io call":
- *read-then-build* (fetch keys, then construct state nothing else aliases yet) — fine as written.
- *check-or-hold, suspend, then act on what you held* — the hazard; pick a shape below.

Rust makes the "hold" half a compile error (`clippy::await_holding_lock`: std/parking_lot guards
"are not designed to operate in an async context across await points"). Zig has no such lint —
this is a review-time check.

### Decision guide (in order)

1. **Don't suspend inside the state change** — mutate synchronously, push I/O to the edge.
2. **Serialize the operation** (waiter/placeholder, per-key exclusivity) — only when the guarded
   work is *short* (an init computation), never across long I/O.
3. **Re-lookup after resume + explicit conflict policy** — when the operation must do long I/O
   mid-flight (a disk write/read), capture the *key*, suspend, re-fetch by key, decide from what is
   there *now*.

### 1. Don't suspend inside the state change (preferred)

All cache/map mutation happens in synchronous code; the suspending call sits between two
synchronous phases and mutates nothing itself. tokio's teaching codebase mini-redis is built on
this: the shared `Db` uses a *blocking* mutex never held across an await — `set()` does
`drop(state)` before notifying the background task, and the purge loop re-acquires fresh state
each iteration, awaiting only outside the critical section. The Tokio tutorial states the rule
outright: "the lock must be released before the `.await`." TigerBeetle is the strongest form: the
VSR state machine never suspends at all — I/O completions re-enter as ordinary events, so no state
ever crosses a yield (sans-IO). *[mini-redis — src/db.rs set()/purge_expired_tasks(); tokio.rs
tutorial "Shared state"; TigerBeetle — docs/internals/vsr.md]*

### 2. Serialize the operation (short critical work only)

First task claims the key (inserts a waiter/permit), racers wait for its result instead of racing.
tokio's `OnceCell.get_or_init` holds a semaphore permit across the init future — after acquiring,
it just asserts uninitialized and runs, because the permit guarantees exclusivity. moka's
`get_with` coalesces concurrent same-key loads through a waiter map the same way. *[tokio —
src/sync/once_cell.rs get_or_try_init; moka — src/future/value_initializer.rs try_insert_waiter]*

Two hard limits: (a) exclusivity across a *long* I/O (a multi-hundred-ms disk write) queues every
other op on that key behind the disk — wrong for hot paths; (b) coalescing dedups *same-intent*
work ("N tasks all fetching missing key K") but cannot arbitrate *conflicting intents* (persist vs
add vs prune on one key) — those need shape 3.

### 3. Re-lookup after resume + explicit conflict policy

Capture the **key** (a value copy — per §12, never a pointer) before suspending; after resume,
re-fetch by key and decide from current state: last-writer-wins (overwrite/downgrade whatever is
resident now), first-writer-wins (adopt the existing value, discard your work), or abandon (entry
vanished → clean up your side effect). The re-lookup is application semantics — no ownership
mechanism (GC, refcount, borrow checker) can answer "what should the entry be now?".

```zig
const key = try self.datastore.write(io, cp_key, bytes); // suspends; the world may change
// Re-lookup by key; never touch the pre-write entry pointer again.
const cur = self.cache.getPtr(cp_key) orelse {
    self.datastore.remove(io, key) catch |err| log.warn(...); // vanished: undo side effect
    return;
};
switch (cur.item) {
    .in_memory => |im| { cur.item = .{ .persisted = key }; destroyState(im.state); }, // LWW
    .persisted => {}, // racer already persisted: no-op
}
```
*[lodestar-z — src/beacon_node/chain/state_cache/checkpoint_state_cache.zig processPastEpoch]*

The same shape, independent of language and of thread-vs-task concurrency:
- moka re-checks the cache after its coordination await — "Check if the value has already been
  inserted by other thread." → `get_with_hash` re-fetch → `ReadExisting(value)` (first-writer-wins).
  *[moka @ 7006d8c9 — src/future/value_initializer.rs:191, :223-233]*
- ScyllaDB parks a range scan by *copying the key* (`_prev_snapshot_pos = it->key()`) and re-seeks
  with `lower_bound` on resume — never trusts the pre-yield iterator, and documents why:
  "restore invariants before deferring". *[scylladb @ 373085cd — db/row_cache.cc:1269, :1250, :1088]*
- Reth validates a transaction against a state snapshot (async), then takes the pool lock and
  inserts *re-checked against the pool's current state* (replacement/underpriced/already-known).
  *[reth @ 1a4a5c96 — crates/transaction-pool/src/pool/mod.rs:578, :617]*

### Testing suspension races

Interleave scenarios need **real suspension**, not synchronous re-entry through a vtable: a
single-threaded runtime, a gated I/O fake that parks the op on `std.Io.Event`, and a rendezvous
sequence witness asserting the order actually interleaved (`parked < racer_done < resumed`).
Same-stack re-entry reproduces the memory outcome but not the control flow — it cannot catch state
held across a true park. *[lodestar-z — checkpoint_state_cache.zig GatedCPStateDatastore +
Rendezvous tests; zio single-threaded `Runtime.init(.{ .executors = .exact(1) })`]*