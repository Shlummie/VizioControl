import type { AgentEvent } from './shared/types';

export function appendAgentEvent(events: AgentEvent[], event: AgentEvent) {
  if (event.type === 'idle') return [];
  if (event.type === 'preview') return events;
  return [...events, event].slice(-40);
}

export function activeAgentQuestion(events: AgentEvent[]) {
  const last = [...events].reverse().find((event) => event.type !== 'preview' && event.type !== 'idle');
  return last?.type === 'choiceRequired' || last?.type === 'confirmationRequired' ? last : undefined;
}

export function resolveAgentQuestion(events: AgentEvent[], requestId: string) {
  return events.filter((event) => !(
    (event.type === 'choiceRequired' || event.type === 'confirmationRequired')
    && event.requestId === requestId
  ));
}
