import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import type {
  AgentEvent,
  AppSettings,
  SleepTimerValue,
  TvAction,
  TvKey,
  TvNumericSetting,
  TvSettingName,
} from '../../src/shared/types';
import { AppCatalog } from './AppCatalog';
import { CdpObserver, SmartCastScreenUnavailableError, type ScreenObservation } from './CdpObserver';
import {
  CodexAppServerService,
  LUNA_MODEL,
  type LunaToolCall,
  type LunaToolResult,
  type LunaToolSpec,
} from './CodexAppServerService';
import {
  KEY_CODES,
  SLEEP_TIMER_VALUES,
  SmartCastClient,
  TV_SETTING_DESCRIPTIONS,
} from './SmartCastClient';
import { SENSITIVE_ACTION_CONFIRMATION_REASON } from './SafetyPolicy';

interface ActiveRun {
  abort: AbortController;
  startedAt: number;
  actionCount: number;
  lastObservation: ScreenObservation | null;
  finish: AgentFinish | null;
  learnedActions: TvAction[];
  macroEligible: boolean;
  cancelReason?: string;
}

export interface AgentFinish {
  status: 'success' | 'paused' | 'failed';
  summary: string;
  label?: string;
  actions?: TvAction[];
}

interface PendingAnswer {
  resolve: (value: string | boolean) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

const MAX_ACTIONS = 100;
const MAX_DURATION = 5 * 60 * 1000;

export class AgentController extends EventEmitter {
  private active: ActiveRun | null = null;
  private pendingAnswers = new Map<string, PendingAnswer>();

  constructor(
    private readonly tv: SmartCastClient,
    private readonly observer: CdpObserver,
    private readonly catalog: AppCatalog,
    private readonly luna: CodexAppServerService,
    private readonly getSettings: () => AppSettings,
    private readonly rememberPreferredProfile: (profile: string) => Promise<void> = async () => undefined,
  ) {
    super();
  }

  get running() {
    return Boolean(this.active);
  }

  async run(prompt: string): Promise<AgentFinish> {
    if (this.active) throw new Error('A Luna TV navigation request is already running. Take over or cancel it first.');
    const settings = this.getSettings();
    const run: ActiveRun = {
      abort: new AbortController(),
      startedAt: Date.now(),
      actionCount: 0,
      lastObservation: null,
      finish: null,
      learnedActions: [],
      macroEligible: true,
    };
    this.active = run;
    this.event({ type: 'observing', message: `Checking ${LUNA_MODEL} access and starting Max reasoning…`, at: now() });
    const timeout = setTimeout(() => void this.cancel('The five-minute Luna navigation limit was reached.'), MAX_DURATION);

    try {
      await this.luna.run({
        prompt,
        instructions: agentInstructions(settings.preferredProfile),
        tools: buildTvTools(),
        signal: run.abort.signal,
        onTool: async (call) => await this.handleTool(call, run),
      });

      const finish = run.finish ?? {
        status: 'paused' as const,
        summary: 'Luna ended without a screen-verified result. The latest TV screen is preserved for manual takeover.',
      };
      this.event({ type: finish.status === 'success' ? 'completed' : finish.status, message: finish.summary, at: now() });
      return finish;
    } catch (error) {
      const message = error instanceof DOMException && error.name === 'AbortError'
        ? run.cancelReason || error.message || 'Luna navigation stopped. Manual control is ready.'
        : error instanceof Error ? error.message : 'Luna could not finish the TV request.';
      this.event({ type: 'paused', message, at: now() });
      return { status: 'paused', summary: message };
    } finally {
      clearTimeout(timeout);
      this.rejectPending(new Error('Luna navigation run ended.'));
      this.active = null;
    }
  }

  async cancel(reason = 'Luna navigation stopped. Manual control is ready.') {
    const run = this.active;
    if (!run) return;
    run.cancelReason = reason;
    run.abort.abort();
    this.rejectPending(abortError());
  }

