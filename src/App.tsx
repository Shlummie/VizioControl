import {
  useEffect,
  useRef,
  useState,
  type CSSProperties,
  type FormEvent,
  type MouseEvent as ReactMouseEvent,
  type PointerEvent as ReactPointerEvent,
} from 'react';
import {
  AppWindow,
  ArrowDown,
  ArrowLeft,
  ArrowRight,
  ArrowUp,
  Bot,
  Cable,
  Check,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  ChevronUp,
  CircleEllipsis,
  Copy,
  Eye,
  EyeOff,
  FastForward,
  House,
  LogIn,
  LogOut,
  Maximize2,
  Menu,
  Minimize2,
  Monitor,
  Pause,
  Play,
  Power,
  RefreshCw,
  Rewind,
  Settings,
  Sparkles,
  Square,
  Trash2,
  Undo2,
  Volume2,
  VolumeX,
  Wifi,
  WifiOff,
  X,
  type LucideIcon,
} from 'lucide-react';
import type {
  AgentEvent,
  AppSettings,
  BootstrapState,
  DeviceCandidate,
  SavedButton,
  ScreenFrame,
  ScreenStreamState,
  TvKey,
  TvState,
} from './shared/types';
import { resolveVizioApi } from './devMock';
import { activeAgentQuestion, appendAgentEvent, resolveAgentQuestion } from './agentEvents';
import { presentAiRuntime, type AiAccountAction } from './aiPresentation';
import { LatestFrameQueue } from './latestFrameQueue';
import { shouldClearCommittedFrame, unavailableViewportCopy } from './screenPreviewState';

const api = resolveVizioApi(window.vizioControl);
const TRANSPARENT_PIXEL = 'data:image/gif;base64,R0lGODlhAQABAAD/ACwAAAAAAQABAAACADs=';

