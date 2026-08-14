import { describe, expect, it } from 'vitest';
import { shouldClearCommittedFrame, unavailableViewportCopy } from '../src/screenPreviewState';

describe('screen preview unavailable state', () => {
  it('clears a stale continuous-stream frame but preserves a Luna observation', () => {
    expect(shouldClearCommittedFrame('unavailable', 'localStream')).toBe(true);
    expect(shouldClearCommittedFrame('unavailable', 'agentObservation')).toBe(false);
    expect(shouldClearCommittedFrame('live', 'localStream')).toBe(false);
  });

  it('describes the current retry without declaring an app permanently unsupported', () => {
    expect(unavailableViewportCopy('Prime Video')).toEqual({
      title: 'Prime Video is not sending a preview yet.',
      detail: 'VizioControl is retrying automatically. The next valid frame will resume immediately; manual controls still work.',
    });
    expect(unavailableViewportCopy('SmartCast app 1').title).toBe('Waiting for a capturable TV screen.');
  });
});
