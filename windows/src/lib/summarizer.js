'use strict';

const { isLoopbackUrl, assertLoopback } = require('./net');

// Ollama must run on this computer. An OLLAMA_HOST that points elsewhere is ignored: transcripts never leave the PC.
function defaultBase() {
  const h = process.env.OLLAMA_HOST;
  if (h) {
    const url = `http://${h.replace(/^https?:\/\//, '')}`;
    if (isLoopbackUrl(url)) return url;
  }
  return 'http://127.0.0.1:11434';
}
const BASE = defaultBase();
const preferred = ['qwen2.5:14b', 'qwen2.5:7b', 'llama3.1:8b', 'gemma2:9b', 'mistral:7b', 'llama3.2:3b'];

const PROMPT = `You are given the transcript of a work call (lines look like "[mm:ss] Speaker: text"). It may contain recognition errors. Write a concise summary in the language the call was mostly held in, in Markdown, with these sections:
## Summary (3-6 sentences)
## Key points (bullets)
## Decisions (bullets, or "None")
## Action items (bullets: who - what - when if mentioned, or "None")
## Open questions (bullets, or "None")
Lines marked [Screen] describe screenshots of what was shown on screen at that moment (slides, documents, diagrams); use them as context and mention them where relevant.
Use only what is in the transcript; do not invent names, numbers or decisions.`;

/** The topic is typed by the user before the call; it steers the summary. One line, bounded length. */
function topicLine(topic) {
  const t = String(topic || '').replace(/\s+/g, ' ').trim().slice(0, 300);
  if (!t) return '';
  return `Topic of this call, set in advance by the user: "${t}". Organize the summary around this topic: what was said, decided and left open about it; mention anything important but off-topic briefly. If the transcript says nothing about the topic, say so.\n\n`;
}

class SummaryError extends Error {}

/** Prompt + transcript, for pasting into any chat (e.g. claude.ai). */
const pasteText = (transcript, topic = '') => `${PROMPT}\n\n${topicLine(topic)}Transcript:\n${transcript}`;

async function installedModels(base = BASE) {
  assertLoopback(base);
  try {
    const r = await fetch(`${base}/api/tags`, { signal: AbortSignal.timeout(3000) });
    const j = await r.json();
    return (j.models || []).map((m) => m.name).filter(Boolean);
  } catch {
    throw new SummaryError('Ollama isn\'t running. Install it from ollama.com and start it.');
  }
}

function pickModel(installed) {
  for (const p of preferred) {
    const m = installed.find((x) => x === p || x.startsWith(p + '-'));
    if (m) return m;
  }
  return installed.find((x) => !x.includes('embed')) || null;
}

function split(textIn, limit) {
  if (textIn.length <= limit) return [textIn];
  const out = [];
  let cur = '';
  for (const line of textIn.split('\n')) {
    if (cur.length + line.length > limit && cur) { out.push(cur); cur = ''; }
    cur += line + '\n';
  }
  if (cur) out.push(cur);
  return out;
}

async function generate(base, model, prompt) {
  assertLoopback(base);
  const r = await fetch(`${base}/api/generate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, prompt, stream: false, options: { num_ctx: 16384, temperature: 0.2 } }),
    signal: AbortSignal.timeout(600000),
  });
  const j = await r.json().catch(() => ({}));
  if (j.error) throw new SummaryError(`Ollama: ${j.error}`);
  if (r.status !== 200 || typeof j.response !== 'string') throw new SummaryError('Ollama returned an unexpected answer.');
  return j.response.trim();
}

async function summarize(transcript, { base = BASE, chunkLimit = 20000, topic = '' } = {}) {
  const installed = await installedModels(base);
  const model = pickModel(installed);
  if (!model) throw new SummaryError('No Ollama model installed. Run: ollama pull qwen2.5:7b');
  const chunks = split(transcript, chunkLimit);      // long calls: summarize chunks first, then the summaries
  if (chunks.length === 1) return generate(base, model, pasteText(chunks[0], topic));
  const parts = [];
  for (let i = 0; i < chunks.length; i++) {
    parts.push(await generate(base, model,
      `Summarize part ${i + 1} of ${chunks.length} of a call transcript in detail (key points, decisions, action items with owners, open questions). Same language as the transcript.\n\n${chunks[i]}`));
  }
  return generate(base, model,
    `${PROMPT}\n\n${topicLine(topic)}Instead of a transcript you get notes on consecutive parts of the call:\n\n${parts.join('\n\n---\n\n')}`);
}

// ---- screenshots: described by a local vision model ---------------------------------------------------------------------

const visionPreferred = ['qwen2.5vl', 'qwen3-vl', 'llama3.2-vision', 'gemma3', 'minicpm-v', 'llava'];

function pickVisionModel(installed) {
  for (const p of visionPreferred) {
    const m = installed.find((x) => x.toLowerCase().startsWith(p));
    if (m) return m;
  }
  return installed.find((x) => /vision|-vl|llava|moondream/i.test(x)) || null;
}

/** Describes one screenshot (PNG/JPEG bytes). Returns text, or throws SummaryError. */
async function describeImage(bytes, { base = BASE, model, topic = '' } = {}) {
  assertLoopback(base);
  const body = {
    model, stream: false, options: { temperature: 0.1, num_ctx: 8192 },
    images: [Buffer.from(bytes).toString('base64')],
    prompt: 'This is a screenshot from a work call (a shared presentation, document, chart or picture). ' +
      'Transcribe the visible titles and the key text exactly, then describe any diagram, chart or picture in a sentence. ' +
      (topic ? `The call is about: ${String(topic).slice(0, 200)}. ` : '') + 'Answer in at most 120 words, plain text, no preamble.',
  };
  const r = await fetch(`${base}/api/generate`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(300000),
  });
  const j = await r.json().catch(() => ({}));
  if (j.error) throw new SummaryError(`Ollama: ${j.error}`);
  if (r.status !== 200 || typeof j.response !== 'string') throw new SummaryError('Ollama returned an unexpected answer for a screenshot.');
  return j.response.trim().replace(/\s+/g, ' ');
}

module.exports = { generate, BASE, summarize, pasteText, installedModels, pickModel, pickVisionModel, describeImage, topicLine, split, SummaryError, PROMPT };
