'use strict';
const { sandbox } = require('./helpers');
const dir = sandbox();
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

// ---- fake whisper tools (Node scripts standing in for whisper-cli / whisper-server) and empty model files -----------
const support = process.env.CALLREC_SUPPORT;
fs.mkdirSync(path.join(support, 'bin'), { recursive: true });
fs.mkdirSync(path.join(support, 'models'), { recursive: true });
for (const m of ['ggml-base.bin', 'ggml-large-v3-turbo-q5_0.bin']) fs.writeFileSync(path.join(support, 'models', m), '');
const node = process.execPath;
fs.writeFileSync(path.join(support, 'bin', 'whisper-cli'), `#!${node}
console.log('[00:00:00.000 --> 00:00:02.000]   hello from the first voice');
console.log('[00:00:02.000 --> 00:00:04.000]   and now the second voice talks');
`, { mode: 0o755 });
fs.writeFileSync(path.join(support, 'bin', 'whisper-server'), `#!${node}
const http = require('http');
const port = Number(process.argv[process.argv.indexOf('--port') + 1]);
http.createServer((req, res) => {
  if (req.url === '/health') { res.end('ok'); return; }
  req.resume();
  req.on('end', () => {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ language: 'english', segments: [{ start: 0, end: 1.2, text: ' live words here', no_speech_prob: 0, avg_logprob: -0.1,
      words: [{ word: ' live', start: 0, end: 0.4 }, { word: ' words', start: 0.4, end: 0.8 }, { word: ' here', start: 0.8, end: 1.2 }] }] }));
  });
}).listen(port, '127.0.0.1');
`, { mode: 0o755 });

const { Session } = require('../src/session');
const config = require('../src/lib/config');
const layout = require('../src/lib/layout');
// the one call folder created under <root>/<date>/
const lastCall = (root) => { const day = config.dayFolder(root); const ds = fs.readdirSync(day).sort(); return path.join(day, ds[ds.length - 1]); };

const tone = (sec, rate = 48000) => Float32Array.from({ length: Math.round(sec * rate) }, (_, i) => 0.2 * Math.sin(i / 9));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function makeSession(over = {}) {
  const states = [];
  const hooks = {
    changed: (s) => states.push(s),
    startCapture: async () => ({ sampleRate: 48000 }),
    stopCapture: async () => {},
  };
  const deps = {
    diarize: async () => [{ speaker: 'Speaker 1', start: 0, end: 2 }, { speaker: 'Speaker 2', start: 2, end: 4 }],
    summarize: async (t) => '## Summary\nA short call.',
    ...over,
  };
  const s = new Session(hooks, deps);
  s.settings = { ...s.settings, language: 'en-US', verifyAfterLive: true, identifySpeakers: true, summarizeCalls: true, glossaryCorrect: false };
  return { s, states };
}

function feed(s, seconds) {
  for (let i = 0; i < seconds * 10; i++) { s.addAudio('system', tone(0.1)); s.addAudio('mic', tone(0.1)); }
}

test('plain recording: MP3 is made, then transcribed with speaker labels and summarized', async () => {
  const { s } = makeSession();
  await s.toggle(false);
  assert.ok(s.s.isRecording);
  feed(s, 4);
  await s.toggle(false);
  const call = lastCall();
  assert.match(path.basename(call), /^\d\d-\d\d-\d\d(-\d+)?$/);
  assert.ok(fs.statSync(path.join(call, 'audio.mp3')).size > 1000);
  const raw = fs.readFileSync(path.join(call, 'raw_transcript.txt'), 'utf8');
  assert.match(raw, /Speaker 1: hello from the first voice/);
  assert.match(raw, /Speaker 2: and now the second voice talks/);
  assert.strictEqual(fs.readFileSync(path.join(call, 'fixed_transcript.txt'), 'utf8'), raw);   // glossary off: identical
  assert.match(fs.readFileSync(path.join(call, 'summary.md'), 'utf8'), /A short call/);
  assert.deepStrictEqual(s.s.speakerLabels, ['Speaker 1', 'Speaker 2']);
  assert.match(s.s.summaryNote, /Summary saved/);
});

