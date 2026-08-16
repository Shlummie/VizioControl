import { EventEmitter } from 'node:events';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import type {
  AgentEvent,
  AppSettings,
  BootstrapState,
  ButtonPatch,
  DeviceCandidate,
  PairedDevice,
  RunRequestResult,
  SavedButton,
  ScreenFrame,
  ScreenStreamState,
  TvAction,
  TvKey,
  TvState,
  AiRuntimeState,
} from '../../src/shared/types';
import { TV_SCREEN_STREAM_FPS } from '../../src/shared/types';
import { AgentController } from './AgentController';
import { AppCatalog } from './AppCatalog';
import { AppStore } from './AppStore';
import { CdpObserver, type CdpStreamFrame, type CdpStreamState } from './CdpObserver';
import { CodexAppServerService, CODEX_RUNTIME_VERSION, LUNA_EFFORT, LUNA_MODEL } from './CodexAppServerService';
import { DiscoveryService } from './DiscoveryService';
import { normalizeRequest, parseRequest } from './RequestParser';
import { SmartCastClient } from './SmartCastClient';
import { normalizeMacAddress, WakeOnLanService } from './WakeOnLanService';

interface PairingSession {
  candidate: DeviceCandidate;
  deviceId: string;
  requestToken: number;
}

const emptyTvState: TvState = {
  connected: false,
  power: null,
  volume: null,
  muted: null,
  currentApp: null,
  address: null,
};

export class RemoteController extends EventEmitter {
  readonly store: AppStore;
  readonly ai: CodexAppServerService;
  private readonly discovery = new DiscoveryService();
  private readonly catalog = new AppCatalog();
  private readonly tv: SmartCastClient;
  private readonly observer: CdpObserver;
  private readonly agent: AgentController;
  private readonly wake = new WakeOnLanService();
  private pairing: PairingSession | null = null;
  private tvState: TvState = structuredClone(emptyTvState);
  private events: AgentEvent[] = [];
  private previewDataUrl: string | null = null;
  private screenFrameSequence = 0;
  private screenStreamPublishing = false;
  private screenStreamState: ScreenStreamState = {
    enabled: false,
    status: 'off',
    targetFps: TV_SCREEN_STREAM_FPS,
    message: 'Continuous local streaming is off.',
  };
  private refreshPromise: Promise<TvState> | null = null;
  private tvRefreshTimer: NodeJS.Timeout | null = null;
  private postCommandRefreshTimer: NodeJS.Timeout | null = null;
  private lastIdentityVerifiedAt = 0;
  private aiState: AiRuntimeState = {
    available: true,
    signedIn: false,
    ready: false,
    status: 'starting',
    model: LUNA_MODEL,
    effort: LUNA_EFFORT,
    runtimeVersion: CODEX_RUNTIME_VERSION,
  };

  constructor(userDataPath: string) {
    super();
    this.store = new AppStore(userDataPath);
    this.ai = new CodexAppServerService(userDataPath);
    this.tv = new SmartCastClient('127.0.0.1');
    this.observer = new CdpObserver('127.0.0.1');
    this.agent = new AgentController(
      this.tv,
      this.observer,
      this.catalog,
      this.ai,
      () => this.store.snapshot().settings,
      async (profile) => {
        const settings = await this.store.updateSettings({ preferredProfile: profile });
        this.emit('settings', settings);
      },
    );
    this.ai.on('state', (state: AiRuntimeState) => {
      this.aiState = state;
      this.emit('ai', state);
    });
    this.agent.on('event', (event: AgentEvent) => {
      if (event.type === 'preview') {
        this.previewDataUrl = event.dataUrl;
        if (event.dataUrl) this.emitScreenFrame(event.dataUrl, event.title, 'agentObservation');
      }
      this.events = [...this.events, event].slice(-40);
      this.emit('agent', event);
    });
    this.observer.on('streamFrame', (frame: CdpStreamFrame) => {
      if (!this.screenStreamPublishing) return;
      this.emitScreenFrame(frame.dataUrl, frame.title, 'localStream');
    });
    this.observer.on('streamState', (state: CdpStreamState) => {
      if (!this.screenStreamPublishing) return;
      this.screenStreamState = {
        enabled: true,
        status: state.status,
        targetFps: TV_SCREEN_STREAM_FPS,
        title: state.title,
        message: state.message,
      };
      this.emit('screenStream', structuredClone(this.screenStreamState));
    });
  }

