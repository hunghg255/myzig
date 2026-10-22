<a id="testing-binary-size-and-adding-a-feature"></a>

# Kiểm tra, kích thước nhị phân và thêm tính năng

Cách kiểm tra myzig mà không bao giờ hiển thị cửa sổ hoặc điều khiển màn hình, cách thu nhỏ ứng dụng và danh sách kiểm tra để thêm tính năng. Quay lại [tổng quan](architecture.md); để kiểm tra view riêng của ứng dụng, hãy xem [thử nghiệm giao diện native](ui/testing.md).

<a id="the-rules"></a>

## Các quy tắc

- **Không bao giờ hiển thị cửa sổ trên màn hình của nhà phát triển**, không bao giờ lấy nét, không bao giờ tổng hợp các sự kiện chuột hoặc bàn phím, không bao giờ chụp màn hình. Giao diện native được thử nghiệm với `ui.Tester` (đang xử lý, được hiển thị ngoài màn hình), các ứng dụng có `--myzig-snapshot` và `--myzig-script`, các trang có `--myzig-eval` hoặc `--myzig-hidden`: tất cả đều ẩn cửa sổ.
- **Các kiểm thử không bao giờ chạm đến trạng thái của người dùng**: không có khay nhớ tạm hệ thống (Người kiểm thử có khay nhớ tạm riêng), không có tệp nào bên ngoài thư mục tạm thời, không có giá trị mặc định hoặc khóa đăng ký của người dùng.
- **Các bài kiểm tra không bao giờ phụ thuộc vào thời gian trên đồng hồ treo tường.** Nâng cao đồng hồ của Người kiểm tra (`t.advance(seconds)`, `t.settle(max)`) và chờ các điều kiện chứ không phải thời lượng. Chỉ `live:` bước và `myzig.runFor` chạy vòng lặp sự kiện thực, để trả lời và xử lý, không bao giờ vượt qua xác nhận.

## ui.Tester

`ui.Tester` (`src/ui/tester.zig`) chạy `ui.View` không có cửa sổ, thông qua cùng `frame.run` cách sử dụng cửa sổ và hiển thị nó ngoài màn hình: với Metal trên macOS, với bộ kết xuất CPU ở nơi khác và với `-Dportable=true`.

```zig
var t: ui.Tester = undefined;
try t.init(std.testing.allocator, .init(&state, Counter.view), .{ .width = 480, .height = 360 });
defer t.deinit();
try t.clickText("Increment");
try std.testing.expect(t.hasText("1"));
t.advance(0.3); // animations move by simulated time
try t.screenshot("/tmp/counter.png");
```

Nó cung cấp đầu vào con trỏ (`moveTo`, `click`, `doubleClick`, `rightClick`, `middleClick`, `drag`, `scroll`, `wheel`, `clickText`), các phím (`key`, `keyEdge`, `shortcut`, `typeText`, `textOps`), thời gian (`frame`, `advance`, `settle`, với `dt` giây một khung), `resize`, truy vấn (`findText`, `hasText`, `containsText`) và pixel (`render`, `rasterize`, `screenshot`, `pixelSize`). `clipboard` của nó là một bộ đệm riêng. `runScript` chạy các bước mà cờ `--myzig-script` thực hiện: `click:TEXT`, `rclick:TEXT`, `move:TEXT`, `visible:TEXT` (không thành công trừ khi văn bản hiển thị toàn bộ trong cửa sổ), `type:TEXT`, `key:enter|backspace|tab|escape|left|right`, `shortcut:ctrl+shift+p` (tổ hợp phím, tới bộ tăng tốc của thanh menu và view dưới dạng một cửa sổ cung cấp nó), `scroll:DY`, `wheel:DY` (vết khía, lướt), `drag:FROM>TO`, `wait:SECONDS` (mô phỏng), `frames:N`, `live:SECONDS` (vòng lặp thực) và `resize:WxH`.

Mọi hành vi của widget đều được kiểm tra thông qua Trình kiểm tra trong `src/ui/tests*.zig` (`tests_overlays_menu.zig`, `tests_controls_date.zig`, `tests_richtext.zig`, ...), được đăng ký trong khối kiểm tra của `ui.zig`.

<a id="headless-flags"></a>

## Headless cờ

`src/dev.zig` đọc các cờ mà mọi ứng dụng chấp nhận để thử và kiểm tra ứng dụng đó mà không cần chạm vào màn hình:

