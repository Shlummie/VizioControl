import { EventEmitter } from 'node:events';
import http from 'node:http';
import net from 'node:net';
import WebSocket from 'ws';
import { evaluateSensitiveAction } from './SafetyPolicy';

interface CdpTarget {
  id: string;
  title: string;
  type: string;
  url: string;
  webSocketDebuggerUrl: string;
}

interface PendingCommand {
  resolve: (value: unknown) => void;
  reject: (reason?: unknown) => void;
  timer: NodeJS.Timeout;
}

export interface ScreenObservation {
  dataUrl: string;
  title: string;
  url: string;
  accessibility: string;
  focusedText: string;
  sensitiveActionVisible: boolean;
  sensitiveContextVisible: boolean;
  port: number;
}

interface PortScanOptions {
  start: number;
  end: number;
  concurrency: number;
  timeoutMs: number;
}

const DEFAULT_PORT_SCAN: PortScanOptions = { start: 32768, end: 49151, concurrency: 320, timeoutMs: 110 };
const STREAM_RETRY_MS = 2500;
const FULL_SCAN_COOLDOWN_MS = 10_000;
const MAX_STREAM_FRAME_BASE64 = 2 * 1024 * 1024;
const STREAM_SOURCE_FRAME_DIVISOR = 2;

export interface CdpStreamFrame {
  dataUrl: string;
  title: string;
}

export interface CdpStreamState {
  status: 'connecting' | 'live' | 'unavailable';
  title?: string;
  message?: string;
}

export class SmartCastScreenUnavailableError extends Error {
  constructor() {
    super('This SmartCast app does not expose a screen that VizioControl can inspect. Manual controls still work.');
    this.name = 'SmartCastScreenUnavailableError';
  }
}

export class CdpObserver extends EventEmitter {
  private cachedPort: number | null = null;
  private recentOpenPorts: number[] = [];
  private lastFullScanAt = 0;
  private socket: WebSocket | null = null;
  private socketTarget = '';
  private connecting: { url: string; promise: Promise<void> } | null = null;
  private nextId = 1;
  private pending = new Map<number, PendingCommand>();
  private streamAbort: AbortController | null = null;
  private streamSessionActive = false;
  private streamTargetFps = 24;
  private streamTitle = 'SmartCast';
  private nextStreamFrameAt = 0;
  private streamRetryRequested = false;

  constructor(private address: string, private readonly portScan: PortScanOptions = DEFAULT_PORT_SCAN) {
    super();
  }

  setAddress(address: string) {
    if (address === this.address) return;
    this.address = address;
    this.cachedPort = null;
    this.recentOpenPorts = [];
    this.lastFullScanAt = 0;
    this.disconnect();
  }

  startStream(targetFps = 24) {
    const safeFps = Math.max(1, Math.min(24, Math.round(targetFps)));
    this.streamTargetFps = safeFps;
    if (this.streamAbort && !this.streamAbort.signal.aborted) return;
    const controller = new AbortController();
    this.streamAbort = controller;
    void this.runStream(controller).finally(() => {
      if (this.streamAbort === controller) this.streamAbort = null;
    });
  }

  stopStream() {
    const controller = this.streamAbort;
    this.streamAbort = null;
    controller?.abort();
    this.streamRetryRequested = false;
    this.nextStreamFrameAt = 0;
    if (this.streamSessionActive) {
      this.streamSessionActive = false;
      void this.command('Page.stopScreencast', {}).catch(() => undefined);
    }
  }

  notifyAppLaunch() {
    this.cachedPort = null;
    this.lastFullScanAt = 0;
    this.streamRetryRequested = true;
    this.disconnect();
  }

  async observe(signal?: AbortSignal): Promise<ScreenObservation> {
    const { target, port } = await this.findTarget(signal, false, true);
    await this.connect(target.webSocketDebuggerUrl, signal);
    await Promise.all([
      this.command('Page.enable', {}, signal),
      this.command('Accessibility.enable', {}, signal),
    ]);
    const [screen, ax] = await Promise.all([
      this.command<{ data: string }>('Page.captureScreenshot', { format: 'jpeg', quality: 72, fromSurface: true }, signal),
      this.command<{ nodes: Array<Record<string, unknown>> }>('Accessibility.getFullAXTree', {}, signal),
    ]);
    const compact = compactAccessibility(ax.nodes ?? []);
    const sensitive = evaluateSensitiveAction(compact.text, compact.focused);
    this.cachedPort = port;
    return {
      dataUrl: `data:image/jpeg;base64,${screen.data}`,
      title: target.title || 'SmartCast',
      url: target.url,
      accessibility: compact.text,
      focusedText: compact.focused,
      sensitiveActionVisible: sensitive.activationFocused,
      sensitiveContextVisible: sensitive.contextVisible,
      port,
    };
  }

