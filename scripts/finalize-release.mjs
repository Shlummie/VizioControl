import { createHash } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const release = path.join(root, 'release');
const artifacts = [
  'VizioControl Setup 1.0.0.exe',
  'VizioControl 1.0.0 Portable.exe',
];

const lines = [];
for (const name of artifacts) {
  const contents = await fs.readFile(path.join(release, name));
  lines.push(`${createHash('sha256').update(contents).digest('hex')}  ${name}`);
}
await fs.copyFile(path.join(root, 'OPERATING_GUIDE.md'), path.join(release, 'OPERATING_GUIDE.md'));
await fs.writeFile(path.join(release, 'SHA256SUMS.txt'), `${lines.join('\r\n')}\r\n`, 'utf8');
console.log(lines.join('\n'));
