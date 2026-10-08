'use strict';
const fs = require('fs');
const path = require('path');
const { supportDir } = require('./config');

// Debug log for live sessions, rewritten at the start of each one: <support folder>\live-debug.log
let file = path.join(process.env.CALLREC_LOG_DIR || supportDir, 'live-debug.log');
let t0 = Date.now();

function setFile(f) { file = f; }
function reset() {
  t0 = Date.now();
  try { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, ''); } catch { /* best effort */ }
}
function write(line) {
  const stamp = ((Date.now() - t0) / 1000).toFixed(1).padStart(7);
  try { fs.appendFileSync(file, `${stamp}s ${line}\n`); } catch { /* best effort */ }
}
module.exports = { reset, write, setFile, get file() { return file; } };
