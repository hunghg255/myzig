# Rendering

A frame of native UI goes through four steps, the same in a window and in
a [Tester](testing.md) (`src/ui/frame.zig`):

1. **Build.** The view runs and opens boxes into the context's tree. When
   an interaction changes state (`c.changed`), the view is built again
   before anything is drawn, up to three more times, so the screen never
   lags the state.
2. **Layout.** Flexbox measures and arranges the tree (`layout.zig`); right
   to left, it is then [mirrored](right-to-left.md).
3. **Paint.** The tree becomes instances in paint order (`paint.zig`):
   quads that are rounded rectangles with borders, glyphs and icons from
   the glyph atlas, Gaussian shadows, and pictures from the image atlas,
   each clipped to a rectangle whose corners may be rounded. Boxes out of
   their clip are culled. Transforms, gradients, blurs and effects add rows
   of data after the instances (`gpu.Frame`).
4. **Draw.** A renderer draws the instances: on the GPU in one instanced
   draw call (split only where a backdrop effect or a blurred layer must
   read what is under it), or on the CPU.

## The renderers

Every renderer draws the same instances (`src/ui/gpu.zig`) with the same
shader, written once for Metal and translated line for line:

| Where | Renderer | Shader | Shown by |
|---|---|---|---|
| macOS | Metal (`metal.zig`), a ring of three instance buffers | `shader.metal`, compiled when the app starts | a `CAMetalLayer`, paced by the display link |
| Windows | Direct3D 11 (`d3d11.zig`), on a hardware device | `d3d11.hlsl`, compiled ahead of time into `d3d11.cso` (`zig run src/ui/d3d11_gen.zig`) | a DXGI flip model swap chain |
| Linux | OpenGL 3.3 core or OpenGL ES 3.0 (`gl.zig`), loaded at run time | `gl.glsl` | a GtkGLArea, at the frame clock's pace |
| Browsers | WebGL 2 (`webgl.zig`, the context held by `web/host_gl.js`) | `gl.glsl` in GLSL ES 3.0 | the window's canvas, in animation frames |
| Everywhere | the CPU renderer (`raster.zig`) | its own Zig, the same arithmetic | cairo on Linux, GDI on Windows, a 2D canvas in browsers |

The shader computes rounded rectangles, borders and shadows from the
distance to their edges, so they stay sharp at any size and scale.
Shadows are Gaussian, after GPUI's shader. Text comes from a glyph atlas
that grows as glyphs are needed and uploads only when it changes: glyphs
rasterized by CoreText on macOS, and by myzig's own TrueType reader
(`src/ui/tt/`) elsewhere. Icons are SF Symbols on macOS and line icons
drawn by myzig (`icons.zig`) elsewhere. Pictures are decoded once and
packed into a BGRA atlas (`images.zig`).

## The CPU twin

The CPU renderer draws the very pixels the GPU renderers draw: BGRA,
premultiplied, sRGB-encoded values blended as the GPU blends them. Each
GPU renderer is tested against it, offscreen, to a level or two of
blending's rounding:

- `src/ui/tests_raster.zig`: the CPU renderer against Metal, a frame of
  text, icons, borders, rounded corners and clips, shadows and a picture.
- `src/ui/d3d11_test.zig`: Direct3D 11 into a texture read back (skipped
  without Direct3D on a GPU).
- `src/ui/gl_test.zig`: OpenGL 3.3 and OpenGL ES 3.0 through EGL without a
  surface (skipped without EGL); `gl_gtk_test.zig` the GtkGLArea path.
- `src/ui/gpu_fx_test.zig`: what draws on the general path and between a
  frame's parts (random transforms of every kind, gradients, backdrop
  effects plain and with a shader, blurred layers), on every GPU renderer
  it finds. Plugins test their own effects with it (`ui.gpu_testing`).
- `src/ui/gpu_corners_test.zig`: continuous corners (fills, borders,
  shadows cut into nine-patches, pictures, gradients, clips) on every GPU
  renderer.
- Browsers: `src/web/test_browser.js` compares WebGL 2's pixels with the
  CPU renderer's in a headless Chromium.

Because the pixels are the same, a window that cannot draw on the GPU
shows the same frames drawn on the CPU, and a test's snapshot drawn on the
CPU is what the GPU shows.

The CPU renderer draws a frame in bands of 64 rows, on several cores when
the frame is large (threads started once, which wait between frames);
every pixel is what drawing it alone gives, so bands draw the same pixels
in any order. The clear skips what an opaque background drawn first
covers. Within an instance, what is the same
along a row or a column is found once, a solid fill is copied, and empty
texels are skipped (`raster_lanes.zig` does eight pixels at a time). Each
of these fast paths gives the very value the general path gives, and
`hillclimb --hash` checks that a faster renderer leaves every frame's
pixels as they were.

Backdrop effects ([frosted glass](transforms.md), [shaders](shaders.md))
and blurred layers draw between a frame's parts: the renderer reads what
it drew so far around the shape, blurs it (averaged down for large blurs,
then a Gaussian along rows and columns, rounded to 8 bits at each step as
textures hold them; `backdrop.zig`), and draws the box from it. The GPUs
do it in passes over textures (`metal_fx.zig`, `d3d11_fx.zig`,
`gl_fx.zig`), the CPU renderer with the same steps (`raster_fx.zig`), and
an effect's shader runs as HLSL, GLSL or Metal on the GPUs and as its CPU
twin (`Shader.cpu`) on the CPU.

## Choosing the renderer

- **macOS** draws with Metal. `zig build -Dportable=true` builds the
  text and CPU renderer of Linux and Windows instead, to test that path on
  a Mac.
- **Windows** makes a Direct3D 11 device on hardware with the first frame
  a window shows. Without one (no hardware device, or no swap chain), or once its device is lost, the window draws on the CPU and GDI
  copies the frame to it; the log says why (`myzig: no Direct3D (...)`).
- **Linux** draws with OpenGL in a GtkGLArea (GTK 3.16 and later) when a
  GPU is there. On a display-only DRM driver (virtual machines' and
  servers': `simpledrm`, `bochs`, `vboxvideo`, `hyperv_drm` and the like) it draws on the
  CPU, as Mesa's llvmpipe would be slower than myzig's CPU renderer, and
  cairo shows the frame. `MYZIG_GPU=0` keeps frames on the CPU,
  `MYZIG_GPU=1` draws with OpenGL even where it would not.
- **Browsers** draw with WebGL 2, or on the CPU into a 2D canvas where the
  browser has none (`start({ webgl: false })` forces it). A lost WebGL
  context draws again once the browser restores it.

## When frames are drawn

Nothing polls. A frame is built and drawn on input, on a resize, when the
app asks for one from outside the view, and while an animation runs
(`c.animating`): at the display's refresh on macOS (the display link), the
frame clock on Linux (a tick callback), a 60 Hz timer on Windows, and
`requestAnimationFrame` in browsers. An idle window draws nothing, and an
idle app uses no CPU. While a window is out of sight (on macOS hidden,
minimized, on another Space or covered by other windows, by its
`occlusionState`; in browsers a tab in the background), no frames are
drawn for it at all, until some of it shows again (see
[Out of sight](performance.md#out-of-sight)).

When a frame changes what is under a still pointer, another frame follows,
so hover follows content that moved.

## Frame costs

Each frame records its costs in `c.stats` (`ui.FrameStats`): the time to
build, lay out and paint in milliseconds, how many times the view was
built (`passes`), the boxes (`nodes`) and the renderer's `instances`. The
[inspector](inspector.md) shows them for the last 60 frames, and
[hillclimb](performance.md) measures them headless.