test('renaming a speaker updates the shown lines and the saved file', async () => {
  const { s } = makeSession();
  await s.toggle(false); feed(s, 3); await s.toggle(false);
  s.renameSpeaker('Speaker 1', 'Anna');
  assert.ok(s.s.finalLines.some((l) => l.includes('] Anna: hello')));
  assert.ok(fs.readFileSync(path.join(lastCall(), 'fixed_transcript.txt'), 'utf8').includes('Anna: hello'));
  assert.deepStrictEqual(s.s.speakerLabels, ['Speaker 2']);
});

test('live recording: live lines, then the verified transcript replaces them and the live one is kept', async () => {
  const { s, states } = makeSession();
  await s.toggle(true);
  assert.ok(s.s.isRecording && s.s.liveMode);
  for (let i = 0; i < 40; i++) { feed(s, 0.1); await sleep(100); }       // ~4 s of audio in real time
  assert.ok(states.some((x) => x.finalLines.some((l) => l.includes('Them: live words'))) ||
            states.some((x) => Object.keys(x.partials).length), 'no live text was produced');
  await s.toggle(true);
  const call = lastCall();
  assert.ok(fs.existsSync(path.join(call, 'live_transcript.txt')), 'live transcript was not kept');
  const finalTxt = fs.readFileSync(path.join(call, 'raw_transcript.txt'), 'utf8');
  assert.match(finalTxt, /Speaker 1: hello from the first voice/);
  assert.match(finalTxt, /Me: /);                                          // the mic track keeps its own label
  assert.match(s.s.checkNote, /Speakers found: 2/);
});

test('speaker recognition failing is reported, labels fall back to Them/Me', async () => {
  const { s } = makeSession({ diarize: async () => { throw new Error('model download blocked'); } });
  await s.toggle(true);
  for (let i = 0; i < 20; i++) { feed(s, 0.1); await sleep(100); }
  await s.toggle(true);
  assert.match(s.s.checkNote, /Speaker recognition FAILED: model download blocked/);
  const txt = fs.readFileSync(path.join(lastCall(), 'fixed_transcript.txt'), 'utf8');
  assert.match(txt, /Them: /);
});

test('starting a new recording clears the previous summary and notes', async () => {
  const { s } = makeSession();
  await s.toggle(false); feed(s, 3); await s.toggle(false);
  assert.ok(s.s.summaryText);
  await s.toggle(false);
  assert.strictEqual(s.s.summaryText, '');
  assert.strictEqual(s.s.summaryNote, '');
  assert.deepStrictEqual(s.s.speakerLabels, []);
  feed(s, 1); await s.toggle(false);
});

test('a capture failure is shown and nothing is left recording', async () => {
  const states = [];
  const s = new Session({ changed: (x) => states.push(x), startCapture: async () => { throw new Error('no loopback'); }, stopCapture: async () => {} },
    { summarize: async () => '' });
  await s.toggle(false);
  assert.strictEqual(s.s.isRecording, false);
  assert.match(s.s.status, /Could not start: no loopback/);
});

test('too little speech gives a clear note instead of a summary', async () => {
  const { s } = makeSession();
  await s.summarize(['[00:00] Me: hi'], layout.names(config.dayFolder(), 'x.'));
  assert.strictEqual(s.s.summaryNote, 'Too little speech for a summary.');
});

