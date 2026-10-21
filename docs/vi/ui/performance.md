<a id="native-ui-performance"></a>

# Giao diện native hiệu suất

View là chế độ ngay lập tức: view chạy trên mọi frame và xây dựng lại toàn bộ cây. Điều đó rẻ vì một khung chỉ được xây dựng khi có điều gì đó xảy ra (đầu vào, thay đổi kích thước, hoạt ảnh, yêu cầu từ bên ngoài view) và bởi vì những gì đắt tiền sẽ được giữ trên các khung:

- **Bố cục** giữ lại văn bản, chiều rộng và hai dòng bọc cuối cùng của mỗi hộp văn bản, được tìm thấy lại theo id của nó và so sánh (`layout_cache.zig`, sau bộ đệm bố cục của mygo): một hộp có văn bản vẫn như cũ, như hầu hết, không yêu cầu hệ thống văn bản gì và một hộp có văn bản thay đổi sẽ không phân bổ gì. Trong một khung, một chiếc hộp được đo lại theo chiều rộng mà nó được đo như cũ, vì vậy những cây sâu được đo một lần chứ không phải một lần cho mỗi tầng xung quanh chúng.
- **Bố cục văn bản** được lưu vào bộ nhớ đệm theo chuỗi và kiểu của chúng, đồng thời các glyph được rasterized một lần vào atlas glyph; ASCII có thể in được có nhánh tối ưu chính xác trên macOS (`shaper.zig`, được kiểm tra để phù hợp với hình dạng của CoreText). Một phông chữ được giữ cho mỗi kích thước văn bản được hiển thị; qua 256 trong số chúng (kích thước thay đổi từng frame, như thanh trượt thu phóng cung cấp), một frame cho phép tất cả chúng đi và bắt đầu lại, sắp xếp lại các glyph của nó.
- **Hình ảnh** được giải mã một lần và đóng gói vào atlas hình ảnh, bắt đầu ở kích thước 512 pixel một cạnh và tăng gấp đôi khi hình ảnh cần, lên tới 2048. Khi GPU vẽ (Metal, Direct3D 11), hình ảnh sẽ chuyển thẳng sang kết cấu của nó và không có bản sao nào của atlas lưu lại trong bộ nhớ.
- **Bộ nhớ của khung** là một arena đặt lại từng frame: các chuỗi được tạo bằng `c.print` và `c.alloc()` tốn một con trỏ.
- **Bản vẽ** là một bản vẽ tạm thời gọi một khung trên GPU (xem [Kết xuất](rendering.md)).

<a id="writing-fast-views"></a>

## Viết lượt xem nhanh

