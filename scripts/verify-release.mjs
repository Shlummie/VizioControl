import { createHash } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const release = path.join(root, 'release');
const artifacts = ['VizioControl Setup 1.0.0.exe', 'VizioControl 1.0.0 Portable.exe'];
const sums = await fs.readFile(path.join(release, 'SHA256SUMS.txt'), 'utf8');
const result = [];
const retiredLocalAiMarkers = [
  'http://127.0.0.1:11434',
  'Ollama',
  'qwen-heretic',
  'LocalAiService',
];

let privateToken;
if (process.argv[2]) {
  const rundown = await fs.readFile(process.argv[2], 'utf8');
  privateToken = extractToken(rundown);
  if (!privateToken) throw new Error('Could not locate the private token for the leak check.');
}

for (const artifact of artifacts) {
  const file = path.join(release, artifact);
  const contents = await fs.readFile(file);
  const hash = createHash('sha256').update(contents).digest('hex');
  if (contents[0] !== 0x4d || contents[1] !== 0x5a) throw new Error(`${artifact} is not a Windows PE executable.`);
  if (!sums.includes(`${hash}  ${artifact}`)) throw new Error(`${artifact} does not match SHA256SUMS.txt.`);
  if (privateToken && contents.includes(Buffer.from(privateToken))) throw new Error(`${artifact} contains the private TV token.`);
  for (const marker of retiredLocalAiMarkers) {
    if (contents.includes(Buffer.from(marker))) throw new Error(`${artifact} contains retired local-AI marker ${marker}.`);
  }
  result.push({ artifact, bytes: contents.length, sha256: hash, tokenAbsent: Boolean(privateToken), retiredLocalAiMarkersAbsent: true });
}

console.log(JSON.stringify({ ok: true, artifacts: result }));

function extractToken(value) {
  return [
    /(?:AUTH_TOKEN|AUTH|authentication token|auth token)\s*(?:is|:|=)\s*[`'\"]?([A-Za-z0-9._~-]{8,})/i,
    /[`'\"]AUTH[`'\"]\s*:\s*[`'\"]([A-Za-z0-9._~-]{8,})/i,
  ].map((pattern) => value.match(pattern)?.[1]).find(Boolean)
    ?? value.split(/\r?\n/)
      .filter((line) => /auth|token/i.test(line))
      .flatMap((line) => line.match(/[A-Fa-f0-9]{12,}/g) ?? [])
      .sort((left, right) => right.length - left.length)[0];
}
