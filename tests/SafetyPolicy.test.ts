import { describe, expect, it } from 'vitest';
import { containsSensitiveAction, evaluateSensitiveAction } from '../electron/services/SafetyPolicy';

describe('host-enforced sensitive TV action policy', () => {
  it.each([
    ['purchase', 'Buy now'],
    ['rental', 'Rent this movie'],
    ['subscription', 'Subscribe'],
    ['trial', 'Start a free trial'],
    ['sign in', 'Sign In'],
    ['log in', 'Log In'],
    ['sign out', 'Sign Out'],
    ['profile change', 'Edit Profile'],
    ['account change', 'Switch Account'],
    ['account settings', 'Account Settings'],
    ['destructive delete', 'Delete profile'],
    ['factory reset', 'Factory Reset'],
    ['erase', 'Erase all data'],
    ['unsubscribe', 'Unsubscribe'],
  ])('detects %s actions', (_category, label) => {
    expect(containsSensitiveAction(label)).toBe(true);
  });

  it('does not gate ordinary playback and navigation labels', () => {
    for (const label of ['Play latest episode', 'Search', 'My Stuff', 'TV', 'Continue watching']) {
      expect(containsSensitiveAction(label)).toBe(false);
    }
  });

  it('gates the focused sensitive action without blocking the remembered profile beside Manage Profiles', () => {
    const profilePicker = 'Who is watching?\nViewer\nManage Profiles';
    expect(evaluateSensitiveAction(profilePicker, 'button: TV')).toEqual({
      contextVisible: true,
      activationFocused: false,
    });
    expect(evaluateSensitiveAction(profilePicker, 'button: Manage Profiles')).toEqual({
      contextVisible: true,
      activationFocused: true,
    });
    expect(evaluateSensitiveAction('Rental $4.99\nConfirm', 'button: Confirm')).toEqual({
      contextVisible: true,
      activationFocused: true,
    });
  });
});
