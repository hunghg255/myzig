# mainthread

Gói này chuyển công việc từ luồng khác về luồng chính. Trang web, view, phương thức được bind và sự kiện cửa sổ đều chạy trên luồng chính. Các luồng của plugin dùng gói này để chuyển kết quả như phản hồi HTTP, tin nhắn WebSocket hoặc thay đổi file về nơi xử lý giao diện. Các plugin fetch, websocket, watch, updater và terminal phụ thuộc vào nó.

Gói này là `plugins/mainthread` (mô-đun `mainthread`); nó không phụ thuộc vào gì cả, kể cả myzig.

```zig
const mainthread = @import("mainthread");

const Job = struct {
    window: *myzig.Window,
    result: []u8,

    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(ctx));
        // On the main thread: emit an event, change a view's state, ...
        _ = job;
    }
};

try mainthread.init(); // once, on the main thread (plugins' services do it when created)
if (!mainthread.post(job, Job.run)) {
    // Not queued (no init, or out of memory): the caller still owns `job`.
}
```

- `init()` chuẩn bị hàng đợi; gọi lại lần nữa cũng không có tác dụng gì.
- `post(ctx, func)` lên lịch chạy `func(ctx)` trên luồng chính. Có thể gọi an toàn từ mọi luồng; các công việc chạy theo thứ tự được gửi. `func` có kiểu `mainthread.Func`, tức `*const fn (?*anyopaque) callconv(.c) void`.
- `runUntil(&done)` chạy hàng đợi cho đến khi cờ nguyên tử được đặt, dành cho các kiểm thử và công cụ không có vòng lặp sự kiện của riêng chúng (chỉ luồng chính).

Đây là hàng đợi riêng của luồng chính trên mỗi nền tảng, vì vậy không có polling nào:

| Nền tảng | Hàng đợi |
|---|---|
| macOS | hàng đợi chính của libdispatch (`dispatch_async_f`) |
| Linux | Ngữ cảnh mặc định của GLib (`g_idle_add`), vòng lặp của GTK chạy |
| Windows | Cửa sổ chỉ nhận message (`PostMessageW`), do vòng lặp message của ứng dụng xử lý |

Trong trình duyệt (`wasm32-wasi`) không có luồng nào khác và gói không biên dịch ở đó.

Trong myzig, công việc được chuyển về luồng chính qua `myzig.App.after` (timer), hoặc `objc.dispatchMain` trên macOS. Xem [hướng dẫn kiến trúc](../architecture.md) để tìm hiểu mô hình phân luồng.

```sh
cd plugins/mainthread
zig build test                              # on this machine
zig build check -Dtarget=x86_64-linux-gnu   # type-check another platform
```