  answer(requestId: string, value: string | boolean) {
    const pending = this.pendingAnswers.get(requestId);
    if (!pending) throw new Error('That Luna question is no longer active.');
    clearTimeout(pending.timer);
    this.pendingAnswers.delete(requestId);
    pending.resolve(value);
  }

  private async handleTool(call: LunaToolCall, run: ActiveRun): Promise<LunaToolResult> {
    this.guard(run);
    const args = call.arguments ?? {};
    switch (call.name) {
      case 'tv_observe': {
        z.object({}).strict().parse(args);
        this.event({ type: 'observing', message: 'Reading the current SmartCast screen…', at: now() });
        let observation: ScreenObservation;
        try {
          observation = await this.observer.observe(run.abort.signal);
        } catch (error) {
          if (!(error instanceof SmartCastScreenUnavailableError)) throw error;
          run.lastObservation = null;
          return {
            text: 'No inspectable SmartCast web screen is active. This is normal on SmartCast Home, HDMI inputs, and some native apps. Do not stop yet if the request clearly targets an allowlisted streaming app: read TV state, launch that app, wait for its screen target, and observe again. For a content request with no named service, VizioControl v1 uses Hulu as the default. If the intended app cannot be identified safely or still has no target after launch, pause for manual takeover.',
          };
        }
        run.lastObservation = observation;
        if (this.getSettings().showPreview) {
          this.event({ type: 'preview', dataUrl: observation.dataUrl, title: observation.title, at: now() });
        }
        return {
          text: `Page title: ${observation.title}\nFocused element:\n${observation.focusedText}\nAccessibility tree:\n${observation.accessibility}`,
          imageDataUrl: observation.dataUrl,
        };
      }
      case 'tv_get_state': {
        z.object({}).strict().parse(args);
        return { text: JSON.stringify(await this.tv.getState()) };
      }
      case 'tv_read_setting': {
        const parsed = z.object({ setting: tvSettingSchema() }).strict().parse(args);
        const value = await this.tv.readSetting(parsed.setting);
        return { text: JSON.stringify({ setting: parsed.setting, value, description: TV_SETTING_DESCRIPTIONS[parsed.setting] }) };
      }
      case 'tv_set_setting': {
        const parsed = z.object({
          setting: tvSettingSchema(),
          value: z.union([z.number(), z.string()]),
        }).strict().parse(args);
        const action = settingAction(parsed.setting, parsed.value);
        this.countAction(run);
        this.event({ type: 'acting', message: `Setting ${friendlySetting(parsed.setting)}…`, at: now() });
        const value = action.setting === 'sleepTimer'
          ? await this.tv.setSetting(action.setting, action.value)
          : await this.tv.setSetting(action.setting, action.value);
        run.learnedActions.push(action);
        return { text: JSON.stringify({ setting: parsed.setting, value, verified: true }) };
      }
      case 'tv_adjust_setting': {
        const parsed = z.object({
          setting: z.enum(['screenBrightness', 'pictureBrightness']),
          delta: z.number().int().min(-25).max(25).refine((value) => value !== 0),
        }).strict().parse(args);
        this.countAction(run);
        this.event({ type: 'acting', message: `Adjusting ${friendlySetting(parsed.setting)}…`, at: now() });
        const result = await this.tv.adjustSetting(parsed.setting, parsed.delta);
        run.learnedActions.push({ type: 'adjustSetting', setting: parsed.setting, delta: parsed.delta });
        return { text: JSON.stringify({ setting: parsed.setting, ...result, verified: true }) };
      }
      case 'tv_launch_app': {
        const parsed = z.object({ name: z.string().trim().min(1).max(80) }).strict().parse(args);
        this.countAction(run);
        run.macroEligible = false;
        this.event({ type: 'acting', message: `Opening ${parsed.name}…`, at: now() });
        const app = await this.catalog.resolve(parsed.name);
        await this.tv.launchApp(app);
        this.observer.notifyAppLaunch();
        const screenReady = await this.observer.waitUntilAvailable(run.abort.signal, 15_000);
        return {
          text: screenReady
            ? `${app.name} launch command succeeded and its inspectable screen is ready. Observe the TV before the next action.`
            : `${app.name} launch command succeeded, but no inspectable screen appeared within 15 seconds. Wait once and observe again; if it remains unavailable, pause for manual takeover.`,
        };
      }
      case 'tv_press_key': {
        const parsed = z.object({
          key: z.enum(Object.keys(KEY_CODES) as [TvKey, ...TvKey[]]),
          count: z.number().int().min(1).max(4).default(1),
        }).strict().parse(args);
        if ((parsed.key === 'ok' || parsed.key === 'play') && run.lastObservation?.sensitiveActionVisible) {
          const confirmed = await this.askConfirmation(SENSITIVE_ACTION_CONFIRMATION_REASON);
          if (!confirmed) return { text: 'The user declined the sensitive action. Do not select it; pause or offer a safe alternative.' };
        }
        this.countAction(run, parsed.count);
        run.macroEligible = false;
        this.event({ type: 'acting', message: `${friendlyKey(parsed.key)}${parsed.count > 1 ? ` ×${parsed.count}` : ''}`, at: now() });
        await this.tv.pressKey(parsed.key, parsed.count);
        await abortableDelay(350, run.abort.signal);
        return { text: 'Key command succeeded. Observe the TV again before assuming focus or page state changed.' };
      }
      case 'tv_type_text': {
        const parsed = z.object({ text: z.string().min(1).max(120).regex(/^[\x00-\x7F]+$/) }).strict().parse(args);
        if (run.lastObservation?.sensitiveContextVisible ?? run.lastObservation?.sensitiveActionVisible) {
          const confirmed = await this.askConfirmation(SENSITIVE_ACTION_CONFIRMATION_REASON);
          if (!confirmed) return { text: 'The user declined text entry on the sensitive screen. Do not enter it; pause for manual takeover.' };
        }
        this.countAction(run);
        run.macroEligible = false;
        this.event({ type: 'acting', message: 'Entering search text…', at: now() });
        await this.tv.typeText(parsed.text);
        return { text: 'Text entry succeeded. Observe the resulting TV screen.' };
      }
      case 'tv_wait': {
        const parsed = z.object({ milliseconds: z.number().int().min(100).max(5000) }).strict().parse(args);
        this.event({ type: 'acting', message: 'Waiting for the TV screen to settle…', at: now() });
        await abortableDelay(parsed.milliseconds, run.abort.signal);
        return { text: 'Wait completed.' };
      }
      case 'tv_request_choice': {
        const parsed = z.object({
          question: z.string().min(1).max(240),
          options: z.array(z.string().min(1).max(120)).min(2).max(6),
        }).strict().parse(args);
        run.macroEligible = false;
        return { text: `The user selected: ${await this.resolveChoice(parsed.question, parsed.options, run)}` };
      }
      case 'tv_request_confirmation': {
        const parsed = z.object({ reason: z.string().min(1).max(300) }).strict().parse(args);
        run.macroEligible = false;
        const confirmed = await this.askConfirmation(parsed.reason);
        return { text: confirmed ? 'The user explicitly confirmed this action.' : 'The user declined this action. Do not perform it.' };
      }
      case 'tv_finish': {
        const parsed = z.object({
          status: z.enum(['success', 'paused', 'failed']),
          summary: z.string().min(1).max(400),
          label: z.string().min(1).max(40).optional(),
          saveAsMacro: z.boolean().optional(),
        }).strict().parse(args);
        run.finish = {
          status: parsed.status,
          summary: parsed.summary,
          label: parsed.label,
          ...(parsed.saveAsMacro === true
            && parsed.status === 'success'
            && run.macroEligible
            && run.learnedActions.length > 0
            ? { actions: structuredClone(run.learnedActions) }
            : {}),
        };
        return { text: 'Result recorded. End the Luna turn now.' };
      }
      default:
        throw new Error(`Unknown TV tool: ${call.name}`);
    }
  }

