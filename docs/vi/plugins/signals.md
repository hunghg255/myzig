# signals

State toàn cục cho ứng dụng: signal giữ giá trị, computed suy ra giá trị từ chúng khi được đọc và lưu cache, còn effect chạy lại khi những gì nó đã đọc thay đổi. Đây là bản port của [alien-signals](https://github.com/stackblitz/alien-signals) (3.2.1) sang Zig, giữ nguyên thuật toán (đồ thị push-pull gồm các node nối bằng link, không cấp phát khi một lần đọc thấy không có gì thay đổi) và các kiểm thử của nó.

Gói này là `plugins/signals` (mô-đun `signals`); nó không phụ thuộc vào gì cả, kể cả myzig, nên dùng được cho giao diện native, service được bind cho trang web và Zig thuần.

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

const e = signals.effect(log); // in 0
store.count.set(1); // in 2
e.dispose();
```

## Signal

- `Signal(T).init(value)` tạo một signal; nó là giá trị của người gọi (biến toàn cục, hoặc field của state sống lâu hơn các effect của nó) và không được di chuyển khi còn thứ đang đọc nó.
- `get()` trả về giá trị và khiến effect hoặc computed đang chạy phụ thuộc vào nó; `peek()` trả về mà không tạo phụ thuộc.
- `set(value)` thay đổi giá trị. Giá trị được so sánh bằng `std.meta.eql`, nên slice hoặc con trỏ chỉ thay đổi khi địa chỉ đổi, giống object trong JavaScript; `set` một giá trị bằng nhau không làm gì.
- `mutate()` trả về con trỏ để sửa giá trị tại chỗ (thêm vào danh sách, đổi một field), rồi `trigger()` chạy lại những gì đọc nó.

## Computed

- `Computed(T).init(getter)` nhận `fn (previous: ?T) T` (null ở lần đầu); `Computed(T).initWith(ctx, getter)` nhận `fn (@TypeOf(ctx), ?T) T` với `ctx` là con trỏ.
- `get()` cập nhật giá trị và lưu cache: getter chỉ chạy khi thứ nó đọc đã thay đổi, và chỉ khi được đọc. `peek()` đọc mà không tạo phụ thuộc.
- Computed được effect đọc sẽ buông các phụ thuộc khi các effect đó dừng; computed được đọc ngoài effect giữ link cho đến khi gọi `deinit()`.

## Effect và scope

- `effect(f)` (`fn () void`) hoặc `effectWith(ctx, f)` (`fn (@TypeOf(ctx)) void`) chạy `f` ngay và chạy lại sau mỗi thay đổi của những gì nó đã đọc. Trả về `*Effect`; `dispose()` dừng nó.
- `onCleanup(f)` / `onCleanupWith(ctx, f)`, gọi trong hàm của effect, gán cho nó một cleanup chạy trước lần chạy kế tiếp và khi bị dispose (tương đương hàm mà effect của alien-signals trả về).
- Effect và scope được tạo khi một effect đang chạy thuộc về effect đó: chúng bị dispose (trong cùng và mới nhất trước) khi nó chạy lại hoặc bị dispose. Đừng tự dispose chúng sau đó.
- Mỗi effect và scope chỉ bị dispose một lần, bởi người gọi hoặc bởi chính hàm của nó (effect con còn có thể bởi effect cha, trừ khi người gọi đã dispose nó trước). Vì không có garbage collector, con trỏ của nó không được dùng sau đó, trong khi alien-signals cho phép gọi dispose lại.
- `effectScope(f)` / `effectScopeWith(ctx, f)` chạy `f` một lần và gom các effect nó tạo; dispose scope sẽ dispose chúng.

## Batch, trigger, đọc không theo dõi

- `startBatch()` và `endBatch()` giữ effect lại cho đến khi batch ngoài cùng kết thúc, để nhiều lần ghi chỉ chạy mỗi effect một lần.
- `trigger(f)` / `triggerWith(ctx, f)` chạy `f`, rồi chạy lại những gì đọc các signal và computed mà `f` đã đọc, như thể chúng vừa thay đổi.
- `setActiveSub(null)` đọc không theo dõi cho đến khi đặt lại node nó trả về; `getActiveSub()` và `getBatchDepth()` giống alien-signals.

## Bộ nhớ và luồng

Đồ thị là toàn cục, như của alien-signals, và thuộc về một luồng: trong ứng dụng là luồng chính (công việc từ luồng khác đến đó qua [mainthread](mainthread.md)). Effect, scope và link giữa các node lấy từ `signals.allocator` (allocator SMP, hoặc allocator WebAssembly); hãy đặt nó trước lần đọc đầu tiên. Một lần đọc không thể thất bại, nên hết bộ nhớ sẽ panic. Những gì bị dispose hoặc unlink được giải phóng khi không còn lời gọi signal nào đang chạy và không có batch nào mở (effect đã dispose còn chờ đến khi hàng đợi không còn effect nào chờ chạy); `signals.deinit()` bỏ hàng đợi và giải phóng phần còn lại, dùng để kiểm tra rò rỉ trong test.

## Với giao diện native

View chạy lại ở mỗi sự kiện, nên nó đọc store như mọi state khác. State thay đổi ngoài sự kiện (timer, kết quả từ luồng khác) cần vẽ lại cửa sổ: một effect đọc những gì view hiển thị sẽ gọi `window.redraw()`, và chỉ khi chúng thay đổi. Ví dụ giữ tiêu đề cửa sổ đồng bộ cũng theo cách đó:

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
zig build test                              # các kiểm thử, và ví dụ được render offscreen
zig build run                               # chạy ví dụ
zig build check -Dtarget=x86_64-linux-gnu   # kiểm tra kiểu cho nền tảng khác
```
