'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');

/** Isolated support/output folders for a test; must be called before the lib modules are first required. */
function sandbox() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'callrec-test-'));
  process.env.CALLREC_SUPPORT = path.join(dir, 'support');
  process.env.CALLREC_DIR = path.join(dir, 'out');
  process.env.CALLREC_LOG_DIR = path.join(dir, 'logs');
  fs.mkdirSync(process.env.CALLREC_SUPPORT, { recursive: true });
  return dir;
}
module.exports = { sandbox };
