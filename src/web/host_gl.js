// The WebGL 2 side of myzig's renderer in browsers (`src/ui/webgl.zig`):
// a window's canvas, its program (the shaders the app hands over, gl.glsl),
// the instance buffer, the two atlases and the frame's rows. A frame is
// one instanced draw, four vertices a quad, six vec4s an instance,
// premultiplied alpha; or, with backdrop effects and blurred layers, draws
// in parts with the passes of gl_fx.glsl between them, as the app plans
// them (`webgl.zig`'s `Plan`).

const stride = 96;
const planFloats = 48;

export class GL {
  /// WebGL 2 on `canvas`, or null where the browser has none. Its drawing
  /// buffer keeps what was drawn, so that frames draw only what changed
  /// (`damage.zig`), and its pixels keep their alpha (frames are opaque, but a blurred layer is drawn on
  /// its cleared, transparent area before it goes over what was there).
  static create(canvas, onLost, onRestored) {
    const attrs = { alpha: true, antialias: false, depth: false, stencil: false, premultipliedAlpha: true, preserveDrawingBuffer: true };
    const gl = canvas.getContext("webgl2", attrs);
    if (!gl) return null;
    const g = new GL(canvas, gl);
    canvas.addEventListener("webglcontextlost", (e) => { e.preventDefault(); g.lost = true; onLost?.(); });
    canvas.addEventListener("webglcontextrestored", () => {
      g.lost = false;
      if (g.sources) g.init(...g.sources);
      onRestored?.();
    });
    return g;
  }

  constructor(canvas, gl) {
    this.canvas = canvas;
    this.gl = gl;
    this.lost = false;
    this.sources = null;
    this.fx = null;
  }

  shader(type, source) {
    const gl = this.gl;
    const s = gl.createShader(type);
    gl.shaderSource(s, source);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error("myzig: shader: " + gl.getShaderInfoLog(s));
    return s;
  }

  link(vs, fs) {
    const gl = this.gl;
    const p = gl.createProgram();
    gl.attachShader(p, this.shader(gl.VERTEX_SHADER, vs));
    gl.attachShader(p, this.shader(gl.FRAGMENT_SHADER, fs));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error("myzig: program: " + gl.getProgramInfoLog(p));
    return p;
  }

  texture() {
    const gl = this.gl;
    const t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    for (const [k, v] of [[gl.TEXTURE_MIN_FILTER, gl.NEAREST], [gl.TEXTURE_MAG_FILTER, gl.NEAREST], [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]]) gl.texParameteri(gl.TEXTURE_2D, k, v);
    return t;
  }

