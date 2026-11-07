<a id="testing-binary-size-and-adding-a-feature"></a>

# Test, kích thước binary và thêm tính năng

Cách myzig được test mà không bao giờ hiện cửa sổ hay điều khiển màn hình, cách giữ app nhỏ gọn, và danh sách việc cần làm khi thêm một tính năng. Quay lại [phần tổng quan](architecture.md). Để test view của chính app, xem [test native UI](ui/testing.md).

<a id="the-rules"></a>

## Các quy tắc

- **Không bao giờ hiện cửa sổ trên màn hình của lập trình viên.** Không lấy focus, không giả lập event chuột hay bàn phím, không chụp màn hình.
- Native UI được test bằng `ui.Tester` (trong tiến trình, render offscreen). App được test bằng `--myzig-snapshot` và `--myzig-script`, page bằng `--myzig-eval` hoặc `--myzig-hidden`. Tất cả đều giữ cửa sổ ẩn.
- **Test không bao giờ chạm vào dữ liệu của người dùng**: không dùng clipboard của hệ thống (`ui.Tester` có clipboard riêng), không đụng file ngoài thư mục tạm, không đụng defaults hay registry key của người dùng.
- **Test không bao giờ phụ thuộc vào giờ thật.** Hãy cho đồng hồ của `ui.Tester` chạy tới (`t.advance(seconds)`, `t.settle(max)`), và chờ điều kiện chứ không chờ một khoảng thời gian.
- Chỉ các bước `live:` và `myzig.runFor` chạy event loop thật. Chúng dành cho reply và tiến trình, không bao giờ để làm một assertion qua được.

<a id="ui-tester"></a>

## ui.Tester

`ui.Tester` (`src/ui/tester.zig`) chạy một `ui.View` không cần cửa sổ, qua chính `frame.run` mà cửa sổ dùng. Nó render offscreen: bằng Metal trên macOS, bằng CPU renderer ở nơi khác và khi có `-Dportable=true`.

```zig
var t: ui.Tester = undefined;
try t.init(std.testing.allocator, .init(&state, Counter.view), .{ .width = 480, .height = 360 });
defer t.deinit();
try t.clickText("Increment");
try std.testing.expect(t.hasText("1"));
t.advance(0.3); // animation chạy theo thời gian giả lập
try t.screenshot("/tmp/counter.png");
```

| nó cung cấp | method |
|---|---|
| input con trỏ | `moveTo`, `click`, `doubleClick`, `rightClick`, `middleClick`, `drag`, `scroll`, `wheel`, `clickText` |
| phím | `key`, `keyEdge`, `shortcut`, `typeText`, `textOps` |
| thời gian, `dt` giây mỗi frame | `frame`, `advance`, `settle` |
| kích thước | `resize` |
| truy vấn | `findText`, `hasText`, `containsText` |
| pixel | `render`, `rasterize`, `screenshot`, `pixelSize` |

`clipboard` của nó là một buffer riêng. `runScript` chạy các bước mà flag `--myzig-script` nhận:

| bước | việc nó làm |
|---|---|
| `click:TEXT`, `rclick:TEXT`, `move:TEXT` | |
| `visible:TEXT` | thất bại nếu chữ không hiện trọn trong cửa sổ |
| `type:TEXT` | |
| `key:enter\|backspace\|tab\|escape\|left\|right` | |
| `shortcut:ctrl+shift+p` | một tổ hợp phím, gửi tới phím tắt của thanh menu và tới view, như cửa sổ gửi |
| `scroll:DY` | |
| `wheel:DY` | theo nấc, có trượt quán tính |
| `drag:FROM>TO` | |
| `wait:SECONDS` | thời gian giả lập |
| `frames:N` | |
| `live:SECONDS` | event loop thật |
| `resize:WxH` | |

Mỗi hành vi của widget đều có test qua `ui.Tester` trong `src/ui/tests*.zig` (`tests_overlays_menu.zig`, `tests_controls_date.zig`, `tests_richtext.zig`, ...), được đăng ký trong khối test của `ui.zig`.

<a id="headless-flags"></a>

## Flag headless

