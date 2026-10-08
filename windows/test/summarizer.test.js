'use strict';
const { sandbox } = require('./helpers');
sandbox();
const test = require('node:test');
const assert = require('node:assert');
const http = require('http');
const summarizer = require('../src/lib/summarizer');
const { nameSpeakers } = require('../src/lib/diarize');

function fakeOllama(models, handler) {
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => { body += d; });
    req.on('end', () => {
      res.setHeader('Content-Type', 'application/json');
      if (req.url === '/api/tags') res.end(JSON.stringify({ models: models.map((name) => ({ name })) }));
      else res.end(JSON.stringify(handler(JSON.parse(body))));
    });
  });
  return new Promise((r) => server.listen(0, '127.0.0.1', () => r({ server, base: `http://127.0.0.1:${server.address().port}` })));
}

test('summary uses the best installed model and the transcript', async () => {
  const seen = [];
  const { server, base } = await fakeOllama(['nomic-embed-text:latest', 'llama3.1:8b', 'qwen2.5:7b'], (b) => { seen.push(b); return { response: ' ## Summary\nok ' }; });
  try {
    const out = await summarizer.summarize('[00:00] Me: hello', { base });
    assert.strictEqual(out, '## Summary\nok');
    assert.strictEqual(seen[0].model, 'qwen2.5:7b');
    assert.match(seen[0].prompt, /\[00:00\] Me: hello/);
    assert.strictEqual(seen[0].stream, false);
  } finally { server.close(); }
});

test('a long transcript is summarized in parts, then combined', async () => {
  let calls = 0;
  const { server, base } = await fakeOllama(['qwen2.5:7b'], () => { calls++; return { response: 'part ' + calls }; });
  try {
    const long = Array.from({ length: 50 }, (_, i) => `[00:${i}] Me: ${'word '.repeat(20)}`).join('\n');
    const out = await summarizer.summarize(long, { base, chunkLimit: 1000 });
    assert.ok(calls > 2);
    assert.strictEqual(out, 'part ' + calls);
  } finally { server.close(); }
});

test('no Ollama or no model gives an actionable message', async () => {
  await assert.rejects(summarizer.summarize('x', { base: 'http://127.0.0.1:9' }), /Ollama isn't running/);
  const { server, base } = await fakeOllama([], () => ({}));
  try { await assert.rejects(summarizer.summarize('x', { base }), /ollama pull/); } finally { server.close(); }
});

test('nameSpeakers numbers speakers by first appearance and drops tiny ones', () => {
  const out = nameSpeakers([
    { speaker: '7', start: 10, end: 20 }, { speaker: '3', start: 0, end: 5 },
    { speaker: '9', start: 6, end: 7 },                     // 1 s in total: noise, not a person
    { speaker: '3', start: 21, end: 25 },
  ]);
  assert.deepStrictEqual(out.map((t) => t.speaker), ['Speaker 1', 'Speaker 2', 'Speaker 1']);
  assert.deepStrictEqual(out.map((t) => t.start), [0, 10, 21]);
});

test('the topic set in advance is part of the prompt', async () => {
  const seen = [];
  const { server, base } = await fakeOllama(['qwen2.5:7b'], (b) => { seen.push(b); return { response: 'ok' }; });
  try {
    await summarizer.summarize('[00:00] Me: hello', { base, topic: 'Release 4.2 go/no-go' });
    assert.match(seen[0].prompt, /Release 4\.2 go\/no-go/);
    assert.match(summarizer.pasteText('x', 'Budget'), /Budget/);
    assert.ok(!/set in advance/.test(summarizer.pasteText('x')));
  } finally { server.close(); }
});

test('vision model choice and image description go to the local server as base64', async () => {
  assert.strictEqual(summarizer.pickVisionModel(['qwen2.5:7b', 'llava:7b', 'qwen2.5vl:7b']), 'qwen2.5vl:7b');
  assert.strictEqual(summarizer.pickVisionModel(['qwen2.5:7b']), null);
  const seen = [];
  const { server, base } = await fakeOllama(['qwen2.5vl:7b'], (b) => { seen.push(b); return { response: ' A slide titled Roadmap ' }; });
  try {
    const d = await summarizer.describeImage(Buffer.from('png'), { base, model: 'qwen2.5vl:7b', topic: 'Roadmap' });
    assert.strictEqual(d, 'A slide titled Roadmap');
    assert.deepStrictEqual(seen[0].images, [Buffer.from('png').toString('base64')]);
  } finally { server.close(); }
});