  /// Compiles and links the shaders; false when they fail.
  init(vs, fs) {
    this.sources = [vs, fs];
    const gl = this.gl;
    try {
      this.program = this.link(vs, fs);
    } catch (e) {
      console.warn(String(e));
      return false;
    }
    const p = this.program;
    this.u = Object.fromEntries(["frame", "atlas", "images", "rows"].map((n) => [n, gl.getUniformLocation(p, n)]));
    this.vao = gl.createVertexArray();
    gl.bindVertexArray(this.vao);
    this.buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer);
    for (let i = 0; i < 6; i++) {
      gl.enableVertexAttribArray(i);
      gl.vertexAttribPointer(i, 4, gl.FLOAT, false, stride, i * 16);
      gl.vertexAttribDivisor(i, 1);
    }
    this.base = 0;
    gl.bindVertexArray(null);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    // Empty until the app sends them: never sampled then.
    this.atlas = this.texture();
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, 1, 1, 0, gl.RED, gl.UNSIGNED_BYTE, new Uint8Array(1));
    this.images = this.texture();
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(4));
    this.imagesSide = 0;
    this.rows = this.texture();
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA32F, 1, 1, 0, gl.RGBA, gl.FLOAT, new Float32Array(4));
    this.rowsHeight = 0;
    this.fxVao = null;
    this.layers = [];
    if (this.fx) this.fx.programs = new Map();
    return true;
  }

  /// The glyph atlas, one byte a texel.
  setAtlas(pixels, size, row0, row1) {
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.atlas);
    if (this.atlasSize !== size) {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, size, size, 0, gl.RED, gl.UNSIGNED_BYTE, pixels);
      this.atlasSize = size;
      return;
    }
    // Only the rows whose glyphs changed.
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, row0, size, row1 - row0, gl.RED, gl.UNSIGNED_BYTE, pixels.subarray(row0 * size, row1 * size));
  }

  /// Rows of the image atlas, BGRA: uploaded as RGBA, swizzled by the shader.
  setImages(pixels, side, row0, row1) {
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.images);
    if (this.imagesSide !== side) {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, side, side, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
      this.imagesSide = side;
      return;
    }
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, row0, side, row1 - row0, gl.RGBA, gl.UNSIGNED_BYTE, pixels.subarray(row0 * side * 4, row1 * side * 4));
  }

  /// The passes' source (gl_fx.glsl), the effect pass's entry and the
  /// plain effect's color; programs are made when first needed.
  setFx(source, main, plain) {
    this.fx = { source, main, plain, colors: new Map(), programs: new Map() };
  }

  /// An effect's `effect_color`, by the index the app gave it.
  setEffect(index, color) {
    if (!this.fx) return;
    this.fx.colors.set(index, color);
    this.fx.programs.delete("effect" + index);
  }

  /// Draws a frame whole, or only within `part` ([x0, y0, x1, y1], rows
  /// from the top), keeping what the canvas holds elsewhere.
  draw(instances, count, width, height, scale, r, g, b, plans, part) {
    if (this.lost) return;
    const gl = this.gl;
    const c = this.canvas;
    if (c.width !== width) c.width = width;
    if (c.height !== height) c.height = height;
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, width, height);
    this.part = part;
    this.scissor(height);
    gl.clearColor(r, g, b, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (count === 0) return gl.disable(gl.SCISSOR_TEST);
    // A frame with rows ends with a trailer that says where they start.
    const f = new Float32Array(instances.buffer, instances.byteOffset, count * 24);
    let drawn = count;
    let rows = null;
    if (f[(count - 1) * 24 + 22] === 15) {
      drawn = f[(count - 1) * 24];
      rows = f.subarray(drawn * 24, (count - 1) * 24);
    }
    gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer);
    gl.bufferData(gl.ARRAY_BUFFER, instances.subarray(0, drawn * stride), gl.STREAM_DRAW);
    if (rows && rows.length > 0) this.uploadRows(rows);
    const frame = { width, height, scale };
    this.bindMain(frame);
    let start = 0;
    for (let p = 0; p + planFloats <= plans.length; p += planFloats) {
      const plan = plans.subarray(p, p + planFloats);
      const at = plan[1];
      this.drawRange(start, at);
      this.pass(frame, plan);
      this.bindMain(frame);
      start = at + 1;
    }
    this.drawRange(start, drawn);
    gl.bindVertexArray(null);
    gl.disable(gl.SCISSOR_TEST);
  }

  /// The scissor test on, to the frame's part, when it draws in part.
  scissor(height) {
    const gl = this.gl;
    const p = this.part;
    if (!p) return gl.disable(gl.SCISSOR_TEST);
    gl.enable(gl.SCISSOR_TEST);
    gl.scissor(p[0], height - p[3], p[2] - p[0], p[3] - p[1]);
  }

  bindMain(f) {
    const gl = this.gl;
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, f.width, f.height);
    this.scissor(f.height);
    gl.useProgram(this.program);
    gl.bindVertexArray(this.vao);
    gl.uniform3f(this.u.frame, f.width, f.height, f.scale);
    const units = [["atlas", this.atlas], ["images", this.images], ["rows", this.rows]];
    units.forEach(([name, t], i) => {
      gl.activeTexture(gl.TEXTURE0 + i);
      gl.bindTexture(gl.TEXTURE_2D, t);
      gl.uniform1i(this.u[name], i);
    });
    gl.activeTexture(gl.TEXTURE0);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
  }

  /// Instances [from, to): the attributes point at `from`.
  drawRange(from, to) {
    if (to <= from) return;
    const gl = this.gl;
    if (this.base !== from) {
      gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer);
      for (let i = 0; i < 6; i++) gl.vertexAttribPointer(i, 4, gl.FLOAT, false, stride, from * stride + i * 16);
      this.base = from;
    }
    gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, to - from);
  }

  /// The frame's rows, 1024 a texture row.
  uploadRows(rows) {
    const gl = this.gl;
    const n = rows.length / 4;
    const full = Math.floor(n / 1024), rest = n % 1024;
    const height = full + (rest > 0 ? 1 : 0);
    gl.bindTexture(gl.TEXTURE_2D, this.rows);
    if (height > this.rowsHeight) {
      this.rowsHeight = Math.max(height, this.rowsHeight * 2, 1);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA32F, 1024, this.rowsHeight, 0, gl.RGBA, gl.FLOAT, null);
    }
    if (full > 0) gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 1024, full, gl.RGBA, gl.FLOAT, rows.subarray(0, full * 4096));
    if (rest > 0) gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, full, rest, 1, gl.RGBA, gl.FLOAT, rows.subarray(full * 4096));
  }

  /// A pass's program: "down", "blur", "layer", "clear", "plain" or "effectN".
  fxProgram(name) {
    const fx = this.fx;
    let p = fx.programs.get(name);
    if (p !== undefined) return p;
    const head = "#version 300 es\n";
    const effect = name.startsWith("effect") || name === "plain";
    const define = effect ? "#define EFFECT 1\n" : `#define ${name.toUpperCase()} 1\n`;
    const color = name === "plain" ? fx.plain : effect ? fx.colors.get(Number(name.slice(6))) : "";
    try {
      const id = this.link(head + "#define VERTEX 1\n" + fx.source, head + define + fx.source + (effect ? color + fx.main : ""));
      p = { id, fx: this.gl.getUniformLocation(id, "fx"), src: this.gl.getUniformLocation(id, "src") };
    } catch (e) {
      console.warn(String(e));
      p = name === "plain" ? null : this.fxProgram("plain");
    }
    fx.programs.set(name, p);
    return p;
  }

  /// A texture of w × h drawn into, and its framebuffer.
  target(w, h) {
    const gl = this.gl;
    const tex = this.texture();
    w = Math.max(w, 1);
    h = Math.max(h, 1);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    const fb = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
    return { tex, fb, w, h };
  }

  drop(t) {
    this.gl.deleteFramebuffer(t.fb);
    this.gl.deleteTexture(t.tex);
  }

  /// Pixels [x0, y0, x1, y1) of the frame (rows from the top) into `t`,
  /// its rows from the top too.
  copyFrom(f, t, a) {
    const gl = this.gl;
    gl.bindFramebuffer(gl.READ_FRAMEBUFFER, null);
    gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, t.fb);
    gl.blitFramebuffer(a[0], f.height - a[3], a[2], f.height - a[1], 0, t.h, t.w, 0, gl.COLOR_BUFFER_BIT, gl.NEAREST);
  }

  /// `t` back into pixels [x0, y0, x1, y1) of the frame: drawn, as WebGL
  /// blits into the canvas only from a buffer of its very format.
  copyTo(f, t, a) {
    const u = new Float32Array(48);
    u.set([a[0], a[1], a[2] - a[0], a[3] - a[1]]);
    this.run("layer", t.tex, null, f.width, f.height, u, false);
  }

  /// One pass: `k` the uniforms (12 vec4s), into texture `dst` or the frame.
  run(name, src, dst, w, h, k, blend) {
    const gl = this.gl;
    const p = this.fxProgram(name);
    if (!p) return;
    k[44] = w;
    k[45] = h;
    k[46] = dst ? 0 : 1;
    gl.bindFramebuffer(gl.FRAMEBUFFER, dst ? dst.fb : null);
    gl.viewport(0, 0, w, h);
    gl.useProgram(p.id);
    gl.uniform4fv(p.fx, k);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, src);
    gl.uniform1i(p.src, 0);
    if (blend) {
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    } else gl.disable(gl.BLEND);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  /// An effect's or a layer's passes, as `plan` says (webgl.zig's Plan).
  pass(f, plan) {
    if (!this.fx) return;
    const gl = this.gl;
    // Passes draw into textures too: not scissored to the frame's part.
    gl.disable(gl.SCISSOR_TEST);
    this.fxVao ||= gl.createVertexArray();
    gl.bindVertexArray(this.fxVao);
    const kind = plan[0];
    const a = [plan[3], plan[4], plan[5], plan[6]];
    const area = [a[0], a[1], a[2] - a[0], a[3] - a[1]];
    const sigma = plan[14], radius = plan[15];
    if (kind === 4) {
      const b = [plan[7], plan[8], plan[9], plan[10]];
      const tw = plan[11], th = plan[12], down = plan[13];
      const copy = this.target(b[2] - b[0], b[3] - b[1]);
      this.copyFrom(f, copy, b);
      const t0 = this.target(tw, th), t1 = this.target(tw, th);
      const u = new Float32Array(48);
      u.set([0, 0, tw, th, down, sigma, radius, 0, 0, 0, copy.w, copy.h]);
      this.run("down", copy.tex, t0, tw, th, u, false);
      if (radius > 0) {
        u.set([1, 0, tw, th], 8);
        this.run("blur", t0.tex, t1, tw, th, u, false);
        u.set([0, 1, tw, th], 8);
        this.run("blur", t1.tex, t0, tw, th, u, false);
      }
      const e = new Float32Array(48);
      e.set(area, 0);
      e.set([down, sigma, radius, 0], 4);
      e.set(plan.subarray(16, 28), 12);
      e.set(plan.subarray(32, 48), 24);
      e.set([b[0], b[1], tw, th], 40);
      this.run(plan[2] >= 0 ? "effect" + plan[2] : "plain", t0.tex, null, f.width, f.height, e, true);
      [copy, t0, t1].forEach((t) => this.drop(t));
    } else if (kind === 6) {
      const kept = this.target(area[2], area[3]);
      if (area[2] > 0 && area[3] > 0) {
        this.copyFrom(f, kept, a);
        const u = new Float32Array(48);
        u.set(area, 0);
        this.run("clear", null, null, f.width, f.height, u, false);
      }
      this.layers.push({ kept, a });
    } else {
      const l = this.layers.pop();
      if (!l) return;
      if (area[2] > 0 && area[3] > 0) {
        const layer = this.target(area[2], area[3]);
        this.copyFrom(f, layer, l.a);
        if (radius > 0) {
          const t = this.target(area[2], area[3]);
          const u = new Float32Array(48);
          u.set([0, 0, area[2], area[3], 1, sigma, radius, 1, 1, 0, area[2], area[3]]);
          this.run("blur", layer.tex, t, area[2], area[3], u, false);
          u.set([0, 1, area[2], area[3]], 8);
          this.run("blur", t.tex, layer, area[2], area[3], u, false);
          this.drop(t);
        }
        this.copyTo(f, l.kept, l.a);
        const u = new Float32Array(48);
        u.set(area, 0);
        this.run("layer", layer.tex, null, f.width, f.height, u, true);
        this.drop(layer);
      }
      this.drop(l.kept);
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  }

  /// The pixels just drawn, RGBA from the top row (tests).
  read() {
    const gl = this.gl;
    const w = this.canvas.width, h = this.canvas.height;
    const px = new Uint8Array(w * h * 4);
    gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px);
    const out = new Uint8Array(px.length);
    for (let y = 0; y < h; y++) out.set(px.subarray((h - 1 - y) * w * 4, (h - y) * w * 4), y * w * 4);
    return { width: w, height: h, rgba: out };
  }
}