test('summary failure keeps the transcript and offers Copy for Claude', async () => {
  const { s } = makeSession({ summarize: async () => { throw new Error('Ollama isn\'t running.'); } });
  const lines = Array.from({ length: 5 }, (_, i) => `[00:0${i}] Me: ${'word '.repeat(6)}`);
  await s.summarize(lines, layout.names(config.dayFolder(), 'x.'));
  assert.match(s.s.summaryNote, /No summary: Ollama isn't running\./);
  assert.match(s.copyForClaudeText(), /Transcript:\n\[00:00\] Me:/);
});

test('topic reaches the summary and is shown at its top', async () => {
  const seen = [];
  const { s } = makeSession({ summarize: async (t, o) => { seen.push(o.topic); return '## Summary\nx '.repeat(2); } });
  s.setTopic('Sprint planning');
  await s.toggle(false); feed(s, 4); await s.toggle(false);
  assert.strictEqual(seen[0], 'Sprint planning');
  assert.match(s.s.summaryText, /^\*\*Topic:\*\* Sprint planning/);
});

test('screenshots: saved while recording, described, merged into the summary by time', async () => {
  const png = Buffer.from('89504e470d0a1a0a', 'hex');
  let sent = '';
  const { s } = makeSession({
    describeImage: async () => 'Slide: Q3 roadmap',
    summarize: async (t) => { sent = t; return '## Summary\nok'; },
  });
  s.hooks.captureScreen = async () => png;
  assert.strictEqual(await s.takeScreenshot(), null);            // not recording yet
  await s.toggle(false); feed(s, 4);
  const file = await s.takeScreenshot();
  assert.ok(file && fs.existsSync(file));
  assert.strictEqual(s.s.shotCount, 1);
  const models = require('../src/lib/summarizer');
  const orig = models.installedModels; models.installedModels = async () => ['qwen2.5:7b', 'qwen2.5vl:7b'];
  try { await s.toggle(false); } finally { models.installedModels = orig; }
  assert.match(sent, /\[\d\d:\d\d\] \[Screen\] Slide: Q3 roadmap/);
});

test('merge by time keeps order and puts screen lines in place', () => {
  const m = Session.mergeByTime(['[00:00] Me: a', '[00:30] Me: b'], ['[00:10] [Screen] s']);
  assert.deepStrictEqual(m, ['[00:00] Me: a', '[00:10] [Screen] s', '[00:30] Me: b']);
});

test('recordings folder can be chosen, validated and reset', async () => {
  const target = path.join(dir, 'custom-root');
  const envDir = process.env.CALLREC_DIR; delete process.env.CALLREC_DIR;    // the test sandbox pins it
  const { s } = makeSession();
  s.setSetting('outputRoot', 'relative/path');
  assert.match(s.s.status, /Cannot use that folder/);
  s.setSetting('outputRoot', target);
  assert.strictEqual(config.rootDir(), target);
  await s.toggle(false); feed(s, 4); await s.toggle(false);
  assert.ok(fs.existsSync(path.join(lastCall(target), 'audio.mp3')));
  s.setSetting('outputRoot', '');
  assert.notStrictEqual(config.rootDir(), target);
  process.env.CALLREC_DIR = envDir;
});

test('glossary correction fixes only validated terms, keeps the original, and shows what changed', async () => {
  const glossary = require('../src/lib/glossary');
  const lines = ['[00:00] Me: we plan with safe and the safe deployment is fine', '[00:05] Them: Luxsoft agrees'];
  const answers = JSON.stringify([
    { wrong: 'safe', right: 'SAFe', context: 'we plan with safe and' },
    { wrong: 'Luxsoft', right: 'Luxoft', context: 'Luxsoft agrees' },
    { wrong: 'deployment', right: 'Kubernetes', context: 'safe deployment is' },        // not a glossary term: rejected
    { wrong: 'fine', right: 'SAFe', context: 'made up phrase not in text' },             // context not verbatim: rejected
  ]);
  const r = await glossary.correct(lines, { terms: ['SAFe', 'Luxoft', 'HMI'], generate: async () => '```json\n' + answers + '\n```' });
  assert.deepStrictEqual(r.lines, ['[00:00] Me: we plan with SAFe and the safe deployment is fine', '[00:05] Them: Luxoft agrees']);
  assert.strictEqual(r.changes.length, 2);

  const { s } = makeSession({ glossary: async (l) => glossary.correct(l, { terms: ['SAFe', 'Luxoft'], generate: async () => answers }) });
  s.settings.glossaryCorrect = true;
  const d = path.join(dir, 'gl'); fs.mkdirSync(d, { recursive: true });
  const P = layout.names(d);
  const out = await s.glossaryFix(lines, P);
  assert.match(out[0], /with SAFe and/);
  assert.match(s.s.checkNote, /2 correction\(s\): safe → SAFe, Luxsoft → Luxoft/);
  const off = makeSession({ glossary: async () => { throw new Error('should not run'); } });
  assert.deepStrictEqual(await off.s.glossaryFix(lines, P), lines);   // setting is off
});

test('glossary: a term already spelled correctly is never changed and no fixes means no change', () => {
  const glossary = require('../src/lib/glossary');
  const lines = ['[00:00] Me: it is safe to go'];
  const fixes = glossary.parseFixes(JSON.stringify([{ wrong: 'safe', right: 'SAFe', context: 'it is safe to go' }, { wrong: 'SAFe', right: 'SAFe', context: 'x' }, { wrong: 'Scrum', right: 'SAFe', context: 'x' }]), ['SAFe', 'Scrum'], lines);
  assert.strictEqual(fixes.length, 1);
  assert.deepStrictEqual(glossary.apply(lines, []).lines, lines);
});

test('cancelling the area selection saves nothing', async () => {
  const { s } = makeSession();
  s.hooks.captureScreen = async () => null;
  await s.toggle(false); feed(s, 2);
  assert.strictEqual(await s.takeScreenshot(), null);
  assert.strictEqual(s.s.shotCount, 0);
  assert.match(s.s.status, /cancelled/);
  await s.toggle(false);
});

test('fixed_transcript.txt holds the glossary-corrected text, raw_transcript.txt the original; rename updates both', async () => {
  const glossary = require('../src/lib/glossary');
  const answers = JSON.stringify([{ wrong: 'Luxsoft', right: 'Luxoft', context: 'and Luxsoft agrees' }]);
  const { s } = makeSession({
    whisper: { transcribeFileWithSpeakers: async () => ['[00:00] Speaker 1: we met and Luxsoft agrees with the plan we made today', '[00:09] Speaker 2: fine by me'] },
    glossary: async (l) => glossary.correct(l, { terms: ['Luxoft'], generate: async () => answers }),
  });
  s.settings.glossaryCorrect = true;
  const d = path.join(dir, 'files'); fs.mkdirSync(d, { recursive: true });
  const audio = path.join(d, 'audio.mp3'); fs.writeFileSync(audio, 'x');
  await s.transcribeFile(audio);
  assert.match(fs.readFileSync(path.join(d, 'raw_transcript.txt'), 'utf8'), /Luxsoft/);
  assert.match(fs.readFileSync(path.join(d, 'fixed_transcript.txt'), 'utf8'), /Luxoft agrees/);
  s.renameSpeaker('Speaker 2', 'Anna');
  for (const f of ['raw_transcript.txt', 'fixed_transcript.txt']) assert.match(fs.readFileSync(path.join(d, f), 'utf8'), /\] Anna: fine by me/);
});

test('an audio file from elsewhere gets prefixed names next to it', () => {
  const P = layout.namesForAudio(path.join('x', 'meeting.mp3'));
  assert.strictEqual(path.basename(P.raw), 'meeting.raw_transcript.txt');
  assert.strictEqual(path.basename(P.summary), 'meeting.summary.md');
  assert.strictEqual(path.basename(layout.namesForAudio(path.join('x', 'audio.mp3')).fixed), 'fixed_transcript.txt');
});
