# glass

Liquid Glass cho native UI, theo plugin glass của mygo, vốn đo theo `NSGlassEffectView` của macOS 27. Thứ nằm dưới một tấm kính hiện xuyên qua nó:

- bị làm mờ như kính mờ;
- bị bẻ cong gần các mép, như nhìn qua vành một thấu kính;
- được chỉnh tông để chữ trên kính dễ đọc: sáng hơn trong cửa sổ sáng, tối hơn trong cửa sổ tối;
- được chiếu sáng dọc theo đường viền mảnh.

Nó cũng có một hiệu ứng blur nền đơn thuần.

Package là `plugins/glass` (module `glass`). Xem [Plugin](../plugins.md) để thêm nó vào app.

```zig
const glass = @import("glass");

fn view(s: *State, c: *ui.Context) void {
    // ... nội dung, scroll bên dưới thanh ...
    _ = glass.pane(c, .{ .radius = 22 }, .{ .absolute = true, .offset = .{ .x = 12, .y = 12 }, .padding = .all(8) });
    ui.text(c, "On glass", .{});
    c.end();
}
```

<a id="panes"></a>

## Tấm kính

`glass.pane(c, g, style)` mở một box và trả về id của nó. `style` cho kích thước, padding và vị trí. Các phần tử con của nó theo sau cho đến `c.end()`. `g` là một `glass.Glass`:

| trường | mặc định | |
|---|---|---|
| `style` | `.regular` | `.regular`, hoặc `.clear`, gần như không chỉnh tông |
| `tint` | null | nhuộm kính về một màu, theo alpha của màu đó, như một nút nổi bật |
| `radius` | 16 | bán kính góc, tính bằng DIP |

`glass.paneOf(c, kind, style)` nhận một `glass.Kind`: `.{ .glass = g }`, hoặc `.{ .blur = .{ .radius = 12, .corner = 8 } }` cho blur nền đơn thuần với bán kính `radius` DIP và góc bo tròn.

Chất liệu đi theo kích thước của tấm kính như frame trước đã layout:

- Tấm lớn hơn thì mờ hơn, tối đa 10 DIP.
- Phần viền cong ở 36 DIP cuối, tối đa nửa tấm.
- Phần viền bẻ cong thứ hiện qua nó tới 1,6 lần khoảng đó.

<a id="how-it-draws"></a>

## Cách nó vẽ

Tấm kính là một box có hiệu ứng nền (`ui.Style.effect`; xem [Biến đổi và hiệu ứng](../ui/transforms.md)). Mọi renderer (Metal, Direct3D 11, OpenGL, WebGL 2 và CPU) làm giống nhau:

1. Nó đọc thứ đã vẽ dưới tấm kính và xung quanh, rồi blur lại.
2. Nó vẽ kính từ đó, tại chỗ của tấm kính trong thứ tự vẽ.
3. Các phần tử con của tấm kính vẽ sau, lên trên kính, không bị làm mờ.

GPU vẽ màu của kính bằng `src/glass.metal`, `src/glass.hlsl` và `src/glass.glsl`. Renderer CPU dùng bản sinh đôi của chúng, `pixels.glassColor`. Pixel của chúng khớp nhau trong phạm vi một mức trên 255:

- `ui.gpu_testing` so từng renderer GPU với renderer CPU.
- Các test so frame có tấm kính với `pixels.glass` vẽ lên frame không có nó.

Xem [Render](../ui/rendering.md) để biết về bản sinh đôi CPU.

<a id="what-is-here"></a>

## Những gì có ở đây

- `glass.material`: chất liệu, giống như trong mygo. `material.of(style, tint, w, h, scale, dark)` trả về một `Material` tính bằng pixel thiết bị.
  - Kính thường ánh xạ màu đen thành 54% và màu trắng thành 100% ở chế độ sáng, và thành 15% và 51% ở chế độ tối.
  - Profile của phần viền là squircle của Apple, bẻ cong theo định luật Snell.
  - Nó cũng có khoảng cách tới hình chữ nhật bo góc, pháp tuyến đã làm mượt, và đường cong tông màu.
- `glass.shader`: chất liệu dưới dạng tham số của một hiệu ứng (`effectOf`), shader của kính (mã nguồn GPU và bản sinh đôi CPU), và blur đơn thuần (`blurOf`).
- `glass.pixels`: hiệu ứng chạy trên CPU, trên mọi pixel BGRA (`glass.Image`). `pixels.glass(gpa, image, rect, radii, material)` và `pixels.blur(gpa, image, rect, radii, sigma)`.

<details>
<summary>Cách <code>glass.pixels</code> vẽ</summary>

1. Nền: các pixel dưới hình, và xung quanh nó trong phạm vi blur với tới.
2. Với blur lớn, chúng được lấy trung bình trên các ô vuông từ 1 đến 8 pixel.
3. Một Gaussian tách được làm mờ chúng. Mỗi bước làm tròn về 8 bit, như texture lưu chúng. Các renderer của myzig đọc nền theo cùng cách đó (`src/ui/backdrop.zig`).
4. Sau đó, với từng pixel của hình: lấy mẫu qua thấu kính, chỉnh tông, nhuộm màu và chiếu sáng dọc viền, khử răng cưa dọc mép.

</details>

<a id="left-out"></a>

## Những gì chưa có

- `ScrollEdge` của mygo (mép mềm và mép cứng).
- Blur tăng dần theo một mask.
- Kính tương tác phồng lên khi bấm giữ.
- Màu nhuộm wide-gamut.
- Tấm kính bị xoay hoặc nghiêng bởi một transform. Renderer vẽ hiệu ứng theo các trục của cửa sổ: tấm kính bị dời chỗ, hoặc co giãn đều cả hai chiều, thì được vẽ; bị xoay thì không.

<a id="tests"></a>

## Test

```sh
cd plugins/glass
zig build test                              # the effect over pixels, panes through ui.Tester
zig build check -Dtarget=x86_64-linux-gnu   # type-check another platform
```
