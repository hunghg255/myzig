---
layout: home

hero:
  name: myzig
  text: Ứng dụng desktop bằng Zig
  tagline: Giao diện native vẽ bằng GPU, hoặc frontend web trong webview của hệ thống. Một file chạy dưới một megabyte, trên macOS, Linux, Windows và trình duyệt.
  image:
    src: /logo.png
    alt: Logo của myzig
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
    details: Flexbox và grid, đủ bộ widget, chuyển động, shader và hỗ trợ tiếp cận. Mỗi frame là một lệnh vẽ instanced, với Metal, Direct3D 11, OpenGL hoặc WebGL 2.
    link: /vi/ui/README
  - title: Trang web với IPC có kiểu
    details: WKWebView, WebKitGTK hoặc WebView2 gọi Zig qua một client JavaScript sinh ra từ các kiểu Zig của bạn, kèm khai báo TypeScript, event và channel.
    link: /vi/bindings
  - title: CPU cho ra đúng những pixel đó
    details: Renderer CPU vẽ đúng những gì mọi renderer GPU vẽ, trên nhiều lõi. Mỗi shader được test đối chiếu với nó.
    link: /vi/ui/rendering
  - title: Test không cần cửa sổ
    details: ui.Tester render view ngoài màn hình. App thật chạy headless với --myzig-snapshot, --myzig-script và --myzig-eval.
    link: /vi/ui/testing
  - title: Build từ máy nào cũng được
    details: Thư viện của Linux và Windows được nạp lúc chạy chứ không link, nên -Dtarget build được binary cho chúng ở bất kỳ đâu. Không C shim, không cgo, không phải cài gì lúc build.
    link: /vi/distribution
  - title: Đo đối chiếu với mygo
    details: Hill climb chạy headless so từng cảnh với mygo và với các lần chạy trước. Một thay đổi chỉ được giữ khi nó leo lên.
    link: /vi/ui/performance
---
