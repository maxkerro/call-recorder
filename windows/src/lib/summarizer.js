'use strict';

const BASE = process.env.OLLAMA_HOST ? `http://${process.env.OLLAMA_HOST.replace(/^https?:\/\//, '')}` : 'http://127.0.0.1:11434';
const preferred = ['qwen2.5:14b', 'qwen2.5:7b', 'llama3.1:8b', 'gemma2:9b', 'mistral:7b', 'llama3.2:3b'];

const PROMPT = `You are given the transcript of a work call (lines look like "[mm:ss] Speaker: text"). It may contain recognition errors. Write a concise summary in the language the call was mostly held in, in Markdown, with these sections:
## Summary (3-6 sentences)
## Key points (bullets)
## Decisions (bullets, or "None")
## Action items (bullets: who - what - when if mentioned, or "None")
## Open questions (bullets, or "None")
Use only what is in the transcript; do not invent names, numbers or decisions.`;

class SummaryError extends Error {}

/** Prompt + transcript, for pasting into any chat (e.g. claude.ai). */
const pasteText = (transcript) => `${PROMPT}\n\nTranscript:\n${transcript}`;

async function installedModels(base = BASE) {
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

async function summarize(transcript, { base = BASE, chunkLimit = 20000 } = {}) {
  const installed = await installedModels(base);
  const model = pickModel(installed);
  if (!model) throw new SummaryError('No Ollama model installed. Run: ollama pull qwen2.5:7b');
  const chunks = split(transcript, chunkLimit);      // long calls: summarize chunks first, then the summaries
  if (chunks.length === 1) return generate(base, model, pasteText(chunks[0]));
  const parts = [];
  for (let i = 0; i < chunks.length; i++) {
    parts.push(await generate(base, model,
      `Summarize part ${i + 1} of ${chunks.length} of a call transcript in detail (key points, decisions, action items with owners, open questions). Same language as the transcript.\n\n${chunks[i]}`));
  }
  return generate(base, model,
    `${PROMPT}\n\nInstead of a transcript you get notes on consecutive parts of the call:\n\n${parts.join('\n\n---\n\n')}`);
}

module.exports = { summarize, pasteText, installedModels, pickModel, split, SummaryError, PROMPT };
