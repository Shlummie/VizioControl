import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const root = process.cwd();
const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'viziocontrol-builder-'));
const cli = path.join(root, 'node_modules', 'electron-builder', 'out', 'cli', 'cli.js');
const release = path.join(root, 'release');
const artifacts = ['VizioControl Setup 1.0.0.exe', 'VizioControl 1.0.0 Portable.exe'];

try {
  await run(process.execPath, [
    cli,
    '--win', 'nsis', 'portable',
    '--x64',
    `--config.directories.output=${temporary}`,
  ]);
  await run(process.execPath, [
    path.join(root, 'scripts', 'inspect-packaged-asar.mjs'),
    path.join(temporary, 'win-unpacked', 'resources', 'app.asar'),
  ]);
  await fs.mkdir(release, { recursive: true });
  for (const artifact of artifacts) {
    await fs.copyFile(path.join(temporary, artifact), path.join(release, artifact));
  }
} finally {
  await fs.rm(temporary, { recursive: true, force: true, maxRetries: 5, retryDelay: 250 });
}

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: root, stdio: 'inherit', windowsHide: true });
    child.once('error', reject);
    child.once('exit', (code) => code === 0 ? resolve() : reject(new Error(`Electron Builder exited with code ${code}.`)));
  });
}
