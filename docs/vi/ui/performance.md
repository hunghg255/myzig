<a id="native-ui-performance"></a>

# Hiệu năng của UI native

View chạy theo kiểu immediate mode: view chạy lại mỗi frame và dựng lại toàn bộ cây. Việc này rẻ vì hai lý do:

- Frame chỉ được dựng khi có chuyện xảy ra: input, đổi kích thước, animation, hoặc yêu cầu từ bên ngoài view.
- Những phần tốn kém được giữ lại qua các frame:

| Phần | Được giữ thế nào |
|---|---|
| **Layout** | chữ, độ rộng và hai lần ngắt dòng gần nhất của mỗi box chữ, theo id (`layout_cache.zig`, theo layout cache của mygo) |
| **Layout chữ** | cache theo chuỗi và style; glyph được rasterize một lần vào atlas glyph |
| **Hình ảnh** | giải mã một lần rồi xếp vào atlas ảnh |
| **Bộ nhớ của frame** | một arena được reset mỗi frame |
| **Animation của control** | giá trị giữ theo id của widget |
| **Vẽ** | một draw call instanced mỗi frame trên GPU (xem [Render](rendering.md)) |

**Layout**

- Box có chữ không đổi, như phần lớn các box, không hỏi gì hệ thống chữ. Box có chữ thay đổi cũng không cấp phát gì.
- Trong cùng một frame, box được đo lại ở cùng độ rộng thì giữ nguyên kết quả. Cây sâu chỉ được đo một lần, không phải một lần cho mỗi tầng bao quanh.
- Cứ 60 frame, các mục không dùng tới quá hai frame bị bỏ đi. Lượt dọn xóa hết mọi mục đã hết hạn, nên scroll liên tục không dồn việc tồn đọng. Nếu cấp phát bộ nhớ tạm thất bại, nó vẫn xóa được một ít.

**Layout chữ**

- Ký tự ASCII in được có đường đi nhanh, cho kết quả chính xác, trên macOS (`shaper.zig`, có test khớp với shaping của CoreText).
- Mỗi cỡ chữ đang hiển thị giữ một font. Quá 256 font, frame bỏ hết rồi bắt đầu lại, rasterize lại glyph của nó. Chuyện này xảy ra khi cỡ chữ đổi mỗi frame, như khi kéo slider zoom.

**Hình ảnh**

- Atlas ảnh bắt đầu ở 512 pixel mỗi cạnh và tăng gấp đôi khi cần, tối đa 2048.
- Ở nơi GPU vẽ (Metal, Direct3D 11), ảnh đi thẳng vào texture của GPU. Không có bản sao nào của atlas nằm lại trong bộ nhớ.

**Bộ nhớ của frame.** Chuỗi tạo bằng `c.print` và `c.alloc()` chỉ tốn một lần tăng con trỏ.

**Animation của control.** Cứ 120 frame, các giá trị không dùng tới quá 120 frame bị bỏ đi trong một lượt. Scroll qua các nút không làm dồn lại state hover và bấm cũ. Nếu cấp phát bộ nhớ tạm thất bại, lượt dọn vẫn xóa được một ít.

<a id="writing-fast-views"></a>

## Viết view nhanh

- Hiển thị danh sách dài bằng [list](lists.md) ảo (`ui.list`, theo `uniform_list` của GPUI), table hoặc grid view. Chúng chỉ dựng các dòng đang thấy, nên 100 000 dòng tốn bằng 30 dòng.
- Giữ id ổn định bằng `ui.key` hoặc `c.keyed` cho các phần tử của danh sách. Khi đó state của chúng (hover, focus, animation) đi theo chúng.
- Chỉ đặt `c.changed` khi tương tác thật sự làm đổi state. Mỗi lần đặt là frame được dựng lại (`FrameStats.passes`).
- Chỉ yêu cầu di chuyển con trỏ (`c.wants_moves`) và con lăn (`c.wants_wheel`) ở view cần theo dõi chúng, như một đồ thị. Không yêu cầu thì di chuyển con trỏ trên một view đứng yên chỉ dựng frame khi thứ nằm dưới con trỏ thay đổi.
- Làm việc bên ngoài view. View đọc state; nó không tính toán state. Việc từ thread khác về main thread qua event loop và yêu cầu một frame.

<a id="out-of-sight"></a>

## Khuất tầm nhìn

Khi không phần nào của cửa sổ hiện ra, myzig không vẽ frame nào cho nó. Trình duyệt cũng làm vậy với trang bị khuất, và Apple yêu cầu điều này ở app Mac.

