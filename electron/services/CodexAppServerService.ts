import { EventEmitter } from 'node:events';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { existsSync, promises as fs } from 'node:fs';
import path from 'node:path';
import type { AiRuntimeState, AiUsageState } from '../../src/shared/types';

export const LUNA_MODEL = 'gpt-5.6-luna' as const;
export const LUNA_EFFORT = 'max' as const;
export const CODEX_RUNTIME_VERSION = '0.147.0';

const REQUEST_TIMEOUT_MS = 30_000;
const TURN_START_TIMEOUT_MS = 60_000;
const MAX_STDOUT_BUFFER = 4 * 1024 * 1024;
const MAX_MODEL_TOOL_CALLS = 48;

export const DISABLED_CODEX_FEATURES = [
  'apps',
  'browser_use',
  'browser_use_external',
  'browser_use_full_cdp_access',
  'computer_use',
  'enable_mcp_apps',
  'hooks',
  'image_generation',
  'in_app_browser',
  'memories',
  'multi_agent',
  'multi_agent_v2',
  'plugins',
  'remote_plugin',
  'shell_snapshot',
  'shell_tool',
  'skill_mcp_dependency_install',
  'tool_suggest',
  'unified_exec',
  'workspace_dependencies',
] as const;

export const FORBIDDEN_THREAD_ITEM_TYPES = new Set([
  'commandExecution',
  'fileChange',
  'mcpToolCall',
  'collabAgentToolCall',
  'subAgentActivity',
  'webSearch',
  'imageView',
  'imageGeneration',
]);

const ALLOWED_AUTH_HOSTS = new Set([
  'auth.openai.com',
  'chatgpt.com',
  'openai.com',
  'platform.openai.com',
]);

const HARDENED_CONFIG = `forced_login_method = "chatgpt"
cli_auth_credentials_store = "keyring"
history.persistence = "none"
web_search = "disabled"
check_for_update_on_startup = false
approval_policy = "never"
sandbox_mode = "read-only"
model = "${LUNA_MODEL}"
model_reasoning_effort = "${LUNA_EFFORT}"

[analytics]
enabled = false

[feedback]
enabled = false

[tools]
web_search = false
`;

export interface LunaToolSpec {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

export interface LunaToolCall {
  name: string;
  arguments: Record<string, unknown>;
}

export interface LunaToolResult {
  text: string;
  imageDataUrl?: string;
}

export interface LunaRunOptions {
  prompt: string;
  instructions: string;
  tools: LunaToolSpec[];
  onTool: (call: LunaToolCall) => Promise<LunaToolResult>;
  signal: AbortSignal;
}

interface JsonRpcRequest {
  id: number | string;
  method: string;
  params?: unknown;
}

interface JsonRpcResponse {
  id: number | string;
  result?: unknown;
  error?: { code?: number; message?: string };
}

interface JsonRpcNotification {
  method: string;
  params?: unknown;
}

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

interface ModelEntry {
  id?: string;
  model?: string;
  supportedReasoningEfforts?: Array<{ reasoningEffort?: string }>;
  inputModalities?: string[];
}

interface AccountResponse {
  account: null | { type: string; email?: string | null; planType?: string };
}

interface RateLimitWindow {
  usedPercent?: number;
  resetsAt?: number | null;
}

interface RateLimitSnapshot {
  primary?: RateLimitWindow | null;
  secondary?: RateLimitWindow | null;
  rateLimitReachedType?: string | null;
}

interface ActiveTurn {
  threadId: string;
  turnId: string | null;
  allowedTools: Set<string>;
  onTool: LunaRunOptions['onTool'];
  signal: AbortSignal;
  toolCalls: number;
  settled: boolean;
  resolve: () => void;
  reject: (error: Error) => void;
}

export class CodexAppServerService extends EventEmitter {
  private child: ChildProcessWithoutNullStreams | null = null;
  private starting: Promise<void> | null = null;
  private stdoutBuffer = '';
  private requestId = 1;
  private pending = new Map<number | string, PendingRequest>();
  private loginId: string | null = null;
  private activeTurn: ActiveTurn | null = null;
  private state: AiRuntimeState = baseState('starting');

  private readonly codexHome: string;
  private readonly emptyWorkspace: string;
  private readonly executablePath: string;

