import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { CodexAppServerService, resolveBundledCodexExecutable } from '../electron/services/CodexAppServerService';

const temporaryDirectories: string[] = [];

afterEach(async () => {
  for (const directory of temporaryDirectories.splice(0)) {
    await fs.rm(directory, { recursive: true, force: true, maxRetries: 3 });
  }
});

describe('pinned Codex App Server runtime', () => {
  it('starts over stdio with strict isolated configuration and no shared history', async () => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'tv-luna-runtime-'));
    temporaryDirectories.push(directory);
    const service = new CodexAppServerService(directory, resolveBundledCodexExecutable());
    const internal = service as unknown as { ensureStarted(): Promise<void> };
    try {
      await internal.ensureStarted();
      const config = await fs.readFile(path.join(directory, 'luna-codex-home', 'config.toml'), 'utf8');
      expect(config).toContain('forced_login_method = "chatgpt"');
      expect(config).toContain('cli_auth_credentials_store = "keyring"');
      expect(config).toContain('history.persistence = "none"');
      expect(config).toContain('web_search = "disabled"');
      expect(config).not.toMatch(/api[_-]?key/i);
    } finally {
      await service.shutdown();
    }
  }, 30_000);
});
