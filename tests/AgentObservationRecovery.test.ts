import { describe, expect, it, vi } from 'vitest';
import { AgentController } from '../electron/services/AgentController';
import { SmartCastScreenUnavailableError } from '../electron/services/CdpObserver';

const settings = () => ({
  launchAtStartup: true,
  aiVisionEnabled: true,
  showPreview: true,
  alwaysStreamScreen: false,
  preferredProfile: '',
  manualAddress: '',
});

function activeRun() {
  return {
    abort: new AbortController(),
    startedAt: Date.now(),
    actionCount: 0,
    lastObservation: null,
    finish: null,
  };
}

describe('Luna SmartCast screen recovery', () => {
  it('turns an unobservable SmartCast Home screen into recoverable tool guidance', async () => {
    const observer = { observe: vi.fn().mockRejectedValue(new SmartCastScreenUnavailableError()) };
    const agent = new AgentController({} as never, observer as never, {} as never, {} as never, settings);
    const run = activeRun();
    const internal = agent as unknown as {
      active: unknown;
      handleTool(call: unknown, current: unknown): Promise<{ text: string; imageDataUrl?: string }>;
    };
    internal.active = run;

    const result = await internal.handleTool({ name: 'tv_observe', arguments: {} }, run);

    expect(result.text).toContain('Do not stop yet');
    expect(result.text).toContain('Hulu as the default');
    expect(result.imageDataUrl).toBeUndefined();
  });

  it('waits for the launched app screen before Luna continues', async () => {
    const launchApp = vi.fn();
    const notifyAppLaunch = vi.fn();
    const waitUntilAvailable = vi.fn().mockResolvedValue(true);
    const catalog = { resolve: vi.fn().mockResolvedValue({ appId: '3', namespace: 2, message: '', name: 'Hulu' }) };
    const agent = new AgentController(
      { launchApp } as never,
      { notifyAppLaunch, waitUntilAvailable } as never,
      catalog as never,
      {} as never,
      settings,
    );
    const run = activeRun();
    const internal = agent as unknown as {
      active: unknown;
      handleTool(call: unknown, current: unknown): Promise<{ text: string }>;
    };
    internal.active = run;

    const result = await internal.handleTool({ name: 'tv_launch_app', arguments: { name: 'Hulu' } }, run);

    expect(launchApp).toHaveBeenCalledWith({ appId: '3', namespace: 2, message: '', name: 'Hulu' });
    expect(notifyAppLaunch).toHaveBeenCalledOnce();
    expect(waitUntilAvailable).toHaveBeenCalledWith(run.abort.signal, 15_000);
    expect(result.text).toContain('screen is ready');
  });
});
