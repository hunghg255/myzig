# signals

State toàn cục cho app:

- **signal** giữ giá trị;
- **computed** suy ra giá trị từ chúng khi được đọc, và cache lại;
- **effect** chạy lại khi thứ nó đã đọc thay đổi.

Đây là bản port của [alien-signals](https://github.com/stackblitz/alien-signals) (3.2.1) sang Zig. Nó giữ nguyên các test và thuật toán của alien-signals: một đồ thị push-pull gồm các node nối với nhau bằng link, không cấp phát gì khi một lần đọc thấy không có gì đổi.

Package là `plugins/signals` (module `signals`). Nó không phụ thuộc vào gì, kể cả myzig. Vì vậy nó dùng được như nhau cho native UI, cho các service mà trang web bind tới, và cho Zig thuần.

```zig
const signals = @import("signals");

const store = struct {
    var count = signals.Signal(i64).init(0);
    var doubled = signals.Computed(i64).init(struct {
        fn get(_: ?i64) i64 {
            return count.get() * 2;
        }
    }.get);
};

fn log() void {
    std.debug.print("{d}\n", .{store.doubled.get()});
}

const e = signals.effect(log); // in ra 0
store.count.set(1); // in ra 2
e.dispose();
```

<a id="signals"></a>

## Signal

- `Signal(T).init(value)` tạo một signal. Nó là giá trị do bên gọi giữ: một biến toàn cục, hoặc một trường của state sống lâu hơn các effect của nó. Không được dời nó đi khi còn thứ đang đọc nó.
- `get()` trả về giá trị, và khiến effect hoặc computed đang chạy phụ thuộc vào nó. `peek()` trả về giá trị mà không tạo phụ thuộc.
- `set(value)` đổi giá trị. `set` một giá trị bằng giá trị cũ thì không làm gì.
- Giá trị được so bằng `std.meta.eql`. Nên một slice hay con trỏ được coi là đổi khi địa chỉ của nó đổi, giống object trong JavaScript.
- `mutate()` trả về một con trỏ để sửa giá trị tại chỗ: thêm vào list nó giữ, đổi một trường. Sau đó `trigger()` chạy lại những gì đọc nó.

<a id="computeds"></a>

## Computed

- `Computed(T).init(getter)` nhận `fn (previous: ?T) T`. Lần đầu `previous` là null.
- `Computed(T).initWith(ctx, getter)` nhận `fn (@TypeOf(ctx), ?T) T`, với `ctx` là một con trỏ.
- `get()` cập nhật giá trị rồi cache nó. Getter chỉ chạy khi có thứ nó đã đọc thay đổi, và chỉ khi được đọc.
- `peek()` đọc mà không tạo phụ thuộc.
- Computed được effect đọc sẽ buông những gì nó đọc khi các effect đó dừng. Computed được đọc ngoài mọi effect thì giữ link cho đến `deinit()`.

`withOptions(.{ .eql = ..., .free = ... })` cho computed sở hữu giá trị của nó, ví dụ chuỗi chữ mà nó cấp phát:

- `eql` quyết định giá trị mới có giống giá trị trước không. Nếu giống, những gì đọc nó không chạy lại. Mặc định là `std.meta.eql`, so slice theo địa chỉ.
- `free` giải phóng mỗi giá trị khi nó bị thay, bởi bất cứ thứ gì trừ chính giá trị trước. Giá trị cuối cùng được giải phóng ở `deinit()`.
- Getter không được tự giải phóng giá trị trước của nó.

```zig
fn sameText(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn freeText(s: []const u8) void {
    signals.allocator.free(s);
}

var label = signals.Computed([]const u8).init(struct {
    fn get(_: ?[]const u8) []const u8 {
        return std.fmt.allocPrint(signals.allocator, "Count: {d}", .{count.get()}) catch @panic("OOM");
    }
}.get).withOptions(.{ .eql = sameText, .free = freeText });
```

- Giá trị bị thay chỉ được giải phóng khi không còn lời gọi signal nào đang chạy và không có batch nào đang mở.
- Nên giá trị đã đọc vẫn hợp lệ cho đến khi lệnh ghi làm nó đổi đã trả về. Một effect có thể đang giữ nó trong lúc chính lệnh ghi của effect đó khiến một effect khác tính giá trị mới: nó vẫn đọc được giá trị cũ.
- Muốn giữ lâu hơn thế thì sao chép nó.
- View có thể hiện nó nguyên như vậy: native UI sao chép chữ vào bộ nhớ của frame.

<a id="effects-and-scopes"></a>

## Effect và scope

- `effect(f)` (`fn () void`) hoặc `effectWith(ctx, f)` (`fn (@TypeOf(ctx)) void`) chạy `f` ngay, và chạy lại sau mỗi lần thứ nó đọc thay đổi. Nó trả về một `*Effect`; `dispose()` dừng nó.
- `onCleanup(f)` / `onCleanupWith(ctx, f)`, gọi trong hàm của effect, gắn cho effect một hàm dọn dẹp. Hàm này chạy trước lần chạy kế tiếp của effect, và khi effect bị dispose. Nó tương ứng với hàm mà effect của alien-signals trả về.
- Effect và scope tạo ra trong lúc một effect đang chạy thuộc về effect đó. Chúng bị dispose khi effect đó chạy lại hoặc bị dispose, cái trong cùng và mới nhất trước. Sau đó đừng tự dispose chúng nữa.
- Mỗi effect và scope chỉ được dispose một lần: bởi bên gọi, hoặc bởi chính hàm của nó. Effect con cũng bị phần tử cha dispose, trừ khi bên gọi đã dispose nó trước.
- Không có garbage collector, nên không được dùng con trỏ của nó sau đó nữa. alien-signals thì cho gọi dispose lại lần nữa.
- `effectScope(f)` / `effectScopeWith(ctx, f)` chạy `f` một lần và gom các effect nó tạo ra. Dispose scope thì các effect đó cũng bị dispose.

<a id="batches-triggers-untracked-reads"></a>

## Batch, trigger, đọc không theo dõi

- `startBatch()` và `endBatch()` giữ các effect lại cho đến khi batch ngoài cùng kết thúc. Nhờ vậy nhiều lệnh ghi chỉ làm mỗi effect chạy một lần.
- `trigger(f)` / `triggerWith(ctx, f)` chạy `f`. Rồi nó chạy những gì đọc các signal và computed mà `f` đã đọc, như thể chúng vừa đổi.
- `setActiveSub(null)` cho đọc mà không theo dõi, cho đến khi node nó trả về được đặt lại.
- `getActiveSub()` và `getBatchDepth()` là hàm gốc của alien-signals.

<a id="memory-and-threads"></a>

## Bộ nhớ và thread

- Đồ thị là toàn cục, giống của alien-signals, và thuộc về một thread. Trong app, đó là main thread. Việc từ các thread khác đến được nó qua [mainthread](mainthread.md).
- Trong build Debug và ReleaseSafe, gọi từ một thread khác với thread đã dùng nó đầu tiên sẽ panic. `signals.deinit()` buông thread đó ra.
- Effect, scope và link giữa các node được cấp phát từ `signals.allocator`: allocator SMP, hoặc allocator của WebAssembly. Đặt nó trước lần đọc đầu tiên.
- Đọc không thể thất bại, nên hết bộ nhớ thì panic.
- Một số thứ được giải phóng khi không còn lời gọi signal nào đang chạy và không có batch nào mở: thứ đã bị dispose, thứ đã bị gỡ link, và giá trị bị thay trong computed sở hữu giá trị của nó. Effect đã dispose còn chờ đến khi không còn effect nào trong hàng đợi.
- `signals.deinit()` bỏ hàng đợi và giải phóng phần còn lại, để kiểm tra rò rỉ trong test.

<a id="with-native-ui"></a>

## Dùng với native UI

View chạy ở mọi event, nên nó đọc store như mọi state khác. State đổi ngoài event, như một timer hay kết quả từ một thread, cần vẽ lại cửa sổ. Một effect đọc thứ mà view hiện thì gọi `window.redraw()`, nhờ vậy chỉ vẽ lại khi thứ đó đổi. Ví dụ giữ tiêu đề cửa sổ khớp theo cùng cách:

```zig
fn follow(win: *myzig.Window) void {
    var buf: [64]u8 = undefined;
    win.setTitle(std.fmt.bufPrint(&buf, "Signals: {d}", .{store.count.get()}) catch "Signals");
    win.redraw();
}

const win = try app.newWindow(.{ .content = .{ .view = .init(&state, view) } });
const e = signals.effectWith(win, follow);
defer e.dispose();
```

```sh
cd plugins/signals
zig build test                              # the tests, and the example rendered offscreen
zig build run                               # the example
zig build check -Dtarget=x86_64-linux-gnu   # type-check another platform
```
