import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import * as asar from '@electron/asar';

const asarPath = process.argv[2];
if (!asarPath) throw new Error('Pass the packaged app.asar path.');

const files = asar.listPackage(asarPath);
const main = asar.extractFile(asarPath, 'dist-electron/main.cjs').toString('utf8');
const packageJson = JSON.parse(asar.extractFile(asarPath, 'package.json').toString('utf8'));
const forbidden = ['http://127.0.0.1:11434', 'Ollama', 'qwen-heretic', 'LocalAiService'];
const retired = forbidden.filter((marker) => (
  main.includes(marker)
  || JSON.stringify(packageJson).includes(marker)
  || files.some((file) => file.includes(marker))
));
if (retired.length) throw new Error(`Retired Ollama markers found: ${retired.join(', ')}`);

const required = [
  'gpt-5.6-luna',
  'CodexAppServerService',
  'remoteControl/disable',
  'commandExecution',
  'VizioControl allows TV tools only.',
  'http://127.0.0.1:5173/',
  'will-navigate',
  'buildCodexEnvironment',
  'verified turn identifier',
  'purchase, rental, subscription, authentication, profile/account, or destructive action',
];
const missing = required.filter((marker) => !main.includes(marker));
if (missing.length) throw new Error(`Required Luna security markers are missing: ${missing.join(', ')}`);
if (packageJson.dependencies?.['@openai/codex'] !== '0.147.0') throw new Error('The app does not pin @openai/codex 0.147.0.');

const codexExecutable = path.join(path.dirname(asarPath), 'codex', 'bin', 'codex.exe');
if (!existsSync(codexExecutable)) throw new Error('The packaged Codex App Server runtime is missing.');
const version = spawnSync(codexExecutable, ['--version'], { encoding: 'utf8', windowsHide: true });
if (version.status !== 0 || !version.stdout.includes('0.147.0')) throw new Error('The packaged Codex runtime version check failed.');

console.log(JSON.stringify({
  ok: true,
  files: files.length,
  retiredOllamaMarkersAbsent: true,
  exactModelMarker: 'gpt-5.6-luna',
  runtimeVersion: version.stdout.trim(),
  bundledRuntime: codexExecutable,
}));