  async available() {
    try {
      await this.findTarget(undefined, true);
      return true;
    } catch {
      return false;
    }
  }

  async waitUntilAvailable(signal?: AbortSignal, timeoutMs = 15_000) {
    const deadline = Date.now() + Math.max(0, timeoutMs);
    do {
      if (signal?.aborted) throw abortError();
      try {
        await this.findTarget(signal, false, true);
        return true;
      } catch (error) {
        if (!(error instanceof SmartCastScreenUnavailableError)) throw error;
      }
      const remaining = deadline - Date.now();
      if (remaining <= 0) return false;
      await abortableDelay(Math.min(750, remaining), signal);
    } while (Date.now() < deadline);
    return false;
  }

  disconnect() {
    const socket = this.socket;
    this.socket = null;
    this.socketTarget = '';
    this.connecting = null;
    this.streamSessionActive = false;
    if (socket && socket.readyState < WebSocket.CLOSING) socket.close();
    for (const [, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.reject(new Error('SmartCast screen connection closed.'));
    }
    this.pending.clear();
    this.emit('socketClosed');
  }

  private async findTarget(signal?: AbortSignal, cachedOnly = false, bypassCooldown = false) {
    const first = [...new Set([this.cachedPort, ...this.recentOpenPorts, 9222])]
      .filter((port): port is number => Boolean(port));
    for (const port of first) {
      const target = await identifyTarget(this.address, port, 650).catch(() => null);
      if (target) return { target, port };
    }
    if (cachedOnly) throw new Error('No cached SmartCast screen target is available.');
    if (!bypassCooldown && Date.now() - this.lastFullScanAt < FULL_SCAN_COOLDOWN_MS) throw new SmartCastScreenUnavailableError();

    const openPorts = await scanPorts(
      this.address,
      this.portScan.start,
      this.portScan.end,
      this.portScan.concurrency,
      this.portScan.timeoutMs,
      signal,
    );
    this.lastFullScanAt = Date.now();
    this.recentOpenPorts = openPorts.slice(0, 64);
    const candidates = await Promise.all(openPorts.map(async (port) => ({ port, target: await identifyTarget(this.address, port, 900).catch(() => null) })));
    const match = candidates.find((candidate) => candidate.target);
    if (!match?.target) {
      this.cachedPort = null;
      this.disconnect();
      throw new SmartCastScreenUnavailableError();
    }
    this.cachedPort = match.port;
    return { target: match.target, port: match.port };
  }

  private async connect(url: string, signal?: AbortSignal) {
    if (this.socket?.readyState === WebSocket.OPEN && this.socketTarget === url) return;
    if (this.connecting?.url === url) return await this.connecting.promise;
    this.disconnect();
    const promise = new Promise<void>((resolve, reject) => {
      if (signal?.aborted) return reject(abortError());
      const socket = new WebSocket(url, { handshakeTimeout: 3000 });
      const abort = () => socket.close();
      signal?.addEventListener('abort', abort, { once: true });
      socket.once('open', () => {
        signal?.removeEventListener('abort', abort);
        this.socket = socket;
        this.socketTarget = url;
        resolve();
      });
      socket.once('error', (error) => {
        signal?.removeEventListener('abort', abort);
        reject(error);
      });
      socket.on('message', (raw) => this.onMessage(raw.toString()));
      socket.on('close', () => {
        if (this.socket === socket) this.disconnect();
      });
    });
    this.connecting = { url, promise };
    try {
      await promise;
    } finally {
      if (this.connecting?.promise === promise) this.connecting = null;
    }
  }

  private command<T>(method: string, params: Record<string, unknown>, signal?: AbortSignal): Promise<T> {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) throw new Error('SmartCast screen is not connected.');
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`SmartCast screen command ${method} timed out.`));
      }, 7000);
      const abort = () => {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(abortError());
      };
      signal?.addEventListener('abort', abort, { once: true });
      this.pending.set(id, {
        timer,
        resolve: (value) => {
          signal?.removeEventListener('abort', abort);
          resolve(value as T);
        },
        reject: (error) => {
          signal?.removeEventListener('abort', abort);
          reject(error);
        },
      });
      this.socket!.send(JSON.stringify({ id, method, params }), (error) => {
        if (error) {
          clearTimeout(timer);
          this.pending.delete(id);
          reject(error);
        }
      });
    });
  }

  private onMessage(raw: string) {
    try {
      const message = JSON.parse(raw) as {
        id?: number;
        method?: string;
        params?: { data?: unknown; sessionId?: unknown };
        result?: unknown;
        error?: { message?: string };
      };
      if (message.method === 'Page.screencastFrame') {
        const sessionId = Number(message.params?.sessionId);
        if (Number.isFinite(sessionId)) this.sendWithoutReply('Page.screencastFrameAck', { sessionId });
        const data = message.params?.data;
        if (!this.streamSessionActive || typeof data !== 'string' || data.length === 0 || data.length > MAX_STREAM_FRAME_BASE64) return;
        const now = performance.now();
        if (this.nextStreamFrameAt > now) return;
        const interval = 1000 / this.streamTargetFps;
        if (!this.nextStreamFrameAt) this.nextStreamFrameAt = now;
        do this.nextStreamFrameAt += interval;
        while (this.nextStreamFrameAt <= now);
        this.emit('streamFrame', {
          dataUrl: `data:image/jpeg;base64,${data}`,
          title: this.streamTitle,
        } satisfies CdpStreamFrame);
        return;
      }
      if (!message.id) return;
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error(message.error.message || 'SmartCast screen command failed.'));
      else pending.resolve(message.result);
    } catch {
      // Ignore unsolicited malformed CDP events; no screen data is logged.
    }
  }

  private async runStream(controller: AbortController) {
    const signal = controller.signal;
    let waitingForScreen = false;
    while (!signal.aborted) {
      try {
        if (!waitingForScreen) {
          this.emit('streamState', { status: 'connecting', message: 'Connecting to the SmartCast screen.' } satisfies CdpStreamState);
        }
        const forceScan = this.streamRetryRequested;
        this.streamRetryRequested = false;
        const { target, port } = await this.findTarget(signal, false, forceScan);
        await this.connect(target.webSocketDebuggerUrl, signal);
        await this.command('Page.enable', {}, signal);
        this.streamTitle = target.title || 'SmartCast';
        this.nextStreamFrameAt = 0;
        this.streamSessionActive = true;
        await this.command('Page.startScreencast', {
          format: 'jpeg',
          quality: 60,
          maxWidth: 1280,
          maxHeight: 720,
          // SmartCast commonly renders at 60 FPS. Requesting every frame made
          // the TV encode roughly twice as many JPEGs as the 24 FPS viewport
          // could display, stealing time from remote commands. Thirty source
          // frames still sustain a true 24 FPS output without that excess.
          everyNthFrame: STREAM_SOURCE_FRAME_DIVISOR,
        }, signal);
        this.cachedPort = port;
        this.emit('streamState', { status: 'live', title: this.streamTitle } satisfies CdpStreamState);
        waitingForScreen = false;
        await this.waitForSocketClose(signal);
      } catch (error) {
        if (signal.aborted) break;
        waitingForScreen = true;
        this.emit('streamState', {
          status: 'unavailable',
          message: error instanceof SmartCastScreenUnavailableError
            ? 'This screen is not exposed by SmartCast. Open a compatible streaming app to resume.'
            : 'The SmartCast screen stream was interrupted. Retrying automatically.',
        } satisfies CdpStreamState);
      } finally {
        if (this.streamSessionActive) {
          this.streamSessionActive = false;
          await this.command('Page.stopScreencast', {}).catch(() => undefined);
        }
      }
      if (!signal.aborted) await this.waitForStreamRetry(signal).catch(() => undefined);
    }
  }

  private async waitForStreamRetry(signal: AbortSignal) {
    const deadline = Date.now() + STREAM_RETRY_MS;
    while (!signal.aborted && !this.streamRetryRequested) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) return;
      await abortableDelay(Math.min(100, remaining), signal);
    }
  }

  private waitForSocketClose(signal: AbortSignal) {
    return new Promise<void>((resolve, reject) => {
      if (signal.aborted) return reject(abortError());
      const closed = () => finish(resolve);
      const aborted = () => finish(() => reject(abortError()));
      const finish = (complete: () => void) => {
        this.removeListener('socketClosed', closed);
        signal.removeEventListener('abort', aborted);
        complete();
      };
      this.once('socketClosed', closed);
      signal.addEventListener('abort', aborted, { once: true });
    });
  }

  private sendWithoutReply(method: string, params: Record<string, unknown>) {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return;
    this.socket.send(JSON.stringify({ id: this.nextId++, method, params }), () => undefined);
  }
}

