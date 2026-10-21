<a id="rendering-native-ui"></a>

# Đang hiển thị giao diện native

Cách một view trở thành pixel: đường dẫn khung được chia sẻ bởi windows và Trình kiểm tra, các phiên bản mà mỗi bộ kết xuất vẽ ra, năm bộ kết xuất (Metal, Direct3D 11, OpenGL, WebGL 2 và CPU), bản đối chiếu CPU chứng minh chúng đồng ý, văn bản và bản đồ cũng như bề mặt của từng nền tảng. Để sử dụng giao diện native, hãy xem [hướng dẫn giao diện native](ui/README.md); về khả năng hiển thị và hiệu suất từ ​​phía ứng dụng, [kết xuất](ui/rendering.md) và [hiệu suất](ui/performance.md). Quay lại [tổng quan](architecture.md).

<a id="one-frame"></a>

## Một frame

![Giao diện native pipe: bề mặt cửa sổ hoặc Trình kiểm tra chạy view, bố cục và sơn; vẽ lại giới hạn thiệt hại và bộ kết xuất GPU hoặc CPU sẽ vẽ các phiên bản.](../images/architecture-native-ui.svg)

Đọc các mũi tên từ trình gọi khung thông qua quá trình xây dựng, bố cục và vẽ, sau đó chuyển xuống bộ kết xuất. `gpu.Instance` là hợp đồng vẽ chung; đường dẫn CPU cũng cung cấp các pixel tham chiếu cho các bài kiểm tra GPU. Việc định hình văn bản xảy ra trong quá trình bố trí và các tập bản đồ glyph được đọc trong quá trình vẽ.

`ui/frame.zig`'s `run` tạo một khung và cả bề mặt của mọi cửa sổ và `ui.Tester` đều gọi nó, vì vậy những gì kiểm tra thấy là những gì cửa sổ hiển thị:

1. **Xây dựng.** View (`ui.View`: một con trỏ và hàm `build`) chạy với `*ui.Context`. Các widget mở và đóng các hộp (`Context.open`, `leaf`, `end`) thành một cây nút phẳng cho khung này và trả lời các tương tác (nhấp chuột, di chuột, kéo, phím) từ bố cục của khung **trước**. Một widget có tương tác đã thay đổi bộ trạng thái của ứng dụng `c.changed`; sau đó khung được xây dựng lại (`c.rebuild()`), tối đa bốn lượt chuyển đổi, do đó màn hình không bao giờ bị trễ trạng thái. Một hộp còn mở hoảng loạn có bao nhiêu.
2. **Bố cục** (`ui/layout.zig`). Flexbox chia làm hai lần: `measure` định cỡ các hộp từ nội dung của chúng từ dưới lên (văn bản được định hình và gói ở đây, từ các bố cục được lưu trong bộ nhớ đệm; chiều rộng và phần bao bọc của mỗi hộp văn bản được giữ theo id của nó trên các khung, được so sánh, trong `layout_cache.zig` và một hộp được đo lại ở chiều rộng trong một khung vẫn như cũ), `arrange` đặt chúng từ trên xuống, chia sẻ không gian trống giữa các hộp phát triển và lấy nó từ những hộp co lại thành CSS flexbox thực hiện (`layout_flex.zig`), sắp xếp các đường cơ sở (`layout_baseline.zig`); hộp tuyệt đối, view cuộn, lưới (`grid_layout.zig`) và từ phải sang trái (`direction.zig`) được xử lý tại đây. Hình chữ nhật của mỗi nút được ghi lại theo id cho các tương tác của khung tiếp theo.
3. **Sơn** (`ui/paint.zig`). Cây được bố trí trở thành **phiên bản** của bộ kết xuất theo thứ tự sơn: nền, đường viền, bóng, đường chạy glyph, biểu tượng, hình ảnh, chuyển màu, hiệu ứng và dấu lớp, mỗi phiên bản có clip của nó (bao gồm các clip tròn), các hộp bên ngoài clip của chúng được loại bỏ. Các hộp được chuyển đổi sẽ vẽ cây con trong không gian riêng của chúng (`paint_xf.zig`) và các chuyển màu, các phép biến đổi và hiệu ứng sẽ thêm các hàng dữ liệu sau các phiên bản. Các hộp tương tác ghi lại hình chữ nhật hiển thị của chúng (`hit.zig`), với bản đồ nghịch đảo cho các hình đã được chuyển đổi, do đó con trỏ đi theo những gì được vẽ. Một hộp có **mực** (hộp của nó phát triển nhờ bóng, mờ, văn bản và các biểu tượng vươn ra khỏi hộp, cũng như mực của các hộp bên trong nó, được tìm thấy từ cây trong một lần quay lại phía trước) đoạn clip của nó bị bỏ qua với tất cả những gì nó chứa, khi Blink và Flutter bỏ qua những gì nằm bên ngoài phần chỉnh sửa chọn lọc: một trang được cắt bớt gồm một nghìn hàng sẽ vẽ các hàng trong view. Các hộp đã chuyển đổi và văn bản có thể chọn sẽ được vẽ ở bất kỳ đâu và không có gì bị bỏ qua trong khi các hộp chuyển tiếp di chuyển hoặc với view web; `tests_paint_cull.zig` kiểm tra xem các phiên bản có được vẽ mà không bỏ qua hay không. Nếu atlas được lấp đầy và đặt lại trong quá trình sơn, khung sẽ được sơn lại.
4. **Cam kết.** Nội dung con trỏ kết thúc được cập nhật từ các lượt truy cập mới; nếu nó thay đổi dưới một con trỏ tĩnh, `Result.hot_changed` sẽ yêu cầu một khung khác.

