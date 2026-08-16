import https from 'node:https';
import tls from 'node:tls';
import type {
  PairedDevice,
  SleepTimerValue,
  TvKey,
  TvNumericSetting,
  TvSettingName,
  TvState,
} from '../../src/shared/types';

export interface SmartCastResponse<T = unknown> {
  STATUS?: { RESULT?: string; DETAIL?: string };
  ITEM?: T;
  ITEMS?: T[];
  VALUE?: unknown;
  [key: string]: unknown;
}

class SmartCastRequestError extends Error {
  constructor(
    message: string,
    readonly statusCode: number,
    readonly result?: string,
  ) {
    super(message);
    this.name = 'SmartCastRequestError';
  }
}

interface KeyCode {
  codeset: number;
  code: number;
}

interface PendingKeyRequest {
  keys: TvKey[];
  timeoutMs: number;
  batchable: boolean;
  resolve: () => void;
  reject: (reason?: unknown) => void;
}

interface PendingVolumeRequest {
  value: number;
  waiters: Array<{ resolve: () => void; reject: (reason?: unknown) => void }>;
}

export const KEY_CODES: Record<TvKey, KeyCode> = {
  powerOff: { codeset: 11, code: 0 },
  powerOn: { codeset: 11, code: 1 },
  powerToggle: { codeset: 11, code: 2 },
  volumeDown: { codeset: 5, code: 0 },
  volumeUp: { codeset: 5, code: 1 },
  mute: { codeset: 5, code: 4 },
  input: { codeset: 7, code: 1 },
  up: { codeset: 3, code: 8 },
  down: { codeset: 3, code: 0 },
  left: { codeset: 3, code: 1 },
  right: { codeset: 3, code: 7 },
  ok: { codeset: 3, code: 2 },
  back: { codeset: 4, code: 0 },
  menu: { codeset: 4, code: 8 },
  home: { codeset: 4, code: 3 },
  exit: { codeset: 9, code: 0 },
  fastForward: { codeset: 2, code: 0 },
  rewind: { codeset: 2, code: 1 },
  pause: { codeset: 2, code: 2 },
  play: { codeset: 2, code: 3 },
};

function statusSucceeded(response: SmartCastResponse) {
  const result = response.STATUS?.RESULT;
  return !result || result === 'SUCCESS';
}

function findMenuItem(value: unknown, cname: string): Record<string, unknown> | undefined {
  if (!value || typeof value !== 'object') return undefined;
  if (Array.isArray(value)) {
    for (const item of value) {
      const match = findMenuItem(item, cname);
      if (match) return match;
    }
    return undefined;
  }
  const item = value as Record<string, unknown>;
  if (String(item.CNAME ?? '').toLowerCase() === cname.toLowerCase()) return item;
  for (const child of Object.values(item)) {
    const match = findMenuItem(child, cname);
    if (match) return match;
  }
  return undefined;
}

function itemValue(response: SmartCastResponse, cname: string) {
  return findMenuItem(response, cname)?.VALUE;
}

export const SLEEP_TIMER_VALUES = [
  'Off', '30 minutes', '60 minutes', '90 minutes', '120 minutes', '180 minutes',
] as const satisfies readonly SleepTimerValue[];

const POWER_MODE_PARENT_PATH = '/menu_native/dynamic/tv_settings/system';
const POWER_MODE_WRITE_PATH = `${POWER_MODE_PARENT_PATH}/power_mode`;
const QUICK_START_POWER_MODE = 'Quick Start' as const;

const SETTING_DEFINITIONS = {
  screenBrightness: {
    cname: 'backlight',
    parentPath: '/menu_native/dynamic/tv_settings/picture',
    writePath: '/menu_native/dynamic/tv_settings/picture/backlight',
    kind: 'number',
  },
  pictureBrightness: {
    cname: 'brightness',
    parentPath: '/menu_native/dynamic/tv_settings/picture',
    writePath: '/menu_native/dynamic/tv_settings/picture/brightness',
    kind: 'number',
  },
  sleepTimer: {
    cname: 'sleep_timer',
    parentPath: '/menu_native/dynamic/tv_settings/system/timers',
    writePath: '/menu_native/dynamic/tv_settings/system/timers/sleep_timer',
    kind: 'sleepTimer',
  },
} as const;