  private guard(run: ActiveRun) {
    if (this.active !== run || run.abort.signal.aborted) throw abortError();
    if (Date.now() - run.startedAt > MAX_DURATION) throw new Error('The five-minute Luna navigation limit was reached.');
    if (run.actionCount >= MAX_ACTIONS) throw new Error('The 100-action Luna navigation limit was reached.');
  }

  private countAction(run: ActiveRun, count = 1) {
    this.guard(run);
    if (run.actionCount + count > MAX_ACTIONS) throw new Error('The 100-action Luna navigation limit was reached.');
    run.actionCount += count;
  }

  private askChoice(question: string, options: string[]) {
    const requestId = randomUUID();
    const answer = this.waitForAnswer(requestId);
    this.event({ type: 'choiceRequired', requestId, question, options, at: now() });
    return answer.then(String);
  }

  private async resolveChoice(question: string, options: string[], run: ActiveRun) {
    const profileOptions = existingHuluProfileOptions(question, options, run.lastObservation);
    if (!profileOptions) return await this.askChoice(question, options);

    const preferred = this.getSettings().preferredProfile.trim();
    const remembered = profileOptions.find((option) => option.localeCompare(preferred, undefined, { sensitivity: 'base' }) === 0);
    if (remembered) return remembered;

    let selected: string;
    if (profileOptions.length === 1) {
      selected = profileOptions[0];
    } else {
      selected = await this.askChoice(`${question} Your selection will be remembered for future Hulu requests.`, profileOptions);
    }
    await this.rememberPreferredProfile(selected);
    this.event({ type: 'acting', message: 'Remembered the selected Hulu profile for future requests.', at: now() });
    return selected;
  }