export function App() {
  const [state, setState] = useState<BootstrapState | null>(null);
  const [error, setError] = useState('');
  const [toast, setToast] = useState('');
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [editingButton, setEditingButton] = useState<SavedButton | null>(null);
  const [commandBusy, setCommandBusy] = useState(false);
  const [agentRunning, setAgentRunning] = useState(false);
  const undoButtonRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    let mounted = true;
    api.getBootstrap()
      .then((bootstrap) => {
        if (!mounted) return;
        setState(bootstrap);
        setAgentRunning(bootstrap.agent.running);
      })
      .catch((reason) => setError(readError(reason)));
    const unsubscribers = [
      api.onTvState((tv) => setState((previous) => previous ? { ...previous, tv } : previous)),
      api.onButtons((buttons) => setState((previous) => previous ? { ...previous, buttons } : previous)),
      api.onAiState((ai) => setState((previous) => previous ? { ...previous, ai } : previous)),
      api.onSettings((settings) => setState((previous) => previous ? { ...previous, settings } : previous)),
      api.onScreenStreamState((screenStream) => setState((previous) => previous ? { ...previous, screenStream } : previous)),
      api.onAgentEvent((event) => {
        setState((previous) => {
          if (!previous) return previous;
          if (event.type === 'idle') {
            return {
              ...previous,
              agent: { ...previous.agent, events: [], previewDataUrl: null },
            };
          }
          const events = appendAgentEvent(previous.agent.events, event);
          return {
            ...previous,
            agent: {
              ...previous.agent,
              events,
              previewDataUrl: previous.agent.previewDataUrl,
            },
          };
        });
        if (event.type === 'observing' || event.type === 'acting' || event.type === 'choiceRequired' || event.type === 'confirmationRequired') setAgentRunning(true);
        if (event.type === 'completed' || event.type === 'paused' || event.type === 'failed') setAgentRunning(false);
      }),
    ];
    return () => {
      mounted = false;
      unsubscribers.forEach((unsubscribe) => unsubscribe());
    };
  }, []);

  useEffect(() => {
    if (!toast) return;
    if (toast === 'Button deleted.') {
      undoButtonRef.current?.focus();
      return;
    }
    const timer = setTimeout(() => setToast(''), 4200);
    return () => clearTimeout(timer);
  }, [toast]);

  async function perform<T>(operation: () => Promise<T>, success?: string) {
    setError('');
    setCommandBusy(true);
    try {
      const result = await operation();
      if (success) setToast(success);
      return result;
    } catch (reason) {
      setError(readError(reason));
      throw reason;
    } finally {
      setCommandBusy(false);
    }
  }

  if (!state) {
    return <LoadingScreen error={error} />;
  }

  if (!state.device) {
    return (
      <Onboarding
        settings={state.settings}
        error={error}
        onError={setError}
        onPaired={async () => setState(await api.getBootstrap())}
        onSettings={(settings) => setState((previous) => previous ? { ...previous, settings } : previous)}
      />
    );
  }

  const updateSettings = async (patch: Partial<AppSettings>) => {
    const settings = await perform(() => api.updateSettings(patch));
    setState((previous) => previous ? { ...previous, settings } : previous);
  };

  const manualKey = async (key: TvKey) => {
    setError('');
    try {
      const tv = await api.pressKey(key);
      setState((previous) => previous ? { ...previous, tv } : previous);
    } catch (reason) {
      setError(readError(reason));
    }
  };
  const manualVolume = async (value: number) => {
    setError('');
    try {
      const tv = await api.setVolume(value);
      setState((previous) => previous ? { ...previous, tv } : previous);
    } catch (reason) {
      setError(readError(reason));
    }
  };
  const localControlsDisabled = !state.tv.connected || state.tv.power === false;
  const longActionDisabled = commandBusy || localControlsDisabled;

  return (
    <div className="app-shell">
      <Header
        tv={state.tv}
        ai={state.ai}
        onRefresh={() => void perform(async () => {
          const tv = await api.refreshTvState();
          setState((previous) => previous ? { ...previous, tv } : previous);
        })}
        onSettings={() => setSettingsOpen(true)}
      />

      <main className="app-content">
        {error && <ErrorBanner message={error} onClose={() => setError('')} />}
        <AgentStage
          events={state.agent.events}
          preview={state.agent.previewDataUrl}
          currentApp={state.tv.currentApp}
          screenStream={state.screenStream}
          showPreview={state.settings.showPreview}
          running={agentRunning}
          onTogglePreview={() => void updateSettings({ showPreview: !state.settings.showPreview })}
          onTakeOver={() => void perform(() => api.cancelAgent(), 'Manual control is ready.')}
          onAnswer={(requestId, value) => {
            setState((previous) => previous ? {
              ...previous,
              agent: {
                ...previous.agent,
                events: resolveAgentQuestion(previous.agent.events, requestId),
              },
            } : previous);
            void perform(() => api.answerAgent(requestId, value));
          }}
        />

        <section className="control-surface" aria-label="TV controls">
          <div className="manual-deck">
            <div className="manual-topline">
              <ControlButton
                label={!state.tv.connected ? 'Wake' : state.tv.power === false ? 'Turn on' : 'Standby'}
                icon={Power}
                onPress={() => perform(async () => {
                  const turningOff = state.tv.power === true;
                  const tv = await api.pressKey(turningOff ? 'powerOff' : 'powerOn');
                  setState((previous) => previous ? { ...previous, tv } : previous);
                }, state.tv.power === true ? 'TV is in network standby.' : 'TV is on.')}
                disabled={commandBusy}
              />
              <ControlButton label="Input" icon={Cable} onPress={() => manualKey('input')} disabled={localControlsDisabled} immediate />
              <ControlButton label="Home" icon={House} onPress={() => manualKey('home')} disabled={localControlsDisabled} immediate />
              <ControlButton label="Back" icon={Undo2} onPress={() => manualKey('back')} disabled={localControlsDisabled} immediate />
              <ControlButton label="Menu" icon={Menu} onPress={() => manualKey('menu')} disabled={localControlsDisabled} immediate />
            </div>

            <div className="manual-main">
              <DPad disabled={localControlsDisabled} onPress={(key) => void manualKey(key)} />
              <div className="control-banks">
                <VolumeControl
                  tv={state.tv}
                  disabled={localControlsDisabled}
                  onSet={(value) => manualVolume(value)}
                  onMute={() => void manualKey('mute')}
                />
                <div className="playback-bank" aria-label="Playback controls">
                  <IconControl label="Rewind" icon={Rewind} onPress={() => manualKey('rewind')} disabled={localControlsDisabled} />
                  <IconControl label="Play" icon={Play} onPress={() => manualKey('play')} disabled={localControlsDisabled} />
                  <IconControl label="Pause" icon={Pause} onPress={() => manualKey('pause')} disabled={localControlsDisabled} />
                  <IconControl label="Fast forward" icon={FastForward} onPress={() => manualKey('fastForward')} disabled={localControlsDisabled} />
                </div>
                <div className="app-bank" aria-label="Quick applications">
                  {['Hulu', 'YouTube', 'Netflix'].map((name) => (
                    <button key={name} type="button" className="text-control" disabled={longActionDisabled} onClick={() => void perform(() => api.launchApp(name), `Opening ${name}.`)}>
                      {name}
                    </button>
                  ))}
                </div>
              </div>
            </div>
          </div>

          <SavedRequests
            buttons={state.buttons}
            disabled={longActionDisabled || agentRunning}
            onRun={(id) => void perform(async () => {
              const result = await api.runButton(id);
              setToast(result.message);
            })}
            onEdit={setEditingButton}
          />
        </section>
      </main>

      <RequestComposer
        running={agentRunning}
        disabled={commandBusy}
        onSubmit={(prompt) => void perform(async () => {
          setAgentRunning(true);
          const result = await api.runRequest(prompt);
          setToast(result.message);
          if (!result.ok) setAgentRunning(false);
        }).catch(() => setAgentRunning(false))}
        onCancel={() => void perform(() => api.cancelAgent(), 'Luna navigation stopped. Manual control is ready.')}
      />

      {settingsOpen && (
        <SettingsPanel
          settings={state.settings}
          tv={state.tv}
          ai={state.ai}
          onClose={() => setSettingsOpen(false)}
          onUpdate={(patch) => void updateSettings(patch)}
          onRefreshAi={() => void perform(async () => {
            const ai = await api.refreshAi();
            setState((previous) => previous ? { ...previous, ai } : previous);
          }, 'ChatGPT and Luna status refreshed.')}
          onSignIn={() => void perform(async () => {
            const ai = await api.signInAi();
            setState((previous) => previous ? { ...previous, ai } : previous);
          }, 'Continue ChatGPT sign-in in your browser.')}
          onCancelSignIn={() => void perform(async () => {
            const ai = await api.cancelAiSignIn();
            setState((previous) => previous ? { ...previous, ai } : previous);
          }, 'ChatGPT sign-in canceled.')}
          onSignOut={() => void perform(async () => {
            const ai = await api.signOutAi();
            setState((previous) => previous ? { ...previous, ai } : previous);
          }, 'Signed out of ChatGPT.')}
          onForget={() => void perform(async () => {
            await api.forgetDevice();
            setSettingsOpen(false);
            setState(await api.getBootstrap());
          })}
        />
      )}

      {editingButton && (
        <ButtonEditor
          button={editingButton}
          onClose={() => setEditingButton(null)}
          onSave={(patch) => void perform(async () => {
            const buttons = await api.updateButton(editingButton.id, patch);
            setState((previous) => previous ? { ...previous, buttons } : previous);
            setEditingButton(null);
          }, 'Saved button updated.')}
          onMove={(direction) => void perform(async () => {
            const buttons = await api.reorderButton(editingButton.id, direction);
            setState((previous) => previous ? { ...previous, buttons } : previous);
          })}
          onDuplicate={() => void perform(async () => {
            const buttons = await api.duplicateButton(editingButton.id);
            setState((previous) => previous ? { ...previous, buttons } : previous);
            setEditingButton(null);
          }, 'Button duplicated.')}
          onDelete={() => void perform(async () => {
            const buttons = await api.deleteButton(editingButton.id);
            setState((previous) => previous ? { ...previous, buttons } : previous);
            setEditingButton(null);
            setToast('Button deleted.');
          })}
        />
      )}

      {toast && (
        <div className="toast" role="status">
          <span>{toast}</span>
          {toast === 'Button deleted.' && (
            <div className="toast-actions">
              <button ref={undoButtonRef} type="button" onClick={() => void perform(async () => {
                const buttons = await api.undoDelete();
                setState((previous) => previous ? { ...previous, buttons } : previous);
                setToast('Button restored.');
              })}>Undo</button>
              <button type="button" onClick={() => setToast('')}>Dismiss</button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function Header({ tv, ai, onRefresh, onSettings }: {
  tv: TvState;
  ai: BootstrapState['ai'];
  onRefresh: () => void;
  onSettings: () => void;
}) {
  const aiPresentation = presentAiRuntime(ai);
  return (
    <header className="topbar">
      <div className="brand-lockup">
        <div className="brand-mark" aria-hidden="true"><Monitor size={20} /></div>
        <div>
          <h1>VizioControl</h1>
          <p>{tv.currentApp || (tv.power === false ? 'TV is off' : 'Desktop control')}</p>
        </div>
      </div>
      <div className={`connection-state ${tv.connected ? 'connected' : ''}`}>
        {tv.connected ? <Wifi size={18} /> : <WifiOff size={18} />}
        <span>{!tv.connected ? 'TV is offline' : tv.power === false ? 'TV is off' : 'TV is ready'}</span>
        <button type="button" className="icon-quiet" onClick={onRefresh} aria-label="Refresh TV state"><RefreshCw size={17} /></button>
      </div>
      <div className="top-actions">
        <span className={`ai-state ${ai.status === 'ready' ? 'ready' : ''}`}><Bot size={17} /> {aiPresentation.headerLabel}</span>
        <button type="button" className="icon-button" onClick={onSettings} aria-label="Open settings"><Settings size={20} /></button>
      </div>
    </header>
  );
}

function AgentStage({ events, preview, currentApp, screenStream, showPreview, running, onTogglePreview, onTakeOver, onAnswer }: {
  events: AgentEvent[];
  preview: string | null;
  currentApp: string | null;
  screenStream: ScreenStreamState;
  showPreview: boolean;
  running: boolean;
  onTogglePreview: () => void;
  onTakeOver: () => void;
  onAnswer: (requestId: string, value: string | boolean) => void;
}) {
  const visibleEvents = events.filter((event) => event.type !== 'preview' && event.type !== 'idle').slice(-7);
  const pending = activeAgentQuestion(events);
  const locallyStreaming = screenStream.enabled && showPreview;
  const viewportRef = useRef<HTMLDivElement>(null);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [fullscreenError, setFullscreenError] = useState('');

  useEffect(() => {
    const syncFullscreenState = () => {
      setIsFullscreen(document.fullscreenElement === viewportRef.current);
      if (!document.fullscreenElement) setFullscreenError('');
    };
    const exitFullscreenOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && document.fullscreenElement === viewportRef.current) {
        void document.exitFullscreen().catch(() => undefined);
      }
    };
    document.addEventListener('fullscreenchange', syncFullscreenState);
    document.addEventListener('keydown', exitFullscreenOnEscape);
    return () => {
      document.removeEventListener('fullscreenchange', syncFullscreenState);
      document.removeEventListener('keydown', exitFullscreenOnEscape);
    };
  }, []);

  const toggleFullscreen = async () => {
    setFullscreenError('');
    try {
      if (document.fullscreenElement === viewportRef.current) await document.exitFullscreen();
      else await viewportRef.current?.requestFullscreen();
    } catch {
      setFullscreenError('Fullscreen could not open. Try again or use the window maximize button.');
    }
  };

  return (
    <section className={`agent-stage ${running ? 'is-running' : ''}`} aria-label="Luna TV navigation">
      <div className="viewport-panel">
        <div className="panel-heading">
          <div>
            <h2>{running || locallyStreaming ? 'TV viewport' : 'Ready when you are'}</h2>
            <p>{running
              ? 'Luna sees only the observations it requests during this run.'
              : locallyStreaming
                ? 'The 24 FPS SmartCast stream stays local and runs without Luna.'
                : 'Manual controls stay local; semantic requests use Luna Max.'}</p>
          </div>
          <div className="viewport-actions">
            {locallyStreaming && (
              <span className={`stream-badge ${screenStream.status}`} role="status">
                <i aria-hidden="true" />
                {screenStream.status === 'live' ? 'Local · 24 FPS' : screenStream.status === 'unavailable' ? 'Retrying preview' : 'Connecting'}
              </span>
            )}
            <button type="button" className="quiet-action" onClick={onTogglePreview} aria-pressed={showPreview}>
              {showPreview ? <Eye size={17} /> : <EyeOff size={17} />}
              {showPreview ? 'Hide preview' : 'Show preview'}
            </button>
          </div>
        </div>
        <div ref={viewportRef} className="viewport-frame">
          <ScreenViewport
            initialPreview={preview}
            currentApp={currentApp}
            showPreview={showPreview}
            running={running}
            stream={screenStream}
          />
          {running && <div className="observation-sweep" aria-hidden="true" />}
          {showPreview && (
            <button
              type="button"
              className="viewport-fullscreen-button"
              onClick={() => void toggleFullscreen()}
              aria-label={isFullscreen ? 'Exit fullscreen TV display' : 'Open TV display fullscreen'}
              title={isFullscreen ? 'Exit fullscreen' : 'Fullscreen'}
            >
              {isFullscreen ? <Minimize2 size={19} /> : <Maximize2 size={19} />}
            </button>
          )}
          {fullscreenError && <div className="viewport-fullscreen-error" role="alert">{fullscreenError}</div>}
        </div>
      </div>
      <aside className="timeline-panel">
        <div className="panel-heading">
          <div>
            <h2>Action timeline</h2>
            <p>{running ? 'Luna is navigating the TV' : 'Latest run'}</p>
          </div>
          {running && <span className="live-badge">Live</span>}
        </div>
        <div className="timeline-list" aria-live="polite">
          {visibleEvents.length ? visibleEvents.map((event, index) => (
            <TimelineItem key={`${event.at}-${index}`} event={event} />
          )) : (
            <div className="timeline-empty"><Sparkles size={22} /><p>No Luna actions yet.</p><span>Simple commands still run instantly and locally without contacting Luna.</span></div>
          )}
        </div>
        {pending?.type === 'choiceRequired' && (
          <div className="agent-question" role="alertdialog" aria-live="assertive" aria-label="Luna needs your choice">
            <span className="choice-kicker">Luna needs your choice</span>
            <strong>{pending.question}</strong>
            {pending.options.map((option) => <button type="button" key={option} onClick={() => onAnswer(pending.requestId, option)}>{option}</button>)}
          </div>
        )}
        {pending?.type === 'confirmationRequired' && (
          <div className="agent-question confirmation">
            <strong>Confirmation required</strong>
            <p>{pending.reason}</p>
            <div><button type="button" onClick={() => onAnswer(pending.requestId, false)}>Decline</button><button type="button" className="confirm" onClick={() => onAnswer(pending.requestId, true)}>Allow once</button></div>
          </div>
        )}
        {running && <button type="button" className="takeover-button" onClick={onTakeOver}><Square size={16} /> Take over</button>}
      </aside>
    </section>
  );
}

type ViewportFrame = Pick<ScreenFrame, 'dataUrl' | 'source'>;

function ScreenViewport({ initialPreview, currentApp, showPreview, running, stream }: {
  initialPreview: string | null;
  currentApp: string | null;
  showPreview: boolean;
  running: boolean;
  stream: ScreenStreamState;
}) {
  const imageRefs = [useRef<HTMLImageElement>(null), useRef<HTMLImageElement>(null)] as const;
  const queueRef = useRef<LatestFrameQueue<ViewportFrame> | null>(null);
  const activeImage = useRef(-1);
  const committedSource = useRef<ScreenFrame['source'] | null>(null);
  const showPreviewRef = useRef(showPreview);
  const streamStatusRef = useRef(stream.status);
  const hasFrameRef = useRef(false);
  const [hasFrame, setHasFrame] = useState(false);
  showPreviewRef.current = showPreview;
  streamStatusRef.current = stream.status;

  const clearVisibleFrame = () => {
    activeImage.current = -1;
    committedSource.current = null;
    hasFrameRef.current = false;
    for (const imageRef of imageRefs) {
      imageRef.current?.classList.remove('is-active');
      if (imageRef.current) imageRef.current.src = TRANSPARENT_PIXEL;
    }
    setHasFrame(false);
  };

  useEffect(() => {
    let mounted = true;
    const queue = new LatestFrameQueue<ViewportFrame>(async (frame) => {
      const nextIndex = activeImage.current === 0 ? 1 : 0;
      const image = imageRefs[nextIndex].current;
      if (!image) throw new Error('The screen image layer is unavailable.');
      image.src = frame.dataUrl;
      await decodeImage(image);
      return {
        commit: () => {
          if (!mounted) return;
          const previous = activeImage.current >= 0 ? imageRefs[activeImage.current].current : null;
          image.classList.toggle('is-active', showPreviewRef.current);
          previous?.classList.remove('is-active');
          activeImage.current = nextIndex;
          committedSource.current = frame.source;
          if (!hasFrameRef.current) {
            hasFrameRef.current = true;
            setHasFrame(true);
          }
        },
      };
    });
    queueRef.current = queue;
    const unsubscribe = api.onScreenFrame((frame) => {
      if (frame.source === 'localStream' && streamStatusRef.current === 'unavailable') return;
      queue.push({ dataUrl: frame.dataUrl, source: frame.source });
    });
    return () => {
      mounted = false;
      queue.stop();
      queueRef.current = null;
      unsubscribe();
    };
  }, []);

  useEffect(() => {
    if (initialPreview) queueRef.current?.push({ dataUrl: initialPreview, source: 'agentObservation' });
    else if (!stream.enabled) {
      queueRef.current?.clear();
      clearVisibleFrame();
    }
  }, [initialPreview, stream.enabled]);

  useEffect(() => {
    if (stream.status !== 'unavailable') return;
    queueRef.current?.clear();
    if (shouldClearCommittedFrame(stream.status, committedSource.current)) clearVisibleFrame();
  }, [stream.status]);

  useEffect(() => {
    showPreviewRef.current = showPreview;
    for (let index = 0; index < imageRefs.length; index += 1) {
      imageRefs[index].current?.classList.toggle('is-active', showPreview && hasFrame && activeImage.current === index);
    }
  }, [hasFrame, showPreview]);

  const unavailableCopy = unavailableViewportCopy(currentApp);
  const previewUnavailable = stream.enabled && !hasFrame && stream.status === 'unavailable';
  const title = !showPreview
    ? 'Screen preview is hidden.'
    : previewUnavailable
      ? unavailableCopy.title
      : stream.enabled
        ? 'Connecting to the TV screen…'
        : running
          ? 'Waiting for Luna’s first observation.'
          : 'The screen appears when Luna navigation begins.';
  const detail = !showPreview
    ? 'Showing it again resumes the local stream when Always stream is enabled.'
    : previewUnavailable
      ? unavailableCopy.detail
    : stream.enabled
      ? stream.message || 'Compatible SmartCast apps reconnect automatically; Home, native menus, and HDMI are not exposed.'
      : 'AI observations stay in memory and are sent to OpenAI only during an active Luna request.';
  return <>
    <img ref={imageRefs[0]} className="viewport-image" src={TRANSPARENT_PIXEL} alt="" aria-hidden="true" draggable={false} />
    <img ref={imageRefs[1]} className="viewport-image" src={TRANSPARENT_PIXEL} alt="" aria-hidden="true" draggable={false} />
    {showPreview && hasFrame
      ? <span className="sr-only" role="status">Current SmartCast screen from TV</span>
      : (
        <div className="viewport-empty" role="status">
          <Monitor size={34} aria-hidden="true" />
          <strong>{title}</strong>
          <span>{detail}</span>
        </div>
      )}
  </>;
}

async function decodeImage(image: HTMLImageElement) {
  if (typeof image.decode === 'function') {
    try {
      await image.decode();
      return;
    } catch {
      if (image.complete && image.naturalWidth > 0) return;
    }
  }
  await new Promise<void>((resolve, reject) => {
    if (image.complete) {
      if (image.naturalWidth > 0) resolve();
      else reject(new Error('The SmartCast frame could not be decoded.'));
      return;
    }
    const loaded = () => finish(resolve);
    const failed = () => finish(() => reject(new Error('The SmartCast frame could not be decoded.')));
    const finish = (complete: () => void) => {
      image.removeEventListener('load', loaded);
      image.removeEventListener('error', failed);
      complete();
    };
    image.addEventListener('load', loaded, { once: true });
    image.addEventListener('error', failed, { once: true });
  });
}

function TimelineItem({ event }: { event: AgentEvent }) {
  if (event.type === 'choiceRequired' || event.type === 'confirmationRequired' || event.type === 'preview' || event.type === 'idle') return null;
  const Icon = event.type === 'completed' ? Check : event.type === 'failed' || event.type === 'paused' ? Square : event.type === 'observing' ? Eye : ArrowRight;
  return (
    <div className={`timeline-item ${event.type}`}>
      <span className="timeline-icon"><Icon size={15} /></span>
      <div><strong>{event.message}</strong><time>{formatTime(event.at)}</time></div>
    </div>
  );
}

function DPad({ disabled, onPress }: { disabled: boolean; onPress: (key: TvKey) => void }) {
  return (
    <div className="dpad" aria-label="Directional controls">
      <button type="button" className="dpad-up" disabled={disabled} {...immediatePressHandlers(() => onPress('up'))} aria-label="Up"><ChevronUp size={32} /></button>
      <button type="button" className="dpad-left" disabled={disabled} {...immediatePressHandlers(() => onPress('left'))} aria-label="Left"><ChevronLeft size={32} /></button>
      <button type="button" className="dpad-ok" disabled={disabled} {...immediatePressHandlers(() => onPress('ok'))}>OK</button>
      <button type="button" className="dpad-right" disabled={disabled} {...immediatePressHandlers(() => onPress('right'))} aria-label="Right"><ChevronRight size={32} /></button>
      <button type="button" className="dpad-down" disabled={disabled} {...immediatePressHandlers(() => onPress('down'))} aria-label="Down"><ChevronDown size={32} /></button>
    </div>
  );
}

function VolumeControl({ tv, disabled, onSet, onMute }: { tv: TvState; disabled: boolean; onSet: (value: number) => Promise<unknown>; onMute: () => void }) {
  const [value, setValue] = useState(tv.volume ?? 30);
  const latest = useRef(value);
  const lastSent = useRef<number | null>(tv.volume);
  const localRequestVersion = useRef(0);
  const localRequestPending = useRef(false);
  const pendingFrame = useRef<number | null>(null);
  const onSetRef = useRef(onSet);
  onSetRef.current = onSet;
  useEffect(() => {
    if (tv.volume !== null) {
      if (localRequestPending.current && tv.volume !== lastSent.current) return;
      setValue(tv.volume);
      latest.current = tv.volume;
      lastSent.current = tv.volume;
    }
  }, [tv.volume]);
  useEffect(() => () => {
    if (pendingFrame.current !== null) cancelAnimationFrame(pendingFrame.current);
  }, []);
  const dispatchLatest = () => {
    const next = latest.current;
    if (lastSent.current === next) return;
    lastSent.current = next;
    localRequestPending.current = true;
    const version = ++localRequestVersion.current;
    void onSetRef.current(next).finally(() => {
      if (version === localRequestVersion.current) localRequestPending.current = false;
    });
  };
  const schedule = () => {
    if (pendingFrame.current !== null) return;
    pendingFrame.current = requestAnimationFrame(() => {
      pendingFrame.current = null;
      dispatchLatest();
    });
  };
  const commit = () => {
    if (pendingFrame.current !== null) cancelAnimationFrame(pendingFrame.current);
    pendingFrame.current = null;
    dispatchLatest();
  };
  return (
    <div className="volume-bank">
      <div className="volume-label"><span>Volume</span><output htmlFor="volume-slider">{value}</output></div>
      <div className="volume-row">
        <button type="button" className={`mute-button ${tv.muted ? 'active' : ''}`} {...immediatePressHandlers(onMute)} disabled={disabled} aria-label={tv.muted ? 'Unmute' : 'Mute'}>
          {tv.muted ? <VolumeX size={23} /> : <Volume2 size={23} />}
        </button>
        <input
          id="volume-slider"
          type="range"
          min="0"
          max="100"
          value={value}
          disabled={disabled || !tv.connected}
          aria-label="TV volume"
          style={{ '--volume-fill': `${value}%` } as CSSProperties}
          onChange={(event) => {
            const next = Number(event.target.value);
            latest.current = next;
            setValue(next);
            schedule();
          }}
          onPointerUp={commit}
          onPointerCancel={commit}
          onBlur={commit}
          onKeyUp={(event) => { if (['ArrowLeft', 'ArrowRight', 'Home', 'End', 'PageUp', 'PageDown'].includes(event.key)) commit(); }}
        />
      </div>
    </div>
  );
}

function SavedRequests({ buttons, disabled, onRun, onEdit }: { buttons: SavedButton[]; disabled: boolean; onRun: (id: string) => void; onEdit: (button: SavedButton) => void }) {
  return (
    <section className="saved-panel">
      <div className="saved-heading"><div><h2>Saved requests</h2><p>{buttons.length ? 'Successful requests live here.' : 'Successful requests become buttons.'}</p></div><span>{buttons.length}</span></div>
      <div className="saved-grid">
        {buttons.length ? buttons.map((button) => {
          const Icon = savedIcon(button.icon);
          return (
            <div className="saved-item" key={button.id}>
              <button type="button" className="saved-run" disabled={disabled} onClick={() => onRun(button.id)}>
                <Icon size={20} /><span>{button.label}</span><small>{button.kind === 'intent' ? 'Live request' : 'Local command'}</small>
              </button>
              <button type="button" className="saved-more" onClick={() => onEdit(button)} aria-label={`Edit ${button.label}`}><CircleEllipsis size={18} /></button>
            </div>
          );
        }) : (
          <div className="saved-empty"><Sparkles size={24} /><strong>Your first success lands here.</strong><span>Try “open Hulu” or ask the agent to find a show.</span></div>
        )}
      </div>
    </section>
  );
}

function RequestComposer({ running, disabled, onSubmit, onCancel }: { running: boolean; disabled: boolean; onSubmit: (prompt: string) => void; onCancel: () => void }) {
  const [prompt, setPrompt] = useState('');
  const submit = (event: FormEvent) => {
    event.preventDefault();
    const value = prompt.trim();
    if (!value || running || disabled) return;
    setPrompt('');
    onSubmit(value);
  };
  return (
    <form className="composer" onSubmit={submit}>
      <span className="composer-mark" aria-hidden="true"><Sparkles size={20} /></span>
      <label htmlFor="request-input" className="sr-only">Request for the TV</label>
      <input id="request-input" value={prompt} onChange={(event) => setPrompt(event.target.value)} disabled={running || disabled} placeholder={running ? 'Agent is working…' : 'What should the TV play or do?'} maxLength={500} autoComplete="off" />
      {running ? (
        <button type="button" className="stop-button" onClick={onCancel}><Square size={16} /> Stop</button>
      ) : (
        <button type="submit" className="run-button" disabled={disabled || !prompt.trim()}><Play size={17} /> Run</button>
      )}
    </form>
  );
}

function Onboarding({ settings, error, onError, onPaired, onSettings }: { settings: AppSettings; error: string; onError: (message: string) => void; onPaired: () => void; onSettings: (settings: AppSettings) => void }) {
  const [candidates, setCandidates] = useState<DeviceCandidate[]>([]);
  const [busy, setBusy] = useState(false);
  const [manualAddress, setManualAddress] = useState(settings.manualAddress);
  const [pairing, setPairing] = useState<DeviceCandidate | null>(null);
  const [pin, setPin] = useState('');

  async function discover() {
    onError('');
    setBusy(true);
    try {
      const updated = await api.updateSettings({ manualAddress: manualAddress.trim() });
      onSettings(updated);
      setCandidates(await api.discover());
    } catch (reason) {
      onError(readError(reason));
    } finally {
      setBusy(false);
    }
  }

  async function begin(candidate: DeviceCandidate) {
    onError('');
    setBusy(true);
    try {
      await api.pairStart(candidate);
      setPairing(candidate);
    } catch (reason) {
      onError(readError(reason));
    } finally {
      setBusy(false);
    }
  }

  async function finish(event: FormEvent) {
    event.preventDefault();
    onError('');
    setBusy(true);
    try {
      await api.pairFinish(pin);
      onPaired();
    } catch (reason) {
      onError(readError(reason));
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="onboarding-shell">
      <section className="onboarding-copy">
        <div className="brand-mark large"><Monitor size={27} /></div>
        <h1>Meet VizioControl.</h1>
        <p>Fast local controls when you want them. GPT-5.6 Luna Max can visually navigate streaming apps when finding something takes more than one button.</p>
        <ul><li><Check size={18} /> Manual TV controls stay on this PC and home LAN.</li><li><Check size={18} /> TV credentials are encrypted by Windows.</li><li><Check size={18} /> TV observations go to OpenAI only during an AI request.</li></ul>
      </section>
      <section className="onboarding-card">
        {pairing ? (
          <form onSubmit={finish}>
            <button type="button" className="back-link" onClick={() => { setPairing(null); setPin(''); }}><ArrowLeft size={17} /> Back</button>
            <h2>Enter the TV PIN</h2>
            <p>The TV is showing a four-digit pairing PIN. Two wrong attempts expire this session.</p>
            <label htmlFor="pair-pin">TV pairing PIN</label>
            <input id="pair-pin" className="pin-input" inputMode="numeric" pattern="[0-9]{4}" maxLength={4} value={pin} onChange={(event) => setPin(event.target.value.replace(/\D/g, '').slice(0, 4))} autoFocus />
            <button type="submit" className="primary-button" disabled={busy || pin.length !== 4}>{busy ? 'Pairing…' : 'Finish pairing'}</button>
          </form>
        ) : (
          <>
            <h2>Find your TV</h2>
            <p>Discovery checks Vizio and Google Cast announcements, then your optional fallback address.</p>
            <label htmlFor="manual-ip">Manual IP fallback</label>
            <div className="inline-field"><input id="manual-ip" value={manualAddress} onChange={(event) => setManualAddress(event.target.value)} placeholder="Optional, for example 192.168.50.42" /><button type="button" onClick={() => void discover()} disabled={busy}>{busy ? <RefreshCw className="spin" size={18} /> : <RefreshCw size={18} />} Scan</button></div>
            {error && <ErrorBanner message={error} onClose={() => onError('')} />}
            <div className="device-list">
              {candidates.map((candidate) => (
                <button type="button" className="device-row" key={`${candidate.id}-${candidate.address}`} onClick={() => void begin(candidate)} disabled={busy}>
                  <Monitor size={22} /><span><strong>{candidate.name}</strong><small>{candidate.model || 'Vizio SmartCast'} · {candidate.address}</small></span><ChevronRight size={20} />
                </button>
              ))}
              {!candidates.length && !busy && <div className="device-empty"><Wifi size={25} /><span>Run a scan while the TV is on or in quick-start mode.</span></div>}
            </div>
          </>
        )}
      </section>
    </main>
  );
}

function SettingsPanel({ settings, tv, ai, onClose, onUpdate, onRefreshAi, onSignIn, onCancelSignIn, onSignOut, onForget }: {
  settings: AppSettings;
  tv: TvState;
  ai: BootstrapState['ai'];
  onClose: () => void;
  onUpdate: (patch: Partial<AppSettings>) => void;
  onRefreshAi: () => void;
  onSignIn: () => void;
  onCancelSignIn: () => void;
  onSignOut: () => void;
  onForget: () => void;
}) {
  const [profile, setProfile] = useState(settings.preferredProfile);
  const dialogRef = useDialogFocusTrap(onClose);
  const usagePercent = ai.usage?.primaryUsedPercent;
  const aiPresentation = presentAiRuntime(ai);
  return (
    <div className="dialog-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
      <section ref={dialogRef} className="settings-panel" role="dialog" aria-modal="true" aria-labelledby="settings-title">
        <div className="dialog-heading"><div><h2 id="settings-title">Settings</h2><p>ChatGPT navigation, privacy, startup, and TV controls.</p></div><button type="button" className="icon-button" onClick={onClose} aria-label="Close settings"><X size={20} /></button></div>
        <div className="settings-group">
          <h3>Desktop</h3>
          <ToggleRow label="Start in the tray with Windows" detail="VizioControl stays ready without opening a window." checked={settings.launchAtStartup} onChange={(checked) => onUpdate({ launchAtStartup: checked })} />
        </div>
        <div className="settings-group">
          <h3>TV viewport</h3>
          <ToggleRow label="Show the screen preview" detail="Shows the in-memory SmartCast screen inside VizioControl." checked={settings.showPreview} onChange={(checked) => onUpdate({ showPreview: checked })} />
          <ToggleRow
            label="Always stream at 24 FPS"
            detail="Keeps the local viewport live without Luna whenever a compatible SmartCast app exposes its screen. Home, native menus, and HDMI are not available."
            checked={settings.alwaysStreamScreen}
            onChange={(checked) => onUpdate({ alwaysStreamScreen: checked, ...(checked ? { showPreview: true } : {}) })}
          />
        </div>
        <div className="settings-group">
          <h3>AI vision</h3>
          <ToggleRow label="Allow AI vision" detail="During an AI request only, sends requested in-memory SmartCast screenshots and focus data to OpenAI. The continuous local stream is never forwarded." checked={settings.aiVisionEnabled} onChange={(checked) => onUpdate({ aiVisionEnabled: checked })} />
          <label htmlFor="preferred-profile">Preferred Hulu profile</label>
          <div className="inline-field"><input id="preferred-profile" value={profile} onChange={(event) => setProfile(event.target.value)} placeholder="Your first choice is remembered" maxLength={80} /><button type="button" onClick={() => onUpdate({ preferredProfile: profile.trim() })}>Save</button></div>
        </div>
        <div className="settings-group">
          <h3>ChatGPT navigation</h3>
          <div className="account-row">
            <div>
              <strong>{aiPresentation.settingsTitle}</strong>
              <span>{ai.status === 'ready' ? `${ai.email || 'ChatGPT account'} · ${formatPlan(ai.planType)} plan` : ai.error || 'Manual TV controls remain available without ChatGPT.'}</span>
            </div>
            <button type="button" className="secondary-button" onClick={onRefreshAi}><RefreshCw size={16} /> Refresh</button>
          </div>
          <div className="model-lock" aria-label="Required AI configuration">
            <span><Bot size={18} /> Exact model</span><strong>gpt-5.6-luna</strong>
            <span>Reasoning</span><strong>Max</strong>
            <span>Runtime</span><strong>Codex App Server {ai.runtimeVersion}</strong>
          </div>
          {typeof usagePercent === 'number' && (
            <div className="usage-block">
              <div><span>Current usage window</span><strong>{Math.round(usagePercent)}%</strong></div>
              <progress max="100" value={Math.min(100, Math.max(0, usagePercent))}>{usagePercent}%</progress>
              {ai.usage?.primaryResetsAt && <small>Resets {formatReset(ai.usage.primaryResetsAt)}</small>}
            </div>
          )}
          <div className="account-actions">
            <AiAccountActionControl
              action={aiPresentation.accountAction}
              note={aiPresentation.actionNote}
              onSignIn={onSignIn}
              onCancelSignIn={onCancelSignIn}
              onSignOut={onSignOut}
            />
          </div>
          <p className="privacy-note">The browser is used only to authenticate ChatGPT. Hulu navigation happens through VizioControl’s restricted TV tools—never through browser or Windows control.</p>
        </div>
        <div className="settings-group danger-zone">
          <h3>Paired TV</h3>
          <p>The TV is {tv.connected ? 'connected' : 'currently unreachable'} at {tv.address || 'an unknown address'}.</p>
          <button type="button" className="danger-button" onClick={onForget}><Trash2 size={16} /> Forget TV and erase the local pairing token</button>
        </div>
      </section>
    </div>
  );
}

function AiAccountActionControl({ action, note, onSignIn, onCancelSignIn, onSignOut }: {
  action: AiAccountAction;
  note?: string;
  onSignIn: () => void;
  onCancelSignIn: () => void;
  onSignOut: () => void;
}) {
  switch (action) {
    case 'signIn':
      return <button type="button" className="primary-button compact" onClick={onSignIn}><LogIn size={16} /> Sign in with ChatGPT</button>;
    case 'cancelSignIn':
      return <button type="button" className="secondary-button" onClick={onCancelSignIn}><X size={16} /> Cancel sign-in</button>;
    case 'signOut':
      return <button type="button" className="secondary-button" onClick={onSignOut}><LogOut size={16} /> Sign out</button>;
    case 'none':
      return note ? <span className="account-action-note" role="status">{note}</span> : null;
  }
}

function ButtonEditor({ button, onClose, onSave, onMove, onDuplicate, onDelete }: {
  button: SavedButton;
  onClose: () => void;
  onSave: (patch: { label: string; prompt?: string }) => void;
  onMove: (direction: -1 | 1) => void;
  onDuplicate: () => void;
  onDelete: () => void;
}) {
  const [label, setLabel] = useState(button.label);
  const [prompt, setPrompt] = useState(button.kind === 'intent' ? button.prompt : '');
  const dialogRef = useDialogFocusTrap(onClose);
  return (
    <div className="dialog-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
      <section ref={dialogRef} className="button-editor" role="dialog" aria-modal="true" aria-labelledby="button-editor-title">
        <div className="dialog-heading"><div><h2 id="button-editor-title">Edit saved request</h2><p>{button.kind === 'intent' ? 'This request re-evaluates the live screen each time.' : 'This button runs local commands without AI.'}</p></div><button type="button" className="icon-button" onClick={onClose} aria-label="Close editor"><X size={20} /></button></div>
        <label htmlFor="button-label">Button label</label><input id="button-label" value={label} onChange={(event) => setLabel(event.target.value)} maxLength={40} autoFocus />
        {button.kind === 'intent' && <><label htmlFor="button-prompt">Request</label><textarea id="button-prompt" value={prompt} onChange={(event) => setPrompt(event.target.value)} maxLength={500} rows={4} /></>}
        <div className="editor-actions"><button type="button" onClick={() => onMove(-1)}><ArrowUp size={16} /> Move earlier</button><button type="button" onClick={() => onMove(1)}><ArrowDown size={16} /> Move later</button><button type="button" onClick={onDuplicate}><Copy size={16} /> Duplicate</button></div>
        <div className="dialog-footer"><button type="button" className="danger-text" onClick={onDelete}><Trash2 size={16} /> Delete</button><div><button type="button" className="secondary-button" onClick={onClose}>Cancel</button><button type="button" className="primary-button compact" onClick={() => onSave({ label, ...(button.kind === 'intent' ? { prompt } : {}) })}>Save changes</button></div></div>
      </section>
    </div>
  );
}

function ControlButton({ label, icon: Icon, onPress, disabled, immediate = false }: { label: string; icon: LucideIcon; onPress: () => Promise<unknown>; disabled: boolean; immediate?: boolean }) {
  const activate = () => void onPress();
  return <button type="button" className="control-button" disabled={disabled} {...(immediate ? immediatePressHandlers(activate) : { onClick: activate })} aria-label={label}><Icon size={20} /><span>{label}</span></button>;
}

function IconControl({ label, icon: Icon, onPress, disabled }: { label: string; icon: LucideIcon; onPress: () => Promise<unknown>; disabled: boolean }) {
  const activate = () => void onPress();
  return <button type="button" className="icon-control" disabled={disabled} {...immediatePressHandlers(activate)} aria-label={label} title={label}><Icon size={23} /></button>;
}

function immediatePressHandlers(onPress: () => void) {
  return {
    onPointerDown: (event: ReactPointerEvent<HTMLButtonElement>) => {
      if (event.button === 0 && !event.currentTarget.disabled) onPress();
    },
    // Keyboard and assistive-technology activation produces a click with no
    // pointer click count. Pointer clicks already dispatched on press-down.
    onClick: (event: ReactMouseEvent<HTMLButtonElement>) => {
      if (event.detail === 0 && !event.currentTarget.disabled) onPress();
    },
  };
}

function ToggleRow({ label, detail, checked, onChange }: { label: string; detail: string; checked: boolean; onChange: (value: boolean) => void }) {
  return <label className="toggle-row"><span><strong>{label}</strong><small>{detail}</small></span><input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} /><i aria-hidden="true" /></label>;
}

function ErrorBanner({ message, onClose }: { message: string; onClose: () => void }) {
  return <div className="error-banner" role="alert"><span>{message}</span><button type="button" onClick={onClose} aria-label="Dismiss error"><X size={18} /></button></div>;
}

function LoadingScreen({ error }: { error: string }) {
  return <main className="loading-screen"><div className="brand-mark large"><Monitor size={27} /></div><h1>VizioControl</h1><p>{error || 'Preparing the local controller…'}</p></main>;
}

function savedIcon(name: string): LucideIcon {
  const icons: Record<string, LucideIcon> = {
    'volume-x': VolumeX,
    'volume-2': Volume2,
    power: Power,
    house: House,
    'corner-up-left': Undo2,
    menu: Menu,
    cable: Cable,
    'app-window': AppWindow,
    sparkles: Sparkles,
  };
  return icons[name] ?? Sparkles;
}

function formatPlan(plan?: string) {
  if (!plan || plan === 'unknown') return 'Unknown';
  return plan.replace(/_/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function formatReset(value: number) {
  const milliseconds = value < 10_000_000_000 ? value * 1000 : value;
  return new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(milliseconds));
}

function formatTime(value: string) {
  return new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit', second: '2-digit' }).format(new Date(value));
}

function readError(reason: unknown) {
  const message = reason instanceof Error ? reason.message : String(reason);
  return message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '').replace(/^Error: /, '');
}

function useDialogFocusTrap(onClose: () => void) {
  const dialogRef = useRef<HTMLElement>(null);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  useEffect(() => {
    const previousFocus = document.activeElement as HTMLElement | null;
    const dialog = dialogRef.current;
    if (!dialog) return;
    const selector = 'button:not([disabled]), input:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
    const focusable = () => [...dialog.querySelectorAll<HTMLElement>(selector)].filter((element) => element.offsetParent !== null);
    focusable()[0]?.focus();
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        closeRef.current();
        return;
      }
      if (event.key !== 'Tab') return;
      const items = focusable();
      if (!items.length) return;
      const first = items[0];
      const last = items.at(-1)!;
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('keydown', onKeyDown);
      previousFocus?.focus();
    };
  }, []);
  return dialogRef;
}