Những gì view vượt qua sẽ được đọc trong các giai đoạn sau, sau khi nó trả về: định hình và gói gọn trong bố cục của văn bản, các nét vẽ của nó trong sơn, cây trợ năng sau cả hai. Vì vậy, `Context.leaf` sao chép chuỗi của hộp văn bản và mở rộng vào khu vực của khung (`c.alloc()`, đặt lại khi khung tiếp theo bắt đầu) và `access.describe` chuỗi của nó: giải phóng chúng trong view, ngay cả giữa hai widget hiển thị chúng, không thể để bố cục đọc bộ nhớ trống (`tests_frame_strings.zig`). Bản sao có giá từ 0,04 đến 0,06 ms một frame trên một nghìn hộp văn bản trong cảnh leo đồi. Mọi thứ khác mà nút trỏ tới (byte của ảnh, tên biểu tượng, độ dốc, đường dẫn canvas) phải tồn tại cho đến khi khung được vẽ: ứng dụng sẽ giải phóng dữ liệu đó sau khung (khung sau hoặc vào sự kiện tiếp theo) hoặc giữ bản sao cũ để cập nhật thêm.

`c.stats` (`ui.FrameStats`) ghi lại mili giây, lượt vượt qua, nút và phiên bản của mỗi giai đoạn: người kiểm tra và người leo đồi đọc nó.

Các khung chỉ chạy khi có yêu cầu nào đó: đầu vào, thay đổi kích thước, thay đổi từ bên ngoài view (`Window.redraw()`, trên luồng chính, đối với trạng thái đã thay đổi bên ngoài view: bộ hẹn giờ, đầu ra của quá trình) hoặc hoạt ảnh đang di chuyển (`c.animating`, được đặt bởi `Context.animate` và chuyển động). Không hoạt động, một cửa sổ không thu được gì: `tests_idle.zig` di chuyển một nút có chú giải công cụ, nhấp chuột, chuyển đổi, nhập, rời khỏi một trường, chuyển sang màu tối và thay đổi kích thước, và sau mỗi lần kiểm tra rằng cửa sổ đã xử lý không có hoạt ảnh, không yêu cầu khung sau và dù sao thì khung được tạo sẽ không vẽ gì cả. Mặc dù không có gì trong cửa sổ hiển thị (macOS: bị chặn, một không gian khác, được thu nhỏ; Windows: được thu nhỏ hoặc bị ẩn), nhưng không có khung nào được yêu cầu đầu vào (liên kết hiển thị hoặc bộ hẹn giờ hoạt ảnh, yêu cầu từ bên ngoài, thay đổi kích thước), hãy đợi cho đến khi một số cửa sổ hiển thị, vì trình duyệt không vẽ gì cho các cửa sổ ngoài tầm nhìn; đầu vào vẫn tạo một cái, vì các phím được nhập vào một cửa sổ chính, các cửa sổ khác sẽ che.

