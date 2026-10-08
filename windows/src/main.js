'use strict';
const path = require('path');
const fs = require('fs');
const {
  app, BrowserWindow, globalShortcut, ipcMain, Tray, Menu, nativeImage, dialog, shell, clipboard,
  desktopCapturer, session: electronSession,
} = require('electron');
const { Session } = require('./session');
const config = require('./lib/config');
const text = require('./lib/text');
const log = require('./lib/livelog');
const net = require('./lib/net');
const os = require('os');

if (!app.requestSingleInstanceLock()) { app.quit(); return; }

// No background network chatter from Chromium (component updates, pings, sync…). The app only talks to 127.0.0.1.
for (const sw of ['disable-background-networking', 'disable-component-update', 'disable-sync', 'no-pings',
  'disable-domain-reliability', 'no-default-browser-check']) app.commandLine.appendSwitch(sw);

const isOurPage = (url) => typeof url === 'string' && url.startsWith('file://');

// Raw audio of a crashed session would otherwise stay in the temp folder.
function sweepTemp() {
  try {
    for (const n of fs.readdirSync(os.tmpdir())) {
      if (!/^callrec-/.test(n)) continue;
      const p = path.join(os.tmpdir(), n);
      if (Date.now() - fs.statSync(p).mtimeMs > 60 * 60 * 1000) fs.rmSync(p, { recursive: true, force: true });
    }
  } catch { /* best effort */ }
}

// Debug log: in the project folder when run from source (git-ignored), else next to the settings.
if (!app.isPackaged) log.setFile(path.join(__dirname, '..', 'live-debug.log'));

let win = null;
let tray = null;
let quitting = false;
let session = null;
const pending = new Map();           // id -> resolver for renderer replies
let nextId = 1;

function rpc(channel) {
  return new Promise((resolve, reject) => {
    if (!win || win.isDestroyed()) { reject(new Error('window is not available')); return; }
    const id = nextId++;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('capture did not answer in time')); }, 20000);
    pending.set(id, (r) => { clearTimeout(timer); r.ok ? resolve(r) : reject(new Error(r.error || 'failed')); });
    win.webContents.send(channel, id);
  });
}

function createWindow() {
  win = new BrowserWindow({
    width: 520, height: 800, minWidth: 460, title: 'CallRecorder', autoHideMenuBar: true,
    icon: path.join(__dirname, '..', 'assets', 'icon.png'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true, nodeIntegration: false, sandbox: true, webSecurity: true,
      allowRunningInsecureContent: false,
      backgroundThrottling: false,                 // keep capturing while the window is hidden
      autoplayPolicy: 'no-user-gesture-required',  // the audio graph starts from a hotkey, not a click
    },
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.on('close', (e) => { if (!quitting) { e.preventDefault(); win.hide(); } });   // keep running in the tray
}

function showWindow() {
  if (!win) createWindow();
  if (win.isMinimized()) win.restore();
  win.show(); win.focus();
}

function registerHotKeys() {
  const failed = [];
  const reg = (accel, fn) => { try { if (!globalShortcut.register(accel, fn)) failed.push(accel); } catch { failed.push(accel); } };
  reg('Control+Alt+R', () => session.toggle(false));
  reg('Control+Alt+L', () => session.toggle(true));
  if (failed.length) session.set({ status: `Hotkey already used by another app: ${failed.join(', ')}. Use the buttons instead.` });
}

function buildTray() {
  tray = new Tray(nativeImage.createFromPath(path.join(__dirname, '..', 'assets', 'icon.png')).resize({ width: 16, height: 16 }));
  tray.setToolTip('CallRecorder');
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Show CallRecorder', click: showWindow },
    { label: 'Record / stop   (Ctrl+Alt+R)', click: () => session.toggle(false) },
    { label: 'Record + live / stop   (Ctrl+Alt+L)', click: () => session.toggle(true) },
    { type: 'separator' },
    { label: 'Quit', click: () => { quitting = true; app.quit(); } },
  ]));
  tray.on('click', showWindow);
}

app.on('second-instance', showWindow);

// The window may only ever show our own page: no navigation, no pop-ups.
app.on('web-contents-created', (_e, wc) => {
  wc.setWindowOpenHandler(() => ({ action: 'deny' }));
  wc.on('will-navigate', (ev) => ev.preventDefault());
});