  constructor(userDataPath: string, executablePath = resolveBundledCodexExecutable()) {
    super();
    this.codexHome = path.join(userDataPath, 'luna-codex-home');
    this.emptyWorkspace = path.join(userDataPath, 'luna-empty-workspace');
    this.executablePath = executablePath;
  }

  currentState() {
    return structuredClone(this.state);
  }

  async getState(): Promise<AiRuntimeState> {
    try {
      await this.ensureStarted();
      const accountResponse = await this.request<AccountResponse>('account/read', { refreshToken: false });
      const account = accountResponse.account;
      if (!account) return this.setState(baseState(this.loginId ? 'signingIn' : 'signedOut'));
      if (account.type !== 'chatgpt') {
        return this.setState({
          ...baseState('unavailable'),
          available: true,
          error: 'VizioControl accepts ChatGPT sign-in only. API-key and provider sessions are rejected.',
        });
      }

      const models = await this.listModels();
      const luna = models.find((model) => model.id === LUNA_MODEL || model.model === LUNA_MODEL);
      const supportsMax = luna?.supportedReasoningEfforts?.some((entry) => entry.reasoningEffort === LUNA_EFFORT) === true;
      const supportsImages = luna?.inputModalities?.includes('image') === true;
      const usage = await this.readUsage();
      const common = {
        ...baseState('ready'),
        available: true,
        signedIn: true,
        email: account.email ?? undefined,
        planType: account.planType ?? 'unknown',
        usage,
      } satisfies AiRuntimeState;

      if (!luna) {
        return this.setState({ ...common, ready: false, status: 'unavailable', error: 'This ChatGPT account does not currently expose GPT-5.6 Luna.' });
      }
      if (!supportsMax || !supportsImages) {
        return this.setState({
          ...common,
          ready: false,
          status: 'unavailable',
          error: `GPT-5.6 Luna is present but does not advertise ${!supportsMax ? 'Max reasoning' : 'image input'} for this account.`,
        });
      }
      if (usage.limitReached) {
        return this.setState({ ...common, ready: false, status: 'unavailable', error: 'The current ChatGPT usage limit has been reached. Manual TV controls still work.' });
      }
      return this.setState(common);
    } catch (error) {
      return this.setState({
        ...baseState('unavailable'),
        error: publicError(error, 'The bundled Luna runtime is unavailable. Manual TV controls still work.'),
      });
    }
  }

  async signIn(): Promise<{ state: AiRuntimeState; authUrl?: string }> {
    await this.ensureStarted();
    const account = await this.request<AccountResponse>('account/read', { refreshToken: false });
    if (account.account?.type === 'chatgpt') return { state: await this.getState() };
    const response = await this.request<{ type: string; loginId?: string; authUrl?: string }>('account/login/start', {
      type: 'chatgpt',
      codexStreamlinedLogin: true,
    });
    if (response.type !== 'chatgpt' || !response.loginId || !response.authUrl || !isAllowedAuthUrl(response.authUrl)) {
      throw new Error('The bundled runtime returned an invalid ChatGPT authentication URL.');
    }
    this.loginId = response.loginId;
    return { state: this.setState({ ...baseState('signingIn'), available: true }), authUrl: response.authUrl };
  }

  async cancelSignIn() {
    if (this.loginId) {
      await this.request('account/login/cancel', { loginId: this.loginId }).catch(() => undefined);
      this.loginId = null;
    }
    return await this.getState();
  }

  async signOut() {
    await this.ensureStarted();
    await this.request('account/logout', undefined);
    this.loginId = null;
    return await this.getState();
  }