<a id="instances"></a>

## Trường hợp

`ui/gpu.zig` là hợp đồng giữa sơn và mọi bộ kết xuất. Một khung là một mảng `gpu.Instance`, mỗi khung một phần tư:

```zig
pub const Instance = extern struct {
    rect: [4]f32,
    color: [4]f32,
    border_color: [4]f32 = .{ 0, 0, 0, 0 },
    uv: [4]f32 = .{ 0, 0, 0, 0 },
    clip: [4]f32 = .{ -1e6, -1e6, 1e6, 1e6 },
    radius: f32 = 0,
    border_width: f32 = 0,
    kind: f32 = 0,
    clip_round: f32 = 0,
};
```

`kind` (`gpu.Kind`) cho biết hình tứ giác là gì: `quad` (một hình chữ nhật tròn có đường viền), `text` (một hình tượng hoặc biểu tượng từ atlas hình tượng), `shadow` (một hình mờ Gaussian của một hộp tròn, như GPUI vẽ chúng), `image` (từ atlas hình ảnh), `effect` (dấu của hiệu ứng phông nền), `gradient`, `layer`/`layer_end` (một nhóm bị mờ hoặc mờ) và `trailer`. Các bit cao của `kind` mang hàng của phép biến đổi. `gpu.Frame.of(instances)` phân tách các phiên bản được rút ra từ các hàng dữ liệu được đóng gói sau chúng, mà phiên bản `trailer` cuối cùng trỏ đến. Trình kết xuất sẽ vẽ một khung trong một lệnh gọi vẽ tạm thời, chỉ phân tách khung ở các hiệu ứng và lớp.

`radius` phủ định yêu cầu các góc liên tục (`Style.corners`, `raster_corner.zig`, sau mygo: đường cong của Core Animation) và `clip_round` được tạo bởi `gpu.clipContinuous` (các bit của các góc cộng với 16) cho một clip. Mọi bộ kết xuất đều tính toán đường cong theo cùng một số học (các hàm `cont_*` của shader): chỉ trong hộp của một góc (`extent` lần bán kính từ góc), ở những nơi khác, khoảng cách đến cạnh gần nhất như đối với các góc vuông, cạnh của nó được làm mịn bởi độ dốc của giá trị bằng các chênh lệch cách nhau một phần mười sáu pixel và các hàng của bóng mờ bị thu hẹp ở nơi có đường cong, được tìm thấy bởi regula falsi. Trình kết xuất GPU cắt các bóng lớn có các góc liên tục thành chín miếng (`gpu_corners.zig`, sau 8b35d8e và 3e9f9c6 của mygo): các dải hàng ngang qua các góc khi chúng ở cuối và giống như cặp song sinh của chúng với các góc vuông ở giữa và dải giữa chúng là cặp đôi, tính toán các giá trị rất giống nhau mà không cần tìm kiếm; một dải chỉ bị cắt khi các pixel của cặp song sinh tiết kiệm được nhiều hơn chi phí của các mảnh (mỗi mảnh). Trình kết xuất CPU sẽ vẽ toàn bộ chúng; pixel của nó giống nhau.

<a id="the-renderers"></a>

## Trình kết xuất

| bộ kết xuất | tập tin và đổ bóng | ở đâu |
|---|---|---|
| Metal | `ui/metal.zig`, `shader.metal`, hiệu ứng trong `metal_fx.zig`/`metal_fx.metal` | macOS, vào `CAMetalLayer` máy chủ view native |
| Direct3D 11 | `ui/d3d11.zig`, `d3d11.hlsl` (được biên dịch trước thành `d3d11.cso`), `d3d11_fx.*` | Windows, thành một chuỗi hoán đổi tuần tự lật |
| OpenGL | `ui/gl.zig`, `gl.glsl`, `gl_fx.*`, được tải qua `gl_api.zig` (libepoxy) | Linux, trong GtkGLArea (`gl_gtk.zig`); OpenGL 3.3 lõi hoặc ES 3.0 |
| WebGL 2 | `ui/webgl.zig`, `webgl_shaders.zig` (`gl.glsl` dưới dạng GLSL ES 3.0) | trình duyệt; bối cảnh tồn tại trong `web/host_gl.js` |
| CPU | `ui/raster.zig`, `raster_lanes.zig`, `raster_fill.zig`, `raster_shadow.zig`, `raster_xf.zig`, `raster_fx.zig`, `raster_pool.zig` | ở mọi nơi: dự phòng, tắt Trình kiểm tra macOS, tham chiếu |