  async initialize() {
    await this.store.load();
    const snapshot = this.store.snapshot();
    if (snapshot.device) {
      const token = await this.store.readToken();
      this.configureDevice(snapshot.device, token);
      void this.refreshTvState();
    }
    this.syncScreenStream();
    this.tvRefreshTimer = setInterval(() => void this.refreshTvState(), 15_000);
    this.tvRefreshTimer.unref();
    void this.refreshAi();
  }

  async bootstrap(): Promise<BootstrapState> {
    const snapshot = this.store.snapshot();
    return {
      settings: snapshot.settings,
      device: snapshot.device,
      tv: this.tvState,
      buttons: this.store.buttons(),
      ai: this.aiState,
      agent: { running: this.agent.running, events: this.events, previewDataUrl: this.previewDataUrl },
      screenStream: structuredClone(this.screenStreamState),
    };
  }

  async discover() {
    const snapshot = this.store.snapshot();
    return await this.discovery.discover(snapshot.device, snapshot.settings.manualAddress);
  }

  async pairStart(candidate: DeviceCandidate) {
    const verified = await this.discovery.probe(candidate.address, candidate.source);
    this.tv.address = verified.address;
    this.tv.setFingerprint(verified.fingerprint ?? null);
    this.tv.setToken(null);
    const deviceId = randomBytes(16).toString('hex');
    const pair = await this.tv.startPairing(deviceId);
    this.pairing = { candidate: verified, deviceId, requestToken: pair.requestToken };
    return { requestToken: pair.requestToken, deviceId, candidate: verified };
  }

  async pairFinish(pin: string) {
    if (!this.pairing) throw new Error('Start a new pairing session first.');
    if (!/^\d{4}$/.test(pin)) throw new Error('Enter the four-digit PIN shown on TV.');
    const token = await this.tv.finishPairing(this.pairing.deviceId, this.pairing.requestToken, pin);
    const now = new Date().toISOString();
    const { source: _source, ...candidate } = this.pairing.candidate;
    const device: PairedDevice = {
      ...candidate,
      name: this.pairing.candidate.name || 'Vizio TV',
      deviceId: this.pairing.deviceId,
      pairedAt: now,
    };
    await this.store.saveToken(token);
    await this.store.setDevice(device);
    this.configureDevice(device, token);
    this.syncScreenStream();
    this.pairing = null;
    await this.refreshTvState();
    return device;
  }

  async forgetDevice() {
    await this.agent.cancel();
    this.screenStreamPublishing = false;
    this.observer.stopStream();
    await this.store.clearToken();
    await this.store.setDevice(null);
    this.pairing = null;
    this.tv.setToken(null);
    this.tv.setFingerprint(null);
    this.observer.disconnect();
    this.screenStreamState = {
      enabled: this.store.snapshot().settings.alwaysStreamScreen,
      status: 'off',
      targetFps: TV_SCREEN_STREAM_FPS,
      message: 'Pair a TV to start the local screen stream.',
    };
    this.emit('screenStream', structuredClone(this.screenStreamState));
    this.tvState = structuredClone(emptyTvState);
    this.emit('tv', this.tvState);
  }

  async refreshTvState() {
    if (!this.refreshPromise) {
      this.refreshPromise = this.refreshTvStateOnce().finally(() => {
        this.refreshPromise = null;
      });
    }
    return await this.refreshPromise;
  }

  private async refreshTvStateOnce() {
    const device = this.store.snapshot().device;
    if (!device) {
      this.tvState = structuredClone(emptyTvState);
    } else if (hasMismatchedSerialIdentity(device)) {
      // A 1.0.0 discovery bug could preserve TV's serial-derived id while
      // copying another Vizio's mutable fields. Never query or control that
      // address as if it were TV; force identity-based recovery first.
      this.tvState = {
        ...emptyTvState,
        address: device.address,
        error: 'The saved TV identity was inconsistent. Rediscovering the verified TV.',
      };
      this.tvState = await this.rediscoverDevice(device).catch(() => this.tvState);
    } else {
      this.tvState = await this.tv.getState();
      if (!this.tvState.connected) {
        this.tvState = await this.rediscoverDevice(device).catch(() => this.tvState);
      }
    }
    if (this.tvState.connected) {
      this.lastIdentityVerifiedAt = Date.now();
      await this.rememberVerifiedMacAddress();
    } else {
      this.lastIdentityVerifiedAt = 0;
    }
    this.emit('tv', this.tvState);
    return this.tvState;
  }

