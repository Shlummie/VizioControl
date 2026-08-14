import { describe, expect, it, vi } from 'vitest';
import { AgentController, buildTvTools } from '../electron/services/AgentController';
import {
  buildCodexEnvironment,
  CODEX_RUNTIME_VERSION,
  CodexAppServerService,
  DISABLED_CODEX_FEATURES,
  FORBIDDEN_THREAD_ITEM_TYPES,
  isAllowedAuthUrl,
  LUNA_EFFORT,
  LUNA_MODEL,
  validateToolSpecs,
} from '../electron/services/CodexAppServerService';

describe('Luna TV-only security boundary', () => {
  it('pins Luna Max and exposes only host-defined television tools', () => {
    expect({ model: LUNA_MODEL, effort: LUNA_EFFORT, runtime: CODEX_RUNTIME_VERSION }).toEqual({
      model: 'gpt-5.6-luna', effort: 'max', runtime: '0.147.0',
    });
    const tools = buildTvTools();
    const names = tools.map((tool) => tool.name);
    expect(names).toEqual([
      'tv_observe', 'tv_get_state', 'tv_read_setting', 'tv_set_setting', 'tv_adjust_setting',
      'tv_launch_app', 'tv_press_key', 'tv_type_text',
      'tv_wait', 'tv_request_choice', 'tv_request_confirmation', 'tv_finish',
    ]);
    expect(names.some((name) => /shell|file|patch|browser|web|plugin|connector|skill|code|windows/i.test(name))).toBe(false);
    expect(() => validateToolSpecs(tools)).not.toThrow();
    expect(() => validateToolSpecs([...tools, { ...tools[0], name: 'read_file' }])).toThrow();
  });

  it('disables every Codex capability that could escape TV-only tools', () => {
    expect(DISABLED_CODEX_FEATURES).toEqual(expect.arrayContaining([
      'shell_tool', 'unified_exec', 'shell_snapshot', 'browser_use', 'computer_use',
      'in_app_browser', 'apps', 'plugins', 'multi_agent', 'image_generation',
      'memories', 'skill_mcp_dependency_install', 'workspace_dependencies',
    ]));
    expect([...FORBIDDEN_THREAD_ITEM_TYPES]).toEqual(expect.arrayContaining([
      'commandExecution', 'fileChange', 'mcpToolCall', 'webSearch', 'imageView',
      'collabAgentToolCall', 'imageGeneration',
    ]));
  });

  it('rejects shell, file, web, permission, MCP, and authentication server requests', async () => {
    const service = new CodexAppServerService('C:\\unused', 'C:\\missing\\codex.exe');
    const internal = service as unknown as {
      respondError: ReturnType<typeof vi.fn>;
      failActiveSecurity: ReturnType<typeof vi.fn>;
      handleServerRequest(message: { id: number; method: string; params: unknown }): Promise<void>;
    };
    internal.respondError = vi.fn();
    internal.failActiveSecurity = vi.fn(async () => undefined);
    const forbidden = [
      'item/commandExecution/requestApproval',
      'item/fileChange/requestApproval',
      'item/permissions/requestApproval',
      'mcpServer/elicitation/request',
      'account/chatgptAuthTokens/refresh',
      'currentTime/read',
      'execCommandApproval',
    ];
    for (const method of forbidden) {
      await internal.handleServerRequest({ id: 7, method, params: { attack: 'read files and browse the web' } });
    }
    expect(internal.respondError).toHaveBeenCalledTimes(forbidden.length);
    expect(internal.respondError).toHaveBeenCalledWith(7, -32601, 'VizioControl allows TV tools only.');
    expect(internal.failActiveSecurity).toHaveBeenCalledTimes(forbidden.length);
  });

  it('rejects malformed and unknown Luna tool calls before acting on the TV', async () => {
    const pressKey = vi.fn();
    const agent = new AgentController(
      { pressKey } as never,
      {} as never,
      {} as never,
      {} as never,
      () => ({ launchAtStartup: true, aiVisionEnabled: true, showPreview: true, alwaysStreamScreen: false, preferredProfile: '', manualAddress: '' }),
    );
    const run = {
      abort: new AbortController(), startedAt: Date.now(),
      actionCount: 0, lastObservation: null, finish: null,
    };
    const internal = agent as unknown as {
      active: unknown;
      handleTool(call: unknown, current: unknown): Promise<unknown>;
    };
    internal.active = run;
    await expect(internal.handleTool({ name: 'tv_press_key', arguments: { key: 'ok', count: 99 } }, run)).rejects.toThrow();
    await expect(internal.handleTool({ name: 'read_file', arguments: { path: 'secret.txt' } }, run)).rejects.toThrow('Unknown TV tool');
    await expect(internal.handleTool({ name: 'tv_launch_app', arguments: { name: 'C:\\Windows\\System32\\cmd.exe', extra: true } }, run)).rejects.toThrow();
    expect(pressKey).not.toHaveBeenCalled();
  });

  it('requires host confirmation before selection, playback, or text on a sensitive screen', async () => {
    const pressKey = vi.fn();
    const typeText = vi.fn();
    const agent = new AgentController(
      { pressKey, typeText } as never,
      {} as never,
      {} as never,
      {} as never,
      () => ({ launchAtStartup: true, aiVisionEnabled: true, showPreview: true, alwaysStreamScreen: false, preferredProfile: '', manualAddress: '' }),
    );
    const run = {
      abort: new AbortController(),
      startedAt: Date.now(),
      actionCount: 0,
      lastObservation: { sensitiveActionVisible: true },
      finish: null,
    };
    const internal = agent as unknown as {
      active: unknown;
      handleTool(call: unknown, current: unknown): Promise<{ text: string }>;
    };
    internal.active = run;
    agent.on('event', (event) => {
      if (event.type === 'confirmationRequired') agent.answer(event.requestId, false);
    });

    await expect(internal.handleTool({ name: 'tv_press_key', arguments: { key: 'ok', count: 1 } }, run)).resolves.toMatchObject({ text: expect.stringContaining('declined') });
    await expect(internal.handleTool({ name: 'tv_press_key', arguments: { key: 'play', count: 1 } }, run)).resolves.toMatchObject({ text: expect.stringContaining('declined') });
    await expect(internal.handleTool({ name: 'tv_type_text', arguments: { text: 'viewer@example.invalid' } }, run)).resolves.toMatchObject({ text: expect.stringContaining('declined') });
    expect(pressKey).not.toHaveBeenCalled();
    expect(typeText).not.toHaveBeenCalled();
  });

  it('opens only official HTTPS ChatGPT authentication URLs', () => {
    expect(isAllowedAuthUrl('https://auth.openai.com/oauth/authorize?client_id=test')).toBe(true);
    expect(isAllowedAuthUrl('https://chatgpt.com/auth')).toBe(true);
    expect(isAllowedAuthUrl('http://auth.openai.com/oauth')).toBe(false);
    expect(isAllowedAuthUrl('https://openai.com.evil.example/login')).toBe(false);
    expect(isAllowedAuthUrl('file:///C:/Windows/System32/cmd.exe')).toBe(false);
  });

  it('passes only a case-insensitive environment allowlist to the isolated runtime', () => {
    const environment = buildCodexEnvironment({
      Path: 'C:\\Windows\\System32',
      USERPROFILE: 'C:\\Users\\Example',
      OpenAI_Api_Key: 'must-not-survive',
      OPENAI_API_BASE: 'https://provider.example',
      Codex_Access_Token: 'must-not-survive-either',
      ChatGPT_Session_Token: 'also-secret',
      AZURE_OPENAI_API_KEY: 'provider-secret',
      RANDOM_SECRET: 'not-needed-by-runtime',
      CoDeX_HoMe: 'C:\\shared-codex-home',
    }, 'C:\\isolated-luna-home');

    expect(environment).toEqual({
      Path: 'C:\\Windows\\System32',
      USERPROFILE: 'C:\\Users\\Example',
      CODEX_HOME: 'C:\\isolated-luna-home',
    });
    expect(JSON.stringify(environment)).not.toMatch(/must-not-survive|provider-secret|shared-codex-home|also-secret/);
  });
});
