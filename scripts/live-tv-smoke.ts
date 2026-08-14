import { promises as fs } from 'node:fs';
import path from 'node:path';
import { AppCatalog } from '../electron/services/AppCatalog';
import { CdpObserver } from '../electron/services/CdpObserver';
import { parseDeviceInfo, SmartCastClient } from '../electron/services/SmartCastClient';

const rundownPath = process.argv[2];
if (!rundownPath) throw new Error('Pass the verified TV rundown file path.');
const rundown = await fs.readFile(rundownPath, 'utf8');
const address = rundown.match(/\b(?:10|192\.168|172\.(?:1[6-9]|2\d|3[01]))(?:\.\d{1,3}){2}\b/)?.[0];
const token = extractToken(rundown);
if (!address || !token) throw new Error('The rundown did not contain a usable private address and auth token.');

const client = new SmartCastClient(address);
const fingerprint = await client.getCertificateFingerprint();
client.setFingerprint(fingerprint);
client.setToken(token);

const rawDeviceInfo = await client.getDeviceInfo();
const device = parseDeviceInfo(rawDeviceInfo);
const before = await client.getState();
if (!before.connected) throw new Error(before.error || 'TV did not answer the live state check.');

let volumeNoOp = 'skipped';
const audioBefore = await client.getAudioState().catch(() => ({ volume: null, muted: null }));
if (audioBefore.volume !== null) {
  await client.setVolume(audioBefore.volume);
  const after = await client.getAudioState();
  if (after.volume !== audioBefore.volume) throw new Error(`Volume changed unexpectedly from ${audioBefore.volume} to ${after.volume}.`);
  volumeNoOp = `verified at ${after.volume}`;
}

const catalog = new AppCatalog();
const hulu = await catalog.resolve('Hulu');
if (hulu.appId !== '3' || hulu.namespace !== 2) throw new Error('Hulu did not resolve to the verified SmartCast launch identity.');
await client.launchApp(hulu);
await delay(3500);

let visualTarget: { available: boolean; title?: string; port?: number } = { available: false };
const observer = new CdpObserver(address);
try {
  const observation = await observer.observe();
  visualTarget = { available: true, title: observation.title, port: observation.port };
  if (!observation.dataUrl.startsWith('data:image/jpeg;base64,')) throw new Error('CDP did not return an in-memory JPEG observation.');
} catch {
  visualTarget = { available: false };
} finally {
  observer.disconnect();
}

await assertSecretAbsent(process.cwd(), token);
console.log(JSON.stringify({
  device: { name: device.name ?? 'TV', model: device.model ?? null },
  connected: before.connected,
  power: before.power,
  volumeNoOp,
  huluLaunch: { appId: hulu.appId, namespace: hulu.namespace },
  visualTarget,
  tokenLeakCheck: 'passed',
}));

function extractToken(value: string) {
  const explicit = [
    /(?:AUTH_TOKEN|AUTH|authentication token|auth token)\s*(?:is|:|=)\s*[`'\"]?([A-Za-z0-9._~-]{8,})/i,
    /[`'\"]AUTH[`'\"]\s*:\s*[`'\"]([A-Za-z0-9._~-]{8,})/i,
  ].map((pattern) => value.match(pattern)?.[1]).find(Boolean);
  if (explicit) return explicit;
  const candidates = value.split(/\r?\n/)
    .filter((line) => /auth|token/i.test(line))
    .flatMap((line) => line.match(/[A-Fa-f0-9]{12,}/g) ?? [])
    .sort((left, right) => right.length - left.length);
  return candidates[0];
}

async function assertSecretAbsent(root: string, secret: string) {
  const ignored = new Set(['.git', 'node_modules', 'dist', 'dist-electron', 'release']);
  const visit = async (directory: string): Promise<void> => {
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
      if (ignored.has(entry.name)) continue;
      const fullPath = path.join(directory, entry.name);
      if (entry.isDirectory()) await visit(fullPath);
      else if ((await fs.stat(fullPath)).size < 2_000_000) {
        const content = await fs.readFile(fullPath).catch(() => Buffer.alloc(0));
        if (content.includes(Buffer.from(secret))) throw new Error(`Private TV token leaked into ${path.relative(root, fullPath)}.`);
      }
    }
  };
  await visit(root);
}

function delay(milliseconds: number) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
