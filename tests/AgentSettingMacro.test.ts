import { describe, expect, it, vi } from 'vitest';
import { AgentController } from '../electron/services/AgentController';

function activeRun() {
  return {
    abort: new AbortController(),
    startedAt: Date.now(),
    actionCount: 0,
    lastObservation: null,
    finish: null,
    learnedActions: [],
    macroEligible: true,
  };
}

function controller(tv: Record<string, unknown>) {
  return new AgentController(
    tv as never,
    {} as never,
    {} as never,
    {} as never,
    () => ({ launchAtStartup: true, aiVisionEnabled: true, showPreview: true, alwaysStreamScreen: false, preferredProfile: '', manualAddress: '' }),
  );
}

describe('Luna setting macro learning', () => {
  it('records only a host-verified setting write and returns it when Luna explicitly teaches a macro', async () => {
    const setSetting = vi.fn(async () => '60 minutes');
    const agent = controller({ setSetting });
    const run = activeRun();
    const internal = agent as unknown as {
      active: unknown;
      handleTool(call: unknown, current: unknown): Promise<{ text: string }>;
    };
    internal.active = run;

    await internal.handleTool({
      name: 'tv_set_setting',
      arguments: { setting: 'sleepTimer', value: '60 minutes' },
    }, run);
    await internal.handleTool({
      name: 'tv_finish',
      arguments: { status: 'success', summary: 'Sleep timer set.', label: 'Sleep in 60', saveAsMacro: true },
    }, run);

    expect(setSetting).toHaveBeenCalledWith('sleepTimer', '60 minutes');
    expect(run.finish).toMatchObject({
      status: 'success',
      actions: [{ type: 'setSetting', setting: 'sleepTimer', value: '60 minutes' }],
    });
  });

  it('records a bounded relative brightness adjustment as a reusable local action', async () => {
    const adjustSetting = vi.fn(async () => ({ before: 35, value: 45 }));
    const agent = controller({ adjustSetting });
    const run = activeRun();
    const internal = agent as unknown as {
      active: unknown;
      handleTool(call: unknown, current: unknown): Promise<{ text: string }>;
    };
    internal.active = run;

    await internal.handleTool({
      name: 'tv_adjust_setting',
      arguments: { setting: 'screenBrightness', delta: 10 },
    }, run);
    await internal.handleTool({
      name: 'tv_finish',
      arguments: { status: 'success', summary: 'Screen brightness increased.', saveAsMacro: true },
    }, run);

    expect(adjustSetting).toHaveBeenCalledWith('screenBrightness', 10);
    expect(run.finish).toMatchObject({
      actions: [{ type: 'adjustSetting', setting: 'screenBrightness', delta: 10 }],
    });
  });

  it('refuses to learn a workflow that also entered text or used visual navigation', async () => {
    const setSetting = vi.fn(async () => 50);
    const typeText = vi.fn(async () => undefined);
    const agent = controller({ setSetting, typeText });
    const run = activeRun();
    const internal = agent as unknown as {
      active: unknown;
      handleTool(call: unknown, current: unknown): Promise<{ text: string }>;
    };
    internal.active = run;

    await internal.handleTool({ name: 'tv_type_text', arguments: { text: 'Family Guy' } }, run);
    await internal.handleTool({
      name: 'tv_set_setting',
      arguments: { setting: 'pictureBrightness', value: 50 },
    }, run);
    await internal.handleTool({
      name: 'tv_finish',
      arguments: { status: 'success', summary: 'Done.', saveAsMacro: true },
    }, run);

    expect(run.finish).not.toHaveProperty('actions');
  });

  it('rejects unknown settings and illegal timer values before a TV write', async () => {
    const setSetting = vi.fn();
    const agent = controller({ setSetting });
    const run = activeRun();
    const internal = agent as unknown as {
      active: unknown;
      handleTool(call: unknown, current: unknown): Promise<unknown>;
    };
    internal.active = run;

    await expect(internal.handleTool({
      name: 'tv_set_setting',
      arguments: { setting: 'factoryReset', value: true },
    }, run)).rejects.toThrow();
    await expect(internal.handleTool({
      name: 'tv_set_setting',
      arguments: { setting: 'sleepTimer', value: '45 minutes' },
    }, run)).rejects.toThrow();
    expect(setSetting).not.toHaveBeenCalled();
  });
});
