# glass

Liquid Glass for myzig apps of native UI, after mygo's
[glass plugin](../../../mygo/docs/plugins/glass.md) (macOS 27's
NSGlassEffectView, measured): what is under a pane shows through it,
frosted, bent near its edges as through the rim of a lens, toned so that
what is on it reads (lighter in light windows, darker in dark ones), and
lit along its hairline rim; and a plain backdrop blur.

```zig
const glass = @import("glass");

fn view(s: *State, c: *ui.Context) void {
    // ... the content, which scrolls under the bar ...
    _ = glass.pane(c, .{ .radius = 22 }, .{ .absolute = true, .offset = .{ .x = 12, .y = 12 }, .padding = .all(8) });
    ui.text(c, "On glass", .{});
    c.end();
}
```

A pane is a box with a backdrop effect (myzig's `Style.effect`,
`src/ui/effect.zig`): every renderer (Metal, Direct3D 11, OpenGL, WebGL 2
and the CPU) reads what it drew under the pane and around it, blurs it,
and draws the glass from it in the pane's place in paint order, before the
pane's children, which draw on the glass unfrosted. The GPUs draw the
glass's color with `glass.hlsl`, `glass.glsl` and `glass.metal`; the CPU
renderer with its twin, `pixels.glassColor`. Their pixels match within a
level of 255 (myzig's `gpu_fx_test.zig` compares them, and a pane's frame
with `pixels.glass` drawn over the frame without it).

## What is here

- `material.zig`: the material, as mygo has it: `material.of(style, tint,
  w, h, scale, dark)` (regular glass maps black to 54% and white to 100%
  in light mode, 15% and 51% in dark mode; `.clear` barely tones; larger
  panes blur more, up to 10 DIPs; the bezel curves the last 36 DIPs, at
  most half the pane, and bends what shows through by up to 1.6 times
  that, through Apple's squircle profile and Snell's law), the rounded
  rectangle's distance and smoothed normal, and the tone curve.
- `shader.zig`: the material as an effect's parameters (`effectOf`), the
  glass's shader (its GPU sources and its CPU twin), and the plain blur
  (`blurOf`).
- `pixels.zig`: the effect on the CPU, mygo's CPU twin: the backdrop
  (the pixels under the shape and around it as far as the blur reaches,
  averaged over squares of 1 to 8 pixels for large blurs, blurred by a
  separable Gaussian, rounded to 8 bits at each step as textures hold
  them; myzig's renderers read it the same way, `src/ui/backdrop.zig`),
  then for each pixel of the shape the lens's sample, toned, tinted and
  lit along the rim, antialiased along the edge. `pixels.glass(gpa,
  image, rect, radii, material)` and `pixels.blur(gpa, image, rect, radii,
  sigma)` draw over any BGRA pixels.
- `pane.zig`: panes in views. `glass.pane` (or `paneOf` with `.blur`)
  opens a box whose children draw on the glass; its material follows the
  pane's size as the last frame laid it out.

```sh
zig build test                              # the effect over pixels, panes through ui.Tester
zig build check -Dtarget=x86_64-linux-gnu   # type-check another platform
```

## Left out

mygo's `ScrollEdge` (soft and hard edges), the progressive blur along a
mask (`Blur.Mask`, its levels), interactive glass growing while pressed,
wide-gamut tints, and panes turned or slanted by a transform (myzig's
renderers draw effects in the window's axes: a pane moved or scaled alike
both ways is drawn, one turned is not).