  async pressKey(key: TvKey, count = 1) {
    const device = this.requireDevice();
    // A successful authenticated key request is already scoped by TV's
    // device token. Do not put a multi-request state poll in front of every
    // manual press; refresh only when the cached connection is actually down.
    let state = this.tvState.connected ? this.tvState : await this.refreshTvState();
    if ((key === 'powerOn' || key === 'powerToggle') && !state.connected) {
      return await this.wakeDevice(this.store.snapshot().device ?? device);
    }
    if (!state.connected) throw offlineControlError(state.error);
    if (key === 'powerOn' && state.power === true) return state;
    if (key === 'powerOff' && state.power === false) return state;
    if (state.power === false && key !== 'powerOn' && key !== 'powerToggle') {
      state = await this.refreshTvState();
      if (state.power === false) throw new Error('TV is off. Turn it on before sending controls.');
      if (!state.connected) throw offlineControlError(state.error);
    }
    const turningOff = key === 'powerOff' || (key === 'powerToggle' && state.power === true);
    const actualKey: TvKey = turningOff
      ? 'powerOff'
      : key === 'powerToggle' && state.power === false
        ? 'powerOn'
        : key;
    if (turningOff) {
      try {
        await this.tv.ensureQuickStartPowerMode();
      } catch {
        throw new Error('TV stayed on because network standby could not be verified. On the TV, choose Menu > System > Power Mode > Quick Start, then try Standby again.');
      }
    }
    try {
      await this.tv.pressKey(actualKey, count);
    } catch (error) {
      if (actualKey === 'powerOn') {
        return await this.wakeDevice(this.store.snapshot().device ?? device);
      }
      this.lastIdentityVerifiedAt = 0;
      this.scheduleStateRefresh(0);
      throw error;
    }
    // Several rapid renderer calls can share one SmartCast KEYLIST response.
    // Apply each completion to the latest optimistic state so repeated volume
    // or mute presses accumulate instead of all restarting from the same
    // pre-batch snapshot.
    state = optimisticTvStateForKey(this.tvState.connected ? this.tvState : state, actualKey, count);
    this.tvState = state;
    this.emit('tv', state);
    const refreshDelay = stateRefreshDelayForKey(actualKey);
    if (refreshDelay !== null) this.scheduleStateRefresh(refreshDelay);
    return state;
  }

  async setVolume(value: number) {
    this.requireDevice();
    let state = await this.manualControlState();
    if (state.power === false) state = await this.refreshTvState();
    if (state.power === false) throw new Error('TV is off. Turn it on before changing volume.');
    const safeValue = Math.max(0, Math.min(100, Math.round(value)));
    await this.tv.setVolume(safeValue);
    this.tvState = { ...state, volume: safeValue, muted: false };
    this.emit('tv', this.tvState);
    this.scheduleStateRefresh(300);
    return this.tvState;
  }

  async typeText(value: string) {
    this.requireDevice();
    const state = await this.manualControlState();
    if (state.power === false) throw new Error('TV is off. Turn it on before entering text.');
    await this.tv.typeText(value);
  }

  async launchApp(name: string) {
    this.requireDevice();
    let state = await this.manualControlState();
    if (state.power === false) state = await this.refreshTvState();
    if (state.power === false) throw new Error('TV is off. Turn it on before opening an app.');
    const app = await this.catalog.resolve(name);
    await this.tv.launchApp(app);
    this.observer.notifyAppLaunch();
    this.tvState = { ...state, currentApp: name };
    this.emit('tv', this.tvState);
    this.scheduleStateRefresh(1_200);
  }

