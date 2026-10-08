'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const config = require('./lib/config');
const tools = require('./lib/tools');
const whisper = require('./lib/whisper');
const text = require('./lib/text');
const log = require('./lib/livelog');
const { WhisperServer } = require('./lib/server');
const { StreamingTranscriber, Downsampler } = require('./lib/live');
const summarizer = require('./lib/summarizer');

const fmtTime = (s) => {
  s = Math.floor(Math.max(s, 0));
  return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
};

/**
 * All app logic, independent of Electron. `hooks` supplies what only the GUI can do:
 *   startCapture() -> Promise<{sampleRate}>, stopCapture() -> Promise,
 *   changed(state) is called whenever the visible state changes.
 * `deps` lets tests replace the heavy parts (diarizer, whisper, summarizer, mixer).
 */
class Session {
  constructor(hooks, deps = {}) {
    this.hooks = hooks;
    this.deps = {
      diarize: deps.diarize || ((f) => require('./lib/diarize').diarize(f)),
      whisper: deps.whisper || whisper,
      summarize: deps.summarize || summarizer.summarize,
      describeImage: deps.describeImage || summarizer.describeImage,
      server: deps.server || new WhisperServer(),
      runTool: deps.runTool || tools.run,
      ffmpegPath: deps.ffmpegPath || tools.ffmpegPath,
      isReady: deps.isReady || tools.isReady,
      isLiveReady: deps.isLiveReady || tools.isLiveReady,
    };
    this.settings = config.loadSettings();
    this.s = {
      isRecording: false, liveMode: false, busy: false, status: 'Ready', elapsed: '00:00',
      finalLines: [], partials: {}, checkNote: '', summaryText: '', summaryNote: '', speakerLabels: [],
      sysSeconds: 0, micSeconds: 0, topic: '', shotCount: 0,
    };
    this.shots = [];
    this.lines = [];
    this.openLine = {};
    this.transcribers = [];
    this.tracks = null;
    this.summaryTranscript = '';
    this.lastTranscriptFile = null;
    this.outDir = config.dayFolder();
    this.timer = null;
  }

  // ---- state -------------------------------------------------------------------------------------------------------

  snapshot() {
    return {
      ...this.s,
      settings: this.settings,
      languages: config.languages,
      whisperHint: this.whisperHint(),
      syncWarning: config.cloudSyncWarning(),
      rootDir: config.rootDir(),
    };
  }

  set(patch) { Object.assign(this.s, patch); this.hooks.changed(this.snapshot()); }

  whisperHint() {
    return this.deps.isReady() ? null : 'Whisper isn\'t set up yet: run setup-whisper.ps1 (right-click, Run with PowerShell), then restart the app.';
  }

  setTopic(topic) { this.set({ topic: String(topic || '').slice(0, 300) }); }

  setSetting(key, value) {
    if (key === 'outputRoot') {                       // '' = back to the default folder
      const dir = String(value || '').trim();
      if (dir) {
        try {
          if (!path.isAbsolute(dir)) throw new Error('the path must be absolute');
          fs.mkdirSync(dir, { recursive: true });
          fs.accessSync(dir, fs.constants.W_OK);
        } catch (e) { this.set({ status: `Cannot use that folder: ${e.message}` }); return; }
      }
      this.settings.outputRoot = dir;
      config.saveSettings(this.settings);
      if (!this.s.isRecording) this.outDir = config.dayFolder();
      this.set({ status: dir ? `Recordings will be saved in ${dir}` : 'Recordings go to the default folder again' });
      return;
    }
    if (!['language', 'verifyAfterLive', 'identifySpeakers', 'summarizeCalls', 'offlineMode'].includes(key)) return;
    if (key === 'language' && !config.languages.some((l) => l.id === value)) return;
    this.settings[key] = value;
    config.saveSettings(this.settings);
    this.hooks.changed(this.snapshot());
  }

  // ---- recording ---------------------------------------------------------------------------------------------------

