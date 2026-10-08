'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');

function appData() {
  return process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
}

const supportDir = process.env.CALLREC_SUPPORT || path.join(appData(), 'CallRecorder');
const modelsDir = path.join(supportDir, 'models');
const binDir = path.join(supportDir, 'bin');
const speakerDir = path.join(supportDir, 'speaker-models');
const vocabularyFile = path.join(supportDir, 'vocabulary.txt');
const settingsFile = path.join(supportDir, 'settings.json');

/** Root of all recordings; each day gets its own sub-folder. */
function rootDir() {
  // Not in Documents: Windows often syncs Documents to OneDrive, which would copy every recording to the cloud.
  const base = process.env.CALLREC_DIR || path.join(os.homedir(), 'CallRecordings');
  fs.mkdirSync(base, { recursive: true });
  return base;
}

function dayStamp(d = new Date()) {
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function timeStamp(d = new Date()) {
  const p = (n) => String(n).padStart(2, '0');
  return `${dayStamp(d)}_${p(d.getHours())}-${p(d.getMinutes())}-${p(d.getSeconds())}`;
}

function dayFolder(root = rootDir(), d = new Date()) {
  const dir = path.join(root, dayStamp(d));
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

const defaults = { language: 'en-US', verifyAfterLive: true, identifySpeakers: true, summarizeCalls: true, offlineMode: false };

/** A warning when the recordings folder looks like it is synced to a cloud service. */
function cloudSyncWarning(dir = rootDir()) {
  const m = /onedrive|dropbox|google ?drive|icloud|\bbox\b|nextcloud|sync/i.exec(dir);
  return m ? `The recordings folder (${dir}) looks cloud-synced (“${m[0]}”). Choose another folder with CALLREC_DIR so recordings stay on this PC.` : null;
}

function loadSettings() {
  try {
    return { ...defaults, ...JSON.parse(fs.readFileSync(settingsFile, 'utf8')) };
  } catch {
    return { ...defaults };
  }
}

function saveSettings(s) {
  try {
    fs.mkdirSync(supportDir, { recursive: true });
    fs.writeFileSync(settingsFile, JSON.stringify(s, null, 2));
  } catch { /* best effort */ }
}

const languages = [
  { id: 'auto', name: 'Auto-detect (Whisper)' },
  { id: 'en-US', name: 'English (US)' },
  { id: 'en-GB', name: 'English (UK)' },
  { id: 'de-DE', name: 'Deutsch' },
  { id: 'ru-RU', name: 'Русский' },
];

function languageCode(localeID) {
  return localeID === 'auto' ? 'auto' : String(localeID).split('-')[0] || 'en';
}

module.exports = {
  supportDir, modelsDir, binDir, speakerDir, vocabularyFile, settingsFile,
  rootDir, cloudSyncWarning, dayStamp, timeStamp, dayFolder, loadSettings, saveSettings, languages, languageCode,
};