Mỗi bộ kết xuất GPU sử dụng một đường dẫn: nó tải lên các phiên bản của khung, các hàng atlas đã thay đổi kể từ lần cuối cùng nó thực hiện (`dirty`) và vẽ các phiên bản trong một lệnh gọi. Metal và Direct3D 11 chụp ảnh thẳng vào kết cấu của chúng mà không có bản sao atlas hình ảnh trong bộ nhớ. Các hiệu ứng và lớp làm mờ cần những gì đã được vẽ cho đến nay: tại dấu `effect` bộ kết xuất sẽ đọc các pixel xung quanh hình dạng, làm mờ chúng (`backdrop.zig`: tính trung bình xuống đối với các điểm làm mờ lớn, sau đó là Gaussian dọc theo hàng và cột) và vẽ hộp từ chúng, với shader của hiệu ứng hoặc nguyên trạng.

`d3d11.cso` là HLSL được biên dịch trước thời hạn với `zig run src/ui/d3d11_gen.zig` (trên Windows, sau khi thay đổi shader), do đó các cửa sổ sẽ mở mà không tải trình biên dịch shader; nó bắt đầu bằng hàm băm của nguồn và thay vào đó, một bộ kết xuất có hàm băm nhúng khác với nguồn của nó sẽ biên dịch nguồn khi bắt đầu.

<a id="drawing-only-what-changed"></a>

### Chỉ vẽ những gì đã thay đổi

Một frame ít thay đổi cửa sổ (dấu mũ nhấp nháy, vòng quay xoay, nút bên dưới con trỏ) chỉ vẽ các pixel có thể khác với frame cuối cùng, phần còn lại được giữ nguyên, sau `scene.Differ` (`ui/damage.zig`) của mygo. `Differ` so sánh các phiên bản của khung với phiên bản cuối cùng từ cả hai đầu; các phiên bản khác nhau sẽ làm hỏng các pixel mà chúng đã vẽ và vẽ hiện tại (`boundsOf`: giới hạn của bộ kết xuất CPU, thêm hai pixel cho các hình tứ giác của GPU, năm pixel dưới một biến đổi). Các phiên bản được so sánh với các hàng mà chúng đọc (một biến đổi, một gradient, một hiệu ứng) bất kể các hàng đó ở đâu; hình ảnh được tính là đã thay đổi khi atlas hình ảnh đã thay đổi; một khung có kích thước, tỷ lệ hoặc nền khác hoặc sau khi atlas hình tượng được làm trống (`Atlas.resets`), vẽ toàn bộ. Các hiệu ứng và lớp mờ đọc những gì bên dưới chúng: một vùng gặp một, nó phát triển nhờ tất cả các hiệu ứng đọc (`grow`, đến một điểm cố định), sao cho hiệu ứng không đọc gì ở khung cuối cùng và được vẽ một phần, khung chỉ vẽ các hiệu ứng và lớp trong vùng của nó (`Markers`). Quá nửa cửa sổ, nó được vẽ toàn bộ. Được vẽ từng phần, mỗi pixel là một pixel được vẽ mà toàn bộ frame mang lại, từng byte: `damage_test.zig` vẽ các frame ngẫu nhiên của mọi loại phiên bản thay đổi frame này đến frame khác theo cả hai cách, trên CPU và với mỗi bộ kết xuất GPU. `MYZIG_PARTIAL=0` vẽ toàn bộ frame.

