'use strict';
/**
 * Where the files of one call live:
 *   <root>/<yyyy-MM-dd>/<HH-mm-ss>/audio.mp3, raw_transcript.txt, fixed_transcript.txt, summary.md, screenshots/
 * (plus live_transcript.txt: the live version, kept when the accurate check pass replaced it).
 * A file transcribed from elsewhere (not named audio.*) gets the same names next to it, prefixed with its own name.
 */
const fs = require('fs');
const path = require('path');
const config = require('./config');

const pad = (n) => String(n).padStart(2, '0');

/** Creates <root>/<date>/<time>/ (adds -2, -3… if that second is taken). */
function newCallFolder(root = config.rootDir(), d = new Date()) {
  const day = config.dayFolder(root, d);
  const stamp = `${pad(d.getHours())}-${pad(d.getMinutes())}-${pad(d.getSeconds())}`;
  for (let i = 1; ; i++) {
    const dir = path.join(day, i === 1 ? stamp : `${stamp}-${i}`);
    try { fs.mkdirSync(dir); return dir; } catch (e) { if (e.code !== 'EEXIST') throw e; }
  }
}

/** Names of all files of a call. `prefix` is '' inside a call folder. */
function names(dir, prefix = '') {
  const f = (n) => path.join(dir, prefix + n);
  return {
    dir,
    audio: (ext = 'mp3') => path.join(dir, `audio.${ext}`),
    raw: f('raw_transcript.txt'),
    fixed: f('fixed_transcript.txt'),
    live: f('live_transcript.txt'),
    summary: f('summary.md'),
    shotsDir: prefix ? path.join(dir, `${prefix}screenshots`) : path.join(dir, 'screenshots'),
    shotsText: prefix ? path.join(dir, `${prefix}screenshots.txt`) : path.join(dir, 'screenshots', 'descriptions.txt'),
  };
}

/** Names for an existing audio file: its own folder when it is a call's audio.*, else prefixed next to it. */
function namesForAudio(file) {
  const dir = path.dirname(file);
  const base = path.basename(file);
  if (/^audio\.[a-z0-9]+$/i.test(base)) return names(dir);
  return names(dir, path.basename(file, path.extname(file)) + '.');
}

module.exports = { newCallFolder, names, namesForAudio };
