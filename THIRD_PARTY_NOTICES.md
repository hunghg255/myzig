# Third-party notices

myzig's own source code is licensed under the MIT License in
[`LICENSE`](LICENSE). The material below keeps its own copyright and license.

## mygo

myzig began as a port of the core of [mygo](https://github.com/egoist/mygo)
to Zig, Copyright (c) 2026 MyGo contributors, and then of the rest of it
(as of mygo `9c05b11`): its platforms' backends, pages and IPC, native UI's
widgets, renderers, text, accessibility, the CLI, the plugins, the examples
and the documentation, written again in Zig. It keeps mygo's architecture:
the Objective-C runtime called directly, runtime classes for delegates, a
batched outbox with one evaluation per main-loop turn, events held until the
page is ready, a generated typed client, and native UI drawn by the framework.
mygo's MIT license, with its permission and warranty notice, is kept verbatim
in [`third_party/licenses/mygo-MIT.txt`](third_party/licenses/mygo-MIT.txt)
(as of mygo
[`269e2f9`](https://github.com/egoist/mygo/tree/269e2f9aca82b742f67497e467a95f6adb54bf5d)).

The loading plugin (`plugins/loading`) and gallery (`examples/loading`) additionally port the example
and indicator designs from mygo commit
`6725e0d4ef2970dc41ba151f5c2d5bd909cbe278` (PR #538). This is an
loading update; the rest of the port keeps the baseline above. Native UI
also follows mygo's hidden window controls (#553) and pinch input (#601),
reviewed through upstream `976f17c9391fb86f9afeba7a2d3b27b54e6d671a`.
Its loading.dev shapes, path data and timing functions retain Jakub
Krehel's MIT notice in [plugins/loading/NOTICE.md](plugins/loading/NOTICE.md).

## GPUI

myzig's native UI follows designs from
[GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui), part of
Zed, Copyright 2022–2025 Zed Industries, Inc.:
- elements styled by method chains (`src/ui/div.zig`);
- the virtualized `uniform_list` (`src/ui/list.zig`);
- layouts cached across frames, with glyphs rasterized once into an atlas;
- Gaussian shadows (`src/ui/shader.metal`, `src/ui/raster.zig`).

GPUI is licensed under the Apache License 2.0, whose text is kept verbatim in
[`third_party/licenses/GPUI-Apache-2.0.txt`](third_party/licenses/GPUI-Apache-2.0.txt).

## go-mp3

The MP3 decoder's Huffman code tables and synthesis window
(`src/audio/mp3_tables.zig`) come from
[go-mp3](https://github.com/hajimehoshi/go-mp3) (v0.3.4), Copyright 2017
Hajime Hoshi, which has them from the ISO reference decoder. go-mp3 is
licensed under the Apache License 2.0, kept verbatim in
[`third_party/licenses/go-mp3-Apache-2.0.txt`](third_party/licenses/go-mp3-Apache-2.0.txt).
The rest of the MP3 and Ogg Vorbis decoders is written from the
specifications (the Vorbis I specification gives the inverse dB table in
`src/audio/vorbis_floor.zig`).

## The terminal plugin

`plugins/terminal` loads, at run time, builds of
[libghostty-vt](https://github.com/ghostty-org/ghostty) (Ghostty, MIT
License, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors) and
of [OpenConsole's ConPTY](https://github.com/microsoft/terminal) (Windows
Terminal, MIT License, Copyright (c) Microsoft Corporation), which apps
ship beside them with those notices. Its themes
(`plugins/terminal/src/themes_*.zig`) are Ghostty's, from
[iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes)
(MIT License), whose notice the theme files keep.
