# Cuộn và thu phóng bằng cử chỉ

`Div.handleInput(state, callback)` cho phép chart, canvas hoặc widget tự
xử lý cuộn và pinch trên touchpad. Callback chạy trên main thread, trước
lượt dựng view kế tiếp, và trả về việc có nhận sự kiện hay không. Con trỏ
state phải còn hợp lệ trong suốt thời gian phần tử hiển thị.

```zig
fn input(s: *State, e: ui.InputEvent) bool {
    switch (e.kind) {
        .zoom => s.zoom *= e.scale,
        .scroll => s.pan += e.dx,
    }
    return true;
}

const plot = ui.div(c).size(400, 240).handleInput(s, input);
defer plot.end();
```

`kind` là `.scroll` hoặc `.zoom`. `x`, `y` là vị trí con trỏ tương đối với
phần tử, có tính transform. `dx`, `dy` là số point cuộn, dương sang phải
và xuống dưới; `precise` phân biệt touchpad với nấc bánh xe khi nền tảng
cung cấp thông tin đó. `scale` là hệ số nhân: 2 nghĩa là phóng lớn gấp đôi.
`ctrl`, `shift`, `cmd` là các phím bổ trợ.

Sự kiện đến handler trong cùng dưới con trỏ. Trả về `false` chuyển tiếp
cho handler cha, rồi cơ chế cuộn bình thường. Sự kiện cuộn đã được nhận
không cuộn container bên ngoài. Pinch không làm container cuộn. Hệ số
không hữu hạn, không dương hoặc bằng 1 bị bỏ qua.

macOS dùng sự kiện magnification. GTK 3 nhận pinch ở desktop có hỗ trợ,
đặc biệt Wayland. Windows coi delta bánh xe phân số kèm Ctrl là pinch;
nấc bánh xe nguyên vẫn là scroll kèm Ctrl. Trình duyệt dùng Ctrl kèm delta
pixel, bao gồm cả chuột phát kiểu Ctrl-wheel này. Chỉ chặn zoom mặc định
của trình duyệt khi view nhận sự kiện.

Kiểm thử headless với `t.pinch(x, y, scale)`; kết quả cho biết có handler
nhận hay không. `t.scroll` và `t.wheel` cũng đi qua handler. Hai phương thức
cuộn của Tester dùng `dy` dương hướng lên như trước, còn `InputEvent.dy`
được đổi sang dương hướng xuống.

Xem [ví dụ gestures](../../../examples/gestures/main.zig). `zig build
test-web -j1` cũng kiểm tra pinch và pan ngang/dọc trên bản WebAssembly
dưới Node, không mở cửa sổ trình duyệt.

Windows cũng chuyển `WM_MOUSEHWHEEL` thành `dx` của handler, dương sang
phải, kể cả khi giữ Ctrl. Cuộn ngang không bị đổi thành pinch.

Thêm `-Dweb-browser="/path/to/chrome-or-edge"` vào `zig build test-web`
để kiểm tra thêm `WheelEvent` thật trong trình duyệt headless: delta theo
pixel, dòng và trang; Ctrl-pinch; chỉ chặn mặc định khi handler nhận sự
kiện. Test không hiện cửa sổ hay tạo input ở cấp hệ điều hành.
