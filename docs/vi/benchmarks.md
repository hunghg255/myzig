<a id="benchmarks"></a>

# Benchmark

Một app myzig tốn bao nhiêu so với [mygo](https://github.com/egoist/mygo), dự án mà myzig port lại, và [Electron](https://www.electronjs.org).

- Thời gian vẽ frame của native UI so với mygo lấy từ hill climb ([hillclimb/README.md](../../hillclimb/README.md)).
- Kích thước binary nằm ở [Test, kích thước và tính năng](architecture-testing.md).

<a id="memory-of-a-page-window-on-windows"></a>

## Bộ nhớ của một cửa sổ page trên Windows

Một cửa sổ mở `about:blank`. Bộ nhớ là private bytes của cả cây tiến trình của app: chính app và mọi tiến trình WebView2 hay Chromium mà nó khởi chạy. Mỗi con số là trung vị của năm lần chạy.

| tiến trình (MiB) | myzig 0.1.7 | mygo | Electron 38 |
|---|---:|---:|---:|
| app | 3.7 | 47.4 | 36.3 |
| browser (WebView2 Manager) | 29.8 | 30.4 | nằm trong app |
| GPU | 51.8 | 50.9 | 77.1 |
| renderer (page) | 19.4 | 23.5 | 22.6 |
| network service | 11.5 | 11.2 | 13.1 |
| storage service | 7.3 | 7.3 | nằm trong browser |
| crash handler | 2.4 | 2.4 | không có |
| **tổng** | **127.2** | **173.7** | **149.0** |
| số tiến trình | 7 | 7 | 4 |

| trên đĩa | myzig | mygo | Electron |
|---|---:|---:|---:|
| những gì app phải kèm theo | 1.2 MiB (`hello.exe`) | 6.8 MiB | 324 MiB (Chromium riêng của nó) |

Windows 10 19045, Core i5-1145G7, WebView2 Runtime 155, myzig ReleaseSmall, mygo ở commit 9c05b11 build bằng Go 1.27 (`-s -w`).

Các cửa sổ đều bị ẩn. Một page myzig bị ẩn sẽ xin WebView2 mức bộ nhớ thấp ([Pages](pages.md)), nhưng với `about:blank` thì tiết kiệm được rất ít. Với mức bình thường, như cửa sổ đang hiện, tổng của myzig là 130.7 MiB.

Ý nghĩa của bảng:

- **Phần lớn bộ nhớ thuộc về browser engine.** myzig và mygo dùng cùng một engine: các tiến trình WebView2 của chúng chỉ chênh nhau vài MiB.
- Electron chạy Chromium riêng. Nó có ít tiến trình hơn, vì tiến trình chính cũng là browser và chạy luôn phần storage. Tiến trình GPU của nó lớn hơn.
- **Phần riêng của myzig khoảng 4 MiB**: file thực thi, các vùng nhớ nó cấp phát và các DLL hệ thống nó nạp.
- Go runtime của mygo khoảng 47 MiB. Tiến trình chính của Electron (Node và browser) khoảng 36 MiB.
- Một page thật sẽ thêm vào renderer và tiến trình GPU phần mà DOM, script và hình ảnh của nó cần, framework nào cũng vậy.

<a id="why-task-manager-shows-several-processes"></a>

### Vì sao Task Manager hiện nhiều tiến trình

WebView2 là Chromium. Chromium chia việc ra nhiều tiến trình, để một lần crash hay một page bị chiếm quyền chỉ nằm gọn trong tiến trình của nó:

| trong Task Manager | việc nó làm |
|---|---|
| WebView2 Manager | tiến trình browser: khởi chạy và giám sát các tiến trình kia |
| WebView2 GPU Process | ghép lớp và vẽ bằng GPU |
| WebView2 Utility: Network Service | mọi request mạng |
| WebView2 Utility: Storage Service | localStorage, IndexedDB, cache |
| WebView2: *tiêu đề page* | renderer: DOM và JavaScript của page |

App WebView2 nào cũng có chúng; myzig không thêm tiến trình nào.

Một số bản Windows và phiên bản runtime liệt kê chúng dưới app. Số khác liệt kê riêng, với tên "Microsoft Edge WebView2" trong nhóm tiến trình nền, khi đó app trông như chỉ tốn vài MiB. Để so sánh các bản build:

- cộng app và tất cả tiến trình `msedgewebview2.exe` của nó trong tab Details, hoặc
- chạy script bên dưới, script này đi theo cây tiến trình.

<a id="using-less"></a>

### Dùng ít hơn

Chromium nhận flag từ `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`, đặt trước khi app khởi động. Đo với frontend của ví dụ hello, mỗi cấu hình một lần chạy, nên sai số vài MiB:

| flag | số tiến trình | tổng (MiB) |
|---|---:|---:|
| không có | 7 | 131 |
| `--in-process-gpu` | 6 | 120 |
| `--disable-gpu` | 7 | 93 |
| `--disable-gpu --in-process-gpu --enable-features=NetworkServiceInProcess2` | 5 | 80 |

- `--disable-gpu` vẽ page bằng CPU. Ổn với form và bảng, chậm hơn với animation, danh sách dài cần scroll, canvas và WebGL.
- Các flag in-process gộp phần GPU hoặc mạng vào tiến trình browser. Crash ở đó sẽ kéo page sập theo.
- Đó là chi tiết nội bộ của Chromium, một bản cập nhật runtime có thể bỏ chúng.
- Browser, renderer, storage service và crash handler luôn chạy.

<a id="measuring-it-again"></a>

### Đo lại

[hillclimb/webview-memory](../../hillclimb/webview-memory/README.md) có ba app và `measure.ps1`. Script chạy lần lượt từng app mà không hiện cửa sổ nào và in ra bảng ở trên. Kết quả có ghi ngày, so sánh myzig 0.1.5 với 0.1.7, nằm trong [hillclimb/notes](../../hillclimb/notes/webview-memory-vs-mygo-electron-2026-10-22.md).
