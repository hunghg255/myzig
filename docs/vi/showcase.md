<a id="showcase"></a>

# Showcase

Các app làm bằng myzig, tất cả nằm trong [`examples/`](../../examples). Chạy từng app bằng `zig build run-NAME` trong repository; riêng farm là một package riêng (`cd examples/farm && zig build run`). Ảnh được chụp offscreen bằng `--myzig-snapshot`.

<a id="apps"></a>

## App

<a id="notes"></a>

### Notes

![Notes: sidebar danh sách ghi chú và trình soạn rich text cùng thanh công cụ.](../images/showcase/notes.jpg)

Ghi chú rich text: thanh công cụ định dạng, phím tắt Markdown khi gõ, link, và copy dưới dạng Markdown. [Source](../../examples/notes/main.zig)

<a id="documents"></a>

### Documents

![Documents: một ghi chú Markdown đang được viết, kèm số từ.](../images/showcase/documents.jpg)

Trình soạn Markdown và văn bản dựa trên `myzig.Documents`: menu File, mỗi ghi chú một cửa sổ, tự lưu, và khôi phục sau khi app bị crash. [Source](../../examples/documents/main.zig)

<a id="code-editor"></a>

### Code editor

![Code editor: danh sách file, code Zig có tô màu cú pháp và số dòng.](../images/showcase/code-editor.jpg)

Tô màu cú pháp, tìm và thay thế, nhảy tới dòng, ngắt dòng, kèm diff viewer cho các thay đổi và một text area để ghi chú. [Source](../../examples/code-editor/main.zig)

<a id="markdown-chat"></a>

### Markdown chat

![Một cuộc chat có câu trả lời Markdown kèm khối code đang stream về.](../images/showcase/markdown-chat.jpg)

Một trợ lý giả lập có câu trả lời stream về dưới dạng Markdown, được parse ngay khi tới. [Source](../../examples/markdown-chat/main.zig)

<a id="chat-glow"></a>

### Chat glow

![Chat nền tối đang trả lời lịch trình du lịch, ô nhập có viền phát sáng.](../images/showcase/chat-glow.jpg)

Giao diện chat của trợ lý được vẽ bằng shader: quả cầu avatar, ô nhập phát sáng, hiệu ứng lấp lánh của "Thinking…" và viền cửa sổ. [Source](../../examples/chat-glow/main.zig)

<a id="piano"></a>

### Piano

![Bàn phím piano bên dưới các nút của bốn bài nhạc.](../images/showcase/piano.jpg)

Chơi bằng chuột hoặc bàn phím, hoặc để nó tự chơi một bài. Mỗi nốt được tổng hợp và phát bằng `myzig.audio`. [Source](../../examples/piano/main.zig)

<a id="drag-and-drop"></a>

### Kéo thả

![Các thẻ để kéo và một vùng thả trong cửa sổ tên Left.](../images/showcase/drag-drop.jpg)

Kéo ghi chú, chữ, URL và file giữa hai cửa sổ, ra các app khác và vào từ trình quản lý file. [Source](../../examples/drag-drop/main.zig)

<a id="clipboard"></a>

### Clipboard

![Một ghi chú để copy hoặc kéo dưới dạng text, HTML hay JSON.](../images/showcase/clipboard.jpg)

Một ghi chú được copy và kéo dưới dạng text, HTML và JSON; JSON chỉ được tạo khi nơi nhận cần tới. [Source](../../examples/clipboard/main.zig)

<a id="games-and-shaders"></a>

## Game và shader

<a id="farm"></a>

### Farm

![Người nông dân trên lối đất đã cày giữa bãi cỏ, thanh công cụ ở dưới.](../images/showcase/farm.jpg)

Một game nông trại nhỏ: cày đất, gieo hạt, tưới nước và thu hoạch khi ngày chuyển sang đêm, có âm thanh và nhạc. Chạy trên [plugin game](plugins/game.md). [Source](../../examples/farm/main.zig)

<a id="mayoi"></a>

### Mayoi

![Một cô gái trên con phố tối, nhiễu tĩnh điện ập vào từ các mép.](../images/showcase/mayoi.jpg)

Game sinh tồn trên con phố về đêm, vẽ bằng một shader duy nhất. Đi bằng phím mũi tên, hát bằng Space. [Source](../../examples/mayoi/main.zig)

<a id="black-hole"></a>

### Hố đen

![Một hố đen bẻ cong ánh sáng của đĩa bồi tụ.](../images/showcase/blackhole.jpg)

