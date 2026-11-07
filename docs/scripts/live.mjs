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

const source = await readFile(new URL('../../examples/gallery/live_demos.zig', import.meta.url), 'utf8');
const demos = [...source.matchAll(/^\s*entry\("([a-z-]+)",/gm)].map((m) => m[1]);
if (demos.length === 0) throw new Error('no demos in live_demos.zig');
await writeFile(new URL('demos.json', to), JSON.stringify(demos) + '\n');
console.log(`docs/public/live: ${demos.join(', ')}`);
