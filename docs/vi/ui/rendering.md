<a id="rendering"></a>

# Render

Một frame native UI đi qua bốn bước, giống nhau trong cửa sổ và trong [`ui.Tester`](testing.md) (`src/ui/frame.zig`):

1. **Build.** View chạy và mở các box vào cây của context. Khi một tương tác làm state đổi (`c.changed`), view được build lại trước khi vẽ bất cứ gì, tối đa thêm ba lần. Nhờ vậy màn hình không bao giờ chậm hơn state.
2. **Layout.** Flexbox đo và sắp xếp cây (`layout.zig`). Với giao diện phải sang trái, cây sau đó được [lật ngược](right-to-left.md).
3. **Paint.** Cây trở thành các instance theo thứ tự vẽ (`paint.zig`):
   - quad: hình chữ nhật bo góc có viền;
   - glyph và icon từ glyph atlas;
   - bóng Gaussian;
   - hình ảnh từ image atlas.

   Mỗi instance bị cắt (clip) theo một hình chữ nhật, có thể bo góc. Box nằm ngoài vùng clip bị loại bỏ. Transform, gradient, blur và hiệu ứng thêm các hàng dữ liệu sau các instance (`gpu.Frame`).
4. **Vẽ.** Một renderer vẽ các instance: trên CPU, hoặc trên GPU bằng một lệnh vẽ instanced duy nhất. Lệnh này chỉ bị tách ra ở chỗ một hiệu ứng nền hoặc một layer bị blur cần đọc thứ nằm bên dưới.

<a id="the-renderers"></a>

## Các renderer

Mọi renderer vẽ cùng các instance (`src/ui/gpu.zig`) bằng cùng một shader, viết một lần cho Metal rồi dịch từng dòng:

| Ở đâu | Renderer | Shader | Hiển thị qua |
|---|---|---|---|
| macOS | Metal (`metal.zig`), một vòng ba instance buffer | `shader.metal`, biên dịch khi app khởi động | một `CAMetalLayer`, theo nhịp display link |
| Windows | Direct3D 11 (`d3d11.zig`), trên thiết bị phần cứng | `d3d11.hlsl`, biên dịch trước thành `d3d11.cso` (`zig run src/ui/d3d11_gen.zig`) | một swap chain DXGI kiểu flip model |
| Linux | OpenGL 3.3 core hoặc OpenGL ES 3.0 (`gl.zig`), nạp lúc chạy | `gl.glsl` | một GtkGLArea, theo nhịp frame clock |
| Trình duyệt | WebGL 2 (`webgl.zig`, context do `web/host_gl.js` giữ) | `gl.glsl` bằng GLSL ES 3.0 | canvas của cửa sổ, trong các animation frame |
| Mọi nơi | renderer CPU (`raster.zig`) | Zig của riêng nó, cùng phép tính | cairo trên Linux, GDI trên Windows, canvas 2D trong trình duyệt |

- **Hình.** Shader tính hình chữ nhật bo góc, viền và bóng từ khoảng cách tới mép của chúng. Nhờ vậy chúng luôn sắc nét ở mọi kích thước và tỉ lệ. Bóng là Gaussian, theo shader của GPUI.
- **Chữ** lấy từ một glyph atlas. Atlas lớn dần khi cần thêm glyph và chỉ upload khi có thay đổi. Trên macOS, CoreText raster hóa các glyph; ở nơi khác là trình đọc TrueType của chính myzig (`src/ui/tt/`).
- **Icon** là SF Symbols trên macOS, và icon nét do myzig tự vẽ (`icons.zig`) ở nơi khác.
- **Hình ảnh** được giải mã một lần rồi xếp vào một atlas BGRA (`images.zig`).

<a id="the-cpu-twin"></a>

## Bản sinh đôi CPU

Renderer CPU vẽ ra đúng những pixel mà các renderer GPU vẽ: BGRA, premultiplied, giá trị mã hóa sRGB được blend như GPU blend. Mỗi renderer GPU được test đối chiếu với nó, offscreen, sai khác tối đa một hai mức do làm tròn khi blend:

- `src/ui/tests_raster.zig`: renderer CPU đối chiếu với Metal, trên một frame gồm chữ, icon, viền, góc bo và clip, bóng và một hình ảnh.
- `src/ui/d3d11_test.zig`: Direct3D 11 vẽ vào một texture rồi đọc lại (bỏ qua nếu không có Direct3D trên GPU).
- `src/ui/gl_test.zig`: OpenGL 3.3 và OpenGL ES 3.0 qua EGL không cần surface (bỏ qua nếu không có EGL); `gl_gtk_test.zig` cho đường GtkGLArea.
- `src/ui/gpu_fx_test.zig`: những gì vẽ theo đường tổng quát và giữa các phần của frame (transform ngẫu nhiên mọi loại, gradient, hiệu ứng nền thuần và có shader, layer bị blur), trên mọi renderer GPU nó tìm thấy. Plugin dùng nó để test hiệu ứng của mình (`ui.gpu_testing`).
- `src/ui/gpu_corners_test.zig`: góc liên tục (tô, viền, bóng cắt thành nine-patch, hình ảnh, gradient, clip) trên mọi renderer GPU.
- Trình duyệt: `src/web/test_browser.js` so pixel của WebGL 2 với của renderer CPU trong một Chromium headless.

