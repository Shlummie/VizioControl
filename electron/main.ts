import { app, BrowserWindow, ipcMain, Menu, nativeImage, session, shell, Tray } from 'electron';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import type { AppSettings, ButtonPatch, DeviceCandidate, TvKey } from '../src/shared/types';
import { isAllowedRendererNavigation, selectDevelopmentRendererUrl } from './rendererSecurity';
import { RemoteController } from './services/RemoteController';

let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
let controller: RemoteController;
let quitting = false;

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => showWindow());
}

app.setAppUserModelId('com.viziocontrol.desktop');

app.whenReady().then(async () => {
  controller = new RemoteController(app.getPath('userData'));
  await controller.initialize();
  registerIpc();
  createWindow();
  createTray();
  applyStartupSetting(controller.store.snapshot().settings.launchAtStartup);
  wireControllerEvents();
  if (process.argv.includes('--hidden')) mainWindow?.hide();
});

app.on('before-quit', () => {
  quitting = true;
  void controller?.shutdown();
});

app.on('window-all-closed', () => {
  // The tray owns the application lifetime on Windows.
});

function createWindow() {
  mainWindow = new BrowserWindow({
    title: 'VizioControl',
    width: 1440,
    height: 920,
    minWidth: 980,
    minHeight: 690,
    backgroundColor: '#111311',
    show: false,
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      devTools: !app.isPackaged,
    },
  });

  mainWindow.once('ready-to-show', () => {
    if (!process.argv.includes('--hidden')) mainWindow?.show();
  });
  mainWindow.on('close', (event) => {
    if (!quitting) {
      event.preventDefault();
      mainWindow?.hide();
    }
  });
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  mainWindow.webContents.on('will-attach-webview', (event) => event.preventDefault());

  session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
    callback({
      responseHeaders: {
        ...details.responseHeaders,
        'Content-Security-Policy': [
          app.isPackaged
            ? "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'none'; font-src 'self'"
            : "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-eval'; connect-src 'self' ws://127.0.0.1:5173 http://127.0.0.1:5173; font-src 'self'",
        ],
      },
    });
  });

  const rendererPath = path.join(__dirname, '..', 'dist', 'index.html');
  const devUrl = selectDevelopmentRendererUrl(app.isPackaged, process.env.VITE_DEV_SERVER_URL);
  const selectedRendererUrl = devUrl ?? pathToFileURL(rendererPath).href;
  const guardNavigation = (event: Electron.Event, url: string) => {
    if (!isAllowedRendererNavigation(url, selectedRendererUrl)) event.preventDefault();
  };
  mainWindow.webContents.on('will-navigate', guardNavigation);
  mainWindow.webContents.on('will-redirect', guardNavigation);
  if (devUrl) void mainWindow.loadURL(devUrl);
  else void mainWindow.loadFile(rendererPath);
}

function createTray() {
  const icon = nativeImage.createFromDataURL(`data:image/svg+xml;base64,${Buffer.from(traySvg()).toString('base64')}`);
  tray = new Tray(icon.resize({ width: 18, height: 18 }));
  tray.setToolTip('VizioControl');
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Open VizioControl', click: () => showWindow() },
    { label: 'Connect to TV', click: () => void controller.refreshTvState() },
    { label: 'Pause Luna navigator', click: () => void controller.cancelAgent() },
    { type: 'separator' },
    { label: 'Exit', click: () => { quitting = true; app.quit(); } },
  ]));
  tray.on('double-click', () => showWindow());
}

function showWindow() {
  if (!mainWindow) return;
  mainWindow.show();
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.focus();
}