export const TV_SETTING_DESCRIPTIONS: Record<TvSettingName, string> = {
  screenBrightness: 'Panel light output (Vizio Backlight), 0–100.',
  pictureBrightness: 'Picture black-level Brightness, 0–100.',
  sleepTimer: 'Automatic TV power-off timer: Off, 30, 60, 90, 120, or 180 minutes.',
};

export class SmartCastClient {
  private token: string | null = null;
  private expectedFingerprint: string | null = null;
  private expectedSerial: string | null = null;
  private pendingKeys: PendingKeyRequest[] = [];
  private keyPumpRunning = false;
  private pendingVolume: PendingVolumeRequest | null = null;
  private volumePumpRunning = false;
  private readonly requestAgent = new https.Agent({
    keepAlive: true,
    maxSockets: 4,
    maxFreeSockets: 2,
    timeout: 15_000,
  });

  constructor(public address: string) {}

  configure(device: PairedDevice, token: string | null) {
    this.address = device.address;
    this.expectedFingerprint = device.fingerprint ?? null;
    this.expectedSerial = device.serial ?? null;
    this.token = token;
  }

  setToken(token: string | null) {
    this.token = token;
  }

  setFingerprint(fingerprint: string | null) {
    this.expectedFingerprint = fingerprint;
  }

  async getCertificateFingerprint(timeoutMs = 2500) {
    return await new Promise<string>((resolve, reject) => {
      const socket = tls.connect({
        host: this.address,
        port: 7345,
        rejectUnauthorized: false,
      });
      const timer = setTimeout(() => socket.destroy(new Error('Certificate check timed out.')), timeoutMs);
      socket.once('secureConnect', () => {
        clearTimeout(timer);
        const certificate = socket.getPeerCertificate();
        const fingerprint = certificate.fingerprint256;
        socket.end();
        if (!fingerprint) reject(new Error('TV did not provide a TLS certificate fingerprint.'));
        else resolve(fingerprint);
      });
      socket.once('error', reject);
    });
  }

  async getDeviceInfo() {
    return await this.request('/state/device/deviceinfo', 'GET', undefined, false);
  }

  async getPower() {
    const response = await this.request('/state/device/power_mode', 'GET', undefined, false);
    const value = itemValue(response, 'power_mode')
      ?? (response as { ITEM?: { VALUE?: number }; ITEMS?: Array<{ VALUE?: number }> }).ITEM?.VALUE
      ?? (response as { ITEMS?: Array<{ VALUE?: number }> }).ITEMS?.[0]?.VALUE
      ?? response.VALUE;
    return Number(value) === 1;
  }

  async getAudioState() {
    const response = await this.request('/menu_native/dynamic/tv_settings/audio', 'GET');
    const volume = Number(itemValue(response, 'volume'));
    const muteValue = String(itemValue(response, 'mute') ?? '').toLowerCase();
    return {
      volume: Number.isFinite(volume) ? volume : null,
      muted: muteValue ? muteValue === 'on' : null,
    };
  }

  async getCurrentApp() {
    const response = await this.request('/app/current', 'GET');
    const item = response.ITEM as Record<string, unknown> | undefined;
    const value = item?.VALUE as Record<string, unknown> | undefined;
    return {
      appId: String(value?.APP_ID ?? item?.APP_ID ?? ''),
      namespace: Number(value?.NAME_SPACE ?? item?.NAME_SPACE ?? 0),
      message: String(value?.MESSAGE ?? item?.MESSAGE ?? ''),
      name: String(value?.NAME ?? item?.NAME ?? ''),
    };
  }

  async getState(): Promise<TvState> {
    try {
      if (this.expectedSerial) {
        const actual = parseDeviceInfo(await this.getDeviceInfo()).serial;
        if (!actual || actual !== this.expectedSerial) {
          throw new Error('The TV at this address is not the paired TV. Rediscovering the verified TV.');
        }
      }
      const power = await this.getPower();
      if (!power) {
        return { connected: true, power, volume: null, muted: null, currentApp: null, address: this.address };
      }
      const [audio, app] = await Promise.all([
        this.token ? this.getAudioState().catch(() => ({ volume: null, muted: null })) : { volume: null, muted: null },
        this.token ? this.getCurrentApp().catch(() => ({ name: '', appId: '', message: '', namespace: 0 })) : { name: '', appId: '', message: '', namespace: 0 },
      ]);
      return {
        connected: true,
        power,
        volume: audio.volume,
        muted: audio.muted,
        currentApp: app.name || appNameFromMessage(app.message) || appNameFromIdentity(app.appId, app.namespace) || (app.appId ? `SmartCast app ${app.appId}` : null),
        address: this.address,
      };
    } catch (error) {
      return {
        connected: false,
        power: null,
        volume: null,
        muted: null,
        currentApp: null,
        address: this.address,
        error: error instanceof Error ? error.message : 'TV is unreachable.',
      };
    }
  }