  async toggle(live) {
    if (this.s.busy) return;
    if (this.s.isRecording) await this.stopRecording();
    else await this.startRecording(live);
  }

  async startRecording(live) {
    this.set({ busy: true });
    try {
      this.lines = []; this.openLine = {};
      this.outDir = config.dayFolder();
      this.summaryTranscript = ''; this.lastTranscriptFile = null; this.shots = [];
      this.set({ finalLines: [], partials: {}, liveMode: live, summaryText: '', summaryNote: '', checkNote: '',
        speakerLabels: [], sysSeconds: 0, micSeconds: 0, shotCount: 0 });
      if (live) {
        log.reset();
        if (!this.deps.isLiveReady()) {
          this.set({ status: 'Live Whisper needs whisper-server: run setup-whisper.ps1, then try again.' });
          return;
        }
      }
      this.baseName = 'Call_' + config.timeStamp();
      this.tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'callrec-'));
      this.tracks = {};
      for (const name of ['system', 'mic']) {
        this.tracks[name] = { file: path.join(this.tmp, `${name}.pcm`), fd: fs.openSync(path.join(this.tmp, `${name}.pcm`), 'w'),
          bytes: 0, firstAt: null, down: null };
      }
      this.sessionStart = Date.now();

      this.transcribers = [];
      if (live) {
        const lang = config.languageCode(this.settings.language);
        const server = this.deps.server;
        for (const label of ['Them', 'Me']) {
          const t = new StreamingTranscriber({ label, language: lang, transcribe: (s, l) => server.transcribe(s, l) });
          t.onEvent = (e) => this.handleEvent(e);
          t.start();
          this.transcribers.push(t);
        }
        this.tracks.system.sink = this.transcribers[0];
        this.tracks.mic.sink = this.transcribers[1];
      }

      let info;
      try {
        info = await this.hooks.startCapture();
      } catch (e) {
        this.cleanupTracks();
        this.transcribers.forEach((t) => t.halt());
        this.transcribers = [];
        this.set({ status: `Could not start: ${e.message || e}` });
        return;
      }
      this.sampleRate = info.sampleRate || 48000;
      for (const t of Object.values(this.tracks)) t.down = new Downsampler(this.sampleRate);