app.whenReady().then(() => {
  const ses = electronSession.defaultSession;
  // System audio: "loopback" captures everything you hear (Teams, Telemost, browser…), like the Mac version.
  ses.setDisplayMediaRequestHandler((request, callback) => {
    desktopCapturer.getSources({ types: ['screen'] }).then((sources) => {
      callback({ video: sources[0], audio: 'loopback' });
    }).catch(() => callback({}));
  });
  ses.setPermissionRequestHandler((wc, permission, cb) =>
    cb(['media', 'display-capture'].includes(permission) && isOurPage(wc.getURL())));
  ses.setPermissionCheckHandler((wc, permission) =>
    ['media', 'display-capture'].includes(permission) && !!wc && isOurPage(wc.getURL()));
  // Defence in depth: nothing in the window may reach anything but local files and this computer.
  ses.webRequest.onBeforeRequest((details, cb) => {
    const u = details.url;
    const ok = /^(file|devtools|data|blob):/.test(u) || net.isLoopbackUrl(u);
    if (!ok) log.write(`BLOCKED request to ${u}`);
    cb({ cancel: !ok });
  });
  sweepTemp();

  session = new Session({
    changed: (s) => { if (win && !win.isDestroyed()) win.webContents.send('state', s); },
    startCapture: () => rpc('capture:start'),
    stopCapture: () => rpc('capture:stop'),
  });

  const trusted = (e) => !!e.senderFrame && isOurPage(e.senderFrame.url);
  const handle = (ch, fn) => ipcMain.handle(ch, (e, ...a) => (trusted(e) ? fn(e, ...a) : undefined));
  ipcMain.on('audio', (e, track, buf) => { if (trusted(e)) session.addAudio(track, new Float32Array(buf)); });
  ipcMain.on('capture:reply', (e, id, r) => {
    if (!trusted(e)) return;
    const f = pending.get(id); if (f) { pending.delete(id); f(r); }
  });
  handle('state', () => session.snapshot());
  handle('toggle', (e, live) => session.toggle(!!live));
  handle('setSetting', (e, k, v) => session.setSetting(k, v));
  handle('rename', (e, a, b) => session.renameSpeaker(a, b));
  handle('openFolder', () => shell.openPath(config.rootDir()));
  handle('openVocabulary', () => shell.openPath(text.ensureVocabularyFile()));
  handle('copy', (e, what) => {
    clipboard.writeText(what === 'claude' ? session.copyForClaudeText() : session.s.summaryText);
    if (what === 'claude') session.set({ summaryNote: 'Copied. Paste it into a Claude chat to get the summary.' });
  });
  handle('transcribeFile', async () => {
    const r = await dialog.showOpenDialog(win, {
      title: 'Choose an audio file to transcribe', defaultPath: config.dayFolder(),
      filters: [{ name: 'Audio', extensions: ['mp3', 'wav', 'm4a', 'flac', 'ogg', 'mp4', 'aac'] }], properties: ['openFile'],
    });
    if (!r.canceled && r.filePaths[0]) session.transcribeFile(r.filePaths[0]);
  });
  handle('quit', () => { quitting = true; app.quit(); });

  createWindow();
  buildTray();
  registerHotKeys();

  if (process.env.CALLREC_AUTOTEST) {       // developer check: record 3 s from the (fake) mic and report what arrived
    win.webContents.once('did-finish-load', () => setTimeout(async () => {
      await session.toggle(false);
      await new Promise((r) => setTimeout(r, 3500));
      const mic = session.tracks && session.tracks.mic.bytes;
      console.log('AUTOTEST status:', session.s.status, '| mic bytes:', mic);
      await session.toggle(false);
      console.log('AUTOTEST after stop:', session.s.status);
      quitting = true; app.quit();
    }, 1000));
  }
  if (process.env.CALLREC_SMOKE) {          // developer check: render the window once, save a screenshot, exit
    win.webContents.once('did-finish-load', () => setTimeout(async () => {
      const img = await win.webContents.capturePage();
      fs.writeFileSync(process.env.CALLREC_SMOKE, img.toPNG());
      quitting = true; app.quit();
    }, 1500));
  }
});

app.on('before-quit', () => { quitting = true; });
app.on('will-quit', () => { globalShortcut.unregisterAll(); try { session.deps.server.stop(); } catch { /* ignore */ } });
app.on('window-all-closed', () => { /* stay in the tray */ });
