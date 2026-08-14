import { describe, expect, it } from 'vitest';
import { presentAiRuntime } from '../src/aiPresentation';
import type { AiRuntimeState, AiRuntimeStatus } from '../src/shared/types';

function state(status: AiRuntimeStatus, signedIn = status === 'ready'): AiRuntimeState {
  return {
    available: status !== 'unavailable',
    signedIn,
    ready: status === 'ready',
    status,
    model: 'gpt-5.6-luna',
    effort: 'max',
    runtimeVersion: '0.147.0',
    error: status === 'unavailable' ? 'network unavailable' : undefined,
  };
}

describe('Luna runtime presentation', () => {
  it('maps every runtime state without calling unavailable or starting states signed out', () => {
    expect(presentAiRuntime(state('starting'))).toMatchObject({ headerLabel: 'Starting Luna runtime', accountAction: 'none' });
    expect(presentAiRuntime(state('signingIn'))).toMatchObject({ headerLabel: 'ChatGPT sign-in open', accountAction: 'cancelSignIn' });
    expect(presentAiRuntime(state('ready'))).toMatchObject({ headerLabel: 'Luna Max ready', accountAction: 'signOut' });
    expect(presentAiRuntime(state('signedOut'))).toMatchObject({ headerLabel: 'Luna signed out', accountAction: 'signIn' });
    expect(presentAiRuntime(state('unavailable'))).toMatchObject({
      headerLabel: 'Luna unavailable',
      settingsTitle: 'Luna runtime unavailable',
      accountAction: 'none',
    });
  });

  it('allows a signed-in unavailable account to sign out without offering sign-in', () => {
    expect(presentAiRuntime(state('unavailable', true))).toMatchObject({
      settingsTitle: 'Luna access unavailable',
      accountAction: 'signOut',
    });
  });

  it('lets an incompatible provider session switch to the required ChatGPT account', () => {
    expect(presentAiRuntime({ ...state('unavailable'), available: true })).toMatchObject({
      headerLabel: 'ChatGPT account required',
      settingsTitle: 'ChatGPT account required',
      accountAction: 'signIn',
    });
  });
});
