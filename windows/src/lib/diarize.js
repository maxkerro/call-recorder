'use strict';
// Speaker diarization with sherpa-onnx (pyannote segmentation + a speaker-embedding model), fully local.
// Runs in a worker thread so the window stays responsive. Models are downloaded once on first use.
const fs = require('fs');
const path = require('path');
const https = require('https');
const { Worker } = require('worker_threads');
const { speakerDir } = require('./config');
const tools = require('./tools');

const SEG_URL = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2';
const EMB_URL = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx';
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

async function ensureModels() {
  fs.mkdirSync(speakerDir, { recursive: true });
  if (!fs.existsSync(EMB_MODEL)) await download(EMB_URL, EMB_MODEL);
  if (!fs.existsSync(SEG_MODEL)) {
    const archive = path.join(speakerDir, 'segmentation.tar.bz2');
    await download(SEG_URL, archive);
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
function nameSpeakers(raw) {
  const total = new Map();
  for (const r of raw) total.set(r.speaker, (total.get(r.speaker) || 0) + (r.end - r.start));
  const kept = raw.filter((r) => (total.get(r.speaker) || 0) >= 3).sort((a, b) => a.start - b.start);
  const names = new Map();
  return kept.map((r) => {
    if (!names.has(r.speaker)) names.set(r.speaker, `Speaker ${names.size + 1}`);
    return { speaker: names.get(r.speaker), start: r.start, end: r.end };
  });
}

/** Resolves [{speaker, start, end}]. */
async function diarize(file) {
  await ensureModels();
  const samples = await decode(file);
  const raw = await new Promise((resolve, reject) => {
    const w = new Worker(path.join(__dirname, 'diarize-worker.js'), {
      workerData: { seg: SEG_MODEL, emb: EMB_MODEL, samples },
    });
    w.once('message', (m) => (m.error ? reject(new Error(m.error)) : resolve(m.segments)));
    w.once('error', reject);
    w.once('exit', (c) => { if (c !== 0) reject(new Error(`speaker worker exited with code ${c}`)); });
  });
  return nameSpeakers(raw);
}

module.exports = { diarize, nameSpeakers, ensureModels, decode };
