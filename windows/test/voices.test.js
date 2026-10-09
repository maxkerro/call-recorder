'use strict';
require('./helpers').sandbox();
const test = require('node:test');
const assert = require('node:assert');
const voices = require('../src/lib/voices');
const { nameSpeakers } = require('../src/lib/diarize');

const v = (...a) => a;

test('learn stores a unit-length voice; learning again refines it; forget removes it', () => {
  voices.forgetAll();
  voices.learn('Anna', v(3, 4, 0));
  assert.deepStrictEqual(voices.names(), ['Anna']);
  assert.ok(Math.abs(voices.cosine(voices.load()[0].embedding, v(0.6, 0.8, 0)) - 1) < 1e-9);
  voices.learn('Anna', v(0, 1, 0));
  assert.strictEqual(voices.load()[0].count, 2);
  voices.forget('Anna');
  assert.deepStrictEqual(voices.names(), []);
});

test('match: clear matches get the name, each person only once, unclear ones stay unknown', () => {
  const profiles = [{ name: 'Anna', embedding: voices.normalize(v(1, 0, 0)), count: 1 }, { name: 'Boris', embedding: voices.normalize(v(0, 1, 0)), count: 1 }];
  const m = voices.match({ a: v(0.9, 0.1, 0), b: v(0.1, 0.95, 0), c: v(0, 0, 1), d: v(0.8, 0.2, 0) }, profiles);
  assert.strictEqual(m.a, 'Anna');
  assert.strictEqual(m.b, 'Boris');
  assert.strictEqual(m.c, undefined);
  assert.strictEqual(m.d, undefined);             // Anna is already taken by a better match
});

test('nameSpeakers: a known voice gets its name, others are numbered among the unknown', () => {
  const profiles = [{ name: 'Anna', embedding: voices.normalize(v(1, 0, 0)), count: 1 }];
  const raw = [
    { speaker: '0', start: 0, end: 5 }, { speaker: '1', start: 5, end: 10 }, { speaker: '2', start: 10, end: 15 },
  ];
  const turns = nameSpeakers(raw, { 0: v(0, 0, 1), 1: v(1, 0.05, 0), 2: v(0, 1, 0) }, profiles);
  assert.deepStrictEqual(turns.map((t) => t.speaker), ['Speaker 1', 'Anna', 'Speaker 2']);
  assert.deepStrictEqual(Object.keys(turns.voices).sort(), ['Anna', 'Speaker 1', 'Speaker 2']);
});

test('nameSpeakers without voices behaves as before', () => {
  const turns = nameSpeakers([{ speaker: 'x', start: 0, end: 4 }, { speaker: 'y', start: 4, end: 8 }]);
  assert.deepStrictEqual(turns.map((t) => t.speaker), ['Speaker 1', 'Speaker 2']);
});
