import type { AgentEvent, AiRuntimeState, AppSettings, BootstrapState, VizioControlApi, SavedButton, ScreenFrame, ScreenStreamState, TvState } from './shared/types';

export function resolveVizioApi(api: VizioControlApi | undefined): VizioControlApi {
  if (api) return api;
  if (import.meta.env.DEV) return createDevelopmentApi();
  throw new Error('VizioControl could not load its secure desktop bridge. Reinstall the application.');
}

function createDevelopmentApi(): VizioControlApi {
  const now = new Date().toISOString();
  let tv: TvState = { connected: true, power: true, volume: 36, muted: false, currentApp: 'Hulu', address: '192.168.50.42' };
  const buttons: SavedButton[] = [
    intent('the-bear', 'Continue The Bear', 'play the next unwatched episode of The Bear', 0, now),
    macro('hulu', 'Open Hulu', [{ type: 'launchApp', appId: 'Hulu', label: 'Hulu' }], 1, now),
    macro('night', 'Night volume', [{ type: 'setVolume', value: 18 }], 2, now),
  ];
  const events: AgentEvent[] = [
    { type: 'observing', message: 'Read Hulu home and current focus', at: new Date(Date.now() - 13_000).toISOString() },
    { type: 'acting', message: 'Opened Continue Watching', at: new Date(Date.now() - 9_000).toISOString() },
    { type: 'completed', message: 'The Bear is ready to continue', at: new Date(Date.now() - 4_000).toISOString() },
  ];
  const previewDataUrl = mockPreview();
  const tvListeners = new Set<(state: TvState) => void>();
  const buttonListeners = new Set<(value: SavedButton[]) => void>();
  const aiListeners = new Set<(value: AiRuntimeState) => void>();
  const settingsListeners = new Set<(value: AppSettings) => void>();
  const screenFrameListeners = new Set<(value: ScreenFrame) => void>();
  const screenStreamListeners = new Set<(value: ScreenStreamState) => void>();
  let settings: AppSettings = { launchAtStartup: true, aiVisionEnabled: true, showPreview: true, alwaysStreamScreen: false, preferredProfile: '', manualAddress: '' };
  let screenStream: ScreenStreamState = { enabled: false, status: 'off', targetFps: 24, message: 'Continuous local streaming is off.' };
  let ai: AiRuntimeState = {
    available: true,
    signedIn: true,
    ready: true,
    status: 'ready',
    model: 'gpt-5.6-luna',
    effort: 'max',
    runtimeVersion: '0.147.0',
    email: 'viewer@example.invalid',
    planType: 'plus',
    usage: { primaryUsedPercent: 12, limitReached: false },
  };

  const bootstrap = (): BootstrapState => ({
    settings,
    device: { id: 'tv', name: 'TV', address: tv.address!, model: 'TEST-MODEL', deviceId: 'desktop', pairedAt: now },
    tv,
    buttons,
    ai,
    agent: { running: false, events, previewDataUrl },
    screenStream,
  });

  return {
    getBootstrap: async () => structuredClone(bootstrap()),
    discover: async () => [],
    pairStart: async () => { throw new Error('Pairing is disabled in browser preview.'); },
    pairFinish: async () => { throw new Error('Pairing is disabled in browser preview.'); },
    forgetDevice: async () => undefined,
    refreshTvState: async () => structuredClone(tv),
    pressKey: async (key) => {
      if (key === 'mute') tv = { ...tv, muted: !tv.muted };
      tvListeners.forEach((listener) => listener(structuredClone(tv)));
      return structuredClone(tv);
    },
    setVolume: async (volume) => {
      tv = { ...tv, volume };
      tvListeners.forEach((listener) => listener(structuredClone(tv)));
      return structuredClone(tv);
    },
    typeText: async () => undefined,
    launchApp: async (name) => { tv = { ...tv, currentApp: name }; },
    runRequest: async (prompt) => ({ ok: true, message: `${prompt} completed and saved.` }),
    cancelAgent: async () => undefined,
    answerAgent: async () => undefined,
    updateSettings: async (patch) => {
      settings = { ...settings, ...patch };
      screenStream = settings.alwaysStreamScreen && settings.showPreview
        ? { enabled: true, status: 'live', targetFps: 24, title: 'Hulu' }
        : {
            enabled: settings.alwaysStreamScreen,
            status: 'off',
            targetFps: 24,
            message: settings.alwaysStreamScreen ? 'The local stream is paused while the preview is hidden.' : 'Continuous local streaming is off.',
          };
      settingsListeners.forEach((listener) => listener(structuredClone(settings)));
      screenStreamListeners.forEach((listener) => listener(structuredClone(screenStream)));
      if (screenStream.status === 'live') {
        const frame: ScreenFrame = { dataUrl: previewDataUrl, title: 'Hulu', at: new Date().toISOString(), sequence: 1, source: 'localStream' };
        screenFrameListeners.forEach((listener) => listener(structuredClone(frame)));
      }
      return structuredClone(settings);
    },
    updateButton: async () => structuredClone(buttons),
    duplicateButton: async () => structuredClone(buttons),
    deleteButton: async () => structuredClone(buttons),
    undoDelete: async () => structuredClone(buttons),
    reorderButton: async () => structuredClone(buttons),
    runButton: async () => ({ ok: true, message: 'Saved request completed.' }),
    refreshAi: async () => structuredClone(ai),
    signInAi: async () => {
      ai = {
        ...ai,
        signedIn: true,
        ready: true,
        status: 'ready',
        email: 'viewer@example.invalid',
        planType: 'plus',
        usage: { primaryUsedPercent: 12, limitReached: false },
        error: undefined,
      };
      aiListeners.forEach((listener) => listener(structuredClone(ai)));
      return structuredClone(ai);
    },
    cancelAiSignIn: async () => structuredClone(ai),
    signOutAi: async () => {
      ai = { ...ai, signedIn: false, ready: false, status: 'signedOut', email: undefined, planType: undefined, usage: undefined, error: undefined };
      aiListeners.forEach((listener) => listener(structuredClone(ai)));
      return structuredClone(ai);
    },
    onAgentEvent: () => () => undefined,
    onScreenFrame: (callback) => subscribe(screenFrameListeners, callback),
    onScreenStreamState: (callback) => subscribe(screenStreamListeners, callback),
    onTvState: (callback) => subscribe(tvListeners, callback),
    onButtons: (callback) => subscribe(buttonListeners, callback),
    onAiState: (callback) => subscribe(aiListeners, callback),
    onSettings: (callback) => subscribe(settingsListeners, callback),
  };
}