  async runRequest(prompt: string): Promise<RunRequestResult> {
    this.requireDevice();
    const normalized = normalizeRequest(prompt);
    const learnedMacro = this.store.buttons().find(
      (button) => button.kind === 'macro' && button.normalizedRequest === normalized,
    );
    if (learnedMacro?.kind === 'macro') {
      await this.runActions(learnedMacro.actions);
      const buttons = await this.store.upsertButton(learnedMacro);
      this.emit('buttons', buttons);
      this.scheduleStateRefresh(350);
      return {
        ok: true,
        savedButton: buttons.find((candidate) => candidate.id === learnedMacro.id),
        message: `${learnedMacro.label} completed locally from its learned macro. Luna was not used.`,
      };
    }
    const parsed = parseRequest(prompt);
    if (parsed.kind === 'macro' && parsed.actions) {
      await this.runActions(parsed.actions);
      const button = this.makeButton(parsed, prompt);
      const buttons = await this.store.upsertButton(button);
      this.emit('buttons', buttons);
      this.scheduleStateRefresh(350);
      return { ok: true, savedButton: buttons.find((candidate) => candidate.normalizedRequest === parsed.normalized), message: `${parsed.label} completed and saved.` };
    }

    if (!this.store.snapshot().settings.aiVisionEnabled) {
      throw new Error('AI vision is off. Enable it in Settings to run Luna content-navigation requests.');
    }
    await this.ensureConnected();
    this.events = [];
    this.previewDataUrl = null;
    this.emit('agent', { type: 'idle', message: 'Starting a new agent run.', at: new Date().toISOString() } satisfies AgentEvent);
    const result = await this.agent.run(prompt);
    if (result.status !== 'success') return { ok: false, message: result.summary };
    const completed = result.actions?.length
      ? {
          ...parsed,
          kind: 'macro' as const,
          label: result.label || parsed.label,
          icon: 'sparkles',
          color: 'graphite',
          actions: result.actions,
          prompt: undefined,
        }
      : { ...parsed, label: result.label || parsed.label };
    const button = this.makeButton(completed, prompt);
    const buttons = await this.store.upsertButton(button);
    this.emit('buttons', buttons);
    return {
      ok: true,
      savedButton: buttons.find((candidate) => candidate.normalizedRequest === parsed.normalized),
      message: result.actions?.length
        ? `${result.summary} Learned as a local macro; future runs do not use Luna.`
        : result.summary,
    };
  }

  async runButton(id: string) {
    const button = this.store.buttons().find((candidate) => candidate.id === id);
    if (!button) throw new Error('Saved button not found.');
    if (button.kind === 'macro') {
      await this.runActions(button.actions);
      const buttons = await this.store.upsertButton(button);
      this.emit('buttons', buttons);
      this.scheduleStateRefresh(350);
      return { ok: true, savedButton: buttons.find((candidate) => candidate.id === id), message: `${button.label} completed.` };
    }
    return await this.runRequest(button.prompt);
  }

  async updateSettings(patch: Partial<AppSettings>) {
    const current = this.store.snapshot().settings;
    const safePatch: Partial<AppSettings> = {};
    if (typeof patch.launchAtStartup === 'boolean') safePatch.launchAtStartup = patch.launchAtStartup;
    if (typeof patch.aiVisionEnabled === 'boolean') safePatch.aiVisionEnabled = patch.aiVisionEnabled;
    if (typeof patch.showPreview === 'boolean') safePatch.showPreview = patch.showPreview;
    if (typeof patch.alwaysStreamScreen === 'boolean') safePatch.alwaysStreamScreen = patch.alwaysStreamScreen;
    if (typeof patch.preferredProfile === 'string') safePatch.preferredProfile = patch.preferredProfile.trim().slice(0, 80);
    if (typeof patch.manualAddress === 'string') safePatch.manualAddress = patch.manualAddress.trim().slice(0, 45);
    const settings = await this.store.updateSettings({ ...current, ...safePatch });
    this.emit('settings', settings);
    this.syncScreenStream();
    if (safePatch.showPreview === false) {
      this.previewDataUrl = null;
      this.emit('agent', { type: 'preview', dataUrl: null, at: new Date().toISOString() } satisfies AgentEvent);
    }
    return settings;
  }

  async updateButton(id: string, patch: ButtonPatch) {
    const button = this.store.buttons().find((candidate) => candidate.id === id);
    if (!button) throw new Error('Saved button not found.');
    const safePatch: Record<string, unknown> = {};
    if (patch.label !== undefined) safePatch.label = patch.label.trim().slice(0, 40) || button.label;
    if (patch.icon !== undefined) safePatch.icon = patch.icon.slice(0, 32);
    if (patch.color !== undefined) safePatch.color = patch.color.slice(0, 24);
    if (patch.prompt !== undefined && button.kind === 'intent') safePatch.prompt = patch.prompt.trim().slice(0, 500);
    const buttons = await this.store.updateButton(id, safePatch);
    this.emit('buttons', buttons);
    return buttons;
  }