      this.set({ isRecording: true,
        status: (live ? 'Starting Whisper…' : 'Recording') + (info.warning ? ` — warning: ${info.warning}` : '') });
      if (live) {
        this.deps.server.ensureRunning().then(
          () => { if (this.s.isRecording) this.set({ status: 'Recording + live transcript (Whisper)' }); },
          (e) => this.set({ status: `Whisper: ${e.message}` }));
      }
      this.timer = setInterval(() => {
        const sec = Math.floor((Date.now() - this.sessionStart) / 1000);
        this.set({ elapsed: fmtTime(sec),
          sysSeconds: Math.round(this.tracks.system.bytes / 2 / this.sampleRate),
          micSeconds: Math.round(this.tracks.mic.bytes / 2 / this.sampleRate) });
      }, 1000);
    } finally {
      this.set({ busy: false });
    }
  }

  /** Saves a screenshot of the screen (a shared presentation, a picture…) taken during the call. It is described by a
   *  local vision model after the call and becomes part of the summary. */
  async takeScreenshot() {
    if (!this.s.isRecording) { this.set({ status: 'Screenshots can be taken while a recording is running.' }); return null; }
    if (!this.hooks.captureScreen) return null;
    try {
      const png = await this.hooks.captureScreen();
      const t = (Date.now() - this.sessionStart) / 1000;
      const dir = path.join(this.outDir, this.baseName + '_screens');
      fs.mkdirSync(dir, { recursive: true });
      const file = path.join(dir, `${String(this.shots.length + 1).padStart(2, '0')}_${fmtTime(t).replace(':', '-')}.png`);
      fs.writeFileSync(file, png);
      this.shots.push({ t, file });
      this.set({ shotCount: this.shots.length, status: `Screenshot ${this.shots.length} saved at ${fmtTime(t)}` });
      return file;
    } catch (e) {
      this.set({ status: `Screenshot failed: ${e.message || e}` });
      return null;
    }
  }

  /** Audio from the renderer: Float32 mono blocks at the capture rate. */
  addAudio(trackName, floats) {
    const tr = this.tracks && this.tracks[trackName];
    if (!tr || tr.fd < 0) return;
    if (tr.firstAt === null) tr.firstAt = Date.now() - this.sessionStart;
    const pcm = Buffer.allocUnsafe(floats.length * 2);
    for (let i = 0; i < floats.length; i++) {
      pcm.writeInt16LE(Math.round(Math.max(-1, Math.min(1, floats[i])) * 32767), i * 2);
    }
    try { fs.writeSync(tr.fd, pcm); tr.bytes += pcm.length; } catch { /* disk full etc: reported at stop */ }
    if (tr.sink && tr.down) tr.sink.append(tr.down.process(floats));
  }

  cleanupTracks() {
    if (this.tracks) for (const t of Object.values(this.tracks)) { try { fs.closeSync(t.fd); } catch { /* closed */ } }
    if (this.tmp) fs.rmSync(this.tmp, { recursive: true, force: true });
    this.tracks = null;
  }

  async stopRecording() {
    this.set({ busy: true, status: 'Finishing…' });
    clearInterval(this.timer); this.timer = null;
    try { await this.hooks.stopCapture(); } catch { /* already stopped */ }
    this.set({ isRecording: false, elapsed: '00:00' });
    for (const t of Object.values(this.tracks)) { try { fs.closeSync(t.fd); } catch { /* closed */ } t.fd = -1; }

    const shots = this.shots.slice();
    const sinks = this.transcribers; this.transcribers = [];
    const finishing = Promise.all(sinks.map((s) => s.finish()));
    const base = this.baseName;
    const dir = this.outDir;
    const live = this.s.liveMode;
    const mp3 = path.join(dir, base + '.mp3');
    const keepTracks = live && this.settings.verifyAfterLive;
    const wavs = { system: null, mic: null };
    let mp3Saved = false;

    this.set({ status: 'Converting to MP3…' });
    try {
      for (const name of ['system', 'mic']) {
        const tr = this.tracks[name];
        if (tr.bytes > 0) wavs[name] = await this.pcmToWav(tr, path.join(this.tmp, `${name}.wav`));
      }
      await this.mixToMp3(wavs.system, wavs.mic, mp3);
      mp3Saved = true;
      this.set({ status: `Saved ${path.basename(mp3)}`, lastFile: mp3 });
    } catch (e) {
      const d = `system ${this.s.sysSeconds}s, mic ${this.s.micSeconds}s`;
      this.set({ status: `MP3 conversion failed: ${e.message} [${d}]` });
    }

    if (live) {
      if (sinks.length) this.set({ status: 'Finishing transcript…' });
      await finishing;
      this.deps.server.stop();
      for (const [label, t] of Object.entries(this.s.partials)) if (t) this.handleEvent({ label, commit: t, tail: '', newLine: true });
      this.set({ partials: {} });
      const txt = path.join(dir, base + '.txt');
      fs.writeFileSync(txt, this.s.finalLines.join('\n'));
      this.lastTranscriptFile = txt;
      if (mp3Saved) this.set({ status: `Saved ${path.basename(mp3)} + ${path.basename(txt)}` });

      const liveLines = this.s.finalLines.slice();
      if (this.settings.verifyAfterLive && (wavs.system || wavs.mic)) {
        const tmp = this.tmp; this.tmp = null; this.tracks = null;     // the check pass owns the temp files now
        this.set({ busy: false });
        const verified = await this.verify({ base, dir, system: wavs.system, mic: wavs.mic, live: liveLines });
        fs.rmSync(tmp, { recursive: true, force: true });
        await this.summarize(verified, base, dir, shots);
        return;
      }
      this.cleanupTracks();
      this.set({ busy: false });
      await this.summarize(liveLines, base, dir, shots);
      return;
    }

    this.cleanupTracks();
    this.set({ busy: false });
    if (this.settings.summarizeCalls && mp3Saved && this.deps.isReady()) await this.transcribeFile(mp3, { shots });   // summary follows
  }

  async pcmToWav(tr, out) {
    const ffmpeg = this.deps.ffmpegPath();
    if (!ffmpeg) throw new Error('ffmpeg not found — run setup-whisper.ps1 or: winget install Gyan.FFmpeg');
    const args = ['-y', '-loglevel', 'error', '-f', 's16le', '-ar', String(this.sampleRate), '-ac', '1', '-i', tr.file];
    if (tr.firstAt > 150) args.push('-af', `adelay=${Math.round(tr.firstAt)}:all=1`);   // align a late-starting track
    args.push('-c:a', 'pcm_s16le', out);
    const r = await this.deps.runTool(ffmpeg, args);
    if (r.code !== 0) throw new Error(r.stderr || 'ffmpeg failed');
    return out;
  }

  async mixToMp3(system, mic, output) {
    const ffmpeg = this.deps.ffmpegPath();
    if (!ffmpeg) throw new Error('ffmpeg not found — run setup-whisper.ps1 or: winget install Gyan.FFmpeg');
    const inputs = [system, mic].filter(Boolean);
    if (!inputs.length) throw new Error('No audio was captured.');
    const args = ['-y', '-loglevel', 'error'];
    for (const i of inputs) args.push('-i', i);
    if (inputs.length === 2) {
      args.push('-filter_complex',
        '[0:a]aresample=48000,aformat=channel_layouts=stereo[a0];[1:a]aresample=48000,aformat=channel_layouts=stereo[a1];' +
        '[a0][a1]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95[out]', '-map', '[out]');
    }
    args.push('-ac', '2', '-codec:a', 'libmp3lame', '-b:a', '128k', output);
    const r = await this.deps.runTool(ffmpeg, args);
    if (r.code !== 0) throw new Error(r.stderr || 'ffmpeg failed');
  }

  // ---- live transcript ---------------------------------------------------------------------------------------------

  /** Confirmed text is appended to the speaker's current line; the tentative tail is shown separately. */
  handleEvent(e) {
    if (e.error) { this.set({ status: `Live transcription: ${e.error}` }); return; }
    if (e.commit) {
      const t = e.time != null ? e.time : (Date.now() - this.sessionStart) / 1000;
      const i = this.openLine[e.label];
      if (!e.newLine && i !== undefined && this.lines[i].text.length < 300) this.lines[i].text += ' ' + e.commit;
      else { this.lines.push({ t, label: e.label, text: e.commit }); this.openLine[e.label] = this.lines.length - 1; }
    }
    const partials = { ...this.s.partials };
    if (e.tail) partials[e.label] = e.tail; else delete partials[e.label];
    const finalLines = this.lines.slice().sort((a, b) => a.t - b.t)
      .map((l) => `[${fmtTime(l.t)}] ${l.label}: ${l.text}`);
    this.set({ partials, finalLines });
  }

  // ---- check pass / file transcription / summary -------------------------------------------------------------------

  async verify({ base, dir, system, mic, live }) {
    if (!this.deps.isReady()) {
      this.set({ checkNote: 'Transcript check skipped: Whisper isn\'t set up (run setup-whisper.ps1).' });
      return live;
    }
    const lang = config.languageCode(this.settings.language);
    let turns = []; let note = '';
    if (this.settings.identifySpeakers && system) {
      this.set({ checkNote: 'Finding who speaks when… (the first time this downloads small speaker models)' });
      try {
        turns = await this.deps.diarize(system);
        const names = [...new Set(turns.map((t) => t.speaker))].sort();
        note = turns.length ? ` Speakers found: ${names.length} (${names.join(', ')}).`
          : ' Speaker recognition found no distinct voices in the call audio.';
      } catch (e) {
        note = ` Speaker recognition FAILED: ${e.message || e}. Labels are Me/Them.`;
      }
      log.write(`diarization:${note} turns=${turns.length}`);
    } else if (this.settings.identifySpeakers) {
      note = ' Speaker recognition skipped: no call-audio track was captured.';
    }
    this.set({ checkNote: 'Checking the transcript with the accurate model… (a few minutes for long calls)' });
    try {
      const lines = await this.deps.whisper.transcribeTracks({ system, mic, language: lang, turns });
      if (!lines.length) {
        this.set({ checkNote: 'Transcript check heard no speech; the live transcript was kept.' + note });
        return live;
      }
      fs.writeFileSync(path.join(dir, base + '.live.txt'), live.join('\n'));
      const file = path.join(dir, base + '.txt');
      fs.writeFileSync(file, lines.join('\n'));
      if (!this.s.isRecording) {                 // do not clobber the view of a call that started meanwhile
        this.lastTranscriptFile = file;
        this.set({ finalLines: lines });
        this.refreshSpeakers();
      }
      const wc = (ls) => ls.reduce((n, l) => n + (l.split(']: ').pop() || '').split(/\s+/).filter(Boolean).length, 0);
      this.set({ checkNote: `Checked: ${base}.txt now has the verified transcript (${wc(live)} → ${wc(lines)} words). ` +
        `The live version is saved as ${base}.live.txt.` + note });
      return lines;
    } catch (e) {
      this.set({ checkNote: `Transcript check failed: ${e.message}. The live transcript was kept.` });
      return live;
    }
  }

  async transcribeFile(file, { shots = [] } = {}) {
    if (this.s.busy) return;
    this.set({ busy: true, summaryText: '', summaryNote: '', checkNote: '' });
    let lines = null; const base = path.basename(file, path.extname(file)); const dir = path.dirname(file);
    try {
      if (!this.deps.isReady()) { this.set({ status: this.whisperHint() }); return; }
      const lang = config.languageCode(this.settings.language);
      let turns = [];
      if (this.settings.identifySpeakers) {
        this.set({ status: 'Finding who speaks when… (the first time this downloads small speaker models)' });
        try { turns = await this.deps.diarize(file); }
        catch (e) { this.set({ checkNote: `Speaker recognition failed: ${e.message || e}` }); }
      }
      this.set({ status: `Transcribing ${path.basename(file)}… (several minutes for long calls)` });
      let out;
      if (turns.length) {
        lines = await this.deps.whisper.transcribeFileWithSpeakers(file, lang, turns);
        out = lines.join('\n');
      } else {
        out = await this.deps.whisper.transcribeFile(file, lang);
        lines = out.includes('\n\n') ? out.split('\n\n') : out.split('\n');
      }
      if (!out) { this.set({ status: `No speech recognized in ${path.basename(file)}` }); lines = null; return; }
      const target = path.join(dir, base + '.txt');
      fs.writeFileSync(target, out);
      this.lastTranscriptFile = target;
      this.set({ finalLines: lines, status: `Saved ${path.basename(target)}` });
      this.refreshSpeakers();
    } catch (e) {
      this.set({ status: `Transcription failed: ${e.message}` });
      lines = null;
    } finally {
      this.set({ busy: false });
    }
    if (lines) await this.summarize(lines, base, dir, shots);
  }

  /** Descriptions of the screenshots as transcript lines ("[mm:ss] [Screen] …"), made by a local vision model. */
  async describeShots(shots, topic) {
    if (!shots.length) return { lines: [], note: '' };
    let models = [];
    try { models = await summarizer.installedModels(); } catch (e) { return { lines: [], note: `${shots.length} screenshot(s) saved but not described: ${e.message}` }; }
    const model = summarizer.pickVisionModel(models);
    if (!model) {
      return { lines: [], note: `${shots.length} screenshot(s) saved but not described: no vision model in Ollama (run: ollama pull qwen2.5vl:7b).` };
    }
    const lines = [];
    let failed = 0;
    for (let i = 0; i < shots.length; i++) {
      this.set({ summaryNote: `Describing screenshot ${i + 1} of ${shots.length} with ${model}…` });
      try {
        const d = await this.deps.describeImage(fs.readFileSync(shots[i].file), { model, topic });
        lines.push(`[${fmtTime(shots[i].t)}] [Screen] ${d}`);
      } catch { failed++; }
    }
    return { lines, note: failed ? `${failed} screenshot(s) could not be described.` : '' };
  }

  static mergeByTime(lines, extra) {
    const tOf = (l) => { const m = /^\[(\d+):(\d+)\]/.exec(l); return m ? +m[1] * 60 + +m[2] : Infinity; };
    const all = [...lines.map((l, i) => ({ l, t: tOf(l), i })), ...extra.map((l, i) => ({ l, t: tOf(l), i: 1e9 + i }))];
    const keep = (x) => (x.t === Infinity ? -1 : x.t);           // lines without a time stay where they are
    all.sort((a, b) => (keep(a) - keep(b)) || (a.i - b.i));
    return all.map((x) => x.l);
  }

  async summarize(lines, base, dir, shots = []) {
    if (!this.settings.summarizeCalls) return;
    const topic = this.s.topic;
    let described = { lines: [], note: '' };
    if (shots.length) {
      this.set({ summaryText: '', summaryNote: 'Describing the screenshots with a local vision model…' });
      described = await this.describeShots(shots, topic);
      if (described.lines.length) {
        try { fs.writeFileSync(path.join(dir || this.outDir, base + '.screens.txt'), described.lines.join('\n')); } catch { /* ignore */ }
      }
    }
    const all = described.lines.length ? Session.mergeByTime(lines, described.lines) : lines;
    const transcript = all.join('\n');
    if (transcript.split(/\s+/).filter(Boolean).length < 15) {
      this.set({ summaryText: '', summaryNote: ['Too little speech for a summary.', described.note].filter(Boolean).join(' ') });
      return;
    }
    this.set({ summaryText: '', summaryNote: 'Summarizing the call with a local model…' });
    this.summaryTranscript = transcript;
    this.summaryTopic = topic;
    try {
      const body = await this.deps.summarize(transcript, { topic });
      const md = (topic ? `**Topic:** ${topic.replace(/\s+/g, ' ')}\n\n` : '') + body;
      const file = path.join(dir || this.outDir, base + '.summary.md');
      fs.writeFileSync(file, md);
      this.set({ summaryText: md, summaryNote: [`Summary saved as ${path.basename(file)}.`, described.note].filter(Boolean).join(' ') });
    } catch (e) {
      this.set({ summaryNote: `No summary: ${e.message} You can still use “Copy for Claude”.` });
    }
  }

  copyForClaudeText() { return this.summaryTranscript ? summarizer.pasteText(this.summaryTranscript, this.summaryTopic || '') : ''; }

  // ---- speaker names -----------------------------------------------------------------------------------------------

  refreshSpeakers() {
    const seen = [];
    for (const l of this.s.finalLines) {
      const m = /^\[[^\]]*\]\s*([^:]+):/.exec(l);
      if (m && m[1].startsWith('Speaker') && !seen.includes(m[1])) seen.push(m[1]);
    }
    this.set({ speakerLabels: seen });
  }

  renameSpeaker(oldName, newName) {
    const name = String(newName || '').trim();
    if (!name || name === oldName) return;
    const finalLines = this.s.finalLines.map((l) => l.split(`] ${oldName}: `).join(`] ${name}: `));
    this.set({ finalLines });
    if (this.lastTranscriptFile) { try { fs.writeFileSync(this.lastTranscriptFile, finalLines.join('\n')); } catch { /* ignore */ } }
    this.refreshSpeakers();
    this.set({ status: `Renamed ${oldName} to ${name}` });
  }
}

module.exports = { Session, fmtTime };
