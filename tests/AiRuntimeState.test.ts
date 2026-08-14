import { describe, expect, it, vi } from 'vitest';
import { CodexAppServerService } from '../electron/services/CodexAppServerService';

type InternalService = {
  ensureStarted(): Promise<void>;
  request(method: string, params: unknown, timeoutMs?: number): Promise<unknown>;
  child: unknown;
  pending: Map<number, { resolve(value: unknown): void; reject(error: Error): void; timer: NodeJS.Timeout }>;
  consumeStdout(chunk: string): void;
  failRuntime(error: Error): void;
};

function mockedService(handler: (method: string, params: unknown) => unknown) {
  const service = new CodexAppServerService('C:\\unused', 'C:\\missing\\codex.exe');
  const internal = service as unknown as InternalService;
  internal.ensureStarted = vi.fn(async () => undefined);
  internal.request = vi.fn(async (method, params) => handler(method, params));
  return { service, internal };
}

function compatibleLuna() {
  return {
    id: 'gpt-5.6-luna',
    model: 'gpt-5.6-luna',
    supportedReasoningEfforts: [{ reasoningEffort: 'max' }],
    inputModalities: ['text', 'image'],
  };
}

function signedInHandler(overrides: { models?: unknown[]; usedPercent?: number; reached?: string | null } = {}) {
  return (method: string) => {
    if (method === 'account/read') return { account: { type: 'chatgpt', email: 'viewer@example.invalid', planType: 'plus' } };
    if (method === 'model/list') return { data: overrides.models ?? [compatibleLuna()], nextCursor: null };
    if (method === 'account/rateLimits/read') return {
      rateLimits: {
        primary: { usedPercent: overrides.usedPercent ?? 12, resetsAt: 1_800_000_000 },
        secondary: null,
        rateLimitReachedType: overrides.reached ?? null,
      },
    };
    throw new Error(`Unexpected request: ${method}`);
  };
}

