'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const tools = require('./tools');
const text = require('./text');
const log = require('./livelog');

const languageCodes = { english: 'en', german: 'de', russian: 'ru' };

/** 16 kHz mono 16-bit PCM WAV from Float32 samples. */
function wavFrom(samples) {
  const n = samples.length;
  const buf = Buffer.alloc(44 + n * 2);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + n * 2, 4); buf.write('WAVE', 8);
  buf.write('fmt ', 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(16000, 24); buf.writeUInt32LE(32000, 28); buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34);
  buf.write('data', 36); buf.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) {
    const v = Math.max(-1, Math.min(1, samples[i]));
    buf.writeInt16LE(Math.round(v * 32767), 44 + i * 2);
  }
  return buf;
}

/** The server reports sub-word tokens; a token that begins with a space starts a new word. */
function mergeTokens(tokens) {
  const out = [];
  for (const t of tokens) {
    const piece = t.word;
    if (typeof piece !== 'string') continue;
    if (piece.startsWith('[_') || piece.startsWith('<|')) continue;       // special tokens
    const s = typeof t.start === 'number' ? t.start : -1;
    const e = typeof t.end === 'number' ? t.end : -1;
    if (piece.startsWith(' ') || out.length === 0) out.push({ text: piece.trim(), start: s, end: e });
    else { out[out.length - 1].text += piece; out[out.length - 1].end = e; }
  }
  return out.filter((w) => w.text);
}

function interpolate(txt, start, end) {
  const parts = txt.split(/\s+/).filter(Boolean);
  if (!parts.length) return [];
  const total = parts.reduce((a, p) => a + p.length, 0);
  const dur = Math.max(end - start, 0.01);
  let t = start;
  return parts.map((p) => {
    const d = dur * p.length / total;
    const w = { text: p, start: t, end: t + d };
    t += d;
    return w;
  });
}

/** whisper-server verbose_json -> {segs, probs, language} */
function parseResult(root, blocklist = []) {
  const probs = {};
  const lp = root && root.language_probabilities;
  if (lp && typeof lp === 'object') {
    for (const [k, v] of Object.entries(lp)) if (typeof v === 'number') probs[languageCodes[k.toLowerCase()] || k.toLowerCase()] = v;
  }
  let code = '';
  let bp = -1;
  for (const [k, v] of Object.entries(probs)) if (v > bp) { bp = v; code = k; }
  if (!code && root && typeof root.language === 'string') {
    const name = root.language.toLowerCase();
    code = languageCodes[name] || name;
  }
  const segs = [];
  for (const s of (root && root.segments) || []) {
    const rawText = String(s.text || '').trim();
    const t = text.scrub(rawText, blocklist);
    if (!t) continue;
    const start = typeof s.start === 'number' ? s.start : 0;
    const end = typeof s.end === 'number' ? s.end : start;
    let words = t === rawText ? mergeTokens(s.words || []) : [];       // text was cleaned: re-space the words
    if (!words.length || words.some((w) => w.start < 0 || w.end < w.start)) words = interpolate(t, start, end);
    segs.push({ start, end, text: t, noSpeech: s.no_speech_prob || 0, avgLogprob: s.avg_logprob || 0, words });
  }
  return { segs, probs, language: code };
}

class ServerDown extends Error {}

/** whisper-server keeps the model loaded between requests. Restarts itself (with fewer features) after a crash. */
class WhisperServer {
  constructor() {
    this.proc = null; this.port = 0; this.startPromise = null;
    this.prompt = ''; this.blocklist = []; this.level = 0; this.generation = 0; this.lastLog = '';
    this.logFile = path.join(os.tmpdir(), 'whisper-server.log');
  }

  ensureRunning() {
    if (!this.startPromise) {
      this.startPromise = this.launch().catch((e) => {
        this.kill(); this.startPromise = null; throw e;
      });
    }
    return this.startPromise;
  }

  kill() {
    if (this.proc) { try { this.proc.kill(); } catch { /* gone */ } }
    this.proc = null;
  }

  stop() { this.kill(); this.startPromise = null; }

  async launch() {
    const exe = tools.serverPath();
    if (!exe) throw new tools.ToolError('whisper-server not found. Run setup-whisper.ps1');
    const model = tools.modelPath(true);
    if (!model) throw new tools.ToolError('No Whisper model found. Run setup-whisper.ps1 to download one.');
    this.prompt = text.vocabularyPrompt();
    this.blocklist = text.userBlocklist();
    this.port = 20000 + Math.floor(Math.random() * 20000);
    const fd = fs.openSync(this.logFile, 'w');
    // No server-side silence detector: the volume gate in the streaming transcriber already keeps silence away.
    const p = spawn(exe, ['-m', model, '--host', '127.0.0.1', '--port', String(this.port), '-l', 'auto', '-t', '4'],
      { stdio: ['ignore', fd, fd], windowsHide: true });
    let exited = false;
    p.on('exit', () => { exited = true; });
    p.on('error', () => { exited = true; });
    this.proc = p;
    const deadline = Date.now() + 90000;
    while (Date.now() < deadline) {
      if (exited) {
        const tail = (fs.readFileSync(this.logFile, 'utf8') || '').slice(-300);
        throw new tools.ToolError(`whisper-server exited: ${tail}`);
      }
      if (await this.healthOK()) return;
      await new Promise((r) => setTimeout(r, 300));
    }
    throw new tools.ToolError('whisper-server did not become ready in 90 s');
  }

  async healthOK() {
    try {
      const r = await fetch(`http://127.0.0.1:${this.port}/health`, { signal: AbortSignal.timeout(1000) });
      return r.status === 200;
    } catch { return false; }
  }

  /** If the server dies, restart it with fewer features and try again. */
  async transcribe(samples, language) {
    for (let i = 0; i < 3; i++) {
      await this.ensureRunning();
      const gen = this.generation;
      try {
        return await this.request(samples, language);
      } catch (e) {
        if (!(e instanceof ServerDown)) throw e;
        if (gen === this.generation) {                     // first request to notice: replace the server
          this.generation++;
          try { this.lastLog = fs.readFileSync(this.logFile, 'utf8').slice(-400); } catch { /* none */ }
          this.kill(); this.startPromise = null; this.level++;
        }
        if (this.level > 1) break;
      }
    }
    throw new tools.ToolError(`whisper-server keeps stopping. Its log ends with: ${this.lastLog}`);
  }

  async request(samples, language) {
    const form = new FormData();
    form.append('response_format', 'verbose_json');
    form.append('language', language);
    form.append('temperature', '0.0');
    form.append('temperature_inc', this.level >= 1 ? '0.0' : '0.2');   // retry hotter when decoding degenerates
    form.append('suppress_nst', 'true');
    if (language !== 'auto') form.append('no_language_probabilities', 'true');
    if (this.prompt) { form.append('prompt', this.prompt); form.append('carry_initial_prompt', 'true'); }
    form.append('file', new Blob([wavFrom(samples)], { type: 'audio/wav' }), 'chunk.wav');
    let res;
    try {
      res = await fetch(`http://127.0.0.1:${this.port}/inference`, { method: 'POST', body: form, signal: AbortSignal.timeout(25000) });
    } catch (e) {
      log.write(`server request failed: ${e && e.message}`);
      throw new ServerDown(String(e && e.message));
    }
    if (res.status !== 200) throw new tools.ToolError('whisper-server: ' + (await res.text().catch(() => 'request failed')));
    return parseResult(await res.json(), this.blocklist);
  }
}

module.exports = { WhisperServer, parseResult, wavFrom, mergeTokens, interpolate, ServerDown };
