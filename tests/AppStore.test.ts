import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { SavedButton } from '../src/shared/types';

vi.mock('electron', () => ({
  safeStorage: {
    isEncryptionAvailable: () => true,
    encryptString: (value: string) => Buffer.from(`protected:${[...value].reverse().join('')}`, 'utf8'),
    decryptString: (value: Buffer) => [...value.toString('utf8').replace(/^protected:/, '')].reverse().join(''),
  },
}));

import { AppStore } from '../electron/services/AppStore';

let directory = '';

beforeEach(async () => {
  directory = await fs.mkdtemp(path.join(os.tmpdir(), 'viziocontrol-store-'));
});

afterEach(async () => {
  await fs.rm(directory, { recursive: true, force: true });
});

describe('local persistence', () => {
  it('stores the TV token only in encrypted form', async () => {
    const store = new AppStore(directory);
    await store.load();
    await store.saveToken('top-secret-token');
    const stored = await fs.readFile(path.join(directory, 'tv-token.bin'));
    expect(stored.toString('utf8')).not.toContain('top-secret-token');
    expect(await store.readToken()).toBe('top-secret-token');
    expect(await fs.readFile(path.join(directory, 'viziocontrol.json'), 'utf8')).not.toContain('top-secret-token');
  });

  it('deduplicates, persists, reorders, deletes, and restores buttons', async () => {
    const store = new AppStore(directory);
    await store.load();
    await store.upsertButton(button('one', 'mute', 0));
    await store.upsertButton(button('duplicate-id', 'mute', 99));
    expect(store.buttons()).toHaveLength(1);
    expect(store.buttons()[0]).toMatchObject({ id: 'one', usageCount: 2, order: 0 });

    await store.upsertButton(button('two', 'open hulu', 1));
    await store.reorderButton('two', -1);
    expect(store.buttons().map((item) => item.id)).toEqual(['two', 'one']);
    await store.deleteButton('two');
    expect(store.buttons().map((item) => item.id)).toEqual(['one']);
    await store.undoDelete();
    expect(store.buttons().map((item) => item.id)).toEqual(['one', 'two']);

    const reloaded = new AppStore(directory);
    await reloaded.load();
    expect(reloaded.buttons()).toHaveLength(2);
  });

  it('removes obsolete Ollama settings while preserving current preferences', async () => {
    await fs.writeFile(path.join(directory, 'viziocontrol.json'), JSON.stringify({
      version: 1,
      settings: {
        launchAtStartup: false,
        aiVisionEnabled: true,
        showPreview: false,
        preferredProfile: 'TV',
        manualAddress: '192.168.50.42',
        localModel: 'qwen-heretic:latest',
      },
      device: null,
      buttons: [],
    }), 'utf8');
    const store = new AppStore(directory);
    await store.load();
    expect(store.snapshot()).toMatchObject({
      version: 2,
      settings: { launchAtStartup: false, showPreview: false, alwaysStreamScreen: false, preferredProfile: 'TV' },
    });
    expect(store.snapshot().settings).not.toHaveProperty('localModel');
    const persisted = await fs.readFile(path.join(directory, 'viziocontrol.json'), 'utf8');
    expect(persisted).not.toContain('qwen-heretic');
    expect(persisted).toContain('"alwaysStreamScreen": false');
  });

  it('persists the opt-in local screen stream setting without storing frame data', async () => {
    const store = new AppStore(directory);
    await store.load();
    await store.updateSettings({ alwaysStreamScreen: true });
    const persisted = await fs.readFile(path.join(directory, 'viziocontrol.json'), 'utf8');
    expect(store.snapshot().settings.alwaysStreamScreen).toBe(true);
    expect(persisted).toContain('"alwaysStreamScreen": true');
    expect(persisted).not.toContain('data:image');
  });
});

function button(id: string, normalizedRequest: string, order: number): SavedButton {
  const now = '2026-08-13T00:00:00.000Z';
  return {
    kind: 'macro', id, label: normalizedRequest, icon: 'sparkles', color: 'graphite', normalizedRequest,
    order, usageCount: 1, createdAt: now, updatedAt: now, actions: [{ type: 'key', key: 'mute' }],
  };
}