| bộ kết xuất | mục tiêu giữ frame cuối cùng | vẽ một phần |
|---|---|---|
| CPU | pixel của cửa sổ | trong tối đa tám hình chữ nhật cách nhau (`raster.drawPart`), mỗi dải được gắn vào chúng |
| Direct3D 11 | chuỗi hoán đổi, lật *tuần tự*: khi một khung được hiển thị với khu vực mà nó vẽ dưới dạng hình chữ nhật bẩn (`Present1`), DXGI sẽ lấp đầy phần còn lại của bộ đệm từ khung được hiển thị trước đó | bị cắt xén, bị xóa bởi một hình tứ giác mờ đục cùng màu với khung (`damage.clearQuad`); một khung không có gì thay đổi không được trình bày |
| OpenGL | Bộ đệm khung của GtkGLArea, GTK giữ từ kết xuất này sang kết xuất khác nhưng tạo lại khi nó phân bổ khu vực (`Gpu.invalidate`) | bài kiểm tra cắt kéo mà `glClear` cũng tuân theo |
| WebGL 2 | khung vẽ, với `preserveDrawingBuffer` | bài kiểm tra cắt kéo, như OpenGL |
| Metal | các đối tượng có thể vẽ của lớp, mỗi đối tượng giữ khung được vẽ vào đó vài khung trước: `damage.Ages` giữ nguyên, theo kết cấu của đối tượng có thể vẽ (được giữ lại, để không ai khác lấy địa chỉ của nó), điều gì đã thay đổi kể từ đó | vượt qua tải có thể kéo, cắt, xóa theo hình tứ giác; một khung không có gì thay đổi, không thể vẽ được |

Trên cửa sổ 2560 × 1600 pixel (một trang gồm 108 thẻ, Intel Iris Xe), dấu mũ nhấp nháy sẽ khiến bộ kết xuất CPU mất 0,15 ms một frame thay vì 9,3, một spinner 0,34 thay vì 10,4; Direct3D khiến chúng hoàn thành trong 0,64 và 0,78 mili giây thay vì 5,6 và 6,0. Cảnh `caret` và `spinner` của chuyến leo đồi (900 × 640 ở tốc độ 2x) đo lường: trên CPU 0,07 và 0,19 mili giây thay vì 6,7 và 6,8, và với `--gpu` 0,02 và 0,03 mili giây thời gian GPU của Direct3D thay vì 2,2.

Việc chuyển các hiệu ứng và lớp mờ vẽ qua các kết cấu được giữ từ khung này sang khung khác theo kích thước của chúng (`Pool` trong `d3d11_fx.zig`, `gl_fx.zig`, `metal_fx.zig`), sau các lớp hiệu ứng của mygo: một hiệu ứng có hộp di chuyển đọc qua kết cấu của khung trước thay vì kết cấu mới (40 khung của hiệu ứng chuyển động và lớp tạo thành 13 kết cấu, không phải 240) và kết cấu không có khung mất 120 frame.

<a id="falling-back-to-the-cpu"></a>

### Quay trở lại CPU

Trình kết xuất GPU không thể khởi động sẽ không bao giờ ngăn cửa sổ hiển thị; thay vào đó, các khung tương tự được vẽ trên CPU:

- **Windows**: không có thiết bị Direct3D hoặc chuỗi trao đổi, GDI hiển thị các pixel của bộ kết xuất CPU (`windows/surface.zig`).
- **Linux**: không có OpenGL (không có libepoxy, không có ngữ cảnh GL hoặc bộ kết xuất bị lỗi), GtkdrawArea và cairo hiển thị chúng. `MYZIG_GPU=0` giữ các khung trên CPU; `MYZIG_GPU=1` sử dụng OpenGL ngay cả trên llvmpipe của Mesa, nếu không thì bị bỏ qua vì chậm hơn bộ kết xuất CPU của chính myzig.
- **Trình duyệt**: không có WebGL 2, canvas 2D sẽ hiển thị chúng.

<a id="the-cpu-renderer"></a>

### Trình kết xuất CPU

`raster.zig` rút ra các phiên bản `shader.metal` đưa vào bộ nhớ: BGRA, các giá trị được nhân trước, mã hóa sRGB được pha trộn khi GPU trộn chúng. Một khung được vẽ thành từng dải gồm 64 hàng, lần lượt được thực hiện bằng nhiều lõi khi khung lớn; mỗi pixel là những gì bản vẽ mà nó mang lại, vì vậy các dải có thể vẽ theo bất kỳ thứ tự nào. Các lõi là các luồng của `raster_pool.zig`, được bắt đầu khi một khung đầu tiên cần chúng và sau đó chờ đợi một futex giữa các khung, vì các luồng bắt đầu mà mỗi khung có giá tương đương với việc vẽ một khung nhỏ sẽ làm gì: một khung được chia sẻ từ khoảng 2¹⁸ pixel làm việc cho một lõi. Phần rõ ràng để lại các pixel mà phiên bản đầu tiên đặt để lấp đầy bất cứ thứ gì nằm bên dưới chúng, khi nó là một hình tứ giác mờ đục, không có gì cắt các góc, làm nền của cửa sổ (`Frame.clearRows`, `raster_fill.zig`), vì vậy chúng không được viết hai lần. Trong một phiên bản, những gì giống nhau dọc theo một hàng hoặc một cột được tính toán một lần, các phần tô đậm được sao chép, các đoạn văn bản trống bị bỏ qua và `raster_lanes.zig` tính toán tám pixel cùng một lúc, mỗi nhánh tối ưu sẽ đưa ra giá trị chính xác của giá trị chung.