`src/dev.zig` đọc các flag mà app nào cũng nhận, để thử và test app mà không chạm tới màn hình:

| flag | việc nó làm |
|---|---|
| `--myzig-generate=DIR` | ghi client đã sinh (`myzig.js`, `myzig.d.ts`) rồi thoát |
| `--myzig-snapshot=PNG` | render offscreen cửa sổ native UI đầu tiên ra PNG rồi thoát |
| `--myzig-script=STEPS` | đi cùng `--myzig-snapshot`: chạy các bước Tester này trước |
| `--myzig-dark` | đi cùng `--myzig-snapshot`: giao diện tối |
| `--myzig-wait=SECONDS` | đi cùng `--myzig-snapshot`: chạy event loop trong khoảng đó trước |
| `--myzig-hidden` | không bao giờ hiện cửa sổ; các thư mục của app là thư mục tạm (headless) |
| `--myzig-eval=JS` | chạy JS trong mỗi page khi DOM của nó sẵn sàng (kéo theo hidden) |

- Page chạy dưới `--myzig-eval` báo kết quả bằng `myzig.log(...)`, in ra stderr dạng `page: ...`.
- Nó kết thúc app bằng `myzig.window.close()`.
- `MYZIG_DEBUG=1` làm app ghi log cửa sổ và frame của nó cho các công cụ.

```sh
zig-out/bin/gallery --myzig-snapshot=/tmp/g.png --myzig-script="click:Tasks;type:Hi;key:enter"
zig-out/bin/hello --myzig-eval='myzig.call("Greeter.greet","Ada").then(v=>{myzig.log(v);myzig.window.close()})'
```

<a id="the-build-s-test-steps"></a>

## Các bước test của build

| lệnh | chạy gì |
|---|---|
| `zig build test` | unit test và test widget của `src/myzig.zig`, test của plugin loading, và test qua Tester của `blackhole`, `chat-glow`, `wind`, `effort-slider`, `mayoi` và `loading` |
| `zig build test-loading` | plugin loading và gallery của nó: cả 29 mẫu, `duration`, đồng hồ độc lập, dựng lại, tạm dừng/chạy tiếp và giảm chuyển động, render offscreen |
| `zig build test -Dportable=true` | như trên, với chữ TrueType và CPU renderer của myzig (đường đi của Linux và Windows, chạy trên Mac) |
| `zig build test-pages` | page ẩn trong webview thật: page của hello gọi Zig (lời gọi, lỗi, service không tồn tại, một event, client đã sinh), và `examples/pages` (scheme, channel, event, quyền, tải xuống, eval, tìm kiếm, PDF, cookie, độ tin cậy), mỗi cái chờ `page: ok` trên stderr |
| `zig build test-web` | counter, gallery và cử chỉ dưới Node: frame, hành vi khi rảnh, bấm, pinch và pan ngang/dọc |
| `zig build test-web -Dweb-browser="PATH"` | test Node cộng với event wheel/pinch thật của DOM trong Chrome hoặc Edge headless: các delta mode và việc hủy event |
| `zig build test-bin` | cài unit test thành `zig-out/bin/myzig-tests` (`.exe` trên Windows), để chạy trên máy khác |
| `zig build lines` | mọi file tối đa 600 dòng |
| `cd cli && zig build test` | unit test của CLI: cấu hình, bundle, file nén, resource |
| `cd cli && zig build e2e` | `myzig init` tạo ra app mà `zig build` compile được với bản checkout này |
| `cd plugins/<name> && zig build test` | test của một plugin |

Khối test của `myzig.zig` còn phân tích mọi khai báo của mọi module backend và mọi method của page (`std.testing.refAllDecls`). Vì vậy code mà không ví dụ nào gọi vẫn phải compile được trên nền tảng chạy test.

<a id="renderers-against-the-cpu"></a>

### So renderer với CPU

Mỗi GPU renderer được test so với CPU renderer, offscreen. Mỗi test tự bỏ qua khi thiếu API của nó:

