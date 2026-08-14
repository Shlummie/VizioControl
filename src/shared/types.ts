export type TvKey =
  | 'powerOff'
  | 'powerOn'
  | 'powerToggle'
  | 'volumeUp'
  | 'volumeDown'
  | 'mute'
  | 'input'
  | 'up'
  | 'down'
  | 'left'
  | 'right'
  | 'ok'
  | 'back'
  | 'menu'
  | 'home'
  | 'exit'
  | 'play'
  | 'pause'
  | 'rewind'
  | 'fastForward';

export type TvNumericSetting = 'screenBrightness' | 'pictureBrightness';
export type TvSettingName = TvNumericSetting | 'sleepTimer';
export type SleepTimerValue = 'Off' | '30 minutes' | '60 minutes' | '90 minutes' | '120 minutes' | '180 minutes';

export type TvAction =
  | { type: 'key'; key: TvKey; count?: number }
  | { type: 'text'; value: string }
  | { type: 'launchApp'; appId: string; label?: string }
  | { type: 'wait'; milliseconds: number }
  | { type: 'setVolume'; value: number }
  | { type: 'setSetting'; setting: TvNumericSetting; value: number }
  | { type: 'setSetting'; setting: 'sleepTimer'; value: SleepTimerValue }
  | { type: 'adjustSetting'; setting: TvNumericSetting; delta: number };

interface SavedButtonBase {
  id: string;
  label: string;
  icon: string;
  color: string;
  normalizedRequest: string;
  order: number;
  usageCount: number;
  createdAt: string;
  updatedAt: string;
}

export type SavedButton =
  | (SavedButtonBase & { kind: 'macro'; actions: TvAction[] })
  | (SavedButtonBase & { kind: 'intent'; prompt: string });

export type AgentEvent =
  | { type: 'idle'; message?: string; at: string }
  | { type: 'observing' | 'acting' | 'completed'; message: string; at: string }
  | { type: 'choiceRequired'; requestId: string; question: string; options: string[]; at: string }
  | { type: 'confirmationRequired'; requestId: string; reason: string; at: string }
  | { type: 'paused' | 'failed'; message: string; at: string }
  | { type: 'preview'; dataUrl: string | null; title?: string; at: string };

export interface DeviceCandidate {
  id: string;
  name: string;
  address: string;
  model?: string;
  serial?: string;
  fingerprint?: string;
  macAddress?: string;
  source: 'mdns' | 'cached' | 'manual';
}

export interface PairedDevice {
  id: string;
  name: string;
  address: string;
  model?: string;
  serial?: string;
  fingerprint?: string;
  macAddress?: string;
  deviceId: string;
  pairedAt: string;
}

export interface TvState {
  connected: boolean;
  power: boolean | null;
  volume: number | null;
  muted: boolean | null;
  currentApp: string | null;
  address: string | null;
  error?: string;
}

export interface AppSettings {
  launchAtStartup: boolean;
  aiVisionEnabled: boolean;
  showPreview: boolean;
  alwaysStreamScreen: boolean;
  preferredProfile: string;
  manualAddress: string;
}

export const TV_SCREEN_STREAM_FPS = 24 as const;

export interface ScreenStreamState {
  enabled: boolean;
  status: 'off' | 'connecting' | 'live' | 'unavailable';
  targetFps: typeof TV_SCREEN_STREAM_FPS;
  title?: string;
  message?: string;
}

export interface ScreenFrame {
  dataUrl: string;
  title?: string;
  at: string;
  sequence: number;
  source: 'localStream' | 'agentObservation';
}

export type AiRuntimeStatus = 'starting' | 'signedOut' | 'signingIn' | 'ready' | 'unavailable';

export interface AiUsageState {
  primaryUsedPercent?: number;
  primaryResetsAt?: number;
  secondaryUsedPercent?: number;
  secondaryResetsAt?: number;
  limitReached: boolean;
  limitReason?: string;
}

export interface AiRuntimeState {
  available: boolean;
  signedIn: boolean;
  ready: boolean;
  status: AiRuntimeStatus;
  model: 'gpt-5.6-luna';
  effort: 'max';
  runtimeVersion: string;
  email?: string;
  planType?: string;
  usage?: AiUsageState;
  error?: string;
}

export interface BootstrapState {
  settings: AppSettings;
  device: PairedDevice | null;
  tv: TvState;
  buttons: SavedButton[];
  ai: AiRuntimeState;
  agent: {
    running: boolean;
    events: AgentEvent[];
    previewDataUrl: string | null;
  };
  screenStream: ScreenStreamState;
}

export interface PairingStartResult {
  requestToken: number;
  deviceId: string;
  candidate: DeviceCandidate;
}

export interface RunRequestResult {
  ok: boolean;
  savedButton?: SavedButton;
  message: string;
}

export type ButtonPatch = Partial<Pick<SavedButton, 'label' | 'icon' | 'color'>> & {
  prompt?: string;
};

export interface VizioControlApi {
  getBootstrap(): Promise<BootstrapState>;
  discover(): Promise<DeviceCandidate[]>;
  pairStart(candidate: DeviceCandidate): Promise<PairingStartResult>;
  pairFinish(pin: string): Promise<PairedDevice>;
  forgetDevice(): Promise<void>;
  refreshTvState(): Promise<TvState>;
  pressKey(key: TvKey, count?: number): Promise<TvState>;
  setVolume(value: number): Promise<TvState>;
  typeText(value: string): Promise<void>;
  launchApp(name: string): Promise<void>;
  runRequest(prompt: string): Promise<RunRequestResult>;
  cancelAgent(): Promise<void>;
  answerAgent(requestId: string, value: string | boolean): Promise<void>;
  updateSettings(patch: Partial<AppSettings>): Promise<AppSettings>;
  updateButton(id: string, patch: ButtonPatch): Promise<SavedButton[]>;
  duplicateButton(id: string): Promise<SavedButton[]>;
  deleteButton(id: string): Promise<SavedButton[]>;
  undoDelete(): Promise<SavedButton[]>;
  reorderButton(id: string, direction: -1 | 1): Promise<SavedButton[]>;
  runButton(id: string): Promise<RunRequestResult>;
  refreshAi(): Promise<AiRuntimeState>;
  signInAi(): Promise<AiRuntimeState>;
  cancelAiSignIn(): Promise<AiRuntimeState>;
  signOutAi(): Promise<AiRuntimeState>;
  onAgentEvent(callback: (event: AgentEvent) => void): () => void;
  onScreenFrame(callback: (frame: ScreenFrame) => void): () => void;
  onScreenStreamState(callback: (state: ScreenStreamState) => void): () => void;
  onTvState(callback: (state: TvState) => void): () => void;
  onButtons(callback: (buttons: SavedButton[]) => void): () => void;
  onAiState(callback: (state: AiRuntimeState) => void): () => void;
  onSettings(callback: (settings: AppSettings) => void): () => void;
}
