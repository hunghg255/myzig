---
layout: home

hero:
  name: myzig
  text: Ứng dụng desktop bằng Zig
  tagline: Giao diện native được vẽ trên GPU hoặc frontend web trong webview hệ thống. Một file thực thi nhỏ gọn cho macOS, Linux, Windows và trình duyệt.
  image:
    src: /logo.png
    alt: Logo myzig
  actions:
    - theme: brand
      text: Bắt đầu
      link: /vi/getting-started
    - theme: alt
      text: Giao diện native
      link: /vi/ui/README
    - theme: alt
      text: Tổng quan
      link: /vi/README
    - theme: alt
      text: Kiến trúc
      link: /vi/architecture#architecture-at-a-glance

features:
  - title: Giao diện native chỉ bằng Zig
    details: Bố cục flexbox và grid, bộ widget đầy đủ, chuyển động, shader và khả năng tiếp cận. Mỗi frame dùng một lệnh vẽ instancing với Metal, Direct3D 11, OpenGL hoặc WebGL 2.
    link: /vi/ui/README
  - title: Trang web với IPC có kiểu
    details: WKWebView, WebKitGTK hoặc WebView2 gọi Zig qua JavaScript client được sinh từ kiểu Zig, kèm khai báo TypeScript, sự kiện và channel.
    link: /vi/bindings
  - title: CPU kết xuất cùng kết quả pixel
    details: Bộ kết xuất CPU của myzig vẽ cùng kết quả với các backend GPU trên nhiều lõi, đồng thời là bản đối chiếu để kiểm thử từng shader.
    link: /vi/ui/rendering
  - title: Kiểm thử không cần mở cửa sổ
    details: ui.Tester kết xuất view ngoài màn hình; ứng dụng thật chạy headless với --myzig-snapshot, --myzig-script và --myzig-eval.
    link: /vi/ui/testing
  - title: Build từ mọi máy
    details: Thư viện Linux và Windows được nạp khi chạy thay vì liên kết lúc build, nên có thể dùng -Dtarget để tạo binary trên máy khác. Không cần C shim hay cgo.
    link: /vi/distribution
  - title: Đo hiệu năng đối chiếu với mygo
    details: Bộ benchmark headless so sánh từng cảnh với mygo và các lần chạy trước; chỉ giữ thay đổi khi số đo cho thấy cải thiện.
    link: /vi/ui/performance
---
