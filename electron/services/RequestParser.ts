import type { TvAction } from '../../src/shared/types';
import { BUILTIN_LAUNCH_CONFIGS } from './AppCatalog';

export interface ParsedRequest {
  kind: 'macro' | 'intent';
  normalized: string;
  label: string;
  icon: string;
  color: string;
  actions?: TvAction[];
  prompt?: string;
}

const COUNT_WORDS: Record<string, number> = {
  once: 1,
  one: 1,
  twice: 2,
  two: 2,
  three: 3,
  four: 4,
  five: 5,
  six: 6,
  seven: 7,
  eight: 8,
  nine: 9,
  ten: 10,
};

export function normalizeRequest(value: string) {
  return value.trim().toLowerCase().replace(/[^a-z0-9]+/g, ' ').replace(/\s+/g, ' ').trim();
}

export function parseRequest(value: string): ParsedRequest {
  const prompt = value.trim();
  const normalized = normalizeRequest(prompt);
  if (!normalized) throw new Error('Type a request for TV.');

  if (/^(mute|toggle mute|mute the tv)$/.test(normalized)) {
    return macro(normalized, 'Mute', 'volume-x', [{ type: 'key', key: 'mute' }]);
  }
  if (/^(power on|turn (the )?tv on|turn on tv)$/.test(normalized)) {
    return macro(normalized, 'Power on', 'power', [{ type: 'key', key: 'powerOn' }]);
  }
  if (/^(power off|turn (the )?tv off|turn off tv)$/.test(normalized)) {
    return macro(normalized, 'Network standby', 'power', [{ type: 'key', key: 'powerOff' }]);
  }
  if (/^(home|go home|smartcast|open smartcast)$/.test(normalized)) {
    return macro(normalized, 'SmartCast home', 'house', [{ type: 'key', key: 'home' }]);
  }
  if (/^(back|go back)$/.test(normalized)) {
    return macro(normalized, 'Back', 'corner-up-left', [{ type: 'key', key: 'back' }]);
  }
  if (/^(menu|open menu)$/.test(normalized)) {
    return macro(normalized, 'Menu', 'menu', [{ type: 'key', key: 'menu' }]);
  }
  if (/^(input|next input|change input|cycle input)$/.test(normalized)) {
    return macro(normalized, 'Next input', 'cable', [{ type: 'key', key: 'input' }]);
  }

  const exactVolume = normalized.match(/^(?:set )?(?:the )?volume(?: to| at)? (\d{1,3})(?: percent)?$/);
  if (exactVolume) {
    const level = Math.max(0, Math.min(100, Number(exactVolume[1])));
    return macro(normalized, `Volume ${level}`, 'volume-2', [{ type: 'setVolume', value: level }]);
  }

  const volumeDirection = normalized.match(/^(?:turn )?(?:the )?volume (up|down)(?: (\w+))?$/);
  if (volumeDirection) {
    const count = parseCount(volumeDirection[2]);
    const up = volumeDirection[1] === 'up';
    return macro(normalized, `Volume ${up ? 'up' : 'down'}${count > 1 ? ` ×${count}` : ''}`, 'volume-2', [
      { type: 'key', key: up ? 'volumeUp' : 'volumeDown', count },
    ]);
  }

  const openApp = prompt.match(/^\s*(?:open|launch|start)\s+(.+?)\s*$/i);
  const quickLaunchApp = openApp ? resolveQuickLaunchCommand(openApp[1]) : undefined;
  if (quickLaunchApp) {
    return macro(normalized, `Open ${quickLaunchApp}`, 'app-window', [
      { type: 'launchApp', appId: quickLaunchApp, label: quickLaunchApp },
    ]);
  }

  return {
    kind: 'intent',
    normalized,
    label: deriveIntentLabel(prompt),
    icon: 'sparkles',
    color: 'moss',
    prompt,
  };
}

function resolveQuickLaunchCommand(value: string) {
  const candidate = normalizeRequest(value).replace(/^the\s+/, '').replace(/\s+app$/, '');
  return Object.values(BUILTIN_LAUNCH_CONFIGS)
    .find((app) => normalizeRequest(app.name) === candidate)
    ?.name;
}

function macro(normalized: string, label: string, icon: string, actions: TvAction[]): ParsedRequest {
  return { kind: 'macro', normalized, label, icon, color: 'graphite', actions };
}

function parseCount(value?: string) {
  if (!value) return 1;
  const number = Number(value);
  if (Number.isFinite(number)) return Math.max(1, Math.min(10, Math.floor(number)));
  return COUNT_WORDS[value.toLowerCase()] ?? 1;
}

function deriveIntentLabel(prompt: string) {
  const cleaned = prompt
    .replace(/^\s*(please\s+)?(find|play|watch|search for|put on)\s+/i, '')
    .replace(/\s+/g, ' ')
    .trim();
  const label = cleaned || prompt.trim();
  return label.length > 34 ? `${label.slice(0, 31).trim()}…` : titleCase(label);
}

function titleCase(value: string) {
  return value.replace(/\b\w/g, (letter) => letter.toUpperCase());
}