  async startPairing(deviceId: string) {
    const response = await this.request(
      '/pairing/start',
      'PUT',
      pairingStartPayload(deviceId),
      false,
    );
    const item = response.ITEM as { PAIRING_REQ_TOKEN?: number; CHALLENGE_TYPE?: number } | undefined;
    if (!item?.PAIRING_REQ_TOKEN) throw new Error('TV did not start pairing. Try discovery again.');
    return { requestToken: item.PAIRING_REQ_TOKEN, challengeType: item.CHALLENGE_TYPE ?? 1 };
  }

  async finishPairing(deviceId: string, requestToken: number, pin: string) {
    const response = await this.request(
      '/pairing/pair',
      'PUT',
      pairingFinishPayload(deviceId, requestToken, pin),
      false,
    );
    const token = (response.ITEM as { AUTH_TOKEN?: string } | undefined)?.AUTH_TOKEN;
    if (!token) throw new Error(response.STATUS?.DETAIL || 'That PIN was not accepted. Start a new pairing session after two failed attempts.');
    this.token = token;
    return token;
  }

  async pressKey(key: TvKey, count = 1, timeoutMs = 8000) {
    if (!KEY_CODES[key]) throw new Error(`Unsupported TV key: ${key}`);
    const safeCount = Math.max(1, Math.min(10, Math.floor(count)));
    return await new Promise<void>((resolve, reject) => {
      this.pendingKeys.push({
        keys: Array.from({ length: safeCount }, () => key),
        timeoutMs,
        batchable: !key.startsWith('power'),
        resolve,
        reject,
      });
      void this.pumpKeyQueue();
    });
  }

  async ensureQuickStartPowerMode() {
    const current = await this.readConfiguredPowerMode();
    if (isQuickStartPowerMode(current.value)) {
      return { changed: false, value: current.value };
    }
    if (!isEcoPowerMode(current.value)) {
      throw new Error('TV returned an unrecognized Power Mode setting.');
    }
    if (isTrueSettingFlag(current.item.READONLY)) {
      throw new Error('TV reported that Power Mode is read-only.');
    }
    const hash = Number(current.item.HASHVAL);
    if (!Number.isFinite(hash)) throw new Error('TV did not return the Power Mode setting hash.');

    const advertisedQuickStart = settingOptionStrings(current.item.ELEMENTS)
      .find(isQuickStartPowerMode);
    const target = advertisedQuickStart ?? QUICK_START_POWER_MODE;
    await this.request(POWER_MODE_WRITE_PATH, 'PUT', settingPayload(hash, target));

    const verified = await this.readConfiguredPowerMode();
    if (!isQuickStartPowerMode(verified.value)) {
      throw new Error('TV did not confirm Quick Start Power Mode.');
    }
    return { changed: true, value: verified.value };
  }

  async typeText(value: string) {
    const text = value.slice(0, 120);
    if (!text || [...text].some((character) => character.charCodeAt(0) > 127)) {
      throw new Error('Text entry accepts 1–120 ASCII characters.');
    }
    await this.request('/key_command/', 'PUT', textPayload(text));
  }

  async setVolume(value: number) {
    const safeValue = Math.max(0, Math.min(100, Math.round(value)));
    return await new Promise<void>((resolve, reject) => {
      if (this.pendingVolume) {
        // Slider movement can produce dozens of values while TV is still
        // acknowledging the first one. Keep every caller attached to the
        // result, but send only the newest pending value to the TV.
        this.pendingVolume.value = safeValue;
        this.pendingVolume.waiters.push({ resolve, reject });
      } else {
        this.pendingVolume = { value: safeValue, waiters: [{ resolve, reject }] };
      }
      void this.pumpVolumeQueue();
    });
  }

