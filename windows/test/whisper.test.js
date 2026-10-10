'use strict';
const { sandbox } = require('./helpers');
sandbox();
const test = require('node:test');
const assert = require('node:assert');
const whisper = require('../src/lib/whisper');
const server = require('../src/lib/server');

test('parse reads start, end and text of whisper-cli lines and drops noise', () => {
  const out = [
    '[00:00:00.000 --> 00:00:03.500]   Hello there',
    '[00:00:03.500 --> 00:00:04.000]   [BLANK_AUDIO]',
    '[00:01:05.250 --> 00:01:09.000]   Wie geht es dir?',
    '[00:01:10.000 --> 00:01:12.000]   Субтитры создавал DimaTorzok',
  ].join('\n');
  const segs = whisper.parse(out);
  assert.deepStrictEqual(segs, [
    { start: 0, end: 3.5, text: 'Hello there' },
    { start: 65.25, end: 69, text: 'Wie geht es dir?' },
  ]);
});

const turns = [
  { speaker: 'Speaker 1', start: 0, end: 5 },
  { speaker: 'Speaker 2', start: 5, end: 10 },
];

test('speakerFor picks the speaker with the most overlap', () => {
  assert.strictEqual(whisper.speakerFor({ start: 0, end: 4 }, turns), 'Speaker 1');
  assert.strictEqual(whisper.speakerFor({ start: 3, end: 9 }, turns), 'Speaker 2');
  assert.strictEqual(whisper.speakerFor({ start: 20, end: 22 }, turns), null);
});

test('a segment holding two voices is split word by word', () => {
  const seg = { start: 0, end: 10, text: 'aaaa aaaa aaaa aaaa aaaa bbbb bbbb bbbb bbbb bbbb' };
  const parts = whisper.splitBySpeaker(seg, turns, 'Them');
  assert.strictEqual(parts.length, 2);
  assert.strictEqual(parts[0].label, 'Speaker 1');
  assert.strictEqual(parts[1].label, 'Speaker 2');
  assert.strictEqual(parts[0].text, 'aaaa aaaa aaaa aaaa aaaa');
  assert.strictEqual(parts[1].text, 'bbbb bbbb bbbb bbbb bbbb');
});

test('words in a gap take the nearest speaker within 1.5 s, else the previous one', () => {
  const gapTurns = [{ speaker: 'Speaker 1', start: 0, end: 2 }, { speaker: 'Speaker 2', start: 8, end: 10 }];
  assert.strictEqual(whisper.speakerAt(2.9, gapTurns), 'Speaker 1');
  assert.strictEqual(whisper.speakerAt(5, gapTurns), null);
  const parts = whisper.splitBySpeaker({ start: 4, end: 6, text: 'one two' }, gapTurns, 'Them');
  assert.deepStrictEqual(parts.map((p) => p.label), ['Them']);
});

test('toLines merges same-speaker neighbours and orders by time', () => {
  const lines = whisper.toLines([
    { t: 70, label: 'Me', text: 'later' },
    { t: 0, label: 'Speaker 1', text: 'hello' },
    { t: 2, label: 'Speaker 1', text: 'again' },
    { t: 5, label: 'Me', text: 'hi' },
  ]);
  assert.deepStrictEqual(lines, [
    '[00:00] Speaker 1: hello again', '[00:05] Me: hi', '[01:10] Me: later',
  ]);
});

test('format puts a time marker about every 30 seconds', () => {
  const s = whisper.format([{ start: 0, text: 'a' }, { start: 10, text: 'b' }, { start: 35, text: 'c' }]);
  assert.strictEqual(s, '[00:00] a b\n\n[00:35] c');
});

test('whisper-server JSON: tokens are merged into words, language probabilities are read', () => {
  const root = {
    language: 'english',
    language_probabilities: { english: 0.9, german: 0.07, russian: 0.03 },
    segments: [{
      start: 0, end: 2, text: ' Hello world', no_speech_prob: 0.01, avg_logprob: -0.2,
      words: [
        { word: '[_BEG_]', start: 0, end: 0 },
        { word: ' Hel', start: 0.1, end: 0.4 }, { word: 'lo', start: 0.4, end: 0.8 },
        { word: ' world', start: 0.9, end: 1.5 },
      ],
    }],
  };
  const r = server.parseResult(root);
  assert.strictEqual(r.language, 'en');
  assert.ok(Math.abs(r.probs.en - 0.9) < 1e-9);
  assert.deepStrictEqual(r.segs[0].words.map((w) => w.text), ['Hello', 'world']);
  assert.strictEqual(r.segs[0].words[0].end, 0.8);
});

test('whisper-server JSON: hallucinated segments vanish; unusable word timing falls back to even spacing', () => {
  const r = server.parseResult({ segments: [
    { start: 0, end: 2, text: 'Субтитры создавал DimaTorzok', words: [] },
    { start: 2, end: 4, text: 'two words', words: [{ word: ' two', start: -1, end: -1 }] },
  ] });
  assert.strictEqual(r.segs.length, 1);
  assert.deepStrictEqual(r.segs[0].words.map((w) => [w.text, w.start]), [['two', 2], ['words', 2 + 2 * 3 / 8]]);
});

test('wavFrom writes a valid 16 kHz mono header', () => {
  const b = server.wavFrom(new Float32Array([0, 1, -1]));
  assert.strictEqual(b.toString('ascii', 0, 4), 'RIFF');
  assert.strictEqual(b.readUInt32LE(24), 16000);
  assert.strictEqual(b.readUInt32LE(40), 6);
  assert.strictEqual(b.readInt16LE(46), 32767);
  assert.strictEqual(b.readInt16LE(48), -32767);
});

test('parseProgress reads whisper-cli progress lines from stderr', () => {
  const { parseProgress } = require('../src/lib/whisper');
  assert.strictEqual(parseProgress('whisper_print_progress_callback: progress =  10%\nwhisper_print_progress_callback: progress =  35%'), 35);
  assert.strictEqual(parseProgress('something else'), null);
  assert.strictEqual(parseProgress('progress = 100%'), 100);
});