Vì pixel giống nhau, một cửa sổ không vẽ được trên GPU vẫn hiện đúng các frame ấy, vẽ trên CPU. Và snapshot vẽ trên CPU của một test chính là thứ GPU hiện ra.

**Renderer CPU nhanh nhờ đâu.**

- Nó vẽ một frame theo từng dải 64 hàng. Frame lớn dùng nhiều nhân, trên các thread khởi tạo một lần và chờ giữa các frame.
- Mỗi pixel giống hệt như khi vẽ riêng nó, nên các dải vẽ ra cùng pixel theo bất kỳ thứ tự nào.
- Bước xóa nền bỏ qua phần đã bị một nền đục vẽ trước che kín.
- Trong một instance, phần giống nhau theo hàng hoặc theo cột chỉ được tính một lần. Phần tô đặc được sao chép, và texel trống bị bỏ qua. `raster_lanes.zig` xử lý tám pixel một lúc.
- Mỗi đường tắt này cho đúng giá trị mà đường tổng quát cho. `hillclimb --hash` kiểm tra rằng một renderer nhanh hơn vẫn giữ nguyên pixel của mọi frame.

**Hiệu ứng.** Hiệu ứng nền ([kính mờ](transforms.md), [shader](shaders.md)) và layer bị blur được vẽ giữa các phần của frame:

1. Renderer đọc những gì nó đã vẽ tới lúc đó quanh hình.
2. Nó blur phần đó (`backdrop.zig`): lấy trung bình thu nhỏ với blur lớn, rồi Gaussian theo hàng và theo cột. Mỗi bước làm tròn về 8 bit, như texture lưu chúng.
3. Nó vẽ box từ kết quả đó.

GPU làm việc này qua nhiều lượt trên texture (`metal_fx.zig`, `d3d11_fx.zig`, `gl_fx.zig`). Renderer CPU làm theo đúng các bước ấy (`raster_fx.zig`). Shader của một hiệu ứng chạy dưới dạng HLSL, GLSL hoặc Metal trên GPU, và dưới dạng bản sinh đôi CPU (`Shader.cpu`) trên CPU.

<a id="choosing-the-renderer"></a>

## Chọn renderer

- **macOS** vẽ bằng Metal. `zig build -Dportable=true` thay vào đó build phần chữ và renderer CPU của Linux và Windows, để test đường đó trên máy Mac.
- **Windows** bắt đầu tạo thiết bị Direct3D 11 trên phần cứng, trong một thread, cùng lúc với frame đầu tiên cửa sổ hiện.
  - Cho đến khi có thiết bị, các frame được vẽ trên CPU. Nhờ vậy driver khởi động chậm không bao giờ giữ chân cửa sổ.
  - Không có thiết bị (không có thiết bị phần cứng, hoặc không có swap chain), hoặc khi mất thiết bị, cửa sổ vẽ trên CPU và GDI sao chép frame lên nó. Log cho biết lý do (`myzig: no Direct3D (...)`).
- **Linux** vẽ bằng OpenGL trong một GtkGLArea (GTK 3.16 trở lên) khi có GPU.
  - Với driver DRM chỉ để hiển thị, nó vẽ trên CPU và cairo hiện frame. Đây là driver của máy ảo và server: `simpledrm`, `bochs`, `vboxvideo`, `hyperv_drm` và tương tự. Ở đó llvmpipe của Mesa sẽ chậm hơn renderer CPU của myzig.
  - `MYZIG_GPU=0` giữ frame trên CPU. `MYZIG_GPU=1` vẽ bằng OpenGL kể cả ở nơi bình thường nó không làm vậy.
- **Trình duyệt** vẽ bằng WebGL 2, hoặc trên CPU vào một canvas 2D khi trình duyệt không có WebGL 2 (`start({ webgl: false })` ép dùng cách này). Context WebGL bị mất sẽ vẽ lại khi trình duyệt khôi phục nó.

<a id="when-frames-are-drawn"></a>

## Khi nào frame được vẽ

Không có gì chạy polling. Một frame được build và vẽ:

- khi có input;
- khi đổi kích thước;
- khi app xin một frame từ ngoài view;
- trong lúc một animation đang chạy (`c.animating`).

Animation frame đến theo tần số làm tươi của màn hình trên macOS (display link), từ frame clock trên Linux (một tick callback), từ một timer 60 Hz trên Windows, và từ `requestAnimationFrame` trong trình duyệt.

- Cửa sổ rảnh không vẽ gì, và app rảnh không dùng CPU.
- Cửa sổ khuất khỏi tầm nhìn không nhận frame nào, cho đến khi một phần của nó hiện lại (xem [Khi khuất tầm nhìn](performance.md#out-of-sight)). Trên macOS, đó là khi bị ẩn, thu nhỏ, ở Space khác hoặc bị cửa sổ khác che kín, theo `occlusionState` của nó. Trong trình duyệt, đó là tab nằm ở nền.
- Khi một frame làm đổi thứ nằm dưới con trỏ đang đứng yên, một frame nữa theo sau. Nhờ vậy hover đi theo nội dung đã di chuyển.

<a id="frame-costs"></a>

## Chi phí của frame

Mỗi frame ghi chi phí của nó vào `c.stats` (`ui.FrameStats`):

- thời gian build, layout và paint, tính bằng mili giây;
- số lần view được build (`passes`);
- số box (`nodes`);
- số `instances` của renderer.

[Inspector](inspector.md) hiện chúng cho 60 frame gần nhất, và [hillclimb](performance.md) đo chúng ở chế độ headless.