  async duplicateButton(id: string) {
    const buttons = await this.store.duplicateButton(id);
    this.emit('buttons', buttons);
    return buttons;
  }

  async deleteButton(id: string) {
    const buttons = await this.store.deleteButton(id);
    this.emit('buttons', buttons);
    return buttons;
  }

  async undoDelete() {
    const buttons = await this.store.undoDelete();
    this.emit('buttons', buttons);
    return buttons;
  }

  async reorderButton(id: string, direction: -1 | 1) {
    const buttons = await this.store.reorderButton(id, direction);
    this.emit('buttons', buttons);
    return buttons;
  }

  async cancelAgent() {
    await this.agent.cancel();
  }

  answerAgent(requestId: string, value: string | boolean) {
    this.agent.answer(requestId, value);
  }

  private configureDevice(device: PairedDevice, token: string | null) {
    if (this.postCommandRefreshTimer) clearTimeout(this.postCommandRefreshTimer);
    this.postCommandRefreshTimer = null;
    this.lastIdentityVerifiedAt = 0;
    this.tv.configure(device, token);
    this.observer.setAddress(device.address);
    this.tvState = { ...emptyTvState, address: device.address };
  }

  async refreshAi() {
    this.aiState = await this.ai.getState();
    this.emit('ai', this.aiState);
    return this.aiState;
  }

  async signInAi() {
    const result = await this.ai.signIn();
    this.aiState = result.state;
    this.emit('ai', this.aiState);
    return result;
  }

  async cancelAiSignIn() {
    this.aiState = await this.ai.cancelSignIn();
    this.emit('ai', this.aiState);
    return this.aiState;
  }

  async signOutAi() {
    await this.agent.cancel('Luna navigation stopped because ChatGPT was signed out.');
    this.aiState = await this.ai.signOut();
    this.emit('ai', this.aiState);
    return this.aiState;
  }

  async shutdown() {
    if (this.tvRefreshTimer) clearInterval(this.tvRefreshTimer);
    this.tvRefreshTimer = null;
    if (this.postCommandRefreshTimer) clearTimeout(this.postCommandRefreshTimer);
    this.postCommandRefreshTimer = null;
    await this.agent.cancel('VizioControl is closing.');
    this.screenStreamPublishing = false;
    this.observer.stopStream();
    this.observer.disconnect();
    await this.ai.shutdown();
  }

  private async rediscoverDevice(device: PairedDevice) {
    const settings = this.store.snapshot().settings;
    const candidates = await this.discovery.discover(device, settings.manualAddress);
    const match = candidates.find((candidate) => isSameDevice(device, candidate));
    if (!match) return this.tvState;
    const repairOverwrittenIdentity = hasMismatchedSerialIdentity(device);
    const updated: PairedDevice = {
      ...device,
      address: match.address,
      model: match.model ?? device.model,
      // Pairing identity is immutable. Vizio reuses the same TLS certificate
      // across different TVs, so discovery must never replace these fields
      // with values from another set that happens to share the certificate.
      serial: repairOverwrittenIdentity ? match.serial : device.serial ?? match.serial,
      fingerprint: device.fingerprint ?? match.fingerprint,
      macAddress: repairOverwrittenIdentity ? match.macAddress : device.macAddress ?? match.macAddress,
    };
    await this.store.setDevice(updated);
    this.configureDevice(updated, await this.store.readToken());
    return await this.tv.getState();
  }

  private requireDevice() {
    const device = this.store.snapshot().device;
    if (!device) throw new Error('Pair TV before sending controls.');
    return device;
  }

  private async runActions(actions: TvAction[]) {
    for (const action of actions) {
      switch (action.type) {
        case 'key':
          await this.pressKey(action.key, action.count ?? 1);
          break;
        case 'text':
          await this.typeText(action.value);
          break;
        case 'setVolume':
          await this.setVolume(action.value);
          break;
        case 'setSetting': {
          const state = await this.manualControlState();
          if (state.power === false) throw new Error('TV is off. Turn it on before changing TV settings.');
          if (action.setting === 'sleepTimer') await this.tv.setSetting(action.setting, action.value);
          else await this.tv.setSetting(action.setting, action.value);
          break;
        }
        case 'adjustSetting': {
          const state = await this.manualControlState();
          if (state.power === false) throw new Error('TV is off. Turn it on before changing TV settings.');
          await this.tv.adjustSetting(action.setting, action.delta);
          break;
        }
        case 'wait':
          await delay(Math.max(0, Math.min(5000, action.milliseconds)));
          break;
        case 'launchApp':
          await this.launchApp(action.appId);
          break;
        default:
          throw new Error(`Saved macro contains an unsupported action: ${String((action as { type?: unknown }).type ?? 'missing type')}.`);
      }
    }
  }

