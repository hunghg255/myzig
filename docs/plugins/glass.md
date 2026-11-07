# glass

Liquid Glass for native UI, after mygo's glass plugin, which measured
macOS 27's `NSGlassEffectView`. What is under a pane shows through it:

- frosted;
- bent near its edges, as through the rim of a lens;
- toned so that what is on it reads: lighter in light windows, darker in
  dark ones;
- lit along its hairline rim.

It also has a plain backdrop blur.

The package is `plugins/glass` (module `glass`). See
[Plugins](../plugins.md) for adding it to an app.

```zig
const glass = @import("glass");

fn view(s: *State, c: *ui.Context) void {
    // ... the content, which scrolls under the bar ...
    _ = glass.pane(c, .{ .radius = 22 }, .{ .absolute = true, .offset = .{ .x = 12, .y = 12 }, .padding = .all(8) });
    ui.text(c, "On glass", .{});
    c.end();
}
```

## Panes

`glass.pane(c, g, style)` opens a box and returns its id. `style` gives
its size, padding and place. Its children follow until `c.end()`. `g` is
a `glass.Glass`:

| field | default | |
|---|---|---|
| `style` | `.regular` | `.regular`, or `.clear`, which barely tones |
| `tint` | null | colors the glass toward a color, by its alpha, as a prominent button |
| `radius` | 16 | the corner radius, in DIPs |

`glass.paneOf(c, kind, style)` takes a `glass.Kind`: `.{ .glass = g }`, or
`.{ .blur = .{ .radius = 12, .corner = 8 } }` for a plain backdrop blur of
`radius` DIPs with rounded corners.

The material follows the pane's size as the last frame laid it out:

- Larger panes blur more, up to 10 DIPs.
- The bezel curves the last 36 DIPs, at most half the pane.
- The bezel bends what shows through by up to 1.6 times that.

## How it draws

A pane is a box with a backdrop effect (`ui.Style.effect`; see
[Transforms and effects](../ui/transforms.md)). Every renderer (Metal,
Direct3D 11, OpenGL, WebGL 2 and the CPU) does the same:

1. It reads what it drew under the pane and around it, and blurs it.
2. It draws the glass from that in the pane's place in paint order.
3. The pane's children draw after, on the glass, unfrosted.

The GPUs draw the glass's color with `src/glass.metal`, `src/glass.hlsl`
and `src/glass.glsl`. The CPU renderer uses their twin,
`pixels.glassColor`. Their pixels match within one level of 255:

- `ui.gpu_testing` compares each GPU renderer with the CPU one.
- The tests compare a pane's frame with `pixels.glass` drawn over the
  frame without it.

See [Rendering](../ui/rendering.md) for the CPU twin.

## What is here

- `glass.material`: the material, as mygo has it.
  `material.of(style, tint, w, h, scale, dark)` gives a `Material` in
  device pixels.
  - Regular glass maps black to 54% and white to 100% in light mode, and
    to 15% and 51% in dark mode.
  - The bezel's profile is Apple's squircle, bent through Snell's law.
  - It also has the rounded rectangle's distance and smoothed normal, and
    the tone curve.
- `glass.shader`: the material as an effect's parameters (`effectOf`),
  the glass's shader (its GPU sources and its CPU twin), and the plain
  blur (`blurOf`).
- `glass.pixels`: the effect on the CPU over any BGRA pixels
  (`glass.Image`). `pixels.glass(gpa, image, rect, radii, material)` and
  `pixels.blur(gpa, image, rect, radii, sigma)`.

<details>
<summary>How <code>glass.pixels</code> draws</summary>

1. The backdrop: the pixels under the shape, and around it as far as the
   blur reaches.
2. For large blurs, they are averaged over squares of 1 to 8 pixels.
3. A separable Gaussian blurs them. Each step rounds to 8 bits, as
   textures hold them. myzig's renderers read the backdrop the same way
   (`src/ui/backdrop.zig`).
4. Then, for each pixel of the shape: the lens's sample, toned, tinted
   and lit along the rim, antialiased along the edge.

</details>

## Left out

- mygo's `ScrollEdge` (soft and hard edges).
- The progressive blur along a mask.
- Interactive glass growing while pressed.
- Wide-gamut tints.
- Panes turned or slanted by a transform. The renderers draw effects in
  the window's axes: a pane moved, or scaled alike both ways, is drawn;
  one turned is not.

## Tests

```sh
cd plugins/glass
zig build test                              # the effect over pixels, panes through ui.Tester
zig build check -Dtarget=x86_64-linux-gnu   # type-check another platform
```