<a id="the-cpu-twin"></a>

## CPU đôi

Trình kết xuất CPU là tham chiếu mà mọi bộ kết xuất GPU được sử dụng: mỗi shader được viết để tính toán, trên mỗi pixel, những gì `raster.zig` tính toán, theo cùng một số học (các giới hạn của phiên bản được làm tròn theo cùng một cách, độ dốc khoảng cách chính xác thay vì `fwidth`, họa tiết được lọc thủ công từ texels với trọng số chính xác hoàn toàn). Các kiểm thử hiển thị các khung giống nhau theo cả hai cách và so sánh chúng với một hoặc hai cấp độ làm tròn của pha trộn:

| kiểm tra | so sánh |
|---|---|
| `ui/tests_raster.zig` | bộ kết xuất CPU dựa trên Metal (macOS): widget, văn bản, biểu tượng, đường viền, góc tròn và kẹp, bóng, hình ảnh |
| `ui/d3d11_test.zig` | Direct3D 11 ngoài màn hình (kết cấu đọc lại) đối với CPU; bỏ qua mà không có GPU |
| `ui/gl_test.zig` | OpenGL 3.3 và ES 3.0 ngoài màn hình (EGL không có bề mặt, `gl_offscreen.zig`; llvmpipe của Mesa không cần GPU) so với CPU |
| `ui/gl_gtk_test.zig` | đường dẫn GtkGLArea |
| `ui/gpu_fx_test.zig` | mọi bộ kết xuất GPU đối với CPU trên đường dẫn chung: các biến đổi ngẫu nhiên thuộc mọi loại, độ dốc, hiệu ứng phông nền đơn giản và có shader, các lớp mờ, trong khung widget và khung ngẫu nhiên |
| `ui/shader/tests_gpu.zig` | shader `ui.shader` trên mỗi GPU so với bản đối chiếu CPU của chúng |
| `ui/damage_test.zig` | các khung được vẽ một phần dựa vào chúng được vẽ toàn bộ, từng byte: CPU, Direct3D 11 (kết cấu và chuỗi hoán đổi của cửa sổ ẩn), OpenGL 3.3 và ES 3.0 |

`ui.gpu_testing` xuất `gpu_fx_test.zig` để các plugin giữ các hiệu ứng riêng của chúng theo cùng một tiêu chuẩn (shader của plugin glass có bản đối chiếu CPU phải vẽ cùng các pixel).

Ứng dụng Shader ghi (`ui.shader`, các tệp như `examples/*/*.zsl`) tuân theo cùng một quy tắc: một ngôn ngữ nhỏ trong cú pháp của Zig (`ui/shader/parse.zig`) được biên dịch tại thời điểm biên dịch thành HLSL, GLSL (3.3, ES 3.0, WebGL 2), Metal và một bản đối chiếu CPU của mã Zig (`shader/cpu.zig`) mà bộ kết xuất CPU và Trình kiểm tra chạy. Xem [shader](ui/shaders.md).

Các ảnh canvas (`ui.canvas`) và SVG được phân loại trên CPU (`canvas_render.zig`, `path_raster.zig`: một trình raster tích lũy sau các phông chữ, với cả hai quy tắc điền) vào atlas hình ảnh mà mọi bộ kết xuất sẽ vẽ khi vẽ `ui.image`, vì vậy chúng trông giống nhau ở mọi nơi theo kết cấu.

<a id="text"></a>

## Văn bản

`ui/text.zig` chọn hệ thống văn bản tại thời điểm biên dịch:

