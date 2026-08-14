import type { AiRuntimeState } from './shared/types';

export type AiAccountAction = 'none' | 'signIn' | 'cancelSignIn' | 'signOut';

export interface AiRuntimePresentation {
  headerLabel: string;
  settingsTitle: string;
  accountAction: AiAccountAction;
  actionNote?: string;
}

export function presentAiRuntime(ai: AiRuntimeState): AiRuntimePresentation {
  switch (ai.status) {
    case 'starting':
      return {
        headerLabel: 'Starting Luna runtime',
        settingsTitle: 'Starting Luna runtime',
        accountAction: 'none',
        actionNote: 'Checking the bundled runtime and cached ChatGPT authentication.',
      };
    case 'signedOut':
      return {
        headerLabel: 'Luna signed out',
        settingsTitle: 'ChatGPT is signed out',
        accountAction: 'signIn',
      };
    case 'signingIn':
      return {
        headerLabel: 'ChatGPT sign-in open',
        settingsTitle: 'Finish signing in',
        accountAction: 'cancelSignIn',
      };
    case 'ready':
      return {
        headerLabel: 'Luna Max ready',
        settingsTitle: 'GPT-5.6 Luna · Max',
        accountAction: 'signOut',
      };
    case 'unavailable':
      if (!ai.signedIn && ai.available) {
        return {
          headerLabel: 'ChatGPT account required',
          settingsTitle: 'ChatGPT account required',
          accountAction: 'signIn',
        };
      }
      return {
        headerLabel: 'Luna unavailable',
        settingsTitle: ai.signedIn ? 'Luna access unavailable' : 'Luna runtime unavailable',
        accountAction: ai.signedIn ? 'signOut' : 'none',
        actionNote: ai.signedIn
          ? undefined
          : 'Sign-in is unavailable until the bundled runtime recovers.',
      };
  }
}