- "Khuất" trên macOS nghĩa là: bị ẩn, thu nhỏ, nằm ở Space khác, hoặc bị cửa sổ khác che hoàn toàn. Trong trình duyệt: tab ở chế độ nền.
- View không chạy, drawing không được vẽ, và các frame mà animation hay timer yêu cầu phải chờ.
- Ngay khi một phần cửa sổ hiện ra, nó vẽ một lần, với mọi thay đổi trong lúc khuất. Trước đó màn hình giữ frame cuối, trong khoảng một lần làm tươi.
- Frame vẫn được dựng sau input, ví dụ phím gõ vào cửa sổ key đang bị cửa sổ của app khác che. Frame cũng được dựng cho công nghệ hỗ trợ, và cho snapshot (`--myzig-snapshot`), để nó hiện đúng trạng thái hiện tại của cửa sổ.
- Windows và Linux không báo cho myzig khi cửa sổ bị khuất. Ở đó myzig vẽ như mọi khi.

Điều này có nghĩa gì với chuyển động:

- **Những gì myzig animate tiếp tục theo thời gian thật.** Spring, đường cong đang chạy, vòng lặp, keyframe và timeline chạy theo `c.time`, tức đồng hồ, không theo số frame. Những cái đang chạy khi cửa sổ bị khuất sẽ đi xa hơn, hoặc đã xong, khi cửa sổ hiện lại.
- **Đích thay đổi trong lúc khuất sẽ animate khi cửa sổ hiện lại.** Lúc đó view mới thấy đích mới. Giá trị chạy tới đích từ chỗ cũ, giống CSS transition với thay đổi xảy ra trong tab bị ẩn.
- **Tự tính chuyển động của bạn theo thời gian, không theo frame.** Mốc bắt đầu lấy ở frame đầu tiên có vẽ, hay một bộ đếm frame, sẽ bắt đầu lại khi cửa sổ hiện ra. Nó phát lại những gì đã xảy ra như thể vừa mới bắt đầu.

Hãy lấy mốc thời gian lúc state thay đổi, trong chính code thay đổi state. Khi đó view hiển thị thay đổi xảy ra lúc khuất như đã xong:

```zig
/// Chuyển mượt từ giá trị này sang giá trị kế tiếp trong 400 ms, theo đồng hồ.
const Counter = struct {
    from: f32 = 0,
    to: f32 = 0,
    changed: f64 = 0, // ui.clock.now() lúc giá trị thay đổi

    const ease = 0.4;

    fn at(n: Counter, t: f64) f32 {
        const p: f32 = @floatCast(@min((t - n.changed) / ease, 1));
        return n.from + (n.to - n.from) * ui.motion.Easing.at(.ease_out, p);
    }
};

// Ở chỗ giá trị đếm thay đổi, bên ngoài view:
const now = ui.clock.now();
app.count = .{ .from = app.count.at(now), .to = @floatFromInt(n), .changed = now };
win.redraw();

// Trong view:
const value = app.count.at(c.time);
if (c.time - app.count.changed < Counter.ease) c.animationFrame();
```

- **Đưa công việc ra khỏi view.** Polling, lưu dữ liệu, hay khởi chạy job từ view, từ timer mà view yêu cầu, hoặc từ drawing đều phải chờ khi cửa sổ bị khuất. Hãy chạy những việc đó từ app: một thread, hoặc timer của app (`myzig.App.after`). Hiển thị kết quả bằng cách yêu cầu cửa sổ vẽ một frame (`redraw`).

<a id="measuring"></a>

## Đo đạc

`c.stats` (`ui.FrameStats`) chứa chi phí của frame gần nhất: build, layout và paint tính bằng mili giây, số pass, số box và số instance. [Inspector](inspector.md) vẽ đồ thị các số này cho 60 frame gần nhất.

Benchmark được làm theo kiểu hill climb. [`hillclimb/`](../../../hillclimb/README.md) là một app terminal dùng myzig như thư viện. Nó render cùng các cảnh qua frame của myzig và của mygo, không cần cửa sổ, và ghi mọi lần chạy vào `hillclimb/history.jsonl`:

```sh
cd hillclimb
zig build run                                  # mọi cảnh, myzig và mygo
zig build run -- --label "what changed"        # đặt tên lần chạy trong history.jsonl
zig build run -- --scene text,list --only myzig --frames 600 --repeat 5
zig build run -- --only myzig --hash           # và hash các pixel của renderer CPU
```

