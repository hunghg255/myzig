# Showcase

Apps built with myzig, all in [`examples/`](../examples). Each runs with
`zig build run-NAME` from the repository; the farm is a package of its
own (`cd examples/farm && zig build run`). The pictures are snapshots
taken offscreen with `--myzig-snapshot`.

## Apps

### Notes

![Notes: a sidebar of notes and a rich text editor with its toolbar.](images/showcase/notes.jpg)

Rich text notes: a toolbar of formats, Markdown shortcuts as you type,
links, and copying as Markdown. [Source](../examples/notes/main.zig)

### Documents

![Documents: a Markdown note being written, with its word count.](images/showcase/documents.jpg)

A Markdown and text editor on `myzig.Documents`: the File menu, a window
per note, autosave, and recovery after a crash.
[Source](../examples/documents/main.zig)

### Code editor

![The code editor: a file list, Zig code with syntax colors and line numbers.](images/showcase/code-editor.jpg)

Syntax colors, find and replace, go to line and wrapping, with a diff
viewer of the changes and a text area for notes.
[Source](../examples/code-editor/main.zig)

### Markdown chat

![A chat whose answer, Markdown with a code block, streams in.](images/showcase/markdown-chat.jpg)

A pretend assistant whose answers stream in as Markdown, parsed as they
come. [Source](../examples/markdown-chat/main.zig)

### Chat glow

![A dark chat answering a trip plan, its composer ringed by a glow.](images/showcase/chat-glow.jpg)

An assistant's chat drawn with shaders: the orb, the glowing composer,
the "Thinking…" shimmer and the window's edge.
[Source](../examples/chat-glow/main.zig)

### Piano

![A piano keyboard under buttons for four tunes.](images/showcase/piano.jpg)

Play with the mouse or the keyboard, or let it play a tune. Every note is
synthesized and played with `myzig.audio`.
[Source](../examples/piano/main.zig)

### Drag and drop

![Cards to drag and a drop zone in a window called Left.](images/showcase/drag-drop.jpg)

Notes, text, URLs and files dragged between two windows, out to other
apps and in from the file manager. [Source](../examples/drag-drop/main.zig)

### Clipboard

![A note to copy or drag as text, HTML or JSON.](images/showcase/clipboard.jpg)

One note copied and dragged as text, HTML and JSON, the JSON made only
when a receiver asks for it. [Source](../examples/clipboard/main.zig)

## Games and shaders

### Farm

![A farmer on a tilled path in a field of grass, with tools at the bottom.](images/showcase/farm.jpg)

A little farming game: till, plant, water and harvest as days turn to
night, with sound and music. It runs on the
[game plugin](plugins/game.md). [Source](../examples/farm/main.zig)

### Mayoi

![A girl on a dark street, static closing in from the edges.](images/showcase/mayoi.jpg)

A survival game on a street at night, drawn by a single shader. Walk with
the arrows, sing with Space. [Source](../examples/mayoi/main.zig)

### Black hole

![A black hole bending the light of its accretion disk.](images/showcase/blackhole.jpg)

Every pixel's ray traced back through the hole's gravity. Drag to orbit,
scroll to come nearer. [Source](../examples/blackhole/main.zig)

### Wind

![Characters drawn along the way the wind blows, around a text field.](images/showcase/wind.jpg)

A pane of characters stirred by the wind. Move the pointer to warm the
air; click to blow a ripple. [Source](../examples/wind/main.zig)

### Effort slider

![A dark card with a slider whose thumb is a brain.](images/showcase/effort-slider.jpg)

A slider from Low to Max, then past it into Galaxy, where the brain
bursts and the card shakes. [Source](../examples/effort-slider/main.zig)

### Confetti

![Confetti falling over a list of demos and a panel of sliders.](images/showcase/confetti.jpg)

canvas-confetti's demos in native UI, and bursts of your own from the
pointer. [Source](../examples/confetti/main.zig)

## Data, text and motion

### Streaming chart

![Three waveforms in green, red and blue.](images/showcase/chart-streaming.jpg)

Three waveforms of 15 000 samples, 1 000 new ones a second.
[Source](../examples/chart-streaming/main.zig)

### Loading indicators

![A grid of loading spinners with size and speed controls.](images/showcase/loading.jpg)

loading.dev's 29 indicators, with their size, color and easing.
[Source](../examples/loading/main.zig)

### Timeline

![A card titled A timeline with Restart, Pause, Play and Reverse.](images/showcase/timeline.jpg)

Several tweens on one playhead, played, paused and reversed together.
[Source](../examples/timeline/main.zig)

### Large text

![An editor showing lines of mixed English, Hebrew and Arabic text.](images/showcase/text-buffer.jpg)

100 000 editable lines in a rope; only the lines in view are laid out.
[Source](../examples/text-buffer/main.zig)

### A text field of your own

![A text field holding Latin, Hebrew and Arabic text.](images/showcase/text-input.jpg)

A text field built from myzig's text input primitives, with input
methods and the Edit menu. [Source](../examples/text-input/main.zig)

### Gestures

![The words Pinch demo, Scale and Pan, and a Zoom in button.](images/showcase/gestures.jpg)

Pan and pinch, handled before the scrolling box around them.
[Source](../examples/gestures/main.zig)

### Counter

![A large 0 above Increment and Reset buttons.](images/showcase/counter.jpg)

The smallest app: a view is a Zig function of the state.
[Source](../examples/counter/main.zig)

### Gallery

![The gallery: a sidebar of pages and cards of buttons, toggles and sliders.](images/showcase/gallery.jpg)

Every widget, page by page. Its pages run live throughout
[the Native UI docs](ui/README.md). [Source](../examples/gallery/main.zig)

## Web frontends

These show a web page in the system webview, so they have no offscreen
snapshot:

| App | |
|---|---|
| [hello](../examples/hello/main.zig) | a page calling Zig services, with typed events |
| [todo](../examples/todo/main.zig) | a complete app: persistence, dialogs, menus, windows kept in sync |
| [native](../examples/native/main.zig) | the menu bar, a tray icon, dialogs, notifications and the clipboard, from a page |
| [embed-webview](../examples/embed-webview/main.zig) | web pages in tabs inside a window of native UI |