| cờ | làm |
|---|---|
| `--myzig-generate=DIR` | ghi client đã tạo (`myzig.js`, `myzig.d.ts`) và thoát |
| `--myzig-snapshot=PNG` | hiển thị cửa sổ giao diện native đầu tiên ngoài màn hình thành PNG và thoát |
| `--myzig-script=STEPS` | với `--myzig-snapshot`: trước tiên hãy chạy các bước Kiểm tra này |
| `--myzig-dark` | với `--myzig-snapshot`: bề ngoài tối tăm |
| `--myzig-wait=SECONDS` | với `--myzig-snapshot`: chạy vòng lặp sự kiện dài như vậy trước tiên |
| `--myzig-hidden` | không bao giờ hiển thị cửa sổ; thư mục của app là thư mục tạm (headless) |
| `--myzig-eval=JS` | đánh giá JS trong mỗi trang khi DOM của nó đã sẵn sàng (ngụ ý bị ẩn) |

Một trang trong `--myzig-eval` báo cáo với `myzig.log(...)` (được in dưới dạng `page: ...` trên stderr) và kết thúc ứng dụng bằng `myzig.window.close()`. `MYZIG_DEBUG=1` giúp các ứng dụng ghi nhật ký cửa sổ và khung của chúng cho các công cụ.

```sh
zig-out/bin/gallery --myzig-snapshot=/tmp/g.png --myzig-script="click:Tasks;type:Hi;key:enter"
zig-out/bin/hello --myzig-eval='myzig.call("Greeter.greet","Ada").then(v=>{myzig.log(v);myzig.window.close()})'
```

<a id="the-build-s-test-steps"></a>

## Các bước kiểm tra của bản dựng

| lệnh | chạy |
|---|---|
| `zig build test` | unit/widget test của `src/myzig.zig`, test plugin loading và các test qua Tester của `blackhole`, `chat-glow`, `wind`, `effort-slider`, `mayoi`, `loading` |
| `zig build test-loading` | plugin và gallery loading: đủ 29 mẫu, thời lượng, đồng hồ độc lập, rebuild, tạm dừng/tiếp tục và giảm chuyển động, vẽ offscreen |
| `zig build test -Dportable=true` | tương tự với bộ kết xuất CPU và văn bản TrueType của myzig (đường dẫn Linux và Windows, trên máy Mac) |
| `zig build test-pages` | các trang ẩn trong view web thực: trang xin chào gọi Zig (cuộc gọi, lỗi, dịch vụ không xác định, sự kiện, client được tạo) và `examples/pages` (sơ đồ, kênh, sự kiện, quyền, tải xuống, eval, tìm, PDF, cookie, tin cậy), mỗi trang đều mong đợi `page: ok` trên thiết bị lỗi chuẩn |
| `zig build test-web` | counter, gallery và gestures dưới Node: frame, trạng thái idle, nhấp chuột, pinch và pan ngang/dọc |
| `zig build test-web -Dweb-browser="PATH"` | các test Node cùng sự kiện wheel/pinch DOM thật trong Chrome hoặc Edge headless: chế độ delta và việc chặn mặc định |
| `zig build test-bin` | cài đặt các bài kiểm tra đơn vị dưới dạng `zig-out/bin/myzig-tests` (`.exe` trên Windows), để chạy trên máy khác |
| `zig build lines` | mỗi tập tin tối đa 600 dòng |
| `cd cli && zig build test` | kiểm tra đơn vị của CLI: cấu hình, gói, kho lưu trữ, tài nguyên |
| `cd cli && zig build e2e` | `myzig init` tạo các ứng dụng `zig build` biên dịch theo quá trình bản checkout này |
| `cd plugins/<name> && zig build test` | kiểm tra plugin |

Khối kiểm tra của `myzig.zig` cũng phân tích mọi khai báo của mọi mô-đun phụ trợ và mọi phương thức trang (`std.testing.refAllDecls`), do đó, không có lệnh gọi ví dụ nào vẫn phải biên dịch trên nền tảng mà các kiểm thử chạy trên đó.

<a id="renderers-against-the-cpu"></a>

### Trình kết xuất chống lại CPU