  async run(options: LunaRunOptions): Promise<void> {
    throwIfAborted(options.signal);
    const state = await withAbort(this.getState(), options.signal);
    throwIfAborted(options.signal);
    if (!state.ready) throw new Error(state.error || 'Sign in with a ChatGPT account that has GPT-5.6 Luna Max access.');
    if (this.activeTurn) throw new Error('A Luna TV navigation run is already active.');
    validateToolSpecs(options.tools);

    const threadResponse = await withAbort(this.request<{
      thread: { id: string; ephemeral: boolean };
      model: string;
    }>('thread/start', {
      model: LUNA_MODEL,
      cwd: this.emptyWorkspace,
      runtimeWorkspaceRoots: [],
      approvalPolicy: 'never',
      sandbox: 'read-only',
      config: hardenedThreadConfig(),
      baseInstructions: options.instructions,
      developerInstructions: 'Use only the registered tv_* dynamic tools. Never request or use shell, files, Windows control, browser, web, MCP, apps, plugins, connectors, skills, permissions, or other agents.',
      ephemeral: true,
      environments: [],
      selectedCapabilityRoots: [],
      dynamicTools: options.tools.map((tool) => ({
        type: 'function',
        name: tool.name,
        description: tool.description,
        inputSchema: tool.inputSchema,
        deferLoading: false,
      })),
    }), options.signal);
    throwIfAborted(options.signal);

    if (threadResponse.model !== LUNA_MODEL || threadResponse.thread?.ephemeral !== true || !threadResponse.thread.id) {
      throw new Error('The Luna runtime refused the exact ephemeral GPT-5.6 Luna session. No fallback model was used.');
    }

    let resolveTurn!: () => void;
    let rejectTurn!: (error: Error) => void;
    const completion = new Promise<void>((resolve, reject) => {
      resolveTurn = resolve;
      rejectTurn = reject;
    });
    // An abort can reject this promise while turn/start is still awaiting its
    // response. Keep that rejection observed until the main path reaches it.
    void completion.catch(() => undefined);
    const active: ActiveTurn = {
      threadId: threadResponse.thread.id,
      turnId: null,
      allowedTools: new Set(options.tools.map((tool) => tool.name)),
      onTool: options.onTool,
      signal: options.signal,
      toolCalls: 0,
      settled: false,
      resolve: resolveTurn,
      reject: rejectTurn,
    };
    this.activeTurn = active;

    const abort = () => void this.interruptActive('Luna TV navigation canceled.');
    options.signal.addEventListener('abort', abort, { once: true });
    try {
      if (options.signal.aborted) {
        await this.interruptActive('Luna TV navigation canceled.');
        throw abortError('Luna TV navigation canceled.');
      }
      const turnStart = this.request<{ turn: { id: string } }>('turn/start', {
        threadId: active.threadId,
        input: [{ type: 'text', text: `TV request: ${options.prompt}\n\nBegin with the most relevant registered TV read tool: tv_observe for visual app navigation or tv_read_setting for a native setting request. Complete this request only through the registered tv_* tools.`, text_elements: [] }],
        environments: [],
        cwd: this.emptyWorkspace,
        runtimeWorkspaceRoots: [],
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'readOnly', networkAccess: false },
        model: LUNA_MODEL,
        effort: LUNA_EFFORT,
        summary: 'none',
      }, TURN_START_TIMEOUT_MS);
      // If cancellation wins the race before App Server returns a turn id,
      // interrupt that late-created turn as soon as its id becomes available.
      void turnStart.then(async (response) => {
        if (!options.signal.aborted && !active.settled) return;
        await this.request('turn/interrupt', {
          threadId: active.threadId,
          turnId: response.turn.id,
        }, 8_000).catch(() => undefined);
      }).catch(() => undefined);
      let turnResponse: { turn: { id: string } };
      try {
        turnResponse = await withAbort(turnStart, options.signal);
        throwIfAborted(options.signal);
        if (!turnResponse.turn?.id) throw new Error('The Luna runtime did not return a turn identifier.');
      } catch (error) {
        if (!active.turnId) this.failClosedUnidentifiedTurn();
        throw error;
      }
      if (active.turnId && active.turnId !== turnResponse.turn.id) {
        this.failRuntime(new Error('The Luna runtime returned a mismatched turn identifier.'));
        throw new Error('The Luna runtime returned a mismatched turn identifier.');
      }
      active.turnId = turnResponse.turn.id;
      await completion;
    } finally {
      options.signal.removeEventListener('abort', abort);
      if (this.activeTurn === active) this.activeTurn = null;
    }
  }

  async interruptActive(reason = 'Luna TV navigation stopped.') {
    const active = this.activeTurn;
    if (!active || active.settled) return;
    active.settled = true;
    active.reject(abortError(reason));
    if (active.turnId) {
      void this.request('turn/interrupt', { threadId: active.threadId, turnId: active.turnId }, 8_000).catch(() => undefined);
    } else {
      this.failClosedUnidentifiedTurn();
    }
  }

