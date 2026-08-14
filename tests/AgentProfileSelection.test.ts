import { describe, expect, it, vi } from 'vitest';
import { AgentController, existingHuluProfileOptions } from '../electron/services/AgentController';

function makeRun() {
  return {
    abort: new AbortController(),
    startedAt: Date.now(),
    actionCount: 0,
    lastObservation: {
      title: 'Hulu',
      accessibility: 'heading: Who\'s watching?\nbutton: Viewer\nbutton: Add Profile',
      focusedText: '[FOCUSED] button: Viewer',
    },
    finish: null,
  };
}

function makeAgent(preferredProfile: string, remember = vi.fn(async () => undefined)) {
  const agent = new AgentController(
    {} as never,
    {} as never,
    {} as never,
    {} as never,
    () => ({ launchAtStartup: true, aiVisionEnabled: true, showPreview: true, alwaysStreamScreen: false, preferredProfile, manualAddress: '' }),
    remember,
  );
  return { agent, remember };
}

describe('Hulu profile selection', () => {
  it('filters account controls out of visible profile choices', () => {
    expect(existingHuluProfileOptions(
      'Who is watching?',
      ['Viewer', 'Kids', 'Add Profile', 'Manage Profiles'],
      null,
    )).toEqual(['Viewer', 'Kids']);
  });

  it('automatically selects and remembers the only existing Hulu profile', async () => {
    const { agent, remember } = makeAgent('');
    const run = makeRun();
    const choiceEvents: unknown[] = [];
    agent.on('event', (event) => {
      if (event.type === 'choiceRequired') choiceEvents.push(event);
    });
    const internal = agent as unknown as {
      active: unknown;
      handleTool(call: unknown, current: unknown): Promise<{ text: string }>;
    };
    internal.active = run;

    const result = await internal.handleTool({
      name: 'tv_request_choice',
      arguments: { question: 'Which Hulu profile should I use?', options: ['Viewer', 'Add Profile'] },
    }, run);

    expect(result.text).toContain('Viewer');
    expect(remember).toHaveBeenCalledWith('Viewer');
    expect(choiceEvents).toEqual([]);
  });

  it('asks once and remembers the answer when several profiles exist', async () => {
    const { agent, remember } = makeAgent('');
    const run = makeRun();
    agent.on('event', (event) => {
      if (event.type === 'choiceRequired') agent.answer(event.requestId, 'Kids');
    });
    const internal = agent as unknown as {
      active: unknown;
      handleTool(call: unknown, current: unknown): Promise<{ text: string }>;
    };
    internal.active = run;

    const result = await internal.handleTool({
      name: 'tv_request_choice',
      arguments: { question: 'Choose a Hulu profile', options: ['Viewer', 'Kids', 'Manage Profiles'] },
    }, run);

    expect(result.text).toContain('Kids');
    expect(remember).toHaveBeenCalledWith('Kids');
  });

  it('uses a matching remembered profile without asking again', async () => {
    const { agent, remember } = makeAgent('kids');
    const run = makeRun();
    const choiceEvents: unknown[] = [];
    agent.on('event', (event) => {
      if (event.type === 'choiceRequired') choiceEvents.push(event);
    });
    const internal = agent as unknown as {
      active: unknown;
      handleTool(call: unknown, current: unknown): Promise<{ text: string }>;
    };
    internal.active = run;

    const result = await internal.handleTool({
      name: 'tv_request_choice',
      arguments: { question: 'Choose a Hulu profile', options: ['Viewer', 'Kids'] },
    }, run);

    expect(result.text).toContain('Kids');
    expect(remember).not.toHaveBeenCalled();
    expect(choiceEvents).toEqual([]);
  });
});