function subscribe<T>(listeners: Set<(value: T) => void>, callback: (value: T) => void) {
  listeners.add(callback);
  return () => listeners.delete(callback);
}

function macro(id: string, label: string, actions: Extract<SavedButton, { kind: 'macro' }>['actions'], order: number, now: string): SavedButton {
  return { kind: 'macro', id, label, actions, icon: id === 'hulu' ? 'app-window' : 'volume-2', color: 'graphite', normalizedRequest: id, order, usageCount: 4, createdAt: now, updatedAt: now };
}

function intent(id: string, label: string, prompt: string, order: number, now: string): SavedButton {
  return { kind: 'intent', id, label, prompt, icon: 'sparkles', color: 'moss', normalizedRequest: id, order, usageCount: 3, createdAt: now, updatedAt: now };
}

function mockPreview() {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720" viewBox="0 0 1280 720">
    <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#113a32"/><stop offset="1" stop-color="#081713"/></linearGradient></defs>
    <rect width="1280" height="720" fill="url(#g)"/><text x="62" y="78" fill="#f3f4ed" font-family="Arial" font-size="40" font-weight="700">hulu</text>
    <text x="62" y="154" fill="#aab8af" font-family="Arial" font-size="22">Continue Watching</text>
    <rect x="62" y="190" width="360" height="206" rx="13" fill="#c6d481"/><rect x="438" y="190" width="292" height="206" rx="13" fill="#28473e"/><rect x="746" y="190" width="292" height="206" rx="13" fill="#20352f"/>
    <text x="88" y="330" fill="#172019" font-family="Arial" font-size="34" font-weight="700">THE BEAR</text><rect x="62" y="416" width="360" height="5" fill="#d8e89b"/>
    <text x="62" y="490" fill="#f3f4ed" font-family="Arial" font-size="25" font-weight="700">The Bear</text><text x="62" y="528" fill="#b7c3bb" font-family="Arial" font-size="19">S3 E4 · 18 minutes remaining</text>
  </svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}