  async shutdown() {
    await this.interruptActive('VizioControl is closing.');
    const child = this.child;
    this.child = null;
    if (child && !child.killed) child.kill();
    this.rejectAll(new Error('The bundled Luna runtime stopped.'));
  }

  private async ensureStarted() {
    if (this.child && !this.child.killed) return;
    if (!this.starting) {
      this.starting = this.startProcess().finally(() => {
        this.starting = null;
      });
    }
    await this.starting;
  }

  private async startProcess() {
    if (!existsSync(this.executablePath)) throw new Error('The pinned Codex App Server runtime is missing from this build.');
    await fs.mkdir(this.codexHome, { recursive: true });
    await fs.mkdir(this.emptyWorkspace, { recursive: true });
    await fs.writeFile(path.join(this.codexHome, 'config.toml'), HARDENED_CONFIG, { encoding: 'utf8', mode: 0o600 });

    const environment = buildCodexEnvironment(process.env, this.codexHome);
    const args = ['app-server', '--stdio', '--strict-config'];
    for (const feature of DISABLED_CODEX_FEATURES) args.push('--disable', feature);
    const child = spawn(this.executablePath, args, {
      cwd: this.emptyWorkspace,
      env: environment,
      windowsHide: true,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.child = child;
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => this.consumeStdout(chunk));
    // Stderr can contain protocol diagnostics. It is intentionally discarded so
    // authentication, prompts, screenshots, and accessibility data never enter app logs.
    child.stderr.resume();
    child.once('error', (error) => this.handleChildExit(child, error));
    child.once('exit', (code) => this.handleChildExit(child, new Error(`The bundled Luna runtime exited${code === null ? '' : ` with code ${code}`}.`)));

    try {
      await this.request('initialize', {
        clientInfo: { name: 'viziocontrol', title: 'VizioControl', version: '1.0.0' },
        capabilities: {
          experimentalApi: true,
          requestAttestation: false,
          mcpServerOpenaiFormElicitation: false,
          optOutNotificationMethods: [],
        },
      });
      this.notify('initialized');
      // App Server has an optional ChatGPT remote-control transport. VizioControl
      // never uses it; stdio is the sole control channel for this process.
      await this.request('remoteControl/disable', { ephemeral: true });
    } catch (error) {
      const failure = error instanceof Error ? error : new Error('The bundled Luna runtime handshake failed.');
      if (this.child === child) this.terminateChild(child, failure);
      throw failure;
    }
  }

  private consumeStdout(chunk: string) {
    this.stdoutBuffer += chunk;
    if (this.stdoutBuffer.length > MAX_STDOUT_BUFFER) {
      this.failRuntime(new Error('The Luna runtime produced an oversized protocol message.'));
      return;
    }
    for (;;) {
      const newline = this.stdoutBuffer.indexOf('\n');
      if (newline < 0) break;
      const line = this.stdoutBuffer.slice(0, newline).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1);
      if (!line) continue;
      let message: JsonRpcResponse | JsonRpcRequest | JsonRpcNotification;
      try {
        message = JSON.parse(line) as JsonRpcResponse | JsonRpcRequest | JsonRpcNotification;
      } catch {
        this.failRuntime(new Error('The Luna runtime returned malformed protocol data.'));
        return;
      }
      void this.handleMessage(message);
    }
  }