- **CoreText** trên macOS (`text_mac.zig`, `atlas.zig`): phông chữ, tạo hình và rasterization glyph bởi hệ thống, thành kết cấu atlas R8. ASCII có thể in được có nhánh tối ưu chính xác (`shaper.zig`), được thử nghiệm dựa trên hình dạng của chính CoreText.
- **myzig's TrueType** ở mọi nơi khác và trên macOS với `-Dportable=true` (`text_tt.zig`, `ui/tt/`): `tt/fontdb.zig` tìm thấy các phông chữ đã cài đặt một lần (theo họ, độ đậm, độ nghiêng và chiều rộng, được tải trong lần sử dụng đầu tiên, với các họ dự phòng và sau đó là bất kỳ khuôn mặt nào dành cho các ký tự bị thiếu), `tt/font.zig` đọc các tệp phông chữ, `tt/raster.zig` biến đường viền thành vùng phủ sóng và `atlas_tt.zig` giữ các glyph trong hình ảnh byte trên mỗi texel trong bộ nhớ mà bộ kết xuất CPU lấy mẫu và bộ kết xuất GPU tải lên. Biểu tượng là các biểu tượng đường được vẽ bởi myzig (`icons.zig`) thay vì Biểu tượng SF. Trong các trình duyệt, phông chữ đi kèm với trang web ([trình duyệt](browsers.md)).

Cả hai đều cung cấp cùng một giao diện: phông chữ, bố cục được định hình và bao bọc được lưu trong bộ đệm trên các khung, dấu mũ và atlas glyph. Glyph được rasterized một lần cho mỗi phông chữ và một phần tư pixel ở vị trí nằm ngang, theo tỷ lệ của màn hình, được đóng gói trên kệ; một atlas sẽ phát triển khi đầy, sau đó đặt lại (và khung được sơn lại).

Hình ảnh (`ui.image`) được giải mã một lần (ImageIO trên macOS, `png_decode.zig` ở nơi khác), được chia tỷ lệ tối đa theo cạnh của atlas và được đóng gói thành một atlas BGRA (`images.zig`), được làm trống và đóng gói lại khi đầy.

<a id="surfaces"></a>

## Bề mặt

Một bề mặt kết nối một cửa sổ với giao diện native của nó: nó biến các sự kiện của nền tảng thành `ui.Input`, chạy các khung theo yêu cầu và hiển thị chúng.

| nền tảng | bề mặt | quà | nhịp độ frame với |
|---|---|---|---|
| macOS | `ui/surface.zig`: một NSView lưu trữ lớp Metal, NSTextInputClient (`textinput.zig`) | Metal | liên kết hiển thị của view, trong khi nội dung nào đó hoạt hình; bỏ qua trong khi cửa sổ bị chặn |
| Linux | `linux/surface.zig` | GtkGLArea (OpenGL), nếu không thì GtkdrawArea và cairo | Đồng hồ khung của GTK (gọi lại tích tắc) |
| Windows | `windows/surface.zig` | Direct3D Chuỗi hoán đổi 11, nếu không thì GDI | bộ đếm thời gian 60 Hz trong khi có thứ gì đó hoạt hình; `WM_FRAME` cho các yêu cầu từ bên ngoài; đối tượng độ trễ khung của chuỗi hoán đổi (`surface_present.zig`) |
| Trình duyệt | `web/surface.zig` | WebGL 2, nếu không thì là canvas 2D | `requestAnimationFrame`, được hỏi một lần cho mỗi frame |

Tất cả đều vẽ theo tỷ lệ của màn hình (Retina, dpi trên mỗi màn hình, tỷ lệ pixel của thiết bị) và cung cấp văn bản của phương thức nhập vào trường tập trung.

Trên Windows một frame chờ trước màn hình và `Present` không bao giờ chặn luồng chính cho frame đó, sau mygo: chuỗi hoán đổi có một đối tượng độ trễ frame (`FRAME_LATENCY_WAITABLE_OBJECT`, `SetMaximumFrameLatency(1)` trên `IDXGISwapChain2`), mà DXGI báo hiệu khi màn hình nhận một frame. Một khung xuất hiện sau khi quá trình chờ đợi thành công, mã thông báo của thời gian chờ; một khung được vẽ trong khi nó không được báo hiệu sẽ chờ (`pending`) khi một luồng chờ trên đối tượng và đăng `WM_PRESENT` khi nó xuất hiện. Trong khi đó, các khung của bộ hẹn giờ hoạt ảnh không được xây dựng; các khung để đưa đầu vào vào khung chờ (nó thể hiện dưới dạng sự kết hợp của các khu vực bẩn của chúng). Khung của thay đổi kích thước xuất hiện cùng một lúc. Mỗi món quà có một mã thông báo, vì vậy số lượng đối tượng vẫn bằng số frame mà màn hình có thể chụp.