function wireControllerEvents() {
  controller.on('agent', (event) => {
    mainWindow?.webContents.send('event:agent', event);
    if (event.type === 'choiceRequired' || event.type === 'confirmationRequired') {
      showWindow();
      mainWindow?.flashFrame(true);
    }
    if (event.type === 'completed' || event.type === 'paused' || event.type === 'failed') {
      mainWindow?.flashFrame(false);
    }
  });
  controller.on('screenFrame', (frame) => mainWindow?.webContents.send('event:screen-frame', frame));
  controller.on('screenStream', (state) => mainWindow?.webContents.send('event:screen-stream', state));
  controller.on('tv', (state) => mainWindow?.webContents.send('event:tv', state));
  controller.on('buttons', (buttons) => mainWindow?.webContents.send('event:buttons', buttons));
  controller.on('ai', (state) => mainWindow?.webContents.send('event:ai', state));
  controller.on('settings', (settings) => mainWindow?.webContents.send('event:settings', settings));
}

function registerIpc() {
  ipcMain.handle('app:bootstrap', () => controller.bootstrap());
  ipcMain.handle('tv:discover', () => controller.discover());
  ipcMain.handle('tv:pair-start', (_event, candidate: DeviceCandidate) => controller.pairStart(candidate));
  ipcMain.handle('tv:pair-finish', (_event, pin: string) => controller.pairFinish(String(pin)));
  ipcMain.handle('tv:forget', () => controller.forgetDevice());
  ipcMain.handle('tv:refresh', () => controller.refreshTvState());
  ipcMain.handle('tv:press', (_event, key: TvKey, count?: number) => controller.pressKey(key, count));
  ipcMain.handle('tv:volume', (_event, value: number) => controller.setVolume(Number(value)));
  ipcMain.handle('tv:text', (_event, value: string) => controller.typeText(String(value)));
  ipcMain.handle('tv:launch-app', (_event, name: string) => controller.launchApp(String(name)));
  ipcMain.handle('request:run', (_event, prompt: string) => controller.runRequest(String(prompt)));
  ipcMain.handle('agent:cancel', () => controller.cancelAgent());
  ipcMain.handle('agent:answer', (_event, requestId: string, value: string | boolean) => {
    mainWindow?.flashFrame(false);
    return controller.answerAgent(String(requestId), value);
  });
  ipcMain.handle('settings:update', async (_event, patch: Partial<AppSettings>) => {
    const settings = await controller.updateSettings(patch);
    if (patch.launchAtStartup !== undefined) applyStartupSetting(settings.launchAtStartup);
    return settings;
  });
  ipcMain.handle('buttons:update', (_event, id: string, patch: ButtonPatch) => controller.updateButton(String(id), patch));
  ipcMain.handle('buttons:duplicate', (_event, id: string) => controller.duplicateButton(String(id)));
  ipcMain.handle('buttons:delete', (_event, id: string) => controller.deleteButton(String(id)));
  ipcMain.handle('buttons:undo-delete', () => controller.undoDelete());
  ipcMain.handle('buttons:reorder', (_event, id: string, direction: -1 | 1) => controller.reorderButton(String(id), direction === -1 ? -1 : 1));
  ipcMain.handle('buttons:run', (_event, id: string) => controller.runButton(String(id)));
  ipcMain.handle('ai:refresh', () => controller.refreshAi());
  ipcMain.handle('ai:sign-in', async () => {
    const result = await controller.signInAi();
    if (result.authUrl) await shell.openExternal(result.authUrl, { activate: true });
    return result.state;
  });
  ipcMain.handle('ai:cancel-sign-in', () => controller.cancelAiSignIn());
  ipcMain.handle('ai:sign-out', () => controller.signOutAi());
}

function applyStartupSetting(enabled: boolean) {
  const executable = process.env.PORTABLE_EXECUTABLE_FILE || process.execPath;
  app.setLoginItemSettings({ openAtLogin: enabled, path: executable, args: ['--hidden'] });
}

function traySvg() {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="#171a17"/><path d="M17 18h30v28H17z" fill="none" stroke="#b5d16e" stroke-width="5"/><path d="M24 51h16" stroke="#b5d16e" stroke-width="5" stroke-linecap="round"/><circle cx="32" cy="32" r="5" fill="#b5d16e"/></svg>`;
}