  private async sendVolume(value: number) {
    try {
      // TV firmware supports the modern flat endpoint. It is a single PUT
      // and avoids the legacy GET-for-HASHVAL round trip on every slider move.
      await this.request('/audio/volume/level', 'PUT', flatVolumePayload(value));
      return;
    } catch (error) {
      if (!isUnsupportedEndpoint(error)) throw error;
    }

    // Older SmartCast firmware requires the menu-tree HASHVAL dance.
    const current = await this.request('/menu_native/dynamic/tv_settings/audio/volume', 'GET');
    const item = findMenuItem(current, 'volume');
    const hash = Number(item?.HASHVAL);
    if (!Number.isFinite(hash)) throw new Error('TV did not return the volume control hash.');
    await this.request('/menu_native/dynamic/tv_settings/audio/volume', 'PUT', volumePayload(hash, value));
  }

  async readSetting(setting: TvSettingName): Promise<number | SleepTimerValue> {
    const definition = settingDefinition(setting);
    const response = await this.request(definition.parentPath, 'GET');
    const item = findMenuItem(response, definition.cname);
    if (!item) throw new Error(`TV did not expose the ${setting} setting.`);
    if (definition.kind === 'number') {
      const value = Number(item.VALUE);
      if (!Number.isFinite(value)) throw new Error(`TV returned an invalid ${setting} value.`);
      return Math.max(0, Math.min(100, Math.round(value)));
    }
    const value = String(item.VALUE ?? '');
    if (!isSleepTimerValue(value)) throw new Error('TV returned an unsupported sleep timer value.');
    return value;
  }

  async setSetting(setting: TvNumericSetting, value: number): Promise<number>;
  async setSetting(setting: 'sleepTimer', value: SleepTimerValue): Promise<SleepTimerValue>;
  async setSetting(setting: TvSettingName, value: number | SleepTimerValue): Promise<number | SleepTimerValue> {
    const definition = settingDefinition(setting);
    const current = await this.request(definition.parentPath, 'GET');
    const item = findMenuItem(current, definition.cname);
    const hash = Number(item?.HASHVAL);
    if (!Number.isFinite(hash)) throw new Error(`TV did not return the ${setting} setting hash.`);
    const safeValue = definition.kind === 'number'
      ? boundedSettingNumber(value)
      : sleepTimerValue(value);
    await this.request(definition.writePath, 'PUT', settingPayload(hash, safeValue));
    const verified = await this.readSetting(setting);
    if (verified !== safeValue) throw new Error(`TV did not confirm the requested ${setting} value.`);
    return verified;
  }

  async adjustSetting(setting: TvNumericSetting, delta: number) {
    const before = await this.readSetting(setting);
    if (typeof before !== 'number') throw new Error(`${setting} is not numeric.`);
    const safeDelta = Math.max(-25, Math.min(25, Math.round(delta)));
    if (safeDelta === 0) throw new Error('Setting adjustment must be non-zero.');
    const value = await this.setSetting(setting, before + safeDelta);
    return { before, value };
  }

  private async readConfiguredPowerMode() {
    const response = await this.request(POWER_MODE_PARENT_PATH, 'GET');
    const item = findMenuItem(response, 'power_mode');
    if (!item) throw new Error('TV did not expose its Power Mode setting.');
    const value = String(item.VALUE ?? '').trim();
    if (!value) throw new Error('TV returned an empty Power Mode setting.');
    return { item, value };
  }

  async launchApp(config: { appId: string; namespace: number; message: string }) {
    await this.request('/app/launch', 'PUT', {
      VALUE: { APP_ID: config.appId, NAME_SPACE: config.namespace, MESSAGE: config.message },
    });
  }