  private async handleMessage(message: JsonRpcResponse | JsonRpcRequest | JsonRpcNotification) {
    if ('id' in message && !('method' in message)) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error(sanitizeProtocolError(message.error.message)));
      else pending.resolve(message.result);
      return;
    }
    if (!('method' in message)) return;
    if ('id' in message) {
      await this.handleServerRequest(message);
      return;
    }
    this.handleNotification(message);
  }

  private async handleServerRequest(message: JsonRpcRequest) {
    if (message.method !== 'item/tool/call') {
      this.respondError(message.id, -32601, 'VizioControl allows TV tools only.');
      await this.failActiveSecurity(`Blocked unexpected App Server request: ${message.method}`);
      return;
    }
    const params = asRecord(message.params);
    const active = this.activeTurn;
    const tool = typeof params.tool === 'string' ? params.tool : '';
    const threadId = typeof params.threadId === 'string' ? params.threadId : '';
    const turnId = typeof params.turnId === 'string' ? params.turnId : '';
    if (!active || active.settled || active.signal.aborted || params.namespace !== null || threadId !== active.threadId || !turnId || !active.allowedTools.has(tool)) {
      this.respondError(message.id, -32602, 'Rejected unregistered or out-of-session tool call.');
      await this.failActiveSecurity('Luna attempted an unregistered or out-of-session tool call.');
      return;
    }
    if (active.turnId && active.turnId !== turnId) {
      this.respondError(message.id, -32602, 'Rejected mismatched turn.');
      await this.failActiveSecurity('Luna attempted a tool call from a mismatched turn.');
      return;
    }
    active.turnId = turnId;
    active.toolCalls += 1;
    if (active.toolCalls > MAX_MODEL_TOOL_CALLS) {
      this.respondError(message.id, -32001, 'The 48-step Luna reasoning limit was reached.');
      await this.failActiveSecurity('The 48-step Luna reasoning limit was reached.');
      return;
    }
    try {
      const args = asRecord(params.arguments);
      const result = await active.onTool({ name: tool, arguments: args });
      const contentItems: Array<Record<string, unknown>> = [{ type: 'inputText', text: result.text }];
      if (result.imageDataUrl) contentItems.push({ type: 'inputImage', imageUrl: result.imageDataUrl });
      this.respond(message.id, { contentItems, success: true });
    } catch (error) {
      this.respond(message.id, {
        contentItems: [{ type: 'inputText', text: publicError(error, 'The TV tool was rejected.') }],
        success: false,
      });
    }
  }

  private handleNotification(message: JsonRpcNotification) {
    const params = asRecord(message.params);
    if (message.method === 'account/login/completed') {
      const success = params.success === true;
      this.loginId = null;
      if (!success) {
        this.setState({ ...baseState('signedOut'), available: true, error: sanitizeProtocolError(typeof params.error === 'string' ? params.error : 'ChatGPT sign-in did not complete.') });
      } else {
        void this.getState();
      }
      return;
    }
    if (message.method === 'account/updated' || message.method === 'account/rateLimits/updated') {
      void this.getState();
      return;
    }
    if (message.method === 'model/rerouted') {
      void this.failActiveSecurity('The runtime attempted to substitute a different model. Luna navigation stopped.');
      return;
    }
    if (message.method === 'item/started' || message.method === 'item/completed') {
      const item = asRecord(params.item);
      if (typeof item.type === 'string' && FORBIDDEN_THREAD_ITEM_TYPES.has(item.type)) {
        void this.failActiveSecurity(`Blocked unexpected ${item.type} activity from the Luna session.`);
      }
      return;
    }
    if (message.method === 'turn/completed') {
      const active = this.activeTurn;
      const turn = asRecord(params.turn);
      const threadId = typeof params.threadId === 'string' ? params.threadId : '';
      const turnId = typeof turn.id === 'string' ? turn.id : '';
      if (!active || active.settled || active.threadId !== threadId || (active.turnId && active.turnId !== turnId)) return;
      active.turnId = turnId;
      active.settled = true;
      if (turn.status === 'failed') {
        const turnError = asRecord(turn.error);
        active.reject(new Error(sanitizeProtocolError(typeof turnError.message === 'string' ? turnError.message : 'Luna could not complete the TV navigation turn.')));
      } else {
        active.resolve();
      }
    }
  }

  private async failActiveSecurity(message: string) {
    const active = this.activeTurn;
    if (!active || active.settled) return;
    active.settled = true;
    active.reject(new Error(message));
    if (active.turnId) {
      void this.request('turn/interrupt', { threadId: active.threadId, turnId: active.turnId }, 8_000).catch(() => undefined);
    } else {
      this.failClosedUnidentifiedTurn();
    }
  }

  private async listModels() {
    const models: ModelEntry[] = [];
    let cursor: string | null = null;
    for (let page = 0; page < 10; page += 1) {
      const response: { data?: ModelEntry[]; nextCursor?: string | null } = await this.request('model/list', {
        cursor,
        limit: 100,
        includeHidden: true,
      });
      models.push(...(response.data ?? []));
      cursor = response.nextCursor ?? null;
      if (!cursor) break;
    }
    return models;
  }

  private async readUsage(): Promise<AiUsageState> {
    try {
      const response = await this.request<{ rateLimits?: RateLimitSnapshot }>('account/rateLimits/read', undefined);
      const limits = response.rateLimits ?? {};
      return {
        primaryUsedPercent: finiteNumber(limits.primary?.usedPercent),
        primaryResetsAt: finiteNumber(limits.primary?.resetsAt),
        secondaryUsedPercent: finiteNumber(limits.secondary?.usedPercent),
        secondaryResetsAt: finiteNumber(limits.secondary?.resetsAt),
        limitReached: Boolean(limits.rateLimitReachedType)
          || (limits.primary?.usedPercent ?? 0) >= 100
          || (limits.secondary?.usedPercent ?? 0) >= 100,
        limitReason: limits.rateLimitReachedType ?? undefined,
      };
    } catch {
      return { limitReached: false };
    }
  }

  private request<T = unknown>(method: string, params: unknown, timeoutMs = REQUEST_TIMEOUT_MS): Promise<T> {
    const child = this.child;
    if (!child || child.killed || !child.stdin.writable) return Promise.reject(new Error('The bundled Luna runtime is not running.'));
    const id = this.requestId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`The Luna runtime timed out while handling ${method}.`));
      }, timeoutMs);
      this.pending.set(id, { resolve: (value) => resolve(value as T), reject, timer });
      child.stdin.write(`${JSON.stringify({ method, id, params })}\n`, (error) => {
        if (!error) return;
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new Error('Could not write to the bundled Luna runtime.'));
      });
    });
  }

  private notify(method: string, params?: unknown) {
    const child = this.child;
    if (!child || child.killed || !child.stdin.writable) return;
    child.stdin.write(`${JSON.stringify(params === undefined ? { method } : { method, params })}\n`);
  }

  private respond(id: number | string, result: unknown) {
    const child = this.child;
    if (!child || child.killed || !child.stdin.writable) return;
    child.stdin.write(`${JSON.stringify({ id, result })}\n`);
  }

  private respondError(id: number | string, code: number, message: string) {
    const child = this.child;
    if (!child || child.killed || !child.stdin.writable) return;
    child.stdin.write(`${JSON.stringify({ id, error: { code, message } })}\n`);
  }

  private failClosedUnidentifiedTurn() {
    this.failRuntime(new Error('The Luna runtime was restarted because a TV turn began without a verified turn identifier.'));
  }

  private failRuntime(error: Error) {
    const child = this.child;
    if (child) this.terminateChild(child, error);
  }

  private handleChildExit(child: ChildProcessWithoutNullStreams, error: Error) {
    if (this.child !== child) return;
    this.terminateChild(child, error);
  }

  private terminateChild(child: ChildProcessWithoutNullStreams, error: Error) {
    if (this.child !== child) return;
    this.child = null;
    this.stdoutBuffer = '';
    this.rejectAll(error);
    const active = this.activeTurn;
    if (active && !active.settled) {
      active.settled = true;
      active.reject(new Error('The bundled Luna runtime stopped during navigation. Manual TV control is ready.'));
    }
    this.setState({ ...baseState('unavailable'), error: publicError(error, 'The bundled Luna runtime stopped.') });
    if (!child.killed) child.kill();
  }

  private rejectAll(error: Error) {
    for (const [, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }

  private setState(state: AiRuntimeState) {
    this.state = state;
    this.emit('state', structuredClone(state));
    return structuredClone(state);
  }
}

export function isAllowedAuthUrl(value: string) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && (ALLOWED_AUTH_HOSTS.has(url.hostname) || url.hostname.endsWith('.openai.com') || url.hostname.endsWith('.chatgpt.com'));
  } catch {
    return false;
  }
}

