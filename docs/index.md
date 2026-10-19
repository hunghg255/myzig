---
layout: home

hero:
  name: myzig
  text: Desktop apps in Zig
  tagline: Native UI drawn on the GPU, or a web frontend in the system webview. Single binaries of under a megabyte, on macOS, Linux, Windows and browsers.
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

features:
  - title: Native UI in Zig alone
    details: Flexbox and grid layout, a full widget set, motion, shaders and accessibility, drawn in one instanced draw call per frame with Metal, Direct3D 11, OpenGL or WebGL 2.
    link: /ui/README
  - title: Web pages with typed IPC
    details: WKWebView, WebKitGTK or WebView2, calling Zig through a JavaScript client generated from your Zig types, with TypeScript declarations, events and channels.
    link: /bindings
  - title: The same pixels on the CPU
    details: myzig's CPU renderer draws what every GPU renderer draws, on several cores, and is the twin each shader is tested against.
    link: /ui/rendering
  - title: Tested without a window
    details: ui.Tester renders views offscreen; real apps run headless with --myzig-snapshot, --myzig-script and --myzig-eval.
    link: /ui/testing
  - title: Builds from any machine
    details: Linux and Windows libraries are loaded, not linked, so -Dtarget makes their binaries anywhere. No C shims, no cgo, nothing to install at build time.
    link: /distribution
  - title: Measured against mygo
    details: The headless hill climb compares every scene with mygo and with earlier runs; changes are kept only when they climb.
    link: /ui/performance
---