Tia sáng của từng pixel được dò ngược qua trọng lực của hố đen. Kéo để xoay quanh, cuộn để lại gần. [Source](../../examples/blackhole/main.zig)

<a id="wind"></a>

### Gió

![Các ký tự được vẽ theo hướng gió thổi, quanh một ô nhập.](../images/showcase/wind.jpg)

Một mảng ký tự bị gió khuấy động. Di con trỏ để làm ấm không khí, bấm để thổi một gợn sóng. [Source](../../examples/wind/main.zig)

<a id="effort-slider"></a>

### Effort slider

![Một thẻ nền tối có slider với nút kéo hình bộ não.](../images/showcase/effort-slider.jpg)

Slider từ Low tới Max, rồi vượt qua để vào Galaxy, nơi bộ não nổ tung và thẻ rung lên. [Source](../../examples/effort-slider/main.zig)

<a id="confetti"></a>

### Confetti

![Confetti rơi trên danh sách demo và bảng các slider.](../images/showcase/confetti.jpg)

Các demo của canvas-confetti trong native UI, và tự bắn confetti từ vị trí con trỏ. [Source](../../examples/confetti/main.zig)

<a id="data-text-and-motion"></a>

## Dữ liệu, chữ và chuyển động

<a id="streaming-chart"></a>

### Biểu đồ streaming

![Ba dạng sóng màu xanh lá, đỏ và xanh dương.](../images/showcase/chart-streaming.jpg)

Ba dạng sóng, mỗi cái 15 000 mẫu, thêm 1 000 mẫu mới mỗi giây. [Source](../../examples/chart-streaming/main.zig)

<a id="loading-indicators"></a>

### Loading indicator

![Lưới các spinner loading cùng các điều khiển kích thước và tốc độ.](../images/showcase/loading.jpg)

29 indicator của loading.dev, chỉnh được kích thước, màu và easing. [Source](../../examples/loading/main.zig)

<a id="timeline"></a>

### Timeline

![Thẻ tên A timeline với các nút Restart, Pause, Play và Reverse.](../images/showcase/timeline.jpg)

Nhiều tween trên cùng một playhead, phát, dừng và đảo chiều cùng nhau. [Source](../../examples/timeline/main.zig)

<a id="large-text"></a>

### Văn bản lớn

![Trình soạn thảo hiện các dòng chữ trộn tiếng Anh, Hebrew và Ả Rập.](../images/showcase/text-buffer.jpg)

100 000 dòng sửa được, lưu trong một rope; chỉ những dòng đang hiện mới được layout. [Source](../../examples/text-buffer/main.zig)

<a id="a-text-field-of-your-own"></a>

### Tự làm một ô nhập chữ

![Một ô nhập chứa chữ Latin, Hebrew và Ả Rập.](../images/showcase/text-input.jpg)

Một ô nhập chữ dựng từ các primitive nhập chữ của myzig, hỗ trợ bộ gõ và menu Edit. [Source](../../examples/text-input/main.zig)

<a id="gestures"></a>

### Cử chỉ

![Dòng chữ Pinch demo, Scale, Pan và một nút Zoom in.](../images/showcase/gestures.jpg)

Kéo và chụm hai ngón, được xử lý trước box scroll bao quanh. [Source](../../examples/gestures/main.zig)

<a id="counter"></a>

### Counter

![Số 0 cỡ lớn phía trên các nút Increment và Reset.](../images/showcase/counter.jpg)

App nhỏ nhất: view là một hàm Zig của state. [Source](../../examples/counter/main.zig)

<a id="gallery"></a>

### Gallery

![Gallery: sidebar các trang và các thẻ nút, toggle, slider.](../images/showcase/gallery.jpg)

Mọi widget, từng trang một. Các trang của nó chạy trực tiếp khắp [tài liệu Native UI](ui/README.md). [Source](../../examples/gallery/main.zig)

<a id="web-frontends"></a>

## Frontend web

Các app này hiện một trang web trong webview của hệ thống, nên không chụp offscreen được:

| App | |
|---|---|
| [hello](../../examples/hello/main.zig) | một trang gọi service Zig, có event được định kiểu |
| [todo](../../examples/todo/main.zig) | một app hoàn chỉnh: lưu dữ liệu, dialog, menu, nhiều cửa sổ đồng bộ với nhau |
| [native](../../examples/native/main.zig) | menu bar, icon khay hệ thống, dialog, thông báo và clipboard, gọi từ trang web |
| [embed-webview](../../examples/embed-webview/main.zig) | các trang web trong tab bên trong một cửa sổ native UI |