- Hiển thị các bộ sưu tập dài với [danh sách](lists.md) ảo (`ui.list`, sau GPUI's `uniform_list`), bảng hoặc view lưới: chúng chỉ tạo các hàng trong view, vì vậy 100 000 hàng có giá bằng 30 hàng.
- Giữ id ổn định bằng `ui.key` hoặc `c.keyed` cho các mục của bộ sưu tập để trạng thái của chúng (di chuột, tiêu điểm, hoạt ảnh) tuân theo chúng.
- Chỉ đặt `c.changed` khi trạng thái tương tác thay đổi: mỗi trạng thái sẽ tạo lại khung (`FrameStats.passes`).
- Yêu cầu di chuyển con trỏ (`c.wants_moves`) và bánh xe (`c.wants_wheel`) chỉ trong các view theo sau chúng, giống như biểu đồ: nếu không có chúng, việc di chuyển con trỏ qua view tĩnh chỉ tạo khung khi nội dung bên dưới nó thay đổi.
- Thực hiện công việc bên ngoài view: view đọc trạng thái, nó không tính toán trạng thái đó. Công việc từ các luồng khác đến luồng chính thông qua vòng lặp sự kiện và yêu cầu khung.

<a id="out-of-sight"></a>

## Ngoài tầm mắt

Mặc dù không có gì trong cửa sổ hiển thị (trên macOS: bị ẩn, thu nhỏ, trên một Không gian khác hoặc bị che phủ hoàn toàn bởi các cửa sổ khác; trong trình duyệt: một tab ở chế độ nền), myzig không vẽ khung cho nó, vì trình duyệt không vẽ gì cho các trang nằm ngoài tầm nhìn và như Apple yêu cầu đối với các ứng dụng Mac. View không chạy, bản vẽ không được vẽ và tạo khung cho hoạt ảnh hoặc đồng hồ hẹn giờ yêu cầu chờ. Ngay khi một số cửa sổ hiển thị, nó sẽ vẽ một lần, với mọi thứ đã thay đổi trong thời gian đó; cho đến lúc đó màn hình hiển thị frame cuối cùng để làm mới. Một khung vẫn được tạo sau khi nhập (các phím được nhập vào cửa sổ chính sẽ che cửa sổ của ứng dụng khác), dành cho công nghệ hỗ trợ và cho ảnh chụp nhanh (`--myzig-snapshot`), để khung này hiển thị cửa sổ như hiện tại. Windows và Linux không cho myzig biết khi nào một cửa sổ nằm ngoài tầm nhìn, nên nó vẫn vẽ như mọi khi.

Điều này có ý nghĩa gì đối với chuyển động:

- **Những gì myzig hoạt hình tiếp tục diễn ra từ nơi thời gian đặt nó.** Một lò xo, một đường cong trên đường đi, một vòng lặp, frame chính và dòng thời gian chạy khi cửa sổ khuất tầm mắt sẽ tiếp tục chạy dọc hoặc hoàn tất khi nó hiển thị: chúng chạy trên `c.time`, đồng hồ, không phải trên số lượng frame.
- **Mục tiêu đã thay đổi khuất tầm nhìn sẽ hoạt hình khi cửa sổ hiển thị.** Sau đó, view sẽ nhìn thấy mục tiêu mới, do đó, giá trị sẽ di chuyển đến mục tiêu đó từ vị trí ban đầu, giống như quá trình chuyển đổi CSS thực hiện đối với thay đổi được thực hiện trong tab ẩn.
- **Tính toán chuyển động của riêng bạn theo thời gian, không phải từ frame.** Thời gian bắt đầu được thực hiện trong frame đầu tiên vẽ thứ gì đó hoặc số lượng frame, bắt đầu lại khi cửa sổ hiển thị và phát những gì đã xảy ra trong khi đó như thể nó vừa mới bắt đầu. Dành thời gian từ khi trạng thái thay đổi, trong mã thay đổi trạng thái đó và view hiển thị thay đổi được thực hiện ngoài tầm nhìn như đã hoàn tất:

```zig
/// Eases from one value to the next over 400 ms, by the clock.
const Counter = struct {
    from: f32 = 0,
    to: f32 = 0,
    changed: f64 = 0, // ui.clock.now() when it changed

    const ease = 0.4;

    fn at(n: Counter, t: f64) f32 {
        const p: f32 = @floatCast(@min((t - n.changed) / ease, 1));
        return n.from + (n.to - n.from) * ui.motion.Easing.at(.ease_out, p);
    }
};

// Where the count changes, outside the view:
const now = ui.clock.now();
app.count = .{ .from = app.count.at(now), .to = @floatFromInt(n), .changed = now };
win.redraw();

// In the view:
const value = app.count.at(c.time);
if (c.time - app.count.changed < Counter.ease) c.animationFrame();
```

- **Giữ công việc ở ngoài tầm nhìn.** Bỏ phiếu, lưu hoặc bắt đầu công việc từ dạng xem, từ bộ hẹn giờ nó yêu cầu hoặc từ bản vẽ chờ trong khi cửa sổ khuất tầm nhìn. Chạy công việc như vậy từ ứng dụng (một chuỗi hoặc bộ hẹn giờ của ứng dụng, `myzig.App.after`) và hiển thị những gì nó thực hiện bằng cách yêu cầu cửa sổ cung cấp khung (`redraw`).

<a id="measuring"></a>

## Đo lường

`c.stats` (`ui.FrameStats`) giữ chi phí của khung cuối cùng: xây dựng, bố cục và vẽ trong một phần nghìn giây, đường chuyền, hộp và phiên bản. [inspector](inspector.md) vẽ biểu đồ cho 60 frame cuối cùng.

Các điểm chuẩn rất cao: [`hillclimb/`](../../../hillclimb/README.md) là một ứng dụng đầu cuối, được xây dựng trên myzig dưới dạng thư viện, hiển thị các cảnh tương tự thông qua khung của myzig và thông qua khung của mygo, không có cửa sổ và ghi lại mọi lần chạy trong `hillclimb/history.jsonl`:

```sh
cd hillclimb
zig build run                                  # every scene, myzig and mygo
zig build run -- --label "what changed"        # name the run in history.jsonl
zig build run -- --scene text,list --only myzig --frames 600 --repeat 5
zig build run -- --only myzig --hash           # and hash the CPU renderer's pixels
```

Mỗi cảnh chạy 30 frame khởi động, sau đó đo 300 frame, ba lần; lượt chạy có frame trung bình thấp nhất được giữ lại và được so sánh với mygo, với lượt chạy trước đó của myzig và với frame tốt nhất của nó. Những thay đổi trong vòng 5% là tiếng ồn. Công việc về hiệu suất được thực hiện theo cách này: chạy trước và sau, giữ các thay đổi tăng dần, chạy nhãn và không bao giờ đánh đổi độ chính xác để lấy tốc độ (các đường dẫn nhanh đi kèm với các kiểm thử chứng minh rằng chúng phù hợp với đường dẫn chậm; `--hash` chứng tỏ bộ kết xuất CPU nhanh hơn sẽ vẽ cùng các pixel).

Những cảnh:

- **hộp**: 600 hộp tròn, bóng mờ di chuyển và thay đổi màu sắc.
- **văn bản**: 300 nhãn có số thay đổi trong mỗi frame.
- **cuộn**: một cột đơn giản gồm 1000 hàng, được cắt bớt, di chuyển mọi frame.
- **danh sách**: danh sách ảo hóa gồm 100 000 hàng, cuộn từng frame.
- **trang tổng quan**: 12 thẻ văn bản, một số lượng lớn và thanh tiến trình.

<a id="results"></a>

## Kết quả

Trên Apple M3 Ultra, với các khung được vẽ bởi bộ kết xuất ngoài màn hình Metal của mỗi khung, giá trị trung bình trên mỗi frame tính bằng mili giây (càng thấp càng tốt):

| bối cảnh | CPU khung myzig | CPU khung mygo | GPU myzig | GPU mygo |
|---|---:|---:|---:|---:|
| hộp (600 hộp bóng tối) | 0.061 | 0.301 | 0.140 | 1.616 |
| văn bản (300 nhãn thay đổi) | 0.108 | 0.418 | 0.065 | 0.056 |
| cuộn (cột 1000 hàng) | 0.315 | 2.076 | 0.055 | 0.122 |
| danh sách (danh sách ảo 100 000 hàng) | 0.060 | 0.367 | 0.046 | 0.045 |
| bảng điều khiển (12 thẻ) | 0.015 | 0.087 | 0.098 | 0.295 |

Trên Windows (Intel Core i5-1145G7, 8 luồng), với bộ kết xuất CPU của cả hai khung sẽ vẽ toàn bộ frame vào bộ nhớ, trên một số lõi, Zig 0.17.0 so với mygo 9c05b11 ([các lần chạy](../../../hillclimb/notes/windows-results-2026-10-20.md)):

| bối cảnh | CPU khung myzig | CPU khung mygo | kết xuất myzig | kết xuất mygo | xử lý CPU myzig | xử lý CPU mygo |
|---|---:|---:|---:|---:|---:|---:|
| hộp | 0.094 | 0.646 | 5.6 | 17.2 | 37.3 | 125.4 |
| văn bản | 0.276 | 0.993 | 0.8 | 2.5 | 4.8 | 20.3 |
| cuộn | 0.658 | 4.094 | 0.7 | 0.9 | 5.8 | 7.4 |
| danh sách | 0.065 | 0.731 | 0.5 | 1.1 | 3.9 | 8.9 |
| bảng điều khiển | 0.054 | 0.179 | 4.3 | 6.7 | 27.7 | 34.2 |
| bố cục | 0.166 | 0.473 | 1.4 | 2.6 | 8.8 | 12.9 |

Số đo của các cửa sổ thực (thời gian đến frame đầu tiên, bộ nhớ, CPU không hoạt động) nằm trong [hillclimb/notes/windowed-results-2026-10-17.md](../../../hillclimb/notes/windowed-results-2026-10-17.md): không hoạt động, cửa sổ myzig hoàn toàn không sử dụng CPU.

<a id="size"></a>

## Kích thước

Tệp nhị phân phát hành của bộ đếm có kích thước khoảng 0,7 MB (`ReleaseSmall`; 1,14 MB `ReleaseFast` trên Windows), so với 9 đến 12 MB cho mygo's. Những gì ứng dụng không sử dụng sẽ không được liên kết: dữ liệu ngày của i18n chỉ vào các ứng dụng định dạng ngày, bản dịch của chính myzig chỉ sang các ứng dụng gửi các ngôn ngữ đó, [inspector](inspector.md) chỉ vào các bản dựng gỡ lỗi. Xem [hướng dẫn kiến ​​trúc](../architecture-testing.md) về kích thước nhị phân.

Thời gian phụ thuộc vào máy, bộ kết xuất và những gì khác chạy: kiểm tra lại những khác biệt nhỏ và chỉ so sánh lần chạy với lần chạy trước đó trên cùng một nền tảng (`history.jsonl` ghi lại `os` của mỗi lần chạy).