Mọi bộ kết xuất GPU đều được kiểm tra dựa trên bộ kết xuất CPU, ngoài màn hình và bỏ qua nơi thiếu API của nó: `tests_raster.zig` (Metal), `d3d11_test.zig`, `gl_test.zig` (EGL không có bề mặt; llvmpipe của Mesa không cần GPU), `gpu_fx_test.zig` (biến đổi, chuyển màu, hiệu ứng, lớp) và `shader/tests_gpu.zig` (shader ứng dụng và cặp song sinh CPU của chúng). Xem [bản đối chiếu CPU](architecture-rendering.md#the-cpu-twin).

<a id="browsers"></a>

### Trình duyệt

Ngoài `test-web`, `src/web/test_wasm.mjs` còn chạy các bài kiểm tra đơn vị được biên dịch cho `wasm32-wasi` trong Nút (`zig test -target wasm32-wasi --test-no-exec`, sau đó là `node src/web/test_wasm.mjs tests.wasm FONT_DIR`) và `src/web/test_browser_run.mjs` chạy một trang web được xây dựng trong headless Crom (Chrome hoặc Edge) ẩn với WebGL. Xem [trình duyệt](browsers.md).

<a id="other-platforms-from-one-machine"></a>

## Các nền tảng khác từ một máy

Linux và Windows được xây dựng từ bất kỳ máy nào, vì vậy các bài kiểm tra chúng sẽ chạy trong vùng chứa:

- **Linux**: `tools/linux.Dockerfile` là Ubuntu 24.04 với GTK 3, WebKitGTK 4.1, Mesa (EGL, GLES, llvmpipe), libepoxy, phông chữ và Xvfb. Xây dựng trên máy chủ, gắn kết nó, chạy dưới màn hình ảo:

  ```sh
  zig build test-bin -Dtarget=aarch64-linux-gnu --prefix zig-out/linux
  docker build -t myzig-linux -f tools/linux.Dockerfile tools
  docker run --rm -v "$PWD:/work" myzig-linux xvfb-run -a zig-out/linux/bin/myzig-tests
  ```

  Windows có những cái đã được nhận ra nhưng chưa bao giờ được hiển thị (`linux/window_tests.zig`: câu hỏi kết thúc trước, tiêu đề, khung, tờ rơi); `atspi_bus_test.zig` sử dụng xe buýt tiếp cận thực sự khi có; `MYZIG_XVFB=1` cho phép di chuyển khứ hồi vào bảng nhớ tạm thông qua màn hình ảo.
- **Windows**: trên chính Windows, `zig build test`. Windows được tạo nhưng không bao giờ được hiển thị và các thông báo mà hành động của người dùng mang lại sẽ được gửi đến các thủ tục cửa sổ của họ (`windows/window_tests.zig`); Tự động hóa giao diện người dùng đang được kiểm thử trong quá trình (`uia_test.zig`). Từ máy Mac, `tools/wine.Dockerfile` chạy bản dựng arm64 (`-Dtarget=aarch64-windows-gnu`) trong Wine 10 trên Xvfb và `tools/wine-amd64.Dockerfile` x86_64 bản dựng trong mô phỏng.

<a id="benchmarks-the-hill-climb"></a>

## Điểm chuẩn: leo đồi

Hiệu suất công việc được đo bằng `hillclimb/`, một ứng dụng đầu cuối được xây dựng trên myzig dưới dạng thư viện (gói riêng của nó) xây dựng, bố trí và vẽ các cảnh hết khung này đến khung khác và hiển thị chúng ngoài màn hình, dựa trên các khung của chính mygo của cùng một cảnh, không có cửa sổ:

```sh
cd hillclimb
zig build run -- --label "what changed"         # every scene; recorded in history.jsonl
zig build run -- --scene text,list --only myzig --frames 600 --repeat 5
zig build run -- --only myzig --hash            # hashes of the CPU renderer's pixels
```

Cảnh: hộp, văn bản, cuộn, danh sách, trang tổng quan, bố cục (thẻ bao bọc văn bản chủ yếu như cũ: bố cục nào giữ trên các khung) và các cảnh khác trong `hillclimb/README.md`. Nó báo cáo CPU khung (xây dựng, bố cục, vẽ), mã hóa CPU, thời gian GPU trên macOS (Metal) hoặc kết xuất CPU trên Linux và Windows, xử lý CPU trên mỗi frame và vẽ các mục, dựa trên mygo, lần chạy trước đó và lần chạy tốt nhất; những thay đổi trong vòng 5% là tiếng ồn. Một thay đổi giúp bộ kết xuất CPU nhanh hơn phải giữ nguyên `--hash`. Giữ các thay đổi tăng dần, chạy nhãn và không bao giờ đánh đổi tính chính xác để lấy tốc độ: nhánh tối ưu đi kèm với bài kiểm tra chứng minh rằng nó phù hợp với đường dẫn chậm (như `shaper.zig` và `raster_lanes.zig` đã làm). Kết quả của các máy cụ thể được lưu giữ trong `hillclimb/notes/`.

<a id="binary-size"></a>

## Kích thước nhị phân

Bộ đếm có dung lượng khoảng 0,7 MB trong `ReleaseSmall` (1,14 MB `ReleaseFast` trên Windows); `myzig build` xây dựng bản phát hành `ReleaseSmall` và bị loại bỏ theo mặc định. Điều gì giữ cho ứng dụng nhỏ gọn:

- **Trình liên kết loại bỏ những gì không được gọi.** `myzig.App` và `Window` là các loại cụ thể, các dịch vụ và sự kiện ràng buộc được gửi đi bằng mã được tạo cho mỗi loại và các widget là các hàm đơn giản: ứng dụng trả tiền cho các phương thức và widget mà nó tiếp cận. Giữ các tính năng đằng sau các cuộc gọi sử dụng chúng; không đăng ký chúng từ mã mỗi khi ứng dụng chạy (`App.create`, `run`, các menu mặc định).
- **Thư viện được tải, không được liên kết.** WebKitGTK, libepoxy, libsecret, appindicator, Bảo mật và Thông báo người dùng được mở trong lần sử dụng đầu tiên, do đó, một ứng dụng không có trang hoặc bí mật sẽ không mang dữ liệu đường dẫn mã của chúng.
- **Công cụ gỡ lỗi là các tùy chọn xây dựng.** Trình kiểm tra giao diện native biên dịch thành không có gì trừ khi `-Dinspector=true` (bật theo mặc định trong Gỡ lỗi).
- **Dữ liệu nằm ngoài các đường dẫn chung.** Các bảng lớn (dữ liệu ngôn ngữ trong `i18n/data_*.zig`, ngữ pháp của trình soạn thảo mã, chủ đề terminal) nằm trong các mô-đun cần chúng.

Đo lường trước và sau một thay đổi liên quan đến mục tiêu mà mọi ứng dụng đều đạt được:

```sh
zig build -Doptimize=ReleaseSmall
ls -l zig-out/bin/counter zig-out/bin/hello
```

<a id="adding-a-feature"></a>

## Thêm một tính năng

1. **Trước tiên hãy thiết kế nó trong lớp chia sẻ**: các tùy chọn và loại trong `app_types.zig`, `window_types.zig`, `page_types.zig` hoặc một tệp mới; hành vi không cần hệ điều hành trong mã không có nền tảng. Phản chiếu thiết kế của mygo nơi nó có tính năng, theo thành ngữ Zig.
2. **Triển khai nó trong mọi backend**: macOS (đầu `src/`, `*_mac.zig`), `src/linux/`, `src/windows/` và `src/web/` để biết những gì trình duyệt có thể thực hiện. Một nền tảng không có nó sẽ nhận được cùng một tuyên bố không làm gì hoặc trả về `null`/`false`, vì vậy các ứng dụng sẽ biên dịch ở mọi nơi.
3. **Xuất nó** từ `src/myzig.zig` hoặc `src/ui/ui.zig`.
4. **Tránh xa các ứng dụng không sử dụng nó** (ở trên).
5. **Kiểm tra**: các widget thông qua `ui.Tester` trong `src/ui/tests_*.zig`; Ánh xạ loại IPC trong `tsgen.zig`; các trang trong `examples/pages` (được điều hành bởi `test-pages`); cửa sổ trong phần phụ trợ' `window_tests.zig`; bộ kết xuất chống lại CPU. Đăng ký tệp kiểm tra trong khối kiểm tra của `ui.zig` hoặc `myzig.zig`.
6. **Xây dựng mọi nền tảng**: `zig build`, `zig build -Dtarget=x86_64-linux-gnu`, `zig build -Dtarget=x86_64-windows-gnu`, `zig build web`; chạy `zig build test` (và `-Dportable=true`), kiểm thử Linux trong vùng chứa, `zig build lines`.
7. **Không có C**: khai báo `extern`, `dlopen`/`dlsym`, COM vtables; không có tệp `@cImport`, `.c` hoặc `.m`.
8. **Ghi lại tài liệu** trong `docs/` và thêm nó vào ví dụ khi nó hiển thị.
9. **Leo lên dốc** nếu chạm vào khung: chạy `hillclimb` trước và sau.