async function identifyTarget(address: string, port: number, timeoutMs: number): Promise<CdpTarget | null> {
  const targets = await getJson<CdpTarget[]>(`http://${address}:${port}/json/list`, timeoutMs);
  return targets.find((target) => target.type === 'page' && Boolean(target.webSocketDebuggerUrl)) ?? null;
}

function getJson<T>(url: string, timeoutMs: number): Promise<T> {
  return new Promise((resolve, reject) => {
    const request = http.get(url, { timeout: timeoutMs }, (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`HTTP ${response.statusCode}`));
        return;
      }
      const chunks: Buffer[] = [];
      response.on('data', (chunk) => chunks.push(Buffer.from(chunk)));
      response.on('end', () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')) as T);
        } catch (error) {
          reject(error);
        }
      });
    });
    request.on('timeout', () => request.destroy(new Error('Timed out.')));
    request.on('error', reject);
  });
}

export async function scanPorts(
  host: string,
  start: number,
  end: number,
  concurrency: number,
  timeoutMs: number,
  signal?: AbortSignal,
) {
  let next = start;
  const open: number[] = [];
  const worker = async () => {
    while (next <= end && !signal?.aborted) {
      const port = next++;
      if (await isPortOpen(host, port, timeoutMs, signal)) open.push(port);
    }
  };
  await Promise.all(Array.from({ length: concurrency }, worker));
  if (signal?.aborted) throw abortError();
  return open;
}

