'use strict';
// Speaker diarization with sherpa-onnx (pyannote segmentation + a speaker-embedding model), fully local.
// Runs in a worker thread so the window stays responsive. Models are downloaded once on first use.
const fs = require('fs');
const path = require('path');
const https = require('https');
const crypto = require('crypto');
const net = require('./net');
const { Worker } = require('worker_threads');
const { speakerDir } = require('./config');
const tools = require('./tools');
const voiceBook = require('./voices');

const SEG_URL = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2';
const EMB_URL = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx';
// SHA-256 of the files as published; a download that does not match is deleted and never used or unpacked.
const SEG_SHA256 = '24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488';
const EMB_SHA256 = '5ef208a9da1453335308a6b6f4e6dfbd7e183a38b604de0a57664f45d257fe94';
const SEG_MODEL = path.join(speakerDir, 'sherpa-onnx-pyannote-segmentation-3-0', 'model.onnx');
const EMB_MODEL = path.join(speakerDir, 'wespeaker_en_voxceleb_resnet34.onnx');

function download(url, dest, redirects = 6) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': 'CallRecorder' } }, (res) => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location && redirects > 0) {
        res.resume();
        resolve(download(new URL(res.headers.location, url).toString(), dest, redirects - 1));
        return;
      }
      if (res.statusCode !== 200) { res.resume(); reject(new Error(`download failed (${res.statusCode}): ${url}`)); return; }
      const tmp = dest + '.part';
      const out = fs.createWriteStream(tmp);
      res.pipe(out);
      out.on('finish', () => out.close(() => { fs.renameSync(tmp, dest); resolve(); }));
      out.on('error', reject);
    }).on('error', reject);
  });
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

async function downloadVerified(url, dest, expected) {
  net.assertOnline('the speaker models');
  await download(url, dest);
  if (sha256(dest) !== expected) {
    fs.rmSync(dest, { force: true });
    throw new Error(`The speaker model downloaded from ${new URL(url).hostname} does not match its known checksum; it was deleted.`);
  }
}

async function ensureModels() {
  fs.mkdirSync(speakerDir, { recursive: true });
  if (!fs.existsSync(EMB_MODEL)) await downloadVerified(EMB_URL, EMB_MODEL, EMB_SHA256);
  if (!fs.existsSync(SEG_MODEL)) {
    const archive = path.join(speakerDir, 'segmentation.tar.bz2');
    await downloadVerified(SEG_URL, archive, SEG_SHA256);
    // Windows 10+ ships bsdtar as "tar"; it reads .tar.bz2.
    const r = await tools.run('tar', ['-xf', archive, '-C', speakerDir]);
    fs.rmSync(archive, { force: true });
    if (r.code !== 0 || !fs.existsSync(SEG_MODEL)) throw new Error(`could not unpack the speaker model: ${r.stderr.slice(-200)}`);
  }
}

/** 16 kHz mono Float32 samples of any audio file, decoded by ffmpeg. */
async function decode(file) {
  const ffmpeg = tools.ffmpegPath();
  if (!ffmpeg) throw new Error('ffmpeg not found');
  const r = await tools.run(ffmpeg, ['-loglevel', 'error', '-i', file, '-f', 'f32le', '-ar', '16000', '-ac', '1', '-']);
  if (r.code !== 0) throw new Error(`ffmpeg could not read ${path.basename(file)}`);
  const b = r.stdout;
  return new Float32Array(b.buffer.slice(b.byteOffset, b.byteOffset + b.length - (b.length % 4)));
}

/** Names speakers "Speaker 1", "Speaker 2"… in order of first appearance; drops "speakers" under 3 s in total. */
function nameSpeakers(raw, voices = {}, profiles = []) {
  const total = new Map();
  for (const r of raw) total.set(r.speaker, (total.get(r.speaker) || 0) + (r.end - r.start));
  const kept = raw.filter((r) => (total.get(r.speaker) || 0) >= 3).sort((a, b) => a.start - b.start);
  // Known people (named earlier by the user) are recognised by their voice; the rest become "Speaker N".
  const clusters = {};
  for (const [id, emb] of Object.entries(voices)) if ((total.get(id) || 0) >= 3) clusters[id] = emb;
  const known = profiles.length ? voiceBook.match(clusters, profiles) : {};
  const names = new Map(); let unknown = 0;
  const found = {};
  const turns = kept.map((r) => {
    if (!names.has(r.speaker)) {
      names.set(r.speaker, known[r.speaker] || `Speaker ${++unknown}`);
      if (clusters[r.speaker]) found[names.get(r.speaker)] = voiceBook.normalize(Array.from(clusters[r.speaker]));
    }
    return { speaker: names.get(r.speaker), start: r.start, end: r.end };
  });
  turns.voices = found;                       // voice fingerprints by label, for "rename = remember this voice"
  return turns;
}

/** Resolves [{speaker, start, end}]. */
async function diarize(file) {
  await ensureModels();
  const samples = await decode(file);
  const result = await new Promise((resolve, reject) => {
    const w = new Worker(path.join(__dirname, 'diarize-worker.js'), {
      workerData: { seg: SEG_MODEL, emb: EMB_MODEL, samples },
    });
    w.once('message', (m) => (m.error ? reject(new Error(m.error)) : resolve(m)));
    w.once('error', reject);
    w.once('exit', (c) => { if (c !== 0) reject(new Error(`speaker worker exited with code ${c}`)); });
  });
  return nameSpeakers(result.segments, result.voices || {}, voiceBook.load());
}

module.exports = { diarize, nameSpeakers, ensureModels, decode, sha256 };