- `tests_raster.zig` (Metal);
- `d3d11_test.zig`;
- `gl_test.zig` (EGL surfaceless; llvmpipe của Mesa không cần GPU);
- `gpu_fx_test.zig` (biến đổi, gradient, hiệu ứng, layer);
- `shader/tests_gpu.zig` (shader của app và bản song sinh CPU của chúng).

Xem [bản song sinh CPU](architecture-rendering.md#the-cpu-twin).

<a id="browsers"></a>

### Trình duyệt

Ngoài `test-web`:

- `src/web/test_wasm.mjs` chạy unit test compile cho `wasm32-wasi` dưới Node: `zig test -target wasm32-wasi --test-no-exec`, rồi `node src/web/test_wasm.mjs tests.wasm FONT_DIR`.
- `src/web/test_browser_run.mjs` chạy một site đã build trong Chromium headless ẩn (Chrome hoặc Edge) có WebGL.

Xem [trình duyệt](browsers.md).

<a id="other-platforms-from-one-machine"></a>

## Các nền tảng khác từ một máy

Linux và Windows build được từ máy nào cũng được, nên test cho chúng chạy trong container:

- **Linux**: `tools/linux.Dockerfile` là Ubuntu 24.04 có GTK 3, WebKitGTK 4.1, Mesa (EGL, GLES, llvmpipe), libepoxy, font và Xvfb. Build trên máy chính, mount vào, chạy dưới một màn hình ảo:

  ```sh
  zig build test-bin -Dtarget=aarch64-linux-gnu --prefix zig-out/linux
  docker build -t myzig-linux -f tools/linux.Dockerfile tools
  docker run --rm -v "$PWD:/work" myzig-linux xvfb-run -a zig-out/linux/bin/myzig-tests
  ```

  - Cửa sổ ở đó được tạo ra thật nhưng không bao giờ hiện (`linux/window_tests.zig`: đóng thì hỏi trước, tiêu đề, frame, flyout).
  - `atspi_bus_test.zig` dùng accessibility bus thật khi có.
  - `MYZIG_XVFB=1` bật các test copy/paste khứ hồi qua màn hình ảo.
- **Windows**: trên chính Windows, `zig build test`.
  - Cửa sổ được tạo nhưng không bao giờ hiện. Các message mà thao tác của người dùng sinh ra được gửi tới window procedure của chúng (`windows/window_tests.zig`).
  - UI Automation được test trong tiến trình (`uia_test.zig`).
  - Từ một máy Mac, `tools/wine.Dockerfile` chạy bản build arm64 (`-Dtarget=aarch64-windows-gnu`) dưới Wine 10 trên Xvfb. `tools/wine-amd64.Dockerfile` chạy bản build x86_64 qua giả lập.

<a id="benchmarks-the-hill-climb"></a>

## Benchmark: hill climb

Việc tối ưu hiệu năng được đo bằng `hillclimb/`, một app terminal dùng myzig như một thư viện (package riêng). Nó dựng, tính layout và paint các cảnh hết frame này tới frame khác, render offscreen, không cần cửa sổ. Nó so sánh chúng với các frame của chính mygo cho cùng các cảnh đó.

```sh
cd hillclimb
zig build run -- --label "what changed"         # mọi cảnh; ghi vào history.jsonl
zig build run -- --scene text,list --only myzig --frames 600 --repeat 5
zig build run -- --only myzig --hash            # hash các pixel của CPU renderer
```

**Các cảnh**: boxes, text, scroll, list, dashboard, layout (các thẻ chữ ngắt dòng gần như giữ nguyên: đo những gì layout giữ lại qua các frame), và các cảnh khác trong `hillclimb/README.md`.

**Nó báo về**, so với mygo, lần chạy trước và lần tốt nhất:

- CPU cho frame (dựng, layout, paint) và CPU cho encode;
- thời gian GPU trên macOS (Metal), hoặc CPU cho render trên Linux và Windows;
- CPU của tiến trình mỗi frame, và số item được vẽ.

Thay đổi trong vòng 5% là nhiễu.

**Quy tắc:**

- Một thay đổi làm CPU renderer nhanh hơn phải giữ nguyên output của `--hash`.
- Giữ những thay đổi giúp leo lên, và đặt nhãn cho các lần chạy.
- Không bao giờ đổi tính đúng lấy tốc độ. Một đường tắt nhanh phải đi kèm test chứng minh nó khớp với đường chậm (như `shaper.zig` và `raster_lanes.zig`).
- Kết quả của từng máy cụ thể được giữ trong `hillclimb/notes/`.

<a id="binary-size"></a>

## Kích thước binary

Counter khoảng 0.7 MB ở `ReleaseSmall` (1.14 MB `ReleaseFast` trên Windows). `myzig build` mặc định build bản release `ReleaseSmall` và đã strip. Những gì giữ app nhỏ:

- **Linker bỏ những gì không được gọi.** `myzig.App` và `Window` là kiểu cụ thể. Service đã bind và event được điều phối bằng code sinh riêng cho từng kiểu. Widget là hàm bình thường. Vì vậy app chỉ trả giá cho các method và widget mà nó dùng tới.
- Giữ tính năng phía sau các lời gọi dùng nó. Đừng đăng ký chúng từ code mà app nào cũng chạy (`App.create`, `run`, các menu mặc định).
- **Thư viện được nạp, không link.** WebKitGTK, libepoxy, libsecret, appindicator, Security và UserNotifications được mở ở lần dùng đầu. App không có page hay secret thì không mang dữ liệu nào của các đường code đó.
- **Công cụ debug là tùy chọn build.** Inspector của native UI không compile ra gì trừ khi có `-Dinspector=true` (mặc định bật ở Debug).
- **Dữ liệu nằm ngoài các đường code chung.** Các bảng lớn (dữ liệu locale trong `i18n/data_*.zig`, grammar của code editor, theme của terminal) nằm trong module cần chúng.

Đo trước và sau một thay đổi chạm vào những gì app nào cũng dùng tới:

```sh
zig build size -Doptimize=ReleaseSmall -j1
ls -l zig-out/bin/counter zig-out/bin/hello
```

<a id="adding-a-feature"></a>

## Thêm một tính năng

1. **Thiết kế ở lớp dùng chung trước.** Tùy chọn và kiểu nằm trong `app_types.zig`, `window_types.zig`, `page_types.zig` hoặc một file mới. Hành vi không cần tới hệ điều hành nằm trong code không phụ thuộc nền tảng. Theo thiết kế của mygo khi mygo có tính năng đó, viết bằng Zig đúng kiểu.
2. **Cài đặt ở mọi backend**: macOS (phần trên cùng của `src/`, `*_mac.zig`), `src/linux/`, `src/windows/`, và `src/web/` cho những gì trình duyệt làm được. Nền tảng không hỗ trợ thì có cùng khai báo nhưng không làm gì, hoặc trả về `null`/`false`, để app compile được ở mọi nơi.
3. **Export** nó từ `src/myzig.zig` hoặc `src/ui/ui.zig`.
4. **Giữ nó ngoài các app không dùng nó** (xem ở trên).
5. **Test nó**:
   - widget qua `ui.Tester` trong `src/ui/tests_*.zig`;
   - ánh xạ kiểu IPC trong `tsgen.zig`;
   - page trong `examples/pages` (chạy bằng `test-pages`);
   - cửa sổ trong `window_tests.zig` của các backend;
   - renderer so với CPU.

   Đăng ký file test trong khối test của `ui.zig` hoặc `myzig.zig`.
6. **Build mọi nền tảng**: `zig build`, `zig build -Dtarget=x86_64-linux-gnu`, `zig build -Dtarget=x86_64-windows-gnu`, `zig build -Dtarget=x86-windows-gnu`, `zig build web`. Chạy `zig build test` (và `-Dportable=true`), test Linux trong container, và `zig build lines`.
7. **Không C**: khai báo `extern`, `dlopen`/`dlsym`, vtable COM; không `@cImport`, không file `.c` hay `.m`.
8. **Viết tài liệu** trong `docs/`, và thêm vào một ví dụ khi nó có thể hiện ra.
9. **Hill-climb** nếu nó chạm tới frame: chạy `hillclimb` trước và sau.