function isPortOpen(host: string, port: number, timeoutMs: number, signal?: AbortSignal) {
  return new Promise<boolean>((resolve) => {
    if (signal?.aborted) return resolve(false);
    const socket = net.createConnection({ host, port });
    let settled = false;
    const finish = (value: boolean) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener('abort', abort);
      socket.destroy();
      resolve(value);
    };
    const abort = () => finish(false);
    const timer = setTimeout(() => finish(false), timeoutMs);
    signal?.addEventListener('abort', abort, { once: true });
    socket.once('connect', () => {
      clearTimeout(timer);
      finish(true);
    });
    socket.once('error', () => {
      clearTimeout(timer);
      finish(false);
    });
  });
}

function compactAccessibility(nodes: Array<Record<string, unknown>>) {
  const lines: string[] = [];
  const focused: string[] = [];
  for (const node of nodes) {
    if (node.ignored === true) continue;
    const role = String((node.role as { value?: unknown } | undefined)?.value ?? '');
    const name = String((node.name as { value?: unknown } | undefined)?.value ?? '').replace(/\s+/g, ' ').trim();
    const value = String((node.value as { value?: unknown } | undefined)?.value ?? '').replace(/\s+/g, ' ').trim();
    const properties = (node.properties as Array<{ name?: string; value?: { value?: unknown } }> | undefined) ?? [];
    const isFocused = properties.some((property) => property.name === 'focused' && property.value?.value === true);
    if (!name && !value && !isFocused) continue;
    const line = `${isFocused ? '[FOCUSED] ' : ''}${role || 'element'}: ${(name || value).slice(0, 180)}`;
    if (isFocused) focused.push(line);
    if (lines.length < 140) lines.push(line);
  }
  return { text: lines.join('\n'), focused: focused.join('\n') || 'No focused accessibility node reported.' };
}

function abortError() {
  return new DOMException('Operation canceled.', 'AbortError');
}

function abortableDelay(milliseconds: number, signal?: AbortSignal) {
  return new Promise<void>((resolve, reject) => {
    if (signal?.aborted) return reject(abortError());
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', abort);
      resolve();
    }, milliseconds);
    const abort = () => {
      clearTimeout(timer);
      reject(abortError());
    };
    signal?.addEventListener('abort', abort, { once: true });
  });
}