- Mỗi cảnh chạy 30 frame khởi động, rồi 300 frame được đo, lặp ba lần.
- Lần chạy có frame trung vị thấp nhất được giữ lại. Nó được so với mygo, với lần chạy trước của myzig và với kết quả tốt nhất của myzig.
- Chênh lệch trong khoảng 5% là nhiễu.

Việc tối ưu hiệu năng làm theo cách này:

- Chạy trước và sau, giữ thay đổi nào giúp leo lên, và đặt tên cho các lần chạy.
- Không bao giờ đánh đổi tính đúng lấy tốc độ. Đường đi nhanh luôn có test chứng minh khớp với đường đi chậm. `--hash` chứng minh renderer CPU nhanh hơn vẫn vẽ ra đúng các pixel đó.

Các cảnh:

- **boxes**: 600 box bo góc, có bóng, di chuyển và đổi màu.
- **text**: 300 label có con số đổi mỗi frame.
- **scroll**: một cột đơn giản 1000 dòng, bị cắt, di chuyển mỗi frame.
- **list**: một list ảo 100 000 dòng, scroll mỗi frame.
- **dashboard**: 12 card gồm chữ, một con số lớn và một thanh tiến trình.

<a id="results"></a>

## Kết quả

Trên Apple M3 Ultra, frame được vẽ bằng renderer Metal offscreen của từng framework. Trung vị mỗi frame tính bằng mili giây, càng thấp càng tốt:

| cảnh | CPU frame myzig | CPU frame mygo | GPU myzig | GPU mygo |
|---|---:|---:|---:|---:|
| boxes (600 box có bóng) | 0.061 | 0.301 | 0.140 | 1.616 |
| text (300 label thay đổi) | 0.108 | 0.418 | 0.065 | 0.056 |
| scroll (cột 1000 dòng) | 0.315 | 2.076 | 0.055 | 0.122 |
| list (list ảo 100 000 dòng) | 0.060 | 0.367 | 0.046 | 0.045 |
| dashboard (12 card) | 0.015 | 0.087 | 0.098 | 0.295 |

Trên Windows, Intel Core i5-1145G7 với 8 thread. Renderer CPU của cả hai framework vẽ toàn bộ mỗi frame vào bộ nhớ, trên nhiều nhân. Zig 0.17.0 so với mygo 9c05b11 ([các lần chạy](../../../hillclimb/notes/windows-results-2026-10-20.md)):

| cảnh | CPU frame myzig | CPU frame mygo | render myzig | render mygo | CPU tiến trình myzig | CPU tiến trình mygo |
|---|---:|---:|---:|---:|---:|---:|
| boxes | 0.094 | 0.646 | 5.6 | 17.2 | 37.3 | 125.4 |
| text | 0.276 | 0.993 | 0.8 | 2.5 | 4.8 | 20.3 |
| scroll | 0.658 | 4.094 | 0.7 | 0.9 | 5.8 | 7.4 |
| list | 0.065 | 0.731 | 0.5 | 1.1 | 3.9 | 8.9 |
| dashboard | 0.054 | 0.179 | 4.3 | 6.7 | 27.7 | 34.2 |
| layout | 0.166 | 0.473 | 1.4 | 2.6 | 8.8 | 12.9 |

Số đo trên cửa sổ thật (thời gian tới frame đầu tiên, bộ nhớ, CPU khi rảnh) nằm trong [hillclimb/notes/windowed-results-2026-10-17.md](../../../hillclimb/notes/windowed-results-2026-10-17.md). Khi rảnh, cửa sổ myzig không dùng chút CPU nào.

<a id="size"></a>

## Kích thước

Binary release của counter khoảng 0,7 MB (`ReleaseSmall`; 1,14 MB với `ReleaseFast` trên Windows), so với 9 đến 12 MB của mygo. Những gì app không dùng thì không được link vào:

- dữ liệu ngày tháng của i18n chỉ vào app có định dạng ngày;
- bản dịch riêng của myzig chỉ vào app có các ngôn ngữ đó;
- [inspector](inspector.md) chỉ vào bản build debug.

Xem [hướng dẫn kiến trúc](../architecture-testing.md) về kích thước binary.

Thời gian đo phụ thuộc vào máy, renderer và những gì đang chạy cùng. Hãy kiểm tra lại các chênh lệch nhỏ. Chỉ so một lần chạy với các lần chạy trước trên cùng nền tảng (`history.jsonl` ghi `os` của mỗi lần chạy).