Trên macOS luồng chính không bao giờ chặn trong `-[CAMetalLayer nextDrawable]`, sau mygo: lệnh gọi đó chờ trong khi tất cả các đối tượng có thể kéo của lớp đều đang được sử dụng, màn hình sẽ giữ nguyên cho đến lần làm mới tiếp theo, do đó, khung tiếp theo khung khác sẽ đợi hầu hết lần làm mới với đầu vào được xếp hàng đợi phía sau nó. Sau khi mỗi khung được hiển thị ngay khi được vẽ, hàng đợi gửi nối tiếp ở mức ưu tiên của luồng chính (tương tác với người dùng) sẽ tìm nạp khung có thể vẽ tiếp theo vào hộp thư một khe (`ui/metal_present.zig`) và đăng hoàn thành của nó lên hàng đợi chính. Một khung cho đầu vào xuất hiện trong khi đó được xây dựng ngay lập tức (đầu vào được xử lý, bố trí, sơn) và bản vẽ của nó đang chờ; khi đối tượng có thể vẽ xuất hiện, luồng chính sẽ vẽ các phiên bản của bề mặt như hiện tại (`wake`, `drawableCame` của bề mặt), một khung giống như khung cuối cùng không vẽ gì cả. Các dấu tích của liên kết hiển thị không tạo khung trong khi quá trình tìm nạp đang diễn ra (`Renderer.ready`): liên kết tiếp theo được tạo sau khi đối tượng có thể vẽ xuất hiện, trong khi đó liên kết đang tích tắc. Các luồng chia sẻ một điều: hàng đợi ghi nội dung có thể vẽ của hộp thư, sau đó đăng nội dung hoàn thành; luồng chính chỉ đọc nó khi hoàn thành hoặc sau `settle`, chờ hàng đợi (`dispatch_sync_f`), cả hai đều yêu cầu ghi trước khi đọc. Mọi thứ khác (trong chuyến bay, mong muốn, số lần hoàn thành) là của luồng chính. Trước khi lớp thay đổi (kích thước của các đối tượng có thể vẽ, định dạng của chúng, trình bày cùng với giao dịch, bộ kết xuất được giải phóng), luồng chính giải quyết việc tìm nạp và cho phép đối tượng có thể vẽ đi; một khung được trình bày cùng với giao dịch (khung thay đổi kích thước trực tiếp) sẽ có khung riêng trên luồng chính, giống như khung đầu tiên. Người trình bày được giải phóng với các phần hoàn thành được đăng sẽ tự giải phóng khi người trình bày cuối cùng chạy, do đó không có người nào đạt được bộ nhớ đã giải phóng; lần tìm nạp hoàn thành sau `settle` được tính là cũ và không kết thúc ở lần tìm nạp tiếp theo. Giao thức được thử nghiệm với lớp và hàng đợi giả (`ui/metal_present_test.zig`).

Độ trễ đầu vào, từ khi sự kiện đến đến khung hiển thị sự kiện đó trên màn hình, được đo bằng `tools/inputlatency` (README của nó), sau mygo: nhập, cuộn, kéo và hoạt ảnh trong cửa sổ mà nó hiển thị, chia thành chờ luồng chính, xử lý, đến hiện tại và tiếp cận màn hình, với thời gian chờ của luồng chính đối với các đối tượng có thể vẽ và phần làm mới hiển thị frame mới. Nó tổng hợp đầu vào vào cửa sổ riêng của nó, để một người chạy nó; đại lý xây dựng và kiểm thử nó.

Khả năng truy cập là một cây riêng biệt được xây dựng từ khung (`ui/access_tree.zig`) và được phân phát trên mỗi nền tảng: NSAccessibility (`access_mac.zig`), AT-SPI trên D-Bus (`linux/atspi*.zig`), Tự động hóa giao diện người dùng (`windows/uia*.zig`). Xem [khả năng truy cập](ui/accessibility.md).
