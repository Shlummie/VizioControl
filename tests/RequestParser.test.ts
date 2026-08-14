import { describe, expect, it } from 'vitest';
import { normalizeRequest, parseRequest } from '../electron/services/RequestParser';

describe('request parser', () => {
  it('normalizes duplicate requests consistently', () => {
    expect(normalizeRequest('  Open   HULU!! ')).toBe('open hulu');
  });

  it('turns direct commands into local macros', () => {
    expect(parseRequest('mute')).toMatchObject({
      kind: 'macro',
      normalized: 'mute',
      actions: [{ type: 'key', key: 'mute' }],
    });
    expect(parseRequest('volume down twice')).toMatchObject({
      kind: 'macro',
      actions: [{ type: 'key', key: 'volumeDown', count: 2 }],
    });
    expect(parseRequest('set volume to 140')).toMatchObject({
      kind: 'macro',
      actions: [{ type: 'setVolume', value: 100 }],
    });
  });

  it('uses a live intent for content-dependent requests', () => {
    expect(parseRequest('play the latest episode of Abbott Elementary')).toMatchObject({
      kind: 'intent',
      prompt: 'play the latest episode of Abbott Elementary',
    });
    expect(parseRequest('open hulu play a random family guy episode')).toMatchObject({
      kind: 'intent',
      prompt: 'open hulu play a random family guy episode',
    });
    expect(parseRequest('open Hulu and play a random Family Guy episode')).toMatchObject({
      kind: 'intent',
      prompt: 'open Hulu and play a random Family Guy episode',
    });
  });

  it('resolves app launches without invoking the visual agent', () => {
    expect(parseRequest('open Hulu')).toMatchObject({
      kind: 'macro',
      actions: [{ type: 'launchApp', appId: 'Hulu', label: 'Hulu' }],
    });
    expect(parseRequest('launch the YouTube app')).toMatchObject({
      kind: 'macro',
      actions: [{ type: 'launchApp', appId: 'YouTube', label: 'YouTube' }],
    });
  });

  it('routes local power-off requests through protected network standby', () => {
    expect(parseRequest('turn the tv off')).toMatchObject({
      kind: 'macro',
      label: 'Network standby',
      actions: [{ type: 'key', key: 'powerOff' }],
    });
  });
});
