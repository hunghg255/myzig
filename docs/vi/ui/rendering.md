<a id="rendering"></a>

# Kết xuất

Một khung giao diện native trải qua bốn bước, giống nhau trong một cửa sổ và trong [Tester](testing.md) (`src/ui/frame.zig`):

1. **Build.** View chạy và mở các hộp vào cây ngữ cảnh. Khi một tương tác thay đổi trạng thái (`c.changed`), view sẽ được tạo lại trước khi bất kỳ nội dung nào được vẽ, tối đa ba lần nữa, do đó màn hình không bao giờ bị trễ trạng thái.
2. **Bố cục.** Flexbox đo và sắp xếp cây (`layout.zig`); từ phải sang trái thì nó sẽ được [phản chiếu](right-to-left.md).
3. **Sơn.** Cây trở thành các phiên bản theo thứ tự sơn (`paint.zig`): hình tứ giác là các hình chữ nhật bo tròn có đường viền, hình tượng và biểu tượng từ atlas hình tượng, bóng Gaussian và hình ảnh từ atlas hình ảnh, mỗi hình được cắt bớt thành một hình chữ nhật có các góc có thể được làm tròn. Các hộp trong clip của họ đã bị loại bỏ. Biến đổi, chuyển màu, làm mờ và hiệu ứng sẽ thêm các hàng dữ liệu sau các phiên bản (`gpu.Frame`).
4. **Draw.** Trình kết xuất sẽ vẽ các phiên bản: trên GPU trong một lệnh gọi vẽ tạm thời (chỉ phân chia khi hiệu ứng phông nền hoặc lớp mờ phải đọc nội dung bên dưới nó) hoặc trên CPU.

<a id="the-renderers"></a>

## Trình kết xuất

Mọi bộ kết xuất đều vẽ các phiên bản giống nhau (`src/ui/gpu.zig`) với cùng một shader, được viết một lần cho Metal và dịch từng dòng cho mỗi dòng:

| Ở đâu | Trình kết xuất | đổ bóng | Được hiển thị bởi |
|---|---|---|---|
| macOS | Metal (`metal.zig`), một vòng gồm ba bộ đệm phiên bản | `shader.metal`, được biên dịch khi ứng dụng khởi động | a `CAMetalLayer`, được tăng tốc theo liên kết hiển thị |
| Windows | Direct3D 11 (`d3d11.zig`), trên thiết bị phần cứng | `d3d11.hlsl`, được biên soạn trước thành `d3d11.cso` (`zig run src/ui/d3d11_gen.zig`) | chuỗi hoán đổi mô hình lật DXGI |
| Linux | OpenGL 3.3 lõi hoặc OpenGL ES 3.0 (`gl.zig`), được tải trong thời gian chạy | `gl.glsl` | một GtkGLArea, theo tốc độ của đồng hồ frame |
| Trình duyệt | WebGL 2 (`webgl.zig`, bối cảnh được nắm giữ bởi `web/host_gl.js`) | `gl.glsl` trong GLSL ES 3.0 | khung vẽ của cửa sổ, trong khung hoạt hình |
| Mọi nơi | bộ kết xuất CPU (`raster.zig`) | Zig của chính nó, số học tương tự | cairo trên Linux, GDI trên Windows, canvas 2D trong trình duyệt |

Trình đổ bóng tính toán các hình chữ nhật tròn, đường viền và bóng từ khoảng cách đến các cạnh của chúng, để chúng luôn sắc nét ở mọi kích thước và tỷ lệ. Bóng là Gaussian, sau shader của GPUI. Văn bản xuất phát từ atlas hình tượng, phát triển khi cần hình tượng và chỉ tải lên khi nó thay đổi: hình tượng được CoreText raster hóa trên macOS và bởi trình đọc TrueType của chính myzig (`src/ui/tt/`) ở nơi khác. Biểu tượng là Ký hiệu SF trên macOS và biểu tượng đường được vẽ bởi myzig (`icons.zig`) ở nơi khác. Hình ảnh được giải mã một lần và được đóng gói vào atlas BGRA (`images.zig`).

<a id="the-cpu-twin"></a>

## CPU đôi

Trình kết xuất CPU vẽ chính các pixel mà bộ kết xuất GPU vẽ: BGRA, các giá trị được nhân trước, mã hóa sRGB được pha trộn khi GPU trộn chúng. Mỗi bộ kết xuất GPU đều được kiểm tra dựa trên nó, ngoài màn hình, ở một hoặc hai cấp độ làm tròn của pha trộn:

- `src/ui/tests_raster.zig`: bộ kết xuất CPU dựa trên Metal, khung văn bản, biểu tượng, đường viền, các góc và kẹp được bo tròn, bóng và hình ảnh.
- `src/ui/d3d11_test.zig`: Direct3D 11 thành kết cấu đọc lại (bỏ qua mà không có Direct3D trên GPU).
- `src/ui/gl_test.zig`: OpenGL 3.3 và OpenGL ES 3.0 thông qua EGL không có bề mặt (bỏ qua không có EGL); `gl_gtk_test.zig` đường dẫn GtkGLArea.
- `src/ui/gpu_fx_test.zig`: những gì vẽ trên đường dẫn chung và giữa các phần của frame (các biến đổi ngẫu nhiên thuộc mọi loại, độ dốc, hiệu ứng phông nền đơn giản và có shader, các lớp mờ), trên mọi bộ kết xuất GPU mà nó tìm thấy. Các plugin kiểm tra tác dụng của chính chúng với nó (`ui.gpu_testing`).
- `src/ui/gpu_corners_test.zig`: các góc liên tục (nền, đường viền, bóng được cắt thành chín miếng, hình ảnh, độ dốc, clip) trên mọi bộ kết xuất GPU.
- Trình duyệt: `src/web/test_browser.js` so sánh pixel của WebGL 2 với bộ kết xuất CPU trong headless Crom.

