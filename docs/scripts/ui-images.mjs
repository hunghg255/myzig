// Losslessly compress the offscreen PNGs. Only the IDAT encoding changes;
// dimensions, filter bytes, colors and alpha remain exactly as rendered.
import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { deflateSync, inflateSync } from 'node:zlib';

const source = new URL('../../zig-out/docs-ui/', import.meta.url);
const destination = new URL('../images/ui/', import.meta.url);
const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++)
      crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function idat(data) {
  const chunk = Buffer.alloc(data.length + 12);
  chunk.writeUInt32BE(data.length);
  chunk.write('IDAT', 4, 'ascii');
  data.copy(chunk, 8);
  chunk.writeUInt32BE(crc32(chunk.subarray(4, -4)), chunk.length - 4);
  return chunk;
}

function compress(png) {
  if (!png.subarray(0, 8).equals(signature)) throw new Error('Invalid PNG signature');
  const chunks = [];
  const imageData = [];
  for (let offset = 8; offset < png.length;) {
    const length = png.readUInt32BE(offset);
    const end = offset + length + 12;
    if (end > png.length) throw new Error('Truncated PNG chunk');
    const type = png.toString('ascii', offset + 4, offset + 8);
    const chunk = png.subarray(offset, end);
    if (crc32(chunk.subarray(4, -4)) !== chunk.readUInt32BE(chunk.length - 4))
      throw new Error(`Invalid ${type} checksum`);
    chunks.push({ type, bytes: chunk });
    if (type === 'IDAT') imageData.push(chunk.subarray(8, -4));
    offset = end;
  }
  const raw = inflateSync(Buffer.concat(imageData));
  const packed = deflateSync(raw, { level: 9 });
  if (!inflateSync(packed).equals(raw)) throw new Error('PNG bytes changed');
  const output = [signature];
  let written = false;
  for (const chunk of chunks) {
    if (chunk.type !== 'IDAT') output.push(chunk.bytes);
    else if (!written) {
      output.push(idat(packed));
      written = true;
    }
  }
  return Buffer.concat(output);
}

await mkdir(destination, { recursive: true });
// Optional filenames update just the guides whose widgets changed.
const requested = new Set(process.argv.slice(2));
const files = (await readdir(source))
  .filter(name => name.endsWith('.png') && (!requested.size || requested.has(name)))
  .sort();
if (!files.length) throw new Error('No matching PNGs; run zig build docs-ui first');
for (const name of requested)
  if (!files.includes(name)) throw new Error(`No rendered image: ${name}`);
let original = 0;
let compressed = 0;
for (const name of files) {
  const png = await readFile(new URL(name, source));
  const output = compress(png);
  await writeFile(new URL(name, destination), output);
  original += png.length;
  compressed += output.length;
}
console.log(`${files.length} PNGs: ${(original / 1048576).toFixed(1)} MiB → ${(compressed / 1048576).toFixed(2)} MiB`);
console.log(fileURLToPath(destination));
