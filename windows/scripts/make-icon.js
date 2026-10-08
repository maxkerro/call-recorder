// Draws the app icon (red rounded square, white sound bars) as PNG + ICO with no dependencies.
const fs = require('fs');
const zlib = require('zlib');
const path = require('path');

function png(size) {
  const px = Buffer.alloc(size * size * 4);
  const r = size * 0.21, m = size * 0.04;
  const inside = (x, y) => {
    const cx = Math.min(Math.max(x, m + r), size - m - r), cy = Math.min(Math.max(y, m + r), size - m - r);
    return x >= m && x <= size - m && y >= m && y <= size - m && (x - cx) ** 2 + (y - cy) ** 2 <= r * r;
  };
  const heights = [0.21, 0.41, 0.6, 0.41, 0.21];
  const bw = size * 0.078, gap = size * 0.059;
  const total = heights.length * bw + (heights.length - 1) * gap;
  const bar = (x, y) => {
    let bx = (size - total) / 2;
    for (const h of heights) {
      const hh = h * size, top = (size - hh) / 2;
      const c1 = [bx + bw / 2, top + bw / 2], c2 = [bx + bw / 2, top + hh - bw / 2];
      if (x >= bx && x <= bx + bw) {
        if (y >= c1[1] && y <= c2[1]) return true;
        if ((x - c1[0]) ** 2 + (y - c1[1]) ** 2 <= (bw / 2) ** 2 || (x - c2[0]) ** 2 + (y - c2[1]) ** 2 <= (bw / 2) ** 2) return true;
      }
      bx += bw + gap;
    }
    return false;
  };
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    const o = (y * size + x) * 4;
    if (!inside(x + 0.5, y + 0.5)) continue;
    const white = bar(x + 0.5, y + 0.5);
    px[o] = white ? 255 : 219; px[o + 1] = white ? 255 : 31; px[o + 2] = white ? 255 : 46; px[o + 3] = 255;
  }
  const raw = Buffer.alloc((size * 4 + 1) * size);
  for (let y = 0; y < size; y++) { raw[y * (size * 4 + 1)] = 0; px.copy(raw, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4); }
  const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = (b) => { let c = 0xffffffff; for (const v of b) c = crcTable[(c ^ v) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (t, d) => { const len = Buffer.alloc(4); len.writeUInt32BE(d.length); const td = Buffer.concat([Buffer.from(t), d]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(td)); return Buffer.concat([len, td, c]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

const out = path.join(__dirname, '..', 'assets');
fs.mkdirSync(out, { recursive: true });
const big = png(256);
fs.writeFileSync(path.join(out, 'icon.png'), big);
// ICO with one embedded 256x256 PNG
const head = Buffer.alloc(22);
head.writeUInt16LE(0, 0); head.writeUInt16LE(1, 2); head.writeUInt16LE(1, 4);
head[6] = 0; head[7] = 0; head.writeUInt16LE(1, 10); head.writeUInt16LE(32, 12);
head.writeUInt32LE(big.length, 14); head.writeUInt32LE(22, 18);
fs.writeFileSync(path.join(out, 'icon.ico'), Buffer.concat([head, big]));
console.log('icons written');
