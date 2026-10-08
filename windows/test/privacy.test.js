'use strict';
const { sandbox } = require('./helpers');
sandbox();
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const net = require('../src/lib/net');
const config = require('../src/lib/config');
const summarizer = require('../src/lib/summarizer');

test('only loopback addresses count as "this computer"', () => {
  for (const u of ['http://127.0.0.1:11434', 'http://localhost:1', 'http://[::1]:5']) assert.ok(net.isLoopbackUrl(u), u);
  for (const u of ['https://example.com', 'http://192.168.1.5:11434', 'http://127.0.0.1.evil.com', 'not a url']) assert.ok(!net.isLoopbackUrl(u), u);
  assert.throws(() => net.assertLoopback('https://api.example.com/x'), /not on this computer/);
});

test('the summarizer refuses to send a transcript to any non-local server', async () => {
  await assert.rejects(summarizer.summarize('secret words', { base: 'http://10.0.0.7:11434' }), /not on this computer/);
  await assert.rejects(summarizer.summarize('secret words', { base: 'https://api.example.com' }), /not on this computer/);
});

test('an OLLAMA_HOST pointing off this computer is ignored', () => {
  const r = require('child_process').spawnSync(process.execPath, ['-e', "console.log(require('./src/lib/summarizer.js').pickModel.length)"],
    { cwd: path.join(__dirname, '..'), env: { ...process.env, OLLAMA_HOST: 'evil.example.com:11434' } });
  assert.strictEqual(r.status, 0);
  const src = fs.readFileSync(path.join(__dirname, '../src/lib/summarizer.js'), 'utf8');
  assert.match(src, /isLoopbackUrl\(url\)/);
});

test('offline mode forbids downloads, from the setting or the environment', () => {
  config.saveSettings({ ...config.loadSettings(), offlineMode: true });
  assert.throws(() => net.assertOnline('the speaker models'), /Offline mode is on/);
  config.saveSettings({ ...config.loadSettings(), offlineMode: false });
  assert.doesNotThrow(() => net.assertOnline('x'));
  process.env.CALLREC_OFFLINE = '1';
  assert.throws(() => net.assertOnline('x'), /Offline mode is on/);
  delete process.env.CALLREC_OFFLINE;
});

test('a model whose checksum does not match is not accepted', () => {
  const { sha256 } = require('../src/lib/diarize');
  const f = path.join(os.tmpdir(), `hash-${process.pid}.bin`);
  fs.writeFileSync(f, 'tampered');
  assert.notStrictEqual(sha256(f), '5ef208a9da1453335308a6b6f4e6dfbd7e183a38b604de0a57664f45d257fe94');
  fs.rmSync(f);
});

test('the default recordings folder is not under Documents (OneDrive), and cloud-synced folders are flagged', () => {
  delete process.env.CALLREC_DIR;
  assert.ok(!/Documents/.test(config.rootDir()));
  assert.match(config.cloudSyncWarning('C:\\Users\\max\\OneDrive\\Recordings'), /cloud-synced/);
  assert.strictEqual(config.cloudSyncWarning('C:\\Users\\max\\CallRecordings'), null);
});

test('no source file talks to anything but 127.0.0.1 (apart from the checksummed model download)', () => {
  const root = path.join(__dirname, '../src');
  const hits = [];
  const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).forEach((e) => {
    const p = path.join(d, e.name);
    if (e.isDirectory()) return walk(p);
    if (!/\.(js|html)$/.test(p)) return;
    for (const m of fs.readFileSync(p, 'utf8').matchAll(/https?:\/\/[^\s'"`)]+/g)) hits.push([path.relative(root, p), m[0]]);
  });
  walk(root);
  const external = hits.filter(([, u]) => !/^https?:\/\/(127\.0\.0\.1|localhost|\$\{)/.test(u));
  assert.deepStrictEqual([...new Set(external.map(([f]) => f))], ['lib/diarize.js'], JSON.stringify(external));
  assert.ok(external.every(([, u]) => u.startsWith('https://github.com/k2-fsa/')), JSON.stringify(external));
});
