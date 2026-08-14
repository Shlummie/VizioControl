import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('electron', () => ({
  safeStorage: {
    isEncryptionAvailable: () => true,
    encryptString: (value: string) => Buffer.from(value),
    decryptString: (value: Buffer) => value.toString('utf8'),
  },
}));

import { RemoteController } from '../electron/services/RemoteController';
import type { AgentFinish } from '../electron/services/AgentController';
import type { PairedDevice, TvState } from '../src/shared/types';

let directory = '';

beforeEach(async () => {
  directory = await fs.mkdtemp(path.join(os.tmpdir(), 'viziocontrol-learned-macro-'));
});

afterEach(async () => {
  await fs.rm(directory, { recursive: true, force: true });
});

describe('learned macro replay', () => {
  it('converts a successful Luna setting workflow into a local macro and bypasses Luna thereafter', async () => {
    const controller = new RemoteController(directory);
    await controller.store.load();
    await controller.store.setDevice(pairedDevice());
    const agentRun = vi.fn(async (): Promise<AgentFinish> => ({
      status: 'success',
      summary: 'Picture brightness verified at 50.',
      label: 'Picture brightness 50',
      actions: [{ type: 'setSetting', setting: 'pictureBrightness', value: 50 }],
    }));
    const setSetting = vi.fn(async () => 50);
    const internals = controller as unknown as {
      tvState: TvState;
      tv: { setSetting: typeof setSetting };
      agent: { run: typeof agentRun };
    };
    internals.tvState = readyState();
    internals.tv.setSetting = setSetting;
    internals.agent.run = agentRun;
    vi.spyOn(controller, 'refreshTvState').mockResolvedValue(readyState());

    const first = await controller.runRequest('Set picture brightness to 50');
    expect(first.ok).toBe(true);
    expect(first.savedButton).toMatchObject({
      kind: 'macro',
      normalizedRequest: 'set picture brightness to 50',
      actions: [{ type: 'setSetting', setting: 'pictureBrightness', value: 50 }],
    });
    expect(agentRun).toHaveBeenCalledOnce();

    await controller.updateSettings({ aiVisionEnabled: false });
    const second = await controller.runRequest('SET picture brightness to 50!');
    expect(second.message).toContain('Luna was not used');
    expect(setSetting).toHaveBeenCalledOnce();
    expect(agentRun).toHaveBeenCalledOnce();

    const stored = JSON.parse(await fs.readFile(path.join(directory, 'viziocontrol.json'), 'utf8')) as {
      buttons: Array<Record<string, unknown>>;
    };
    expect(stored.buttons[0]).toMatchObject({ kind: 'macro', usageCount: 2 });
    expect(stored.buttons[0]).not.toHaveProperty('prompt');
    await controller.shutdown();
  });
});

function readyState(): TvState {
  return { connected: true, power: true, volume: 50, muted: false, currentApp: 'Hulu', address: '192.168.50.42' };
}

function pairedDevice(): PairedDevice {
  return {
    id: 'c8599ce74c872bfd',
    name: 'LIVING ROOM TV',
    address: '192.168.50.42',
    model: 'TEST-MODEL',
    serial: '14LINID4PZ06139',
    fingerprint: 'AA:BB',
    macAddress: '02:11:22:33:44:55',
    deviceId: 'client-id',
    pairedAt: '2026-08-13T00:00:00.000Z',
  };
}