describe('ChatGPT and Luna readiness', () => {
  it('requires the exact Luna model, Max effort, and image input', async () => {
    const ready = mockedService(signedInHandler());
    await expect(ready.service.getState()).resolves.toMatchObject({
      status: 'ready', signedIn: true, ready: true, model: 'gpt-5.6-luna', effort: 'max', planType: 'plus',
    });

    const missing = mockedService(signedInHandler({ models: [] }));
    await expect(missing.service.getState()).resolves.toMatchObject({ ready: false, status: 'unavailable', error: expect.stringContaining('does not currently expose') });

    const noMax = mockedService(signedInHandler({ models: [{ ...compatibleLuna(), supportedReasoningEfforts: [{ reasoningEffort: 'high' }] }] }));
    await expect(noMax.service.getState()).resolves.toMatchObject({ ready: false, error: expect.stringContaining('Max reasoning') });

    const noImage = mockedService(signedInHandler({ models: [{ ...compatibleLuna(), inputModalities: ['text'] }] }));
    await expect(noImage.service.getState()).resolves.toMatchObject({ ready: false, error: expect.stringContaining('image input') });
  });

  it('disables Luna navigation at a usage limit while preserving signed-in state', async () => {
    const { service } = mockedService(signedInHandler({ usedPercent: 100, reached: 'rate_limit_reached' }));
    await expect(service.getState()).resolves.toMatchObject({
      signedIn: true,
      ready: false,
      usage: { primaryUsedPercent: 100, limitReached: true, limitReason: 'rate_limit_reached' },
      error: expect.stringContaining('usage limit'),
    });
  });

  it('reports signed-out and offline states without affecting manual controls', async () => {
    const signedOut = mockedService((method) => {
      if (method === 'account/read') return { account: null };
      throw new Error(`Unexpected request: ${method}`);
    });
    await expect(signedOut.service.getState()).resolves.toMatchObject({ status: 'signedOut', signedIn: false, ready: false });

    const offline = mockedService(() => undefined);
    offline.internal.ensureStarted = vi.fn(async () => { throw new Error('network unavailable'); });
    await expect(offline.service.getState()).resolves.toMatchObject({ status: 'unavailable', ready: false, error: 'network unavailable' });
  });

  it('reuses cached ChatGPT authentication instead of starting another browser login', async () => {
    const handler = signedInHandler();
    const { service, internal } = mockedService(handler);
    const result = await service.signIn();
    expect(result.authUrl).toBeUndefined();
    expect(result.state).toMatchObject({ signedIn: true, ready: true });
    expect(internal.request).not.toHaveBeenCalledWith('account/login/start', expect.anything());
  });

  it('starts only ChatGPT browser authentication and rejects unsafe authentication URLs', async () => {
    const valid = mockedService((method) => {
      if (method === 'account/read') return { account: null };
      if (method === 'account/login/start') return { type: 'chatgpt', loginId: 'login-1', authUrl: 'https://auth.openai.com/oauth/authorize' };
      throw new Error(`Unexpected request: ${method}`);
    });
    await expect(valid.service.signIn()).resolves.toMatchObject({
      authUrl: 'https://auth.openai.com/oauth/authorize',
      state: { status: 'signingIn', signedIn: false },
    });
    expect(valid.internal.request).toHaveBeenCalledWith('account/login/start', { type: 'chatgpt', codexStreamlinedLogin: true });

    const unsafe = mockedService((method) => {
      if (method === 'account/read') return { account: null };
      if (method === 'account/login/start') return { type: 'chatgpt', loginId: 'login-2', authUrl: 'file:///C:/Windows/System32/cmd.exe' };
      throw new Error(`Unexpected request: ${method}`);
    });
    await expect(unsafe.service.signIn()).rejects.toThrow('invalid ChatGPT authentication URL');
  });

  it('moves to unavailable when App Server is interrupted', () => {
    const { service, internal } = mockedService(() => undefined);
    const child = { killed: false, kill: vi.fn(() => true) };
    internal.child = child;
    internal.failRuntime(new Error('interrupted'));
    expect(service.currentState()).toMatchObject({ status: 'unavailable', ready: false, error: 'interrupted' });
    expect(child.kill).toHaveBeenCalledOnce();
    expect(internal.child).toBeNull();
  });

  it('kills a malformed protocol process after rejecting pending requests', () => {
    const { service, internal } = mockedService(() => undefined);
    const order: string[] = [];
    const child = { killed: false, kill: vi.fn(() => { order.push('kill'); return true; }) };
    const timer = setTimeout(() => undefined, 10_000);
    internal.child = child;
    internal.pending = new Map([[1, {
      resolve: () => undefined,
      reject: () => order.push('reject'),
      timer,
    }]]);

    internal.consumeStdout('{not-json}\n');

    expect(order).toEqual(['reject', 'kill']);
    expect(internal.child).toBeNull();
    expect(service.currentState()).toMatchObject({ status: 'unavailable', error: expect.stringContaining('malformed protocol') });
  });

  it('rejects a pre-canceled Luna run before starting readiness checks', async () => {
    const { service } = mockedService(() => undefined);
    const getState = vi.spyOn(service, 'getState');
    const controller = new AbortController();
    controller.abort();

    await expect(service.run(runOptions(controller.signal))).rejects.toMatchObject({ name: 'AbortError' });
    expect(getState).not.toHaveBeenCalled();
  });

  it('cancels during turn startup and interrupts a turn id that arrives late', async () => {
    let resolveTurnStart!: (value: { turn: { id: string } }) => void;
    const turnStart = new Promise<{ turn: { id: string } }>((resolve) => {
      resolveTurnStart = resolve;
    });
    const { service, internal } = mockedService((method) => {
      if (method === 'thread/start') return { thread: { id: 'thread-1', ephemeral: true }, model: 'gpt-5.6-luna' };
      if (method === 'turn/start') return turnStart;
      if (method === 'turn/interrupt') return {};
      throw new Error(`Unexpected request: ${method}`);
    });
    vi.spyOn(service, 'getState').mockResolvedValue({
      available: true,
      signedIn: true,
      ready: true,
      status: 'ready',
      model: 'gpt-5.6-luna',
      effort: 'max',
      runtimeVersion: '0.147.0',
    });
    const controller = new AbortController();
    const running = service.run(runOptions(controller.signal));
    await vi.waitFor(() => expect(internal.request).toHaveBeenCalledWith('turn/start', expect.anything(), 60_000));

    controller.abort();
    await expect(running).rejects.toMatchObject({ name: 'AbortError' });
    resolveTurnStart({ turn: { id: 'turn-late' } });
    await vi.waitFor(() => expect(internal.request).toHaveBeenCalledWith('turn/interrupt', {
      threadId: 'thread-1',
      turnId: 'turn-late',
    }, 8_000));
  });

  it('rejects Stop immediately even when App Server never answers turn/interrupt', async () => {
    const never = new Promise<never>(() => undefined);
    const { service, internal } = mockedService((method) => {
      if (method === 'thread/start') return { thread: { id: 'thread-live', ephemeral: true }, model: 'gpt-5.6-luna' };
      if (method === 'turn/start') return { turn: { id: 'turn-live' } };
      if (method === 'turn/interrupt') return never;
      throw new Error(`Unexpected request: ${method}`);
    });
    vi.spyOn(service, 'getState').mockResolvedValue({
      available: true,
      signedIn: true,
      ready: true,
      status: 'ready',
      model: 'gpt-5.6-luna',
      effort: 'max',
      runtimeVersion: '0.147.0',
    });
    const controller = new AbortController();
    const running = service.run(runOptions(controller.signal));
    await vi.waitFor(() => expect(internal.request).toHaveBeenCalledWith('turn/start', expect.anything(), 60_000));
    await vi.waitFor(() => expect((service as unknown as { activeTurn: { turnId: string } | null }).activeTurn?.turnId).toBe('turn-live'));

    controller.abort();
    const outcome = await Promise.race([
      running.then(() => 'resolved', (error: unknown) => error instanceof DOMException ? error.name : 'error'),
      new Promise<string>((resolve) => setTimeout(() => resolve('timed-out'), 100)),
    ]);
    expect(outcome).toBe('AbortError');
    expect(internal.request).toHaveBeenCalledWith('turn/interrupt', {
      threadId: 'thread-live',
      turnId: 'turn-live',
    }, 8_000);
  });

  it('rejects a thread response that does not explicitly prove it is ephemeral', async () => {
    const { service, internal } = mockedService((method) => {
      if (method === 'thread/start') return { thread: { id: 'thread-unknown' }, model: 'gpt-5.6-luna' };
      throw new Error(`Unexpected request: ${method}`);
    });
    vi.spyOn(service, 'getState').mockResolvedValue({
      available: true,
      signedIn: true,
      ready: true,
      status: 'ready',
      model: 'gpt-5.6-luna',
      effort: 'max',
      runtimeVersion: '0.147.0',
    });

    await expect(service.run(runOptions(new AbortController().signal))).rejects.toThrow('exact ephemeral GPT-5.6 Luna session');
    expect(internal.request).not.toHaveBeenCalledWith('turn/start', expect.anything(), expect.anything());
  });

  it('terminates the dedicated runtime when turn/start fails before returning an id', async () => {
    const { service, internal } = mockedService((method) => {
      if (method === 'thread/start') return { thread: { id: 'thread-orphan-risk', ephemeral: true }, model: 'gpt-5.6-luna' };
      if (method === 'turn/start') throw new Error('turn/start timed out');
      throw new Error(`Unexpected request: ${method}`);
    });
    const child = { killed: false, kill: vi.fn(() => true) };
    internal.child = child;
    vi.spyOn(service, 'getState').mockResolvedValue({
      available: true,
      signedIn: true,
      ready: true,
      status: 'ready',
      model: 'gpt-5.6-luna',
      effort: 'max',
      runtimeVersion: '0.147.0',
    });

    await expect(service.run(runOptions(new AbortController().signal))).rejects.toThrow('turn/start timed out');
    expect(child.kill).toHaveBeenCalledOnce();
    expect(internal.child).toBeNull();
  });
});

function runOptions(signal: AbortSignal) {
  return {
    prompt: 'open Hulu',
    instructions: 'Use TV tools only.',
    tools: [{
      name: 'tv_observe',
      description: 'Observe the TV.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    }],
    onTool: vi.fn(async () => ({ text: 'ok' })),
    signal,
  };
}
