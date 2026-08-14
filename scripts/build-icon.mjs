import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import pngToIco from 'png-to-ico';
import sharp from 'sharp';

const root = process.cwd();
const source = path.join(root, 'build', 'icon.svg');
const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'tv-icon-'));
const sizes = [16, 24, 32, 48, 64, 128, 256];

try {
  const pngs = await Promise.all(sizes.map(async (size) => {
    const output = path.join(temporary, `tv-${size}.png`);
    await sharp(source).resize(size, size).png().toFile(output);
    return output;
  }));
  await sharp(source).resize(512, 512).png().toFile(path.join(root, 'build', 'icon.png'));
  await fs.writeFile(path.join(root, 'build', 'icon.ico'), await pngToIco(pngs));
} finally {
  await fs.rm(temporary, { recursive: true, force: true });
}