  async request<T = unknown>(
    requestPath: string,
    method: 'GET' | 'PUT',
    body?: unknown,
    authenticated = true,
    timeoutMs = 8000,
  ): Promise<SmartCastResponse<T>> {
    if (authenticated && !this.token) throw new Error('Pair TV before sending controls.');
    const payload = body === undefined ? undefined : JSON.stringify(body);
    return await new Promise((resolve, reject) => {
      const request = https.request(
        {
          host: this.address,
          port: 7345,
          path: requestPath,
          method,
          rejectUnauthorized: false,
          agent: this.requestAgent,
          headers: {
            Accept: 'application/json',
            ...(payload ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } : {}),
            ...(authenticated && this.token ? { AUTH: this.token } : {}),
          },
        },
        (response) => {
          const chunks: Buffer[] = [];
          response.on('data', (chunk) => chunks.push(Buffer.from(chunk)));
          response.on('end', () => {
            const raw = Buffer.concat(chunks).toString('utf8');
            try {
              const parsed = raw ? (JSON.parse(raw) as SmartCastResponse<T>) : ({} as SmartCastResponse<T>);
              if ((response.statusCode ?? 500) >= 400 || !statusSucceeded(parsed)) {
                reject(new SmartCastRequestError(
                  parsed.STATUS?.DETAIL || `TV returned HTTP ${response.statusCode}.`,
                  response.statusCode ?? 500,
                  parsed.STATUS?.RESULT,
                ));
              } else {
                resolve(parsed);
              }
            } catch (error) {
              reject(error instanceof SyntaxError ? new Error('TV returned an unreadable response.') : error);
            }
          });
        },
      );
      request.setTimeout(timeoutMs, () => request.destroy(new Error('TV did not respond in time.')));
      request.on('socket', (socket) => {
        const tlsSocket = socket as tls.TLSSocket;
        tlsSocket.once('secureConnect', () => {
          if (!this.expectedFingerprint) return;
          const actual = tlsSocket.getPeerCertificate().fingerprint256;
          if (!actual || actual !== this.expectedFingerprint) {
            request.destroy(new Error('TV’s security fingerprint changed. Forget and pair the TV again before sending controls.'));
          }
        });
      });
      request.on('error', reject);
      if (payload) request.write(payload);
      request.end();
    });
  }

  private async pumpKeyQueue() {
    if (this.keyPumpRunning) return;
    this.keyPumpRunning = true;
    try {
      while (this.pendingKeys.length) {
        const requests = [this.pendingKeys.shift()!];
        let keyCount = requests[0].keys.length;
        if (requests[0].batchable) {
          while (
            this.pendingKeys[0]?.batchable
            && keyCount + this.pendingKeys[0].keys.length <= 10
          ) {
            const next = this.pendingKeys.shift()!;
            requests.push(next);
            keyCount += next.keys.length;
          }
        }
        try {
          const keys = requests.flatMap((request) => request.keys);
          const timeoutMs = Math.max(...requests.map((request) => request.timeoutMs));
          await this.request('/key_command/', 'PUT', keySequencePayload(keys), true, timeoutMs);
          requests.forEach((request) => request.resolve());
        } catch (error) {
          requests.forEach((request) => request.reject(error));
        }
      }
    } finally {
      this.keyPumpRunning = false;
      if (this.pendingKeys.length) void this.pumpKeyQueue();
    }
  }

  private async pumpVolumeQueue() {
    if (this.volumePumpRunning) return;
    this.volumePumpRunning = true;
    try {
      while (this.pendingVolume) {
        const request = this.pendingVolume;
        this.pendingVolume = null;
        try {
          await this.sendVolume(request.value);
          request.waiters.forEach((waiter) => waiter.resolve());
        } catch (error) {
          request.waiters.forEach((waiter) => waiter.reject(error));
        }
      }
    } finally {
      this.volumePumpRunning = false;
      if (this.pendingVolume) void this.pumpVolumeQueue();
    }
  }
}

export function parseDeviceInfo(response: SmartCastResponse) {
  const values = new Map<string, string>();
  const visit = (value: unknown) => {
    if (!value || typeof value !== 'object') return;
    if (Array.isArray(value)) {
      value.forEach(visit);
      return;
    }
    const item = value as Record<string, unknown>;
    const cname = normalizeIdentityKey(String(item.CNAME ?? item.NAME ?? ''));
    if (cname && item.VALUE !== undefined && item.VALUE !== null) values.set(cname, String(item.VALUE));
    for (const [key, child] of Object.entries(item)) {
      if (typeof child === 'string' || typeof child === 'number') values.set(normalizeIdentityKey(key), String(child));
      else visit(child);
    }
  };
  visit(response);
  const find = (...aliases: string[]) => aliases.map((alias) => values.get(normalizeIdentityKey(alias))).find(Boolean);
  return {
    model: find('MODEL_NAME', 'modelName', 'model'),
    serial: find('SERIAL_NUMBER', 'serialNumber', 'serial'),
    name: find('DEVICE_NAME', 'deviceName', 'friendlyName', 'CAST_NAME', 'castName', 'name'),
  };
}

export function volumePayload(hash: number, value: number) {
  return {
    REQUEST: 'MODIFY' as const,
    HASHVAL: hash,
    VALUE: Math.max(0, Math.min(100, Math.round(value))),
  };
}

