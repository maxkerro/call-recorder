'use strict';
/**
 * Glossary correction. The local model only POINTS at mistakes ("safe" should be "SAFe" in this phrase); this code
 * validates every suggestion and applies it. The model never rewrites the transcript, so it cannot paraphrase or
 * invent content. Everything runs against Ollama on 127.0.0.1.
 */
const summarizer = require('./summarizer');
const text = require('./text');

const bodyOf = (line) => (line.includes(']: ') ? line.slice(line.indexOf(']: ') + 3) : line);
const words = (s) => s.split(/\s+/).filter(Boolean);
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const wordRe = (w) => new RegExp(`(?<![\\p{L}\\p{N}])${esc(w)}(?![\\p{L}\\p{N}])`, 'giu');

function buildPrompt(terms, chunk) {
  return `You check a speech-recognition transcript against a glossary of correct spellings.
Glossary (the only allowed corrections): ${terms.join('; ')}

Find places where the transcript contains a misheard or misspelled version of a glossary term (for example "safe" for "SAFe" when scaled agile is meant, "Luxsoft" for "Luxoft"). Do NOT touch anything else, do not fix grammar, do not correct a word that is used correctly in its ordinary meaning.
Answer ONLY with a JSON array. Each item: {"wrong": "<exact wrong word(s)>", "right": "<glossary term>", "context": "<4 to 8 words copied exactly from the transcript that contain the wrong text>"}.
If nothing needs fixing answer [].

Transcript:
${chunk}`;
}

/** Parses the model answer and keeps only suggestions that pass every check. */
function parseFixes(answer, terms, lines) {
  let arr = [];
  const m = /\[[\s\S]*\]/.exec(answer || '');
  if (m) { try { arr = JSON.parse(m[0]); } catch { arr = []; } }
  if (!Array.isArray(arr)) return [];
  const byNorm = new Map(terms.map((t) => [text.norm(t), t]));
  const bodies = lines.filter((l) => !l.includes('] [Screen] ')).map(bodyOf);
  const out = [];
  for (const f of arr) {
    if (!f || typeof f.wrong !== 'string' || typeof f.right !== 'string' || typeof f.context !== 'string') continue;
    const wrong = f.wrong.trim(), context = f.context.trim();
    const right = byNorm.get(text.norm(f.right));
    if (!right || !wrong || wrong === right) continue;
    if (words(wrong).length > 4 || words(context).length > 12) continue;
    if (terms.includes(wrong)) continue;                              // already spelled exactly like a glossary term
    if (!wordRe(wrong).test(context)) continue;                       // the context must contain the wrong text
    if (!bodies.some((b) => b.includes(context))) continue;          // and be a verbatim piece of the transcript
    out.push({ wrong, right, context });
  }
  return out;
}

/** Applies validated fixes inside their context phrase only; returns the new lines and what changed. */
function apply(lines, fixes) {
  const done = [];
  const out = lines.map((line) => {
    if (line.includes('] [Screen] ')) return line;
    let cur = line;
    for (const f of fixes) {
      if (!cur.includes(f.context)) continue;
      const fixed = f.context.replace(wordRe(f.wrong), f.right);
      if (fixed === f.context) continue;
      cur = cur.split(f.context).join(fixed);
      if (!done.some((d) => d.wrong === f.wrong && d.right === f.right)) done.push({ wrong: f.wrong, right: f.right });
    }
    return cur;
  });
  return { lines: out, changes: done };
}

async function correct(lines, { terms = text.vocabularyTerms(), base, chunkLimit = 12000, generate } = {}) {
  if (!terms.length || !lines.length) return { lines, changes: [] };
  const gen = generate || (async (prompt) => {
    const model = summarizer.pickModel(await summarizer.installedModels(base));
    if (!model) throw new summarizer.SummaryError('No Ollama model installed. Run: ollama pull qwen2.5:7b');
    return summarizer.generate(base || summarizer.BASE, model, prompt);
  });
  const fixes = [];
  for (const chunk of summarizer.split(lines.join('\n'), chunkLimit)) {
    fixes.push(...parseFixes(await gen(buildPrompt(terms, chunk)), terms, lines));
  }
  return apply(lines, fixes);
}

module.exports = { correct, parseFixes, apply, buildPrompt };