export function validateToolSpecs(tools: LunaToolSpec[]) {
  if (!tools.length || tools.length > 12) throw new Error('Invalid Luna TV tool set.');
  const names = new Set<string>();
  for (const tool of tools) {
    if (!/^tv_[a-z_]{2,40}$/.test(tool.name) || names.has(tool.name)) throw new Error('Invalid or duplicate Luna TV tool name.');
    names.add(tool.name);
    if (!tool.description || typeof tool.inputSchema !== 'object') throw new Error('Invalid Luna TV tool definition.');
  }
}

export function resolveBundledCodexExecutable() {
  const resourcesPath = (process as NodeJS.Process & { resourcesPath?: string }).resourcesPath;
  const candidates = [
    resourcesPath && path.join(resourcesPath, 'codex', 'bin', 'codex.exe'),
    path.join(process.cwd(), 'node_modules', '@openai', 'codex-win32-x64', 'vendor', 'x86_64-pc-windows-msvc', 'bin', 'codex.exe'),
  ].filter((candidate): candidate is string => Boolean(candidate));
  return candidates.find((candidate) => existsSync(candidate)) ?? candidates[0];
}

const CODEX_ENVIRONMENT_ALLOWLIST = new Set([
  'APPDATA',
  'COMSPEC',
  'HOME',
  'HOMEDRIVE',
  'HOMEPATH',
  'HTTP_PROXY',
  'HTTPS_PROXY',
  'LANG',
  'LC_ALL',
  'LOCALAPPDATA',
  'NO_PROXY',
  'NUMBER_OF_PROCESSORS',
  'OS',
  'PATH',
  'PATHEXT',
  'PROCESSOR_ARCHITECTURE',
  'PROGRAMDATA',
  'PROGRAMFILES',
  'PROGRAMFILES(X86)',
  'SSL_CERT_DIR',
  'SSL_CERT_FILE',
  'SYSTEMDRIVE',
  'SYSTEMROOT',
  'TEMP',
  'TMP',
  'TZ',
  'USERDOMAIN',
  'USERNAME',
  'USERPROFILE',
  'WINDIR',
]);