  private async ensureConnected() {
    const state = await this.refreshTvState();
    if (!state.connected) throw offlineControlError(state.error);
    return state;
  }

  private async manualControlState() {
    const state = this.tvState.connected ? this.tvState : await this.refreshTvState();
    if (!state.connected) throw offlineControlError(state.error);
    return state;
  }

  private scheduleStateRefresh(delayMs: number) {
    if (this.postCommandRefreshTimer) clearTimeout(this.postCommandRefreshTimer);
    this.postCommandRefreshTimer = setTimeout(() => {
      this.postCommandRefreshTimer = null;
      void this.refreshTvState();
    }, delayMs);
    this.postCommandRefreshTimer.unref();
  }

  private async rememberVerifiedMacAddress() {
    const device = this.store.snapshot().device;
    if (!device || device.macAddress || !this.tvState.connected) return;
    const macAddress = await this.discovery.resolveMacAddress(device.address);
    if (!macAddress) return;
    await this.store.setDevice({ ...device, macAddress });
  }

  private async wakeDevice(device: PairedDevice) {
    let macAddress = device.macAddress;
    if (!macAddress && wasRecentlyPaired(device.pairedAt)) {
      macAddress = await this.discovery.resolveMacAddress(device.address);
      if (macAddress) {
        device = { ...device, macAddress };
        await this.store.setDevice(device);
      }
    }
    if (!macAddress) {
      throw new Error('TV is offline and its wake address is not saved yet. Turn the TV on once, then press Refresh so VizioControl can remember it.');
    }

    await this.wake.wake(macAddress, device.address);
    const deadline = Date.now() + 30_000;
    let attempt = 0;
    while (Date.now() < deadline) {
      await delay(attempt === 0 ? 250 : 900);
      try {
        // Some Vizio firmware exposes SCPL for only a short interval after a
        // wake packet. Send the idempotent Power On key first so that brief
        // window is useful even when a state query would race the service.
        await this.tv.pressKey('powerOn', 1, 1_200);
      } catch {
        // The service is expected to refuse requests until its NIC is awake.
      }
      await delay(200);
      this.tvState = await this.tv.getState();
      if (this.tvState.connected) {
        if (this.tvState.connected && this.tvState.power === true) {
          this.emit('tv', this.tvState);
          return this.tvState;
        }
      }
      attempt += 1;
      if (attempt === 5 || attempt === 12) {
        this.tvState = await this.rediscoverDevice(device).catch(() => this.tvState);
        if (this.tvState.connected && this.tvState.power === true) {
          this.emit('tv', this.tvState);
          return this.tvState;
        }
      }
    }
    const error = 'A wake signal was sent, but TV did not start its network controls. Turn it on once with the physical button and enable Quick Start mode for network power-on.';
    this.tvState = { ...this.tvState, connected: false, error };
    this.emit('tv', this.tvState);
    throw new Error(error);
  }

  private makeButton(parsed: ReturnType<typeof parseRequest>, prompt: string): SavedButton {
    const now = new Date().toISOString();
    const base = {
      id: randomUUID(),
      label: parsed.label,
      icon: parsed.icon,
      color: parsed.color,
      normalizedRequest: parsed.normalized,
      order: this.store.buttons().length,
      usageCount: 1,
      createdAt: now,
      updatedAt: now,
    };
    return parsed.kind === 'macro'
      ? { ...base, kind: 'macro', actions: parsed.actions ?? [] }
      : { ...base, kind: 'intent', prompt: parsed.prompt ?? prompt };
  }

