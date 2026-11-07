---
layout: home

hero:
  name: myzig
  text: Desktop apps in Zig
  tagline: Native UI drawn on the GPU, or a web frontend in the system webview. One binary under a megabyte, on macOS, Linux, Windows and browsers.
  image:
    src: /logo.png
    alt: The myzig logo
  actions:
    - theme: brand
      text: Get started
      link: /getting-started
    - theme: alt
      text: Native UI
      link: /ui/README
    - theme: alt
      text: Overview
      link: /README
    - theme: alt
      text: Architecture
      link: /architecture#architecture-at-a-glance

features:
  - title: Native UI in Zig alone
    details: Flexbox and grid, a full widget set, motion, shaders and accessibility. One instanced draw call per frame, with Metal, Direct3D 11, OpenGL or WebGL 2.
    link: /ui/README
  - title: Web pages with typed IPC
    details: WKWebView, WebKitGTK or WebView2 call Zig through a JavaScript client generated from your Zig types, with TypeScript declarations, events and channels.
    link: /bindings
  - title: The same pixels on the CPU
    details: The CPU renderer draws what every GPU renderer draws, on several cores. Each shader is tested against it.
    link: /ui/rendering
  - title: Tested without a window
    details: ui.Tester renders views offscreen. Real apps run headless with --myzig-snapshot, --myzig-script and --myzig-eval.
    link: /ui/testing
  - title: Builds from any machine
    details: Linux and Windows libraries are loaded, not linked, so -Dtarget builds their binaries anywhere. No C shims, no cgo, nothing to install at build time.
    link: /distribution
  - title: Measured against mygo
    details: The headless hill climb compares every scene with mygo and with earlier runs. A change is kept only when it climbs.
    link: /ui/performance
---