export function buildCodexEnvironment(source: NodeJS.ProcessEnv, codexHome: string): NodeJS.ProcessEnv {
  const environment: NodeJS.ProcessEnv = {};
  for (const [name, value] of Object.entries(source)) {
    if (value !== undefined && CODEX_ENVIRONMENT_ALLOWLIST.has(name.toUpperCase())) {
      environment[name] = value;
    }
  }
  environment.CODEX_HOME = codexHome;
  return environment;
}

function hardenedThreadConfig() {
  return {
    'features.apps': false,
    'features.browser_use': false,
    'features.computer_use': false,
    'features.in_app_browser': false,
    'features.multi_agent': false,
    'features.plugins': false,
    'features.shell_snapshot': false,
    'features.shell_tool': false,
    'features.unified_exec': false,
    'tools.web_search': false,
    web_search: 'disabled',
  };
}

function baseState(status: AiRuntimeState['status']): AiRuntimeState {
  return {
    available: status !== 'unavailable',
    signedIn: status === 'ready',
    ready: status === 'ready',
    status,
    model: LUNA_MODEL,
    effort: LUNA_EFFORT,
    runtimeVersion: CODEX_RUNTIME_VERSION,
  };
}

function asRecord(value: unknown): Record<string, any> {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, any> : {};
}

function finiteNumber(value: unknown) {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

function sanitizeProtocolError(value: unknown) {
  if (typeof value !== 'string' || !value.trim()) return 'The Luna runtime returned an error.';
  return value.replace(/https?:\/\/\S+/gi, '[authentication link hidden]').replace(/[\r\n\t]+/g, ' ').slice(0, 300);
}

function publicError(error: unknown, fallback: string) {
  return error instanceof Error && error.message ? sanitizeProtocolError(error.message) : fallback;
}

function abortError(message: string) {
  return new DOMException(message, 'AbortError');
}

function throwIfAborted(signal: AbortSignal) {
  if (signal.aborted) throw abortError('Luna TV navigation canceled.');
}

function withAbort<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(abortError('Luna TV navigation canceled.'));
  return new Promise<T>((resolve, reject) => {
    const abort = () => {
      cleanup();
      reject(abortError('Luna TV navigation canceled.'));
    };
    const cleanup = () => signal.removeEventListener('abort', abort);
    signal.addEventListener('abort', abort, { once: true });
    promise.then(
      (value) => {
        cleanup();
        resolve(value);
      },
      (error) => {
        cleanup();
        reject(error);
      },
    );
  });
}
