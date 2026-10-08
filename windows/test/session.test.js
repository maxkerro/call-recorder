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
  s.settings = { ...s.settings, language: 'en-US', verifyAfterLive: true, identifySpeakers: true, summarizeCalls: true };
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
  const day = config.dayFolder();
  const files = fs.readdirSync(day);
  const mp3 = files.find((f) => f.endsWith('.mp3'));
  assert.ok(mp3, `no mp3 in ${files}`);
  assert.ok(fs.statSync(path.join(day, mp3)).size > 1000);
  const txt = fs.readFileSync(path.join(day, mp3.replace('.mp3', '.txt')), 'utf8');
  assert.match(txt, /Speaker 1: hello from the first voice/);
  assert.match(txt, /Speaker 2: and now the second voice talks/);
  assert.match(fs.readFileSync(path.join(day, mp3.replace('.mp3', '.summary.md')), 'utf8'), /A short call/);
  assert.deepStrictEqual(s.s.speakerLabels, ['Speaker 1', 'Speaker 2']);
  assert.match(s.s.summaryNote, /Summary saved/);
});

test('renaming a speaker updates the shown lines and the saved file', async () => {
  const { s } = makeSession();
  await s.toggle(false); feed(s, 3); await s.toggle(false);
  s.renameSpeaker('Speaker 1', 'Anna');
  assert.ok(s.s.finalLines.some((l) => l.includes('] Anna: hello')));
  assert.ok(fs.readFileSync(s.lastTranscriptFile, 'utf8').includes('Anna: hello'));
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
  const day = config.dayFolder();
  const live = fs.readdirSync(day).find((f) => f.endsWith('.live.txt'));
  assert.ok(live, 'live transcript was not kept');
  const finalTxt = fs.readFileSync(path.join(day, live.replace('.live.txt', '.txt')), 'utf8');
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
  const txt = fs.readFileSync(s.lastTranscriptFile, 'utf8');
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
  await s.summarize(['[00:00] Me: hi'], 'x', config.dayFolder());
  assert.strictEqual(s.s.summaryNote, 'Too little speech for a summary.');
});

test('summary failure keeps the transcript and offers Copy for Claude', async () => {
  const { s } = makeSession({ summarize: async () => { throw new Error('Ollama isn\'t running.'); } });
  const lines = Array.from({ length: 5 }, (_, i) => `[00:0${i}] Me: ${'word '.repeat(6)}`);
  await s.summarize(lines, 'x', config.dayFolder());
  assert.match(s.s.summaryNote, /No summary: Ollama isn't running\./);
  assert.match(s.copyForClaudeText(), /Transcript:\n\[00:00\] Me:/);
});
