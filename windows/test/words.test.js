'use strict';
require('./helpers').sandbox();
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const wordstats = require('../src/lib/wordstats');
const summarizer = require('../src/lib/summarizer');

const T = [
  '[00:01] Me: We talked to Anna about the HMI release and the SAFe board.',
  '[00:05] Them: Yes the release of ID3 and Luxoft stuff. The release is late, release again.',
  '[01:00] Me: Our release planning with Boris.',
].join('\n');

test('topWords ignores filler words and counts case-insensitively', () => {
  const top = wordstats.topWords(T, 3);
  assert.deepStrictEqual(top[0], { word: 'release', count: 5 });
  assert.ok(!top.some((t) => t.word.toLowerCase() === 'the'));
});

test('unknownWords: names, abbreviations and terms that are not in the vocabulary', () => {
  const u = wordstats.unknownWords(T, ['SAFe', 'Luxoft']).map((x) => x.word);
  assert.deepStrictEqual(u.sort(), ['Anna', 'Boris', 'HMI', 'ID3']);
  assert.strictEqual(wordstats.unknownWords(T, [], 2).length, 2);
});

test('the summary prompt names the participants, but not Me / Them / Speaker N', () => {
  assert.deepStrictEqual(summarizer.participants('[00:01] Anna: hi\n[00:02] Me: x\n[00:03] Speaker 1: y\n[00:04] Them: z\n[00:05] Boris: ok'), ['Anna', 'Boris']);
  assert.match(summarizer.pasteText('[00:01] Anna: hi'), /Named participants.*Anna/);
  assert.doesNotMatch(summarizer.pasteText('[00:01] Them: hi'), /Named participants/);
});
