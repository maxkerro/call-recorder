'use strict';
const { sandbox } = require('./helpers');
sandbox();
const test = require('node:test');
const assert = require('node:assert');
const { Translator, lineBody, buildPrompt } = require('../src/lib/translator');

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (fn, ms = 2000) => { const t = Date.now(); while (!fn()) { if (Date.now() - t > ms) throw new Error('timeout'); await wait(10); } };

test('lineBody takes the spoken text out of "[mm:ss] Label: text"', () => {
  assert.strictEqual(lineBody('[00:12] Speaker 2: hello: world'), 'hello: world');
  assert.strictEqual(lineBody('[01:05] Me: ok'), 'ok');
  assert.strictEqual(lineBody('[00:30] [Screen] A slide: Roadmap'), '[Screen] A slide: Roadmap');
  assert.strictEqual(lineBody('plain'), 'plain');
});

test('nothing is translated while disabled; once enabled each line is translated once, in order, with context', async () => {
  const calls = [];
  const changes = [];
  const t = new Translator({ delay: 5, translate: async (text, o) => { calls.push([text, o.target, o.context]); return `<${text}>`; }, onChange: (v) => changes.push(v) });
  const lines = ['[00:01] Me: hello there', '[00:04] Them: how are you'];
  t.sync(lines);
  await wait(60);
  assert.strictEqual(calls.length, 0);
  t.configure({ enabled: true, target: 'de' });
  t.sync(lines);
  await until(() => calls.length === 2 && changes.length >= 2);
  assert.deepStrictEqual(calls, [['hello there', 'de', ''], ['how are you', 'de', 'hello there']]);
  assert.deepStrictEqual(t.view(), { 'hello there': '<hello there>', 'how are you': '<how are you>' });
  t.sync(lines.slice());                                   // same text again: cached, no new calls
  await wait(60);
  assert.strictEqual(calls.length, 2);
});

test('a grown line is translated again; a new language translates everything again', async () => {
  const calls = [];
  const t = new Translator({ delay: 5, translate: async (text, o) => { calls.push(`${o.target}:${text}`); return `${o.target}|${text}`; } });
  t.configure({ enabled: true, target: 'ru' });
  t.sync(['[00:01] Me: good morning']);
  await until(() => calls.length === 1);
  await wait(20);
  t.sync(['[00:01] Me: good morning everyone']);
  await until(() => calls.length === 2);
  await wait(20);
  t.configure({ target: 'fr' });
  t.sync(['[00:01] Me: good morning everyone']);
  await until(() => calls.length === 3);
  assert.deepStrictEqual(calls, ['ru:good morning', 'ru:good morning everyone', 'fr:good morning everyone']);
});

test('a failing translation is reported, not retried in a tight loop, and does not stop later lines', async () => {
  let n = 0; const errors = [];
  const t = new Translator({ delay: 5, onError: (e) => errors.push(e.message),
    translate: async (text) => { n++; if (text === 'bad line') throw new Error('Ollama isn\'t running.'); return `ok ${text}`; } });
  t.configure({ enabled: true, target: 'de' });
  t.sync(['[00:01] Me: bad line', '[00:03] Me: good line']);
  await until(() => Object.keys(t.view()).length === 1);
  await wait(100);
  assert.strictEqual(n, 2);
  assert.deepStrictEqual(errors, ['Ollama isn\'t running.']);
  assert.deepStrictEqual(t.view(), { 'good line': 'ok good line' });
});

test('the prompt names the language, forbids commentary and shows context separately', () => {
  const p = buildPrompt('Wir liefern am Freitag.', 'English', 'Das Release ist fertig.');
  assert.match(p, /into English/); assert.match(p, /translation only/); assert.match(p, /Previous line, for context only[^\n]*Das Release/);
  assert.ok(p.endsWith('Wir liefern am Freitag.'));
});
