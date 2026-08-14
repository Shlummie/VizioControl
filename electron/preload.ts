import { contextBridge, ipcRenderer } from 'electron';
import type { AgentEvent, AiRuntimeState, AppSettings, VizioControlApi, SavedButton, ScreenFrame, ScreenStreamState, TvState } from '../src/shared/types';

function subscribe<T>(channel: string, callback: (payload: T) => void) {
  const listener = (_event: Electron.IpcRendererEvent, payload: T) => callback(payload);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
}

const api: VizioControlApi = {
  getBootstrap: () => ipcRenderer.invoke('app:bootstrap'),
  discover: () => ipcRenderer.invoke('tv:discover'),
  pairStart: (candidate) => ipcRenderer.invoke('tv:pair-start', candidate),
  pairFinish: (pin) => ipcRenderer.invoke('tv:pair-finish', pin),
  forgetDevice: () => ipcRenderer.invoke('tv:forget'),
  refreshTvState: () => ipcRenderer.invoke('tv:refresh'),
  pressKey: (key, count) => ipcRenderer.invoke('tv:press', key, count),
  setVolume: (value) => ipcRenderer.invoke('tv:volume', value),
  typeText: (value) => ipcRenderer.invoke('tv:text', value),
  launchApp: (name) => ipcRenderer.invoke('tv:launch-app', name),
  runRequest: (prompt) => ipcRenderer.invoke('request:run', prompt),
  cancelAgent: () => ipcRenderer.invoke('agent:cancel'),
  answerAgent: (requestId, value) => ipcRenderer.invoke('agent:answer', requestId, value),
  updateSettings: (patch) => ipcRenderer.invoke('settings:update', patch),
  updateButton: (id, patch) => ipcRenderer.invoke('buttons:update', id, patch),
  duplicateButton: (id) => ipcRenderer.invoke('buttons:duplicate', id),
  deleteButton: (id) => ipcRenderer.invoke('buttons:delete', id),
  undoDelete: () => ipcRenderer.invoke('buttons:undo-delete'),
  reorderButton: (id, direction) => ipcRenderer.invoke('buttons:reorder', id, direction),
  runButton: (id) => ipcRenderer.invoke('buttons:run', id),
  refreshAi: () => ipcRenderer.invoke('ai:refresh'),
  signInAi: () => ipcRenderer.invoke('ai:sign-in'),
  cancelAiSignIn: () => ipcRenderer.invoke('ai:cancel-sign-in'),
  signOutAi: () => ipcRenderer.invoke('ai:sign-out'),
  onAgentEvent: (callback) => subscribe<AgentEvent>('event:agent', callback),
  onScreenFrame: (callback) => subscribe<ScreenFrame>('event:screen-frame', callback),
  onScreenStreamState: (callback) => subscribe<ScreenStreamState>('event:screen-stream', callback),
  onTvState: (callback) => subscribe<TvState>('event:tv', callback),
  onButtons: (callback) => subscribe<SavedButton[]>('event:buttons', callback),
  onAiState: (callback) => subscribe<AiRuntimeState>('event:ai', callback),
  onSettings: (callback) => subscribe<AppSettings>('event:settings', callback),
};

contextBridge.exposeInMainWorld('vizioControl', api);
