import type { ScreenFrame, ScreenStreamState } from './shared/types';

export function shouldClearCommittedFrame(
  status: ScreenStreamState['status'],
  source: ScreenFrame['source'] | null,
) {
  return source === 'localStream' && status === 'unavailable';
}

export function unavailableViewportCopy(currentApp: string | null) {
  const namedApp = currentApp && !/^SmartCast app \d+$/i.test(currentApp) ? currentApp : null;
  return {
    title: namedApp
      ? `${namedApp} is not sending a preview yet.`
      : 'Waiting for a capturable TV screen.',
    detail: 'VizioControl is retrying automatically. The next valid frame will resume immediately; manual controls still work.',
  };
}