  private askConfirmation(reason: string) {
    const requestId = randomUUID();
    const answer = this.waitForAnswer(requestId);
    this.event({ type: 'confirmationRequired', requestId, reason, at: now() });
    return answer.then((value) => value === true || value === 'true');
  }

  private waitForAnswer(requestId: string) {
    return new Promise<string | boolean>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingAnswers.delete(requestId);
        reject(new Error('The Luna question timed out. Manual control is ready.'));
      }, 2 * 60 * 1000);
      this.pendingAnswers.set(requestId, { resolve, reject, timer });
    });
  }

  private rejectPending(error: Error) {
    for (const [, pending] of this.pendingAnswers) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pendingAnswers.clear();
  }

  private event(event: AgentEvent) {
    this.emit('event', event);
  }
}

export function buildTvTools(): LunaToolSpec[] {
  return [
    tool('tv_observe', 'Capture the current SmartCast screen, accessibility tree, and focus. If SmartCast Home has no web screen, the result explains how to launch the intended app safely. Call first and after every navigation burst.', objectSchema({})),
    tool('tv_get_state', 'Read TV power, volume, mute, current app, and connection state.', objectSchema({})),
    tool('tv_read_setting', `Read one host-allowlisted TV setting. ${settingToolDescription()}`, objectSchema({
      setting: { type: 'string', enum: ['screenBrightness', 'pictureBrightness', 'sleepTimer'] },
    }, ['setting'])),
    tool('tv_set_setting', `Set and read-back verify one host-allowlisted TV setting. ${settingToolDescription()}`, objectSchema({
      setting: { type: 'string', enum: ['screenBrightness', 'pictureBrightness', 'sleepTimer'] },
      value: { oneOf: [{ type: 'number' }, { type: 'string', enum: [...SLEEP_TIMER_VALUES] }] },
    }, ['setting', 'value'])),
    tool('tv_adjust_setting', 'Relatively adjust screenBrightness or pictureBrightness by an integer from -25 to 25, then verify the result.', objectSchema({
      setting: { type: 'string', enum: ['screenBrightness', 'pictureBrightness'] },
      delta: { type: 'integer', minimum: -25, maximum: 25, not: { const: 0 } },
    }, ['setting', 'delta'])),
    tool('tv_launch_app', 'Launch an allowlisted TV app by its current Vizio catalog name.', objectSchema({ name: stringSchema('TV app name such as Hulu') }, ['name'])),
    tool('tv_press_key', 'Press one allowlisted TV remote key. Use at most four repeats, then observe.', objectSchema({
      key: { type: 'string', enum: Object.keys(KEY_CODES) },
      count: { type: 'integer', minimum: 1, maximum: 4 },
    }, ['key'])),
    tool('tv_type_text', 'Type bounded ASCII text into the currently focused SmartCast field.', objectSchema({ text: stringSchema('ASCII TV text', 120) }, ['text'])),
    tool('tv_wait', 'Wait briefly for a TV app or page transition.', objectSchema({ milliseconds: { type: 'integer', minimum: 100, maximum: 5000 } }, ['milliseconds'])),
    tool('tv_request_choice', 'Ask the user to choose when multiple plausible content results are visible. On a Hulu profile picker, include only existing profile names; VizioControl remembers the selection.', objectSchema({
      question: stringSchema('Short question', 240),
      options: { type: 'array', minItems: 2, maxItems: 6, items: stringSchema('Visible option', 120) },
    }, ['question', 'options'])),
    tool('tv_request_confirmation', 'Request explicit confirmation before a purchase, rental, subscription, sign-in/out, profile/account change, or destructive action.', objectSchema({ reason: stringSchema('Why confirmation is required', 300) }, ['reason'])),
    tool('tv_finish', 'Record the result only after visual screen verification or host setting read-back verification. Use paused when confidence is insufficient.', objectSchema({
      status: { type: 'string', enum: ['success', 'paused', 'failed'] },
      summary: stringSchema('Plain-language outcome', 400),
      label: stringSchema('Optional saved-button label', 40),
      saveAsMacro: { type: 'boolean', description: 'True only for a verified deterministic TV-setting workflow that should replay locally without Luna.' },
    }, ['status', 'summary'])),
  ];
}

