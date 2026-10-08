'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const { binDir, modelsDir } = require('./config');

const isWin = process.platform === 'win32';
const exe = (n) => (isWin ? `${n}.exe` : n);

function pathDirs() {
  return (process.env.PATH || '').split(path.delimiter).filter(Boolean);
}

/** First existing executable among the app's own bin folder, PATH, and some usual install places. */
function findExecutable(names, extraDirs = []) {
  const dirs = [binDir, ...pathDirs(), ...extraDirs];
  for (const d of dirs) {
    for (const n of names) {
      for (const f of [path.join(d, exe(n)), path.join(d, 'Release', exe(n)), path.join(d, 'bin', exe(n))]) {
        try { if (fs.statSync(f).isFile()) return f; } catch { /* next */ }
      }
    }
  }
  return null;
}

function ffmpegPath() {
  const local = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
  const extra = [
    path.join(local, 'Microsoft', 'WinGet', 'Links'),
    'C:\\ProgramData\\chocolatey\\bin',
    'C:\\Program Files\\ffmpeg\\bin',
    'C:\\ffmpeg\\bin',
    path.join(os.homedir(), 'scoop', 'shims'),
  ];
  return findExecutable(['ffmpeg'], extra);
}

const cliPath = () => findExecutable(['whisper-cli', 'main', 'whisper-cpp']);
const serverPath = () => findExecutable(['whisper-server']);

function modelPath(live = false) {
  const accurate = ['ggml-large-v3.bin', 'ggml-large-v3-q5_0.bin', 'ggml-large-v3-turbo.bin',
    'ggml-large-v3-turbo-q5_0.bin', 'ggml-medium.bin', 'ggml-small.bin', 'ggml-base.bin'];
  const fast = ['ggml-large-v3-turbo-q5_0.bin', 'ggml-large-v3-turbo.bin', 'ggml-large-v3-q5_0.bin',
    'ggml-large-v3.bin', 'ggml-medium.bin', 'ggml-small.bin', 'ggml-base.bin'];
  for (const n of live ? fast : accurate) {
    const p = path.join(modelsDir, n);
    if (fs.existsSync(p)) return p;
  }
  return null;
}

function vadModelPath() {
  const p = path.join(modelsDir, 'ggml-silero-v5.1.2.bin');
  return fs.existsSync(p) ? p : null;
}

const isReady = () => !!(cliPath() && modelPath());
const isLiveReady = () => !!(serverPath() && modelPath(true));

/** Runs a program to completion. Resolves {code, stdout(Buffer), stderr(string tail)}. */
function run(file, args, { input, onSpawn } = {}) {
  return new Promise((resolve, reject) => {
    let p;
    try {
      p = spawn(file, args, { windowsHide: true });
    } catch (e) { reject(e); return; }
    if (onSpawn) onSpawn(p);
    const out = [];
    let err = '';
    p.stdout.on('data', (d) => out.push(d));
    p.stderr.on('data', (d) => { err = (err + d.toString()).slice(-4000); });
    p.on('error', reject);
    p.on('close', (code) => resolve({ code, stdout: Buffer.concat(out), stderr: err }));
    if (input) p.stdin.end(input); else p.stdin.end();
  });
}

class ToolError extends Error {}

module.exports = {
  isWin, exe, findExecutable, ffmpegPath, cliPath, serverPath, modelPath, vadModelPath, isReady, isLiveReady,
  run, ToolError,
};
