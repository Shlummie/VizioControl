import { describe, expect, it } from 'vitest';
import type { AgentEvent } from '../src/shared/types';
import { activeAgentQuestion, appendAgentEvent, resolveAgentQuestion } from '../src/agentEvents';

describe('agent event lifecycle', () => {
  it('begins each semantic run by clearing old renderer history', () => {
    const old: AgentEvent[] = [{ type: 'acting', message: 'Old action', at: '2026-08-13T00:00:00Z' }];
    expect(appendAgentEvent(old, { type: 'idle', at: '2026-08-13T00:00:01Z' })).toEqual([]);
  });

  it('only treats the newest event as an active question', () => {
    const oldQuestion: AgentEvent = {
      type: 'confirmationRequired', requestId: 'old', reason: 'Old prompt', at: '2026-08-13T00:00:00Z',
    };
    const completed: AgentEvent = {
      type: 'completed', message: 'Done', at: '2026-08-13T00:00:01Z',
    };
    expect(activeAgentQuestion([oldQuestion, completed])).toBeUndefined();
    expect(activeAgentQuestion([completed, oldQuestion])).toEqual(oldQuestion);
  });

  it('removes an answered prompt before the IPC response returns', () => {
    const question: AgentEvent = {
      type: 'choiceRequired', requestId: 'question-1', question: 'Which?', options: ['A', 'B'], at: '2026-08-13T00:00:00Z',
    };
    expect(resolveAgentQuestion([question], 'question-1')).toEqual([]);
  });
});