  private syncScreenStream() {
    const snapshot = this.store.snapshot();
    const enabled = snapshot.settings.alwaysStreamScreen;
    const shouldRun = Boolean(snapshot.device && enabled && snapshot.settings.showPreview);
    const wasPublishing = this.screenStreamPublishing;
    this.screenStreamPublishing = shouldRun;
    if (shouldRun) {
      if (wasPublishing) return;
      this.screenStreamState = {
        enabled: true,
        status: 'connecting',
        targetFps: TV_SCREEN_STREAM_FPS,
        message: 'Connecting to the SmartCast screen.',
      };
      this.emit('screenStream', structuredClone(this.screenStreamState));
      this.observer.startStream(TV_SCREEN_STREAM_FPS);
      return;
    }
    this.observer.stopStream();
    this.screenStreamState = {
      enabled,
      status: 'off',
      targetFps: TV_SCREEN_STREAM_FPS,
      message: !snapshot.device
        ? 'Pair a TV to start the local screen stream.'
        : enabled && !snapshot.settings.showPreview
          ? 'The local stream is paused while the preview is hidden.'
          : 'Continuous local streaming is off.',
    };
    this.emit('screenStream', structuredClone(this.screenStreamState));
  }

  private emitScreenFrame(dataUrl: string, title: string | undefined, source: ScreenFrame['source']) {
    const frame: ScreenFrame = {
      dataUrl,
      title,
      at: new Date().toISOString(),
      sequence: ++this.screenFrameSequence,
      source,
    };
    this.emit('screenFrame', frame);
  }
}

export function isSameDevice(device: PairedDevice, candidate: DeviceCandidate) {
  // A verified serial is the strongest available SmartCast identity. Reject a
  // conflicting serial before considering any fallback: Vizio currently uses
  // the same self-signed certificate on multiple physical TVs.
  if (device.serial && candidate.serial) {
    // Version 1.0.0 briefly allowed a shared certificate to overwrite the
    // stored serial while preserving the original serial-derived id. Use that
    // intact id once to find and repair the real paired TV.
    if (hasMismatchedSerialIdentity(device)) return candidate.id === device.id;
    return candidate.serial === device.serial;
  }

  const pairedMac = normalizeMacAddress(device.macAddress);
  const candidateMac = normalizeMacAddress(candidate.macAddress);
  if (pairedMac && candidateMac) return pairedMac === candidateMac;

  // Do not use the TLS fingerprint by itself as a device identity. Legacy
  // records without a serial or MAC may be recognized only at their already
  // verified address; they can still be repaired through manual discovery.
  if (device.serial || candidate.serial) return false;
  return candidate.id === device.id && candidate.address === device.address;
}

export function optimisticTvStateForKey(state: TvState, key: TvKey, count = 1): TvState {
  const presses = Math.max(1, Math.min(10, Math.floor(count)));
  if (key === 'powerOff' || (key === 'powerToggle' && state.power === true)) {
    return { ...state, power: false, volume: null, muted: null, currentApp: null };
  }
  if (key === 'powerOn' || (key === 'powerToggle' && state.power === false)) return { ...state, power: true };
  if (key === 'mute' && state.muted !== null) return { ...state, muted: !state.muted };
  if (key === 'volumeUp' && state.volume !== null) return { ...state, volume: Math.min(100, state.volume + presses), muted: false };
  if (key === 'volumeDown' && state.volume !== null) return { ...state, volume: Math.max(0, state.volume - presses), muted: false };
  return state;
}

function hasMismatchedSerialIdentity(device: PairedDevice) {
  if (!device.serial || !/^[a-f0-9]{16}$/i.test(device.id)) return false;
  return createHash('sha256').update(device.serial).digest('hex').slice(0, 16) !== device.id.toLowerCase();
}

function delay(milliseconds: number) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function wasRecentlyPaired(value: string) {
  const pairedAt = Date.parse(value);
  return Number.isFinite(pairedAt) && Date.now() - pairedAt < 30 * 24 * 60 * 60 * 1_000;
}

function offlineControlError(detail?: string) {
  const suffix = detail && !/ECONNREFUSED|timed out|unreachable/i.test(detail) ? ` ${detail}` : '';
  return new Error(`TV is offline. Use Power to wake it, or turn it on once and press Refresh.${suffix}`);
}

function stateRefreshDelayForKey(key: TvKey) {
  if (key.startsWith('power')) return 1_000;
  if (key === 'volumeUp' || key === 'volumeDown' || key === 'mute') return 250;
  if (key === 'home' || key === 'input') return 700;
  return null;
}
