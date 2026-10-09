'use strict';
// Voice profiles: a name and a voice "fingerprint" (speaker embedding) for people the user has named.
// Stored only on this PC (voices.json in the support folder, owner-only). Never sent anywhere.
const fs = require('fs');
const path = require('path');
const { supportDir } = require('./config');

const THRESHOLD = 0.55;     // minimum cosine similarity to call a voice "the same person"
const MARGIN = 0.04;        // and the lead it needs over the next-best person

const file = () => path.join(supportDir, 'voices.json');

function normalize(v) {
  const n = Math.sqrt(v.reduce((a, x) => a + x * x, 0));
  return n > 0 ? v.map((x) => x / n) : v.slice();
}

function cosine(a, b) {
  if (!a || !b || a.length !== b.length || !a.length) return -1;
  let d = 0;
  for (let i = 0; i < a.length; i++) d += a[i] * b[i];
  return d;                 // both are unit length
}

function load() {
  try { const j = JSON.parse(fs.readFileSync(file(), 'utf8')); return Array.isArray(j) ? j : []; } catch { return []; }
}

function save(profiles) {
  fs.mkdirSync(path.dirname(file()), { recursive: true });
  fs.writeFileSync(file(), JSON.stringify(profiles), { mode: 0o600 });
}

const names = () => load().map((p) => p.name).sort();

/**
 * Which cluster is which known person. Each person goes to at most one cluster (the best match first), and only when
 * the match is clear: above the threshold and ahead of the next-best person by the margin.
 * clusters: {id: embedding}; returns {id: name}.
 */
function match(clusters, profiles = load()) {
  const scored = [];
  for (const [id, emb] of Object.entries(clusters)) {
    const s = profiles.map((p) => ({ name: p.name, score: cosine(normalize(emb), p.embedding) })).sort((a, b) => b.score - a.score);
    if (s.length) scored.push({ id, name: s[0].name, score: s[0].score, runnerUp: s.length > 1 ? s[1].score : -1 });
  }
  const out = {}; const used = new Set();
  for (const c of scored.sort((a, b) => b.score - a.score)) {
    if (c.score < THRESHOLD || c.score - c.runnerUp < MARGIN || used.has(c.name)) continue;
    out[c.id] = c.name; used.add(c.name);
  }
  return out;
}

/** Remembers (or refines) a person's voice. */
function learn(name, embedding) {
  const e = normalize(Array.from(embedding));
  if (!e.length || e.some((x) => !Number.isFinite(x))) return;
  const profiles = load();
  const p = profiles.find((x) => x.name === name);
  if (p && p.embedding.length === e.length) {
    p.embedding = normalize(p.embedding.map((x, i) => x * p.count + e[i]));
    p.count = Math.min(p.count + 1, 20);
  } else {
    const rest = profiles.filter((x) => x.name !== name);
    rest.push({ name, embedding: e, count: 1 });
    return save(rest);
  }
  save(profiles);
}

function forget(name) { save(load().filter((p) => p.name !== name)); }
function forgetAll() { try { fs.rmSync(file(), { force: true }); } catch { /* ignore */ } }

module.exports = { THRESHOLD, MARGIN, normalize, cosine, load, save, names, match, learn, forget, forgetAll };
