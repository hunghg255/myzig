# glass

Liquid Glass for native UI, after mygo's glass plugin (which measured
macOS 27's `NSGlassEffectView`): what is under a pane shows through it,
frosted, bent near its edges as through the rim of a lens, toned so that
what is on it reads (lighter in light windows, darker in dark ones), and
lit along its hairline rim. It also has a plain backdrop blur.

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

`glass.pane(c, g, style)` opens a box styled by `style` (its size,
padding, place) whose children follow until `c.end()`, and returns the
box's id. `g` is a `glass.Glass`:

| field | default | |
|---|---|---|
| `style` | `.regular` | `.regular`, or `.clear`, which barely tones |
| `tint` | null | colors the glass toward a color, by its alpha, as a prominent button |
| `radius` | 16 | the corner radius, in DIPs |

`glass.paneOf(c, kind, style)` takes a `glass.Kind`: `.{ .glass = g }`, or
`.{ .blur = .{ .radius = 12, .corner = 8 } }` for a plain backdrop blur of
`radius` DIPs with rounded corners.

The material follows the pane's size as the last frame laid it out: larger
panes blur more (up to 10 DIPs); the bezel curves the last 36 DIPs (at
most half the pane) and bends what shows through by up to 1.6 times that.

## How it draws

A pane is a box with a backdrop effect (`ui.Style.effect`; see
[Transforms and effects](../ui/transforms.md)). Every renderer (Metal,
Direct3D 11, OpenGL, WebGL 2 and the CPU) reads what it drew under the pane
and around it, blurs it, and draws the glass from it in the pane's place in
paint order, before the pane's children, which draw on the glass
unfrosted.

The GPUs draw the glass's color with `src/glass.metal`, `src/glass.hlsl`
and `src/glass.glsl`; the CPU renderer with its twin, `pixels.glassColor`.
Their pixels match within one level of 255: myzig's `ui.gpu_testing`
compares each GPU renderer with the CPU one, and the tests compare a pane's
frame with `pixels.glass` drawn over the frame without it. See
[Rendering](../ui/rendering.md) for the CPU twin.

## What is here

- `glass.material`: the material, as mygo has it. `material.of(style,
  tint, w, h, scale, dark)` gives a `Material` in device pixels: regular
  glass maps black to 54% and white to 100% in light mode, 15% and 51% in
  dark mode; the bezel's profile is Apple's squircle, bent through Snell's
  law. Also the rounded rectangle's distance and smoothed normal, and the
  tone curve.
- `glass.shader`: the material as an effect's parameters (`effectOf`),
  the glass's shader (its GPU sources and its CPU twin), and the plain
  blur (`blurOf`).
- `glass.pixels`: the effect on the CPU over any BGRA pixels
  (`glass.Image`): the backdrop (the pixels under the shape and around it
  as far as the blur reaches, averaged over squares of 1 to 8 pixels for
  large blurs, blurred by a separable Gaussian, rounded to 8 bits at each
  step as textures hold them; myzig's renderers read it the same way,
  `src/ui/backdrop.zig`), then for each pixel of the shape the lens's
  sample, toned, tinted and lit along the rim, antialiased along the edge.
  `pixels.glass(gpa, image, rect, radii, material)` and
  `pixels.blur(gpa, image, rect, radii, sigma)`.

## Left out

mygo's `ScrollEdge` (soft and hard edges), the progressive blur along a
mask, interactive glass growing while pressed, wide-gamut tints, and panes
turned or slanted by a transform (the renderers draw effects in the
window's axes: a pane moved, or scaled alike both ways, is drawn; one
turned is not).

## Tests

```sh
cd plugins/glass
zig build test                              # the effect over pixels, panes through ui.Tester
zig build check -Dtarget=x86_64-linux-gnu   # type-check another platform
```
