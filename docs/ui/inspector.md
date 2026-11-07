# Inspector

A developer's panel docked at the right of a window of native UI, like a
browser's developer tools. It shows the view's tree of boxes, the box
chosen or under the pointer, and how long the last frames took
(`src/ui/inspector.zig`, after mygo's).

```zig
const App = struct {
    count: i64 = 0,
    inspector: ui.Inspector = .{},

    fn view(s: *App, c: *ui.Context) void {
        {
            const col = ui.div(c).column().sizeFull().center().gap(12);
            defer col.end();
            ui.textf(c, .{ .size = 40, .weight = .bold }, "{d}", .{s.count});
            if (ui.button(c, "Increment", .{ .variant = .primary }).clicked) s.count += 1;
        }
        ui.inspector(c, &s.inspector); // last
    }
};
```

An app opts in: it keeps the inspector's state and builds it last in the
view, over the boxes built before it.

## Opening it

| Keys | What they do |
|---|---|
| F12, or Alt+Cmd+I on macOS and Ctrl+Shift+I elsewhere | opens and closes the panel |
| Shift+Cmd+C (Ctrl+Shift+C) | opens it picking a box, or stops picking |
| Escape | stops picking |

- The panel takes 340 points at the right of the window. The content gets
  the rest, as padding on the window's root box.
- Right to left, it docks at the left, where the mirrored content leaves
  it room.
- The panel itself always reads left to right.

## What it shows

- **The toolbar.** **Pick** chooses the box under the pointer. A cover
  over the content takes the click, so it goes to the inspector, not the
  box. **RTL** lays the window out [right to left](right-to-left.md) or
  back, to try an interface before it is translated. **Close**.
- **Performance.** The last frame's build, layout and paint times in
  milliseconds, its boxes, the renderer's instances, and how many times
  the view was built (passes). A bar for each of the last 60 frames
  against a refresh at 60 Hz (16.7 ms), red when slower. These are the
  context's `FrameStats` (`c.stats`); see [Performance](performance.md).
- **The tree.** Every box of the frame, indented by depth and named by
  what it is: `Text "…"`, `Icon name`, `Image`, or `Row`, `Column`,
  `Scroll` and `Pressable` with their children's count. It is a virtual
  [list](lists.md), so thousands of boxes stay fast. Hovering a row
  outlines its box; clicking chooses it.
- **The details** of the box hovered, else the one chosen:
  - rectangle, padding, gap, width and height, grow, alignment;
  - direction: its own layout direction and its reading direction;
  - background, border, radius, opacity and offset;
  - flags: `scroll`, `absolute`, `clip`, `follow_end`, `selectable`,
    `control`, interactive, focused;
  - what it holds: its text with font and color, its icon, its picture;
  - its id.

The box hovered or chosen is outlined over the content as browsers do:
padding in green, the content box in blue, its size beside it.

## In builds

The inspector is part of debug builds only. In release builds
`ui.Inspector` is an empty struct and `ui.inspector` does nothing. The
calls stay in the code and cost a release nothing. myzig's build option
`inspector` overrides that either way:

```sh
zig build -Doptimize=ReleaseFast -Dinspector=true   # in myzig's own examples
```

and in an app's `build.zig`, through the dependency:

```zig
const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize, .inspector = true }).module("myzig");
```

Code that keeps the state and calls `ui.inspector` compiles the same in
every build: nothing needs to be guarded.

## Pages

Windows of web pages have the webview's own inspector instead:

- Safari's Web Inspector on macOS;
- WebKitGTK's on Linux;
- Edge's developer tools on Windows.

`PageOptions.inspectable` (on by default) allows it, and the page's
`openDevTools` opens it (see [Pages](../pages.md)).

`src/ui/tests_inspector.zig` tests opening, picking, choosing and the
right-to-left toggle through a [Tester](testing.md).
