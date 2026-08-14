import { randomUUID } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { safeStorage } from 'electron';
import type { AppSettings, PairedDevice, SavedButton } from '../../src/shared/types';

interface StoreFile {
  version: 2;
  settings: AppSettings;
  device: PairedDevice | null;
  buttons: SavedButton[];
}

const defaults: StoreFile = {
  version: 2,
  settings: {
    launchAtStartup: true,
    aiVisionEnabled: true,
    showPreview: true,
    alwaysStreamScreen: false,
    preferredProfile: '',
    manualAddress: '',
  },
  device: null,
  buttons: [],
};

export class AppStore {
  private data: StoreFile = structuredClone(defaults);
  private deletedButton: SavedButton | null = null;
  private writeQueue = Promise.resolve();

  constructor(private readonly userDataPath: string) {}

  private get storePath() {
    return path.join(this.userDataPath, 'viziocontrol.json');
  }

  private get tokenPath() {
    return path.join(this.userDataPath, 'tv-token.bin');
  }

  async load() {
    await fs.mkdir(this.userDataPath, { recursive: true });
    try {
      const parsed = JSON.parse(await fs.readFile(this.storePath, 'utf8')) as Partial<StoreFile>;
      this.data = {
        ...structuredClone(defaults),
        ...parsed,
        version: 2,
        settings: sanitizeSettings(parsed.settings),
        buttons: Array.isArray(parsed.buttons) ? parsed.buttons : [],
      };
      if (
        parsed.version !== 2
        || Object.prototype.hasOwnProperty.call(parsed.settings ?? {}, 'localModel')
        || !Object.prototype.hasOwnProperty.call(parsed.settings ?? {}, 'alwaysStreamScreen')
      ) {
        await this.persist();
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
        await fs.rename(this.storePath, `${this.storePath}.corrupt-${Date.now()}`).catch(() => undefined);
      }
      await this.persist();
    }
  }

  snapshot() {
    return structuredClone(this.data);
  }

  async updateSettings(patch: Partial<AppSettings>) {
    this.data.settings = { ...this.data.settings, ...patch };
    await this.persist();
    return structuredClone(this.data.settings);
  }

  async setDevice(device: PairedDevice | null) {
    this.data.device = device;
    await this.persist();
  }

  async saveToken(token: string) {
    if (!safeStorage.isEncryptionAvailable()) {
      throw new Error('Windows credential encryption is unavailable. Pairing token was not saved.');
    }
    await fs.writeFile(this.tokenPath, safeStorage.encryptString(token), { mode: 0o600 });
  }

  async readToken() {
    try {
      const encrypted = await fs.readFile(this.tokenPath);
      return safeStorage.decryptString(encrypted);
    } catch {
      return null;
    }
  }

  async clearToken() {
    await fs.rm(this.tokenPath, { force: true });
  }

  async upsertButton(button: SavedButton) {
    const existingIndex = this.data.buttons.findIndex(
      (candidate) => candidate.id === button.id || candidate.normalizedRequest === button.normalizedRequest,
    );
    if (existingIndex >= 0) {
      const existing = this.data.buttons[existingIndex];
      this.data.buttons[existingIndex] = {
        ...button,
        id: existing.id,
        order: existing.order,
        createdAt: existing.createdAt,
        usageCount: existing.usageCount + 1,
        updatedAt: new Date().toISOString(),
      } as SavedButton;
    } else {
      this.data.buttons.push(button);
    }
    this.normalizeOrder();
    await this.persist();
    return this.buttons();
  }

  async updateButton(id: string, patch: Record<string, unknown>) {
    const index = this.data.buttons.findIndex((button) => button.id === id);
    if (index < 0) throw new Error('Saved button not found.');
    const existing = this.data.buttons[index];
    this.data.buttons[index] = { ...existing, ...patch, id, updatedAt: new Date().toISOString() } as SavedButton;
    await this.persist();
    return this.buttons();
  }

  async duplicateButton(id: string) {
    const source = this.data.buttons.find((button) => button.id === id);
    if (!source) throw new Error('Saved button not found.');
    const now = new Date().toISOString();
    this.data.buttons.push({
      ...source,
      id: randomUUID(),
      label: `${source.label} copy`,
      normalizedRequest: `${source.normalizedRequest}-copy-${Date.now()}`,
      order: this.data.buttons.length,
      usageCount: 0,
      createdAt: now,
      updatedAt: now,
    });
    await this.persist();
    return this.buttons();
  }

  async deleteButton(id: string) {
    const index = this.data.buttons.findIndex((button) => button.id === id);
    if (index < 0) return this.buttons();
    this.deletedButton = this.data.buttons[index];
    this.data.buttons.splice(index, 1);
    this.normalizeOrder();
    await this.persist();
    return this.buttons();
  }

  async undoDelete() {
    if (this.deletedButton) {
      this.data.buttons.push(this.deletedButton);
      this.deletedButton = null;
      this.normalizeOrder();
      await this.persist();
    }
    return this.buttons();
  }

  async reorderButton(id: string, direction: -1 | 1) {
    const buttons = this.data.buttons.sort((a, b) => a.order - b.order);
    const index = buttons.findIndex((button) => button.id === id);
    const target = index + direction;
    if (index >= 0 && target >= 0 && target < buttons.length) {
      [buttons[index], buttons[target]] = [buttons[target], buttons[index]];
      buttons.forEach((button, order) => (button.order = order));
      this.data.buttons = buttons;
      await this.persist();
    }
    return this.buttons();
  }

  buttons() {
    return structuredClone(this.data.buttons).sort((a, b) => a.order - b.order);
  }

  private normalizeOrder() {
    this.data.buttons.sort((a, b) => a.order - b.order).forEach((button, index) => (button.order = index));
  }

  private async persist() {
    const payload = JSON.stringify(this.data, null, 2);
    this.writeQueue = this.writeQueue.then(async () => {
      const temporary = `${this.storePath}.tmp`;
      await fs.writeFile(temporary, payload, 'utf8');
      await fs.rename(temporary, this.storePath);
    });
    await this.writeQueue;
  }
}

export function sanitizeSettings(value: Partial<AppSettings> | undefined): AppSettings {
  return {
    launchAtStartup: typeof value?.launchAtStartup === 'boolean' ? value.launchAtStartup : defaults.settings.launchAtStartup,
    aiVisionEnabled: typeof value?.aiVisionEnabled === 'boolean' ? value.aiVisionEnabled : defaults.settings.aiVisionEnabled,
    showPreview: typeof value?.showPreview === 'boolean' ? value.showPreview : defaults.settings.showPreview,
    alwaysStreamScreen: typeof value?.alwaysStreamScreen === 'boolean' ? value.alwaysStreamScreen : defaults.settings.alwaysStreamScreen,
    preferredProfile: typeof value?.preferredProfile === 'string' ? value.preferredProfile.slice(0, 80) : '',
    manualAddress: typeof value?.manualAddress === 'string' ? value.manualAddress.slice(0, 45) : '',
  };
}
