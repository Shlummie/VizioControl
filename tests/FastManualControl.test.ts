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

import { optimisticTvStateForKey, RemoteController } from '../electron/services/RemoteController';
import type { PairedDevice, TvState } from '../src/shared/types';

let directory = '';

beforeEach(async () => {
  directory = await fs.mkdtemp(path.join(os.tmpdir(), 'viziocontrol-fast-control-'));
});

afterEach(async () => {
  await fs.rm(directory, { recursive: true, force: true });
});

describe('fast manual controls', () => {
  it('sends a cached-connected navigation key without a blocking state refresh or follow-up poll', async () => {
    const controller = new RemoteController(directory);
    await controller.store.load();
    await controller.store.setDevice(pairedDevice());
    const internals = controller as unknown as {
      tvState: TvState;
      lastIdentityVerifiedAt: number;
      tv: { pressKey: ReturnType<typeof vi.fn> };
      postCommandRefreshTimer: NodeJS.Timeout | null;
    };
    internals.tvState = readyState();
    internals.lastIdentityVerifiedAt = Date.now() - 10 * 60_000;
    internals.tv.pressKey = vi.fn(async () => undefined);
    const refresh = vi.spyOn(controller, 'refreshTvState');

    await expect(controller.pressKey('right')).resolves.toMatchObject({ connected: true, power: true });
    expect(internals.tv.pressKey).toHaveBeenCalledWith('right', 1);
    expect(refresh).not.toHaveBeenCalled();
    expect(internals.postCommandRefreshTimer).toBeNull();
    await controller.shutdown();
  });

  it('sets volume without a blocking stale-state refresh', async () => {
    const controller = new RemoteController(directory);
    await controller.store.load();
    await controller.store.setDevice(pairedDevice());
    const internals = controller as unknown as {
      tvState: TvState;
      lastIdentityVerifiedAt: number;
      tv: { setVolume: ReturnType<typeof vi.fn> };
    };
    internals.tvState = readyState();
    internals.lastIdentityVerifiedAt = 0;
    internals.tv.setVolume = vi.fn(async () => undefined);
    const refresh = vi.spyOn(controller, 'refreshTvState');

    await expect(controller.setVolume(61)).resolves.toMatchObject({ volume: 61, muted: false });
    expect(internals.tv.setVolume).toHaveBeenCalledWith(61);
    expect(refresh).not.toHaveBeenCalled();
    await controller.shutdown();
  });

  it('updates mute and volume state optimistically', () => {
    expect(optimisticTvStateForKey(readyState(), 'mute')).toMatchObject({ muted: true });
    expect(optimisticTvStateForKey(readyState(), 'volumeDown', 3)).toMatchObject({ volume: 47, muted: false });
  });

  it('retains the wake path when the cached state is offline', async () => {
    const controller = new RemoteController(directory);
    await controller.store.load();
    await controller.store.setDevice(pairedDevice());
    const offline: TvState = { connected: false, power: null, volume: null, muted: null, currentApp: null, address: '192.168.50.42' };
    const internals = controller as unknown as { tvState: TvState; wakeDevice: (device: PairedDevice) => Promise<TvState> };
    internals.tvState = offline;
    vi.spyOn(controller, 'refreshTvState').mockResolvedValue(offline);
    const wake = vi.spyOn(internals, 'wakeDevice').mockResolvedValue(readyState());

    await expect(controller.pressKey('powerOn')).resolves.toMatchObject({ connected: true, power: true });
    expect(wake).toHaveBeenCalledOnce();
    await controller.shutdown();
  });

  it('verifies Quick Start before sending an explicit standby command', async () => {
    const controller = new RemoteController(directory);
    await controller.store.load();
    await controller.store.setDevice(pairedDevice());
    const internals = controller as unknown as {
      tvState: TvState;
      tv: {
        ensureQuickStartPowerMode: ReturnType<typeof vi.fn>;
        pressKey: ReturnType<typeof vi.fn>;
      };
    };
    internals.tvState = readyState();
    internals.tv.ensureQuickStartPowerMode = vi.fn(async () => ({ changed: true, value: 'Quick Start' }));
    internals.tv.pressKey = vi.fn(async () => undefined);

    await expect(controller.pressKey('powerToggle')).resolves.toMatchObject({ power: false });
    expect(internals.tv.ensureQuickStartPowerMode).toHaveBeenCalledOnce();
    expect(internals.tv.pressKey).toHaveBeenCalledWith('powerOff', 1);
    expect(internals.tv.ensureQuickStartPowerMode.mock.invocationCallOrder[0])
      .toBeLessThan(internals.tv.pressKey.mock.invocationCallOrder[0]);
    await controller.shutdown();
  });

  it('leaves the TV on when Quick Start cannot be verified', async () => {
    const controller = new RemoteController(directory);
    await controller.store.load();
    await controller.store.setDevice(pairedDevice());
    const internals = controller as unknown as {
      tvState: TvState;
      tv: {
        ensureQuickStartPowerMode: ReturnType<typeof vi.fn>;
        pressKey: ReturnType<typeof vi.fn>;
      };
    };
    internals.tvState = readyState();
    internals.tv.ensureQuickStartPowerMode = vi.fn(async () => { throw new Error('unsupported'); });
    internals.tv.pressKey = vi.fn(async () => undefined);

    await expect(controller.pressKey('powerOff')).rejects.toThrow('TV stayed on');
    expect(internals.tv.pressKey).not.toHaveBeenCalled();
    expect(internals.tvState.power).toBe(true);
    await controller.shutdown();
  });

  it('runs the opt-in 24 FPS stream only while the viewport is visible', async () => {
    const controller = new RemoteController(directory);
    await controller.store.load();
    await controller.store.setDevice(pairedDevice());
    const internals = controller as unknown as {
      observer: {
        startStream: ReturnType<typeof vi.fn>;
        stopStream: ReturnType<typeof vi.fn>;
        emit: (event: string, value: unknown) => void;
      };
    };
    internals.observer.startStream = vi.fn();
    internals.observer.stopStream = vi.fn();

    await controller.updateSettings({ alwaysStreamScreen: true });
    expect(internals.observer.startStream).toHaveBeenCalledWith(24);
    await expect(controller.bootstrap()).resolves.toMatchObject({
      settings: { alwaysStreamScreen: true, showPreview: true },
      screenStream: { enabled: true, status: 'connecting', targetFps: 24 },
    });
    internals.observer.emit('streamState', { status: 'live', title: 'Hulu' });
    await controller.updateSettings({ preferredProfile: 'L' });
    expect(internals.observer.startStream).toHaveBeenCalledTimes(1);
    await expect(controller.bootstrap()).resolves.toMatchObject({
      screenStream: { enabled: true, status: 'live', targetFps: 24, title: 'Hulu' },
    });

    await controller.updateSettings({ showPreview: false });
    expect(internals.observer.stopStream).toHaveBeenCalled();
    await expect(controller.bootstrap()).resolves.toMatchObject({
      screenStream: { enabled: true, status: 'off', targetFps: 24 },
    });
    expect(await fs.readFile(path.join(directory, 'viziocontrol.json'), 'utf8')).not.toContain('data:image');
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
