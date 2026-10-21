# glass

Kính lỏng cho giao diện native, sau plugin kính của mygo (đo được macOS 27 của `NSGlassEffectView`): nội dung bên dưới khung hiển thị xuyên qua nó, được làm mờ, uốn cong gần các cạnh của nó như qua vành của thấu kính, được làm săn chắc để những gì trên đó đọc được (sáng hơn trong cửa sổ sáng, tối hơn trong cửa sổ tối) và sáng dọc theo viền chân tóc của nó. Nó cũng có một phông nền mờ đơn giản.

Gói này là `plugins/glass` (mô-đun `glass`). Xem [Plugin](../plugins.md) để thêm plugin vào ứng dụng.

```zig
const glass = @import("glass");

fn view(s: *State, c: *ui.Context) void {
    // ... the content, which scrolls under the bar ...
    _ = glass.pane(c, .{ .radius = 22 }, .{ .absolute = true, .offset = .{ .x = 12, .y = 12 }, .padding = .all(8) });
    ui.text(c, "On glass", .{});
    c.end();
}
```

<a id="panes"></a>

## Tấm

`glass.pane(c, g, style)` mở một hộp được tạo kiểu bởi `style` (kích thước, phần đệm, vị trí) có các phần tử con theo sau cho đến `c.end()` và trả về id của hộp. `g` là `glass.Glass`:

| lĩnh vực | mặc định | |
|---|---|---|
| `style` | `.regular` | `.regular`, hoặc `.clear`, hầu như không có âm sắc |
| `tint` | null | tô màu kính theo một màu, theo chữ cái của nó, làm nút nổi bật |
| `radius` | 16 | bán kính góc, tính bằng DIP |

`glass.paneOf(c, kind, style)` lấy `glass.Kind`: `.{ .glass = g }` hoặc `.{ .blur = .{ .radius = 12, .corner = 8 } }` để làm mờ phông nền đơn giản của `radius` DIP với các góc tròn.

Vật liệu tuân theo kích thước của khung khi khung cuối cùng được bố trí: các khung lớn hơn sẽ mờ hơn (tối đa 10 DIP); khung bezel uốn cong 36 DIP cuối cùng (nhiều nhất là một nửa khung) và uốn cong những gì hiển thị lên tới 1,6 lần.

<a id="how-it-draws"></a>

## Nó vẽ như thế nào

Ô là một hộp có hiệu ứng phông nền (`ui.Style.effect`; xem [Biến đổi và hiệu ứng](../ui/transforms.md)). Mỗi bộ kết xuất (Metal, Direct3D 11, OpenGL, WebGL 2 và CPU) đọc những gì nó vẽ bên dưới khung và xung quanh khung, làm mờ khung đó và vẽ kính từ khung đó vào vị trí của khung theo thứ tự sơn, trước các phần tử con của khung, vẽ trên kính không bị đóng băng.

GPU vẽ màu của kính bằng `src/glass.metal`, `src/glass.hlsl` và `src/glass.glsl`; bộ kết xuất CPU với bộ đôi của nó, `pixels.glassColor`. Các pixel của chúng khớp nhau trong một mức 255: myzig của `ui.gpu_testing` so sánh từng bộ kết xuất GPU với CPU và các kiểm thử so sánh khung của một khung với `pixels.glass` được vẽ trên khung không có khung đó. Xem [Kết xuất](../ui/rendering.md) để biết bản đối chiếu CPU.

<a id="what-is-here"></a>

## Ở đây có gì

- `glass.material`: chất liệu, như mygo có. `material.of(style, tint, w, h, scale, dark)` cho `Material` pixel của thiết bị: kính thông thường ánh xạ màu đen thành 54% và màu trắng thành 100% ở chế độ sáng, 15% và 51% ở chế độ tối; hình dáng của khung bezel là hình tròn của Apple, được uốn cong theo định luật Snell. Ngoài ra khoảng cách của hình chữ nhật được làm tròn và được làm mịn bình thường, và đường cong tông màu.
- `glass.shader`: vật liệu làm tham số của hiệu ứng (`effectOf`), shader của kính (nguồn GPU và bản đối chiếu CPU của nó) và độ mờ đơn giản (`blurOf`).
- `glass.pixels`: hiệu ứng lên CPU trên bất kỳ pixel BGRA nào (`glass.Image`): phông nền (các pixel bên dưới hình dạng và xung quanh nó cho đến khi độ mờ đạt tới, tính trung bình trên các ô vuông từ 1 đến 8 pixel đối với các điểm ảnh mờ lớn, được làm mờ bởi một Gaussian có thể tách rời, được làm tròn thành 8 bit ở mỗi bước khi kết cấu giữ chúng; bộ kết xuất của myzig đọc nó theo cách tương tự, `src/ui/backdrop.zig`), sau đó đối với mỗi pixel của hình dạng, mẫu của ống kính, có tông màu, tông màu và sáng dọc theo viền, khử răng cưa dọc theo cạnh. `pixels.glass(gpa, image, rect, radii, material)` và `pixels.blur(gpa, image, rect, radii, sigma)`.

<a id="left-out"></a>

## Bị bỏ lại

mygo's `ScrollEdge` (cạnh mềm và cứng), độ mờ tăng dần dọc theo mặt nạ, kính tương tác phát triển khi nhấn, tông màu gam màu rộng và các ô được xoay hoặc nghiêng bởi một phép biến đổi (bộ kết xuất vẽ các hiệu ứng theo trục của cửa sổ: một ô được di chuyển hoặc được chia tỷ lệ giống nhau theo cả hai cách sẽ được vẽ; một lượt thì không).

<a id="tests"></a>

## Kiểm tra

```sh
cd plugins/glass
zig build test                              # the effect over pixels, panes through ui.Tester
zig build check -Dtarget=x86_64-linux-gnu   # type-check another platform
```
