'use strict';
const { sandbox } = require('./helpers');
sandbox();
const test = require('node:test');
const assert = require('node:assert');
const text = require('../src/lib/text');

test('scrub removes made-up subtitle credits (the DimaTorzok case)', () => {
  assert.strictEqual(text.scrub('Субтитры создавал DimaTorzok'), '');
  assert.strictEqual(text.scrub('Thanks for watching!'), '');
  assert.strictEqual(text.scrub('Untertitel der Amara.org-Community'), '');
  assert.strictEqual(text.scrub('Hello there, thank you for watching'), 'Hello there');
});

test('scrub leaves normal text alone and honours the ! blocklist', () => {
  assert.strictEqual(text.scrub('We ship on Friday.'), 'We ship on Friday.');
  assert.strictEqual(text.scrub('Please ignore this phrase now', ['this phrase']), 'Please ignore now'.replace('  ', ' '));
});

test('echo filter drops the vocabulary tail after a breath', () => {
  const seq = ['mercedesbenz', 'luxoft', 'infotainment', 'hmi', 'safe', 'scrum', 'telemost'];
  const words = 'We agreed HMI, SAFe, Scrum, Telemost'.split(' ');
  const drop = text.echoIndices(words.map(text.norm), seq);
  assert.deepStrictEqual([...drop], [2, 3, 4, 5]);
  assert.strictEqual(text.stripPromptEcho('We agreed HMI, SAFe, Scrum, Telemost', seq), 'We agreed');
  // a legitimate single use of one term stays
  assert.strictEqual(text.stripPromptEcho('We use Scrum here', seq), 'We use Scrum here');
});

test('noise markers and repetition loops are recognised', () => {
  assert.ok(text.isNoise('[BLANK_AUDIO]'));
  assert.ok(text.isNoise('(music)'));
  assert.ok(!text.isNoise('hello'));
  assert.ok(text.isRepetitive('a little bit of a little bit of a little bit of a little bit of a little bit of'));
  assert.ok(!text.isRepetitive('this is a perfectly normal sentence about the release plan'));
  const w = (s) => s.split(' ').map((t) => ({ text: t, norm: t }));
  assert.deepStrictEqual(text.collapseRepeats(w('so so so so go')).map((x) => x.text), ['so', 'go']);
});