function tool(name: string, description: string, inputSchema: Record<string, unknown>): LunaToolSpec {
  return { name, description, inputSchema };
}

function objectSchema(properties: Record<string, unknown>, required: string[] = []) {
  return { type: 'object', properties, required, additionalProperties: false };
}

function stringSchema(description: string, maxLength = 80) {
  return { type: 'string', description, minLength: 1, maxLength };
}

function agentInstructions(preferredProfile: string) {
  const profileRule = preferredProfile
    ? `When a profile picker is visible, select only the configured TV profile named ${JSON.stringify(preferredProfile)}. If it is not visible, ask the user.`
    : 'When a Hulu profile picker is visible, call tv_request_choice with only the existing profile names, excluding Add Profile, Manage Profiles, or other account controls. VizioControl will automatically use and remember the profile when only one exists, or visibly ask the user once when several exist.';
  return `You are the visual TV navigator inside VizioControl, using GPT-5.6 Luna with Max reasoning. Your only job is to satisfy the user's request on the Vizio TV through the registered tv_* tools.

Rules:
- Begin with the most relevant read tool. Use tv_observe for visual app navigation; use tv_read_setting for native TV-setting requests so no screenshot is needed.
- For a deterministic request that can be completed entirely through tv_read_setting, tv_set_setting, or tv_adjust_setting, verify the final value and finish with saveAsMacro true. VizioControl will replay that verified setting action locally next time without Luna.
- Preserve request semantics in the learned action: use tv_adjust_setting for relative requests such as "turn brightness up," and tv_set_setting for explicit target values such as "brightness 40" or "sleep timer 60 minutes."
- If an explicit target already equals the current setting, still call tv_set_setting once. Its read-back verification creates the concrete action VizioControl needs for the learned local macro.
- Never mark content navigation, searches, playback, app launches, text entry, profile/account work, purchases, confirmations, or D-pad/menu sequences as a macro. Native Vizio menus are not visible in the SmartCast Chromium capture; use only the host setting tools for native settings.
- SmartCast Home itself may have no inspectable web screen. If the first observation reports that recoverable state, do not immediately give up: call tv_get_state, launch the clearly intended allowlisted app, then observe its screen. For content requests that name no service, use Hulu as the configured v1 default and verify the content there rather than assuming it exists.
- Prefer the smallest safe TV action. Never press more than four repeated keys before observing.
- Use the SmartCast screenshot, accessibility text, focus state, and tv_get_state as truth. Never claim content is available or playing without visible evidence.
- If multiple plausible results are visible, call tv_request_choice instead of guessing.
- Ordinary included content may be started automatically.
- Before any purchase, rental, subscription, trial, sign-in/out, account or profile change, deletion, or destructive action, call tv_request_confirmation and act only if confirmed.
- If the intended app still has no observable SmartCast screen after launch and one bounded retry, focus is unclear, or progress is uncertain, call tv_finish with status paused and explain where manual takeover begins.
- You cannot see or control Windows, read files, run commands, browse the web, use MCP, apps, plugins, connectors, skills, permissions, or other agents. Never request them.
- Finish within 100 TV actions, 48 tool steps, and five minutes.
- ${profileRule}`;
}

