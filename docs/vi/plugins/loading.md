# Loading

Package `loading` cung cấp 29 chỉ báo loading.dev cho native UI trên macOS,
Linux, Windows và trình duyệt. Plugin dùng canvas của myzig, không cần
JavaScript hay đăng ký service.

Thêm dependency `.loading = .{ .path = "path/to/myzig/plugins/loading" }`
vào `build.zig.zon`, rồi thêm module vào executable:

```zig
const loading = b.dependency("loading", .{
    .target = target, .optimize = optimize,
}).module("loading");
exe.root_module.addImport("loading", loading);
```

Giữ một `loading.Indicator` riêng trong state cho mỗi chỉ báo đang hiển thị.
Gọi `show` một lần trong mỗi lượt dựng view; kết quả là chỉ số node để có
thể dùng tiếp với `c.interact` hoặc `c.node`.

Mỗi instance có đồng hồ riêng. Tạm dừng một chỉ báo không làm dừng chỉ báo
khác; dựng lại view nhiều lần trong cùng frame không cộng thêm thời gian.
Tăng `duration` gấp đôi sẽ mất gấp đôi thời gian để đạt cùng pha chuyển động.

```zig
const loading = @import("loading");

// Trong state:
busy: loading.Indicator = .{},

// Trong view:
_ = s.busy.show(c, .ring, .{
    .size = 32, .color = c.theme.accent, .label = "Đang lưu",
});
```

`Kind` gồm `arc`, `atom`, `blocks`, `bouncing_dots`, `cascade`,
`circular_dots`, `classic`, `classic_v2`, `clock`, `comet`, `compass`,
`dual`, `eclipse`, `flip`, `gather`, `leap`, `linear_dots`, `loading`,
`morph`, `orbit`, `pulse`, `radar`, `ring`, `ripple`, `slide`, `snake`,
`swirl`, `trace`, `wave`. `loading.names` chứa tên cùng thứ tự.

| Tùy chọn | Ý nghĩa |
| --- | --- |
| `size` | Chiều cao theo point, mặc định 20; phải hữu hạn và dương. |
| `color` | Mặc định là màu chữ của theme. |
| `duration` | Số giây mỗi chu kỳ; hữu hạn và dương. `null` dùng thời lượng riêng của mẫu. |
| `paused` | Giữ thời gian hiện tại, tiếp tục từ đó khi bỏ tạm dừng. |
| `easing` | `.linear`, `.ease_in_out`, `.stacked`. |
| `cap` | Đầu nét `.round` hoặc `.flat`. |
| `sweep` | Blocks: `.diagonal`, `.rows`, `.columns`. |
| `direction` | Ripple: `.out`, `.in`. |
| `origin` | Wave: `.center`, `.bottom`. |
| `label` | Tên cho công cụ hỗ trợ tiếp cận; mặc định là tên mẫu. |

Khi hệ điều hành yêu cầu giảm chuyển động, chỉ báo đứng yên và không yêu
cầu frame liên tục. Khi bị cắt khỏi vùng nhìn thấy, nó cũng ngừng yêu cầu
frame; thông tin này lấy từ lượt vẽ trước. Công cụ hỗ trợ tiếp cận nhận nó
là progress indicator chưa xác định tiến độ.

Canvas có thể rasterize lại mask khi hình thay đổi. Bản port chưa bảo đảm
pixel hay chi phí kết xuất giống plugin mygo đã tối ưu.

Xem [gallery](../../../examples/loading/README.md). Chạy
`zig build test-loading -j1` tại gốc repo, hoặc `zig build test -j1` trong
`plugins/loading` để kiểm tra pixel, đồng hồ và accessibility hoàn toàn offscreen.
Các test so sánh pha đã vẽ với thời lượng khác nhau, kiểm tra đồng hồ độc
lập, rebuild cùng frame, tạm dừng/tiếp tục và hành vi khi ra ngoài vùng nhìn thấy.