export function settingPayload(hash: number, value: number | string) {
  if (!Number.isFinite(hash)) throw new Error('A valid SmartCast setting hash is required.');
  return { REQUEST: 'MODIFY' as const, HASHVAL: hash, VALUE: value };
}

export function flatVolumePayload(value: number) {
  return { LEVEL: Math.max(0, Math.min(100, Math.round(value))) };
}

export function keyPayload(key: TvKey, count = 1) {
  const safeCount = Math.max(1, Math.min(10, Math.floor(count)));
  return keySequencePayload(Array.from({ length: safeCount }, () => key));
}

export function keySequencePayload(keys: TvKey[]) {
  if (!keys.length || keys.length > 10) throw new Error('SmartCast key sequences accept 1–10 commands.');
  return {
    KEYLIST: keys.map((key) => {
      const command = KEY_CODES[key];
      if (!command) throw new Error(`Unsupported TV key: ${key}`);
      return { CODESET: command.codeset, CODE: command.code, ACTION: 'KEYPRESS' as const };
    }),
  };
}

export function textPayload(value: string) {
  return {
    KEYLIST: [...value].map((character) => ({ CODESET: 0, CODE: character.charCodeAt(0), ACTION: 'KEYPRESS' as const })),
  };
}

export function pairingStartPayload(deviceId: string) {
  return { DEVICE_ID: deviceId, DEVICE_NAME: 'VizioControl' };
}

export function pairingFinishPayload(deviceId: string, requestToken: number, pin: string) {
  return {
    DEVICE_ID: deviceId,
    CHALLENGE_TYPE: 1,
    RESPONSE_VALUE: pin,
    PAIRING_REQ_TOKEN: requestToken,
  };
}

function normalizeIdentityKey(value: string) {
  return value.toLowerCase().replace(/[^a-z0-9]/g, '');
}

function appNameFromMessage(message: string) {
  if (!message) return '';
  try {
    const host = new URL(message).hostname.toLowerCase();
    if (host.includes('hulu')) return 'Hulu';
    if (host.includes('netflix')) return 'Netflix';
    if (host.includes('youtube')) return 'YouTube';
    if (host.includes('primevideo') || host.includes('amazon')) return 'Prime Video';
  } catch {
    return '';
  }
  return '';
}

export function appNameFromIdentity(appId: string, namespace: number) {
  const knownApps: Record<string, string> = {
    '3:2': 'Hulu',
    '1:3': 'Netflix',
    '1:4': 'Prime Video',
    '1:5': 'YouTube',
  };
  return knownApps[`${appId}:${namespace}`] ?? '';
}

function isUnsupportedEndpoint(error: unknown) {
  if (!(error instanceof SmartCastRequestError)) return false;
  return error.statusCode === 404 || error.result === 'URI_NOT_FOUND';
}

function settingDefinition(setting: TvSettingName) {
  const definition = SETTING_DEFINITIONS[setting];
  if (!definition) throw new Error(`Unsupported TV setting: ${String(setting)}`);
  return definition;
}

function boundedSettingNumber(value: unknown) {
  const number = Number(value);
  if (!Number.isFinite(number)) throw new Error('TV setting value must be numeric.');
  return Math.max(0, Math.min(100, Math.round(number)));
}

function sleepTimerValue(value: unknown): SleepTimerValue {
  const candidate = String(value);
  if (!isSleepTimerValue(candidate)) throw new Error('Sleep timer must be Off, 30, 60, 90, 120, or 180 minutes.');
  return candidate;
}

function isSleepTimerValue(value: string): value is SleepTimerValue {
  return (SLEEP_TIMER_VALUES as readonly string[]).includes(value);
}

function normalizePowerMode(value: string) {
  return value.toLowerCase().replace(/[^a-z0-9]/g, '');
}

function isQuickStartPowerMode(value: string) {
  return normalizePowerMode(value).includes('quickstart');
}

function isEcoPowerMode(value: string) {
  return normalizePowerMode(value).includes('eco');
}

function isTrueSettingFlag(value: unknown) {
  return value === true || String(value).toLowerCase() === 'true';
}

function settingOptionStrings(value: unknown): string[] {
  if (typeof value === 'string') return [value];
  if (Array.isArray(value)) return value.flatMap(settingOptionStrings);
  if (!value || typeof value !== 'object') return [];
  const item = value as Record<string, unknown>;
  return ['VALUE', 'NAME', 'LABEL']
    .flatMap((key) => settingOptionStrings(item[key]));
}
