'use strict';
const { sandbox } = require('./helpers');
sandbox();
const test = require('node:test');
const assert = require('node:assert');
const { StreamingTranscriber, Downsampler } = require('../src/lib/live');

const tone = (sec, amp = 0.2) => Float32Array.from({ length: Math.round(sec * 16000) }, (_, i) => amp * Math.sin(i / 7));
const quiet = (sec) => new Float32Array(Math.round(sec * 16000));
const word = (text, start, end) => ({ text, start, end });
const seg = (words, extra = {}) => ({
  start: words[0].start, end: words[words.length - 1].end, text: words.map((w) => w.text).join(' '),
  noSpeech: 0, avgLogprob: -0.2, words, ...extra,
});

function make(passes) {
  const calls = [];
  const events = [];
  const t = new StreamingTranscriber({
    label: 'Them', language: 'en', vocabSeq: [],
    transcribe: async (samples, lang) => { calls.push(lang); const p = passes.shift(); return { segs: p ? [seg(p)] : [], probs: {}, language: 'en' }; },
  });
  t.onEvent = (e) => events.push(e);
  return { t, events, calls };
}

test('a word is confirmed only when two passes agree, and the last word is never confirmed early', async () => {
  const { t, events } = make([
    [word('Hello', 0, 0.4), word('wor', 0.5, 0.9)],                    // pass 1: second word cut in half
    [word('Hello', 0, 0.4), word('world', 0.5, 1.1), word('again', 1.2, 1.6)],
  ]);
  t.append(tone(1.5));
  await t.tick(false);
  assert.strictEqual(events.at(-1).commit, '');
  assert.strictEqual(events.at(-1).tail, 'Hello wor');
  t.append(tone(0.5));
  await t.tick(false);
  assert.strictEqual(events.at(-1).commit, 'Hello');                    // agreed on in both passes
  assert.strictEqual(events.at(-1).tail, 'world again');                // the corrected word is not stuck as "wor"
});

test('silence at the end flushes everything, including the last word', async () => {
  const { t, events } = make([
    [word('see', 0, 0.3), word('you', 0.4, 0.7), word('tomorrow', 0.8, 1.4)],
  ]);
  t.append(tone(1.5));
  t.append(quiet(1.5));                                                 // > 1.2 s trailing silence
  await t.tick(false);
  const e = events.at(-1);
  assert.strictEqual(e.commit, 'see you tomorrow');
  assert.strictEqual(e.tail, '');
  assert.strictEqual(e.newLine, true);
});

test('hallucinated or looping segments are ignored', async () => {
  const loop = Array.from({ length: 12 }, (_, i) => word('bit', i * 0.1, i * 0.1 + 0.08));
  const { t, events } = make([loop]);
  t.append(tone(1.5)); t.append(quiet(1.5));
  await t.tick(false);
  assert.strictEqual(events.at(-1).commit, '');
});

test('the vocabulary hint read back after a breath is dropped', async () => {
  const t = new StreamingTranscriber({
    label: 'Me', language: 'en', vocabSeq: ['hmi', 'safe', 'scrum', 'jira'],
    transcribe: async () => ({ segs: [seg([word('ok', 0, 0.3), word('HMI', 0.4, 0.6), word('SAFe', 0.6, 0.8),
      word('Scrum', 0.8, 1.0), word('Jira', 1.0, 1.3)])], probs: {}, language: 'en' }),
  });
  const events = []; t.onEvent = (e) => events.push(e);
  t.append(tone(1.5)); t.append(quiet(1.5));
  await t.tick(false);
  assert.strictEqual(events.at(-1).commit, 'ok');
});

test('auto language is chosen once per utterance among en/de/ru', async () => {
  const calls = [];
  const t = new StreamingTranscriber({
    label: 'Them', language: 'auto', vocabSeq: [],
    transcribe: async (s, lang) => {
      calls.push(lang);
      return { segs: [seg([word('hallo', 0, 0.4), word('welt', 0.5, 0.9)])], probs: { is: 0.5, de: 0.4, en: 0.05, ru: 0.05 }, language: 'is' };
    },
  });
  t.onEvent = () => {};
  t.append(tone(1.5)); t.append(quiet(1.5));
  await t.tick(false);
  assert.deepStrictEqual(calls, ['auto', 'de']);                         // Icelandic is never an option
});

test('silent audio never reaches Whisper', async () => {
  const { t, calls } = make([]);
  t.append(quiet(3));
  await t.tick(false);
  assert.strictEqual(calls.length, 0);
});

test('a transcription error is reported once', async () => {
  const t = new StreamingTranscriber({ label: 'Them', language: 'en', vocabSeq: [], transcribe: async () => { throw new Error('boom'); } });
  const events = []; t.onEvent = (e) => events.push(e);
  t.append(tone(1.5));
  await t.tick(false); t.append(tone(0.5)); await t.tick(false);
  assert.strictEqual(events.filter((e) => e.error).length, 1);
});

test('Downsampler turns 48 kHz into 16 kHz', () => {
  const d = new Downsampler(48000);
  const out = d.process(new Float32Array(4800).fill(0.5));
  assert.strictEqual(out.length, 1600);
  assert.ok(Math.abs(out[10] - 0.5) < 1e-6);
});