function tvSettingSchema() {
  return z.enum(['screenBrightness', 'pictureBrightness', 'sleepTimer']);
}

function settingAction(setting: TvSettingName, value: number | string): Extract<TvAction, { type: 'setSetting' }> {
  if (setting === 'sleepTimer') {
    return {
      type: 'setSetting',
      setting,
      value: z.enum(SLEEP_TIMER_VALUES).parse(value) as SleepTimerValue,
    };
  }
  return {
    type: 'setSetting',
    setting,
    value: z.number().finite().min(0).max(100).parse(value),
  };
}

function settingToolDescription() {
  return (Object.entries(TV_SETTING_DESCRIPTIONS) as Array<[TvSettingName, string]>)
    .map(([setting, description]) => `${setting}: ${description}`)
    .join(' ');
}

function friendlySetting(setting: TvSettingName) {
  const labels: Record<TvSettingName, string> = {
    screenBrightness: 'screen brightness',
    pictureBrightness: 'picture brightness',
    sleepTimer: 'the sleep timer',
  };
  return labels[setting];
}

function friendlyKey(key: TvKey) {
  const labels: Partial<Record<TvKey, string>> = {
    up: 'Moving up', down: 'Moving down', left: 'Moving left', right: 'Moving right', ok: 'Selecting',
    back: 'Going back', home: 'Going home', play: 'Starting playback', pause: 'Pausing',
  };
  return labels[key] ?? key.replace(/([A-Z])/g, ' $1').replace(/^./, (value) => value.toUpperCase());
}

export function existingHuluProfileOptions(
  question: string,
  options: string[],
  observation: Pick<ScreenObservation, 'title' | 'accessibility' | 'focusedText'> | null,
) {
  const evidence = [question, observation?.title, observation?.accessibility, observation?.focusedText].filter(Boolean).join('\n');
  if (!/(?:\bprofile(?:s)?\b|who(?:\s+is|['’]s)?\s+watching|choose who|watching as)/i.test(evidence)) return null;
  const profiles = options
    .map((option) => option.trim())
    .filter(Boolean)
    .filter((option) => !/^(?:add|create|new|manage|edit)(?:\s+(?:a\s+)?profile(?:s)?)?$|^(?:profile|account) settings$|^sign (?:in|out)$|^log (?:in|out)$/i.test(option));
  const unique = profiles.filter((profile, index) => profiles.findIndex(
    (candidate) => candidate.localeCompare(profile, undefined, { sensitivity: 'base' }) === 0,
  ) === index);
  return unique.length ? unique : null;
}

function abortableDelay(milliseconds: number, signal: AbortSignal) {
  return new Promise<void>((resolve, reject) => {
    if (signal.aborted) return reject(abortError());
    const timer = setTimeout(() => {
      signal.removeEventListener('abort', abort);
      resolve();
    }, milliseconds);
    const abort = () => {
      clearTimeout(timer);
      reject(abortError());
    };
    signal.addEventListener('abort', abort, { once: true });
  });
}

function abortError() {
  return new DOMException('Luna navigation canceled.', 'AbortError');
}

function now() {
  return new Date().toISOString();
}