Vì các pixel giống nhau nên một cửa sổ không thể vẽ trên GPU sẽ hiển thị các frame giống nhau được vẽ trên CPU và ảnh chụp nhanh của bài kiểm tra được vẽ trên CPU là những gì GPU hiển thị.

Trình kết xuất CPU vẽ một khung theo dải gồm 64 hàng, trên một số lõi khi khung lớn (các luồng bắt đầu một lần, chờ giữa các khung); mỗi pixel là những gì bản vẽ mà nó mang lại, vì vậy các dải sẽ vẽ các pixel giống nhau theo bất kỳ thứ tự nào. Rõ ràng bỏ qua những gì nền mờ được vẽ đầu tiên bao gồm. Trong một phiên bản, những gì giống nhau dọc theo một hàng hoặc một cột sẽ được tìm thấy một lần, phần tô đậm được sao chép và các đoạn văn bản trống sẽ bị bỏ qua (`raster_lanes.zig` thực hiện tám pixel cùng một lúc). Mỗi đường dẫn nhanh này mang lại giá trị rất cao mà đường dẫn chung mang lại và `hillclimb --hash` kiểm tra xem bộ kết xuất nhanh hơn có giữ nguyên các pixel của mọi frame hay không.

Hiệu ứng phông nền ([kính mờ](transforms.md), [shaders](shaders.md)) và các lớp mờ vẽ giữa các phần của khung: bộ kết xuất đọc những gì nó đã vẽ xung quanh hình dạng đó, làm mờ nó (giảm trung bình cho các vết mờ lớn, sau đó là một Gaussian dọc theo hàng và cột, làm tròn thành 8 bit ở mỗi bước khi họa tiết giữ chúng; `backdrop.zig`) và vẽ hộp từ đó. GPU thực hiện điều đó thông qua các kết cấu (`metal_fx.zig`, `d3d11_fx.zig`, `gl_fx.zig`), bộ kết xuất CPU với các bước tương tự (`raster_fx.zig`) và shader của hiệu ứng chạy dưới dạng HLSL, GLSL hoặc Metal trên GPU và dưới dạng CPU song sinh (`Shader.cpu`) trên CPU.

<a id="choosing-the-renderer"></a>

## Chọn bộ kết xuất

- **macOS** hòa với Metal. `zig build -Dportable=true` thay vào đó xây dựng bộ kết xuất văn bản và CPU của Linux và Windows để kiểm tra đường dẫn đó trên máy Mac.
- **Windows** tạo thiết bị Direct3D 11 trên phần cứng với khung đầu tiên mà cửa sổ hiển thị. Không có (không có thiết bị phần cứng hoặc không có chuỗi trao đổi) hoặc khi thiết bị của nó bị mất, cửa sổ sẽ vẽ CPU và GDI sao chép khung vào đó; nhật ký cho biết lý do tại sao (`myzig: no Direct3D (...)`).
- **Linux** vẽ bằng OpenGL trong GtkGLArea (GTK 3.16 trở lên) khi có GPU. Trên trình điều khiển DRM chỉ hiển thị (máy ảo và máy chủ: `simpledrm`, `bochs`, `vboxvideo`, `hyperv_drm` và tương tự), nó sẽ sử dụng CPU, vì llvmpipe của Mesa sẽ chậm hơn bộ kết xuất CPU của myzig và cairo hiển thị khung. `MYZIG_GPU=0` giữ các khung trên CPU, `MYZIG_GPU=1` vẽ bằng OpenGL ngay cả khi không.
- **Trình duyệt** vẽ bằng WebGL 2 hoặc trên CPU vào khung vẽ 2D mà trình duyệt không có (`start({ webgl: false })` buộc phải làm như vậy). Bối cảnh WebGL bị mất sẽ xuất hiện lại sau khi trình duyệt khôi phục nó.

<a id="when-frames-are-drawn"></a>

## Khi khung được vẽ

Không có polling nào. Một khung được tạo và vẽ dựa trên đầu vào, khi thay đổi kích thước, khi ứng dụng yêu cầu một khung từ bên ngoài view và trong khi hoạt ảnh chạy (`c.animating`): khi màn hình được làm mới trên macOS (liên kết hiển thị), đồng hồ khung trên Linux (gọi lại tích tắc), bộ hẹn giờ 60 Hz trên Windows và `requestAnimationFrame` trong trình duyệt. Cửa sổ nhàn rỗi không thu được gì và ứng dụng nhàn rỗi không sử dụng CPU. Trong khi một cửa sổ bị khuất tầm nhìn (trên macOS bị ẩn, thu nhỏ, trên một Không gian khác hoặc bị che bởi các cửa sổ khác, bởi `occlusionState` của nó; trong trình duyệt, một tab ở chế độ nền), không có khung nào được vẽ cho cửa sổ đó cả, cho đến khi một số khung hiển thị lại (xem [Khuất mắt](performance.md#out-of-sight)).

Khi một khung thay đổi nội dung bên dưới con trỏ tĩnh, một khung khác sẽ theo sau, do đó, di chuột sẽ theo dõi nội dung đã di chuyển.

<a id="frame-costs"></a>

## Chi phí khung

Mỗi khung ghi lại chi phí của nó bằng `c.stats` (`ui.FrameStats`): thời gian xây dựng, bố cục và vẽ tính bằng mili giây, số lần view được tạo (`passes`), các hộp (`nodes`) và `instances` của bộ kết xuất. [inspector](inspector.md) hiển thị chúng trong 60 frame cuối cùng và [hillclimb](performance.md) đo chúng headless.
