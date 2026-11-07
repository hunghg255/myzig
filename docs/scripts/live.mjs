// Puts the demos `zig build docs-live` built into the site: public/live, the
// host, the app and its fonts, and the list of demos the pages may name. The
// site is built where there is no Zig, so these are committed, as the pictures
// of docs/images are.
import { copyFile, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';

const from = new URL('../../zig-out/docs-live/', import.meta.url);
const to = new URL('../public/live/', import.meta.url);

await rm(to, { recursive: true, force: true });
await mkdir(new URL('fonts/', to), { recursive: true });
for (const name of ['app.wasm', 'host.js', 'host_gl.js', 'host_wasi.js', 'fonts/fonts.json'])
  await copyFile(new URL(name, from), new URL(name, to));
for (const name of await readdir(new URL('fonts/', from)))
  if (name.endsWith('.ttf')) await copyFile(new URL(`fonts/${name}`, from), new URL(`fonts/${name}`, to));

// Each demo and the file its view is in, for its Source link: the demos of
// live_demos.zig, then the Gallery's pages of live_gallery.zig.
const dir = 'examples/gallery/';
const read = (name) => readFile(new URL(`../../${dir}${name}`, import.meta.url), 'utf8');
const demos = {};
for (const m of (await read('live_demos.zig')).matchAll(/^\s*entry\("([a-z-]+)",/gm)) demos[m[1]] = `${dir}live_demos.zig`;
const gallery = await read('live_gallery.zig');
const files = Object.fromEntries([...gallery.matchAll(/^const (\w+) = @import\("(\w+)\.zig"\)\.\w+;/gm)].map((m) => [m[1], m[2]]));
files.Basics = 'basics';
for (const m of gallery.matchAll(/^\s*gallery\("([a-z-]+)", (\w+),/gm)) {
  if (!files[m[2]]) throw new Error(`live_gallery.zig: which file is ${m[2]} in?`);
  demos[m[1]] = `${dir}${files[m[2]]}.zig`;
}
if (Object.keys(demos).length === 0) throw new Error('no demos in live_demos.zig');
await writeFile(new URL('demos.json', to), JSON.stringify(demos, null, 1) + '\n');
console.log(`docs/public/live: ${Object.keys(demos).length} demos`);
