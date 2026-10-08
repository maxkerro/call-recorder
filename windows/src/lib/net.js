'use strict';
// Network guard. Everything the app does at run time stays on this computer (127.0.0.1). The only exceptions are
// one-time model downloads, which Offline mode forbids.
const config = require('./config');

const LOOPBACK = new Set(['127.0.0.1', 'localhost', '::1', '[::1]']);

function isLoopbackUrl(u) {
  try { return LOOPBACK.has(new URL(u).hostname); } catch { return false; }
}

function assertLoopback(u) {
  if (!isLoopbackUrl(u)) throw new Error(`Blocked: ${u} is not on this computer.`);
}

function isOffline() {
  return process.env.CALLREC_OFFLINE === '1' || !!config.loadSettings().offlineMode;
}

function assertOnline(what) {
  if (isOffline()) {
    throw new Error(`Offline mode is on, so ${what} is not downloaded. Switch Offline mode off for the first run, ` +
      'or copy the files in by hand (see SECURITY.md).');
  }
}

module.exports = { isLoopbackUrl, assertLoopback, isOffline, assertOnline };
