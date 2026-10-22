<a id="benchmarks"></a>

# Benchmark

Chi phí của một ứng dụng myzig so với [mygo](https://github.com/egoist/mygo),
dự án mà myzig được port từ đó, và [Electron](https://www.electronjs.org).
Thời gian dựng khung hình của giao diện native so với mygo nằm ở phần leo đồi
([hillclimb/README.md](../../hillclimb/README.md)); kích thước nhị phân nằm ở
[Kiểm thử, kích thước và tính năng](architecture-testing.md).

## Bộ nhớ của một cửa sổ trang web trên Windows

Một cửa sổ mở `about:blank`, đo bộ nhớ của toàn bộ cây tiến trình của ứng
dụng (ứng dụng và mọi tiến trình WebView2 hoặc Chromium mà nó khởi chạy),
tính theo private bytes, lấy trung vị của năm lần chạy:

| tiến trình (MiB) | myzig 0.1.7 | mygo | Electron 38 |
|---|---:|---:|---:|
| ứng dụng | 3.7 | 47.4 | 36.3 |
| browser (WebView2 Manager) | 29.8 | 30.4 | nằm trong ứng dụng |
| GPU | 51.8 | 50.9 | 77.1 |
| renderer (trang web) | 19.4 | 23.5 | 22.6 |
| network service | 11.5 | 11.2 | 13.1 |
| storage service | 7.3 | 7.3 | nằm trong browser |
| crash handler | 2.4 | 2.4 | không có |
| **tổng** | **127.2** | **173.7** | **149.0** |
| số tiến trình | 7 | 7 | 4 |

| trên ổ đĩa | myzig | mygo | Electron |
|---|---:|---:|---:|
| những gì ứng dụng mang theo | 1.2 MiB (`hello.exe`) | 6.8 MiB | 324 MiB (Chromium riêng) |

Windows 10 19045, Core i5-1145G7, WebView2 Runtime 155, myzig build
ReleaseSmall, mygo ở commit 9c05b11 build bằng Go 1.27 (`-s -w`). Các cửa sổ
đều ẩn; trang myzig bị ẩn sẽ yêu cầu WebView2 dùng mức bộ nhớ thấp
([Trang web](pages.md)). Với `about:blank` mức này tiết kiệm không đáng kể:
khi giữ mức bình thường, như một cửa sổ đang hiển thị, tổng của myzig là
130.7 MiB.

Ý nghĩa:

- **Phần lớn bộ nhớ thuộc về engine trình duyệt**, và myzig với mygo dùng
  chung một engine: các tiến trình WebView2 của hai bên chỉ chênh nhau vài
  MiB. Electron chạy Chromium riêng, ít tiến trình hơn (tiến trình chính
  kiêm luôn browser, storage cũng chạy trong đó) nhưng tiến trình GPU lớn
  hơn.
- **Phần của riêng myzig khoảng 4 MiB**: file thực thi, bộ nhớ nó cấp phát
  và các DLL hệ thống nó nạp. Go runtime của mygo khoảng 47 MiB, tiến trình
  chính của Electron (Node và browser) khoảng 36 MiB.
- Một trang thật sẽ cộng thêm vào renderer và tiến trình GPU phần mà DOM,
  script và hình ảnh của nó cần, ở framework nào cũng như nhau.

### Vì sao Task Manager hiện nhiều tiến trình

WebView2 là Chromium, và Chromium chia công việc ra nhiều tiến trình để một
lỗi crash hay một trang bị tấn công chỉ nằm trong tiến trình của nó:

| trong Task Manager | việc nó làm |
|---|---|
| WebView2 Manager | tiến trình browser: khởi chạy và giám sát các tiến trình còn lại |
| WebView2 GPU Process | ghép lớp và vẽ bằng GPU |
| WebView2 Utility: Network Service | mọi request mạng |
| WebView2 Utility: Storage Service | localStorage, IndexedDB, cache |
| WebView2: *tiêu đề trang* | renderer: DOM và JavaScript của trang |

Ứng dụng WebView2 nào cũng có các tiến trình này; myzig không thêm tiến
trình nào. Tùy bản Windows và bản runtime, Task Manager có khi gom chúng dưới
ứng dụng, có khi để riêng thành "Microsoft Edge WebView2" trong mục
background processes, khiến ứng dụng trông như chỉ tốn vài MiB. Để so sánh
các bản build, hãy cộng ứng dụng và mọi tiến trình `msedgewebview2.exe` của
nó trong tab Details, hoặc chạy script bên dưới, script này đi theo cây tiến
trình.

### Dùng ít bộ nhớ hơn

Chromium nhận cờ qua biến môi trường `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`,
đặt trước khi ứng dụng khởi chạy. Đo với frontend của ví dụ hello (mỗi cấu
hình chạy một lần, nên sai số vài MiB):

| cờ | số tiến trình | tổng (MiB) |
|---|---:|---:|
| không có | 7 | 131 |
| `--in-process-gpu` | 6 | 120 |
| `--disable-gpu` | 7 | 93 |
| `--disable-gpu --in-process-gpu --enable-features=NetworkServiceInProcess2` | 5 | 80 |

`--disable-gpu` vẽ trang bằng CPU: ổn với form và bảng, chậm hơn với
animation, danh sách cuộn dài, canvas và WebGL. Các cờ in-process gộp phần
GPU hoặc mạng vào tiến trình browser, nên một lỗi crash ở đó sẽ kéo sập
trang; chúng cũng là phần nội bộ của Chromium mà bản runtime sau có thể bỏ.
Browser, renderer, storage service và crash handler thì luôn chạy.

### Đo lại

[hillclimb/webview-memory](../../hillclimb/webview-memory/README.md) có ba
ứng dụng và `measure.ps1`, script chạy lần lượt từng ứng dụng mà không hiện
cửa sổ nào và in ra bảng ở trên. Kết quả theo ngày, kèm so sánh myzig 0.1.5
với 0.1.7, nằm trong
[hillclimb/notes](../../hillclimb/notes/webview-memory-vs-mygo-electron-2026-10-22.md).
