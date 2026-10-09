'use strict';
/**
 * Live translation of the transcript, line by line, with the local Ollama model (127.0.0.1 only).
 * Only runs while the translation pane is open. Results are cached per (language, text), so a line is translated
 * once; a line that grows is translated again after it has been quiet for a moment.
 */
const summarizer = require('./summarizer');

const languages = [
  { code: 'en', name: 'English' }, { code: 'de', name: 'German' }, { code: 'ru', name: 'Russian' },
  { code: 'fr', name: 'French' }, { code: 'es', name: 'Spanish' }, { code: 'it', name: 'Italian' },
  { code: 'pt', name: 'Portuguese' }, { code: 'nl', name: 'Dutch' }, { code: 'pl', name: 'Polish' },
  { code: 'uk', name: 'Ukrainian' }, { code: 'tr', name: 'Turkish' }, { code: 'ar', name: 'Arabic' },
  { code: 'zh', name: 'Chinese' }, { code: 'ja', name: 'Japanese' }, { code: 'ko', name: 'Korean' },
];
const nameOf = (code) => (languages.find((l) => l.code === code) || {}).name;

/** The spoken text of a transcript line "[mm:ss] Label: text" (the whole line if it has no such shape). */
function lineBody(line) {
  const m = /^\[\d+:\d+\]\s+[^:\[\]]{1,40}?:\s+([\s\S]*)$/.exec(line);
  return (m ? m[1] : line.replace(/^\[\d+:\d+\]\s*/, '')).trim();
}

function buildPrompt(text, targetName, context) {
  return `You are a live interpreter. Translate the transcript line below into ${targetName}. ` +
    `Keep names, product names, abbreviations and numbers. Do not explain, do not add anything. ` +
    `Answer with the translation only, written only in ${targetName}.\n` +
    (context ? `\nPrevious line, for context only (do not translate it): ${context}\n` : '') +
    `\nLine to translate:\n${text}`;
}

/** Default translate function: the best installed Ollama text model. */
let modelCache = { at: 0, name: null };
function pickFast(installed) {
  for (const p of ['qwen2.5:7b', 'llama3.1:8b', 'llama3.2:3b', 'gemma2:9b', 'mistral:7b']) {
    const m = installed.find((x) => x === p || x.startsWith(p + '-'));
    if (m) return m;
  }
  return summarizer.pickModel(installed);
}

async function ollamaTranslate(text, { target, context }) {
  if (!modelCache.name || Date.now() - modelCache.at > 60000) {
    modelCache = { at: Date.now(), name: pickFast(await summarizer.installedModels()) };
  }
  if (!modelCache.name) throw new summarizer.SummaryError('No Ollama model installed. Run: ollama pull qwen2.5:7b');
  // Some models slip into Chinese. Unless Chinese/Japanese/Korean was asked for, such an answer is rejected and retried.
  for (let attempt = 0; attempt < 3; attempt++) {
    let p = buildPrompt(text, nameOf(target), context);
    if (attempt) p += `\n\nIMPORTANT: write only in ${nameOf(target)}. No Chinese characters.`;
    const out = await summarizer.generate(summarizer.BASE, modelCache.name, p,
      { num_ctx: 4096, temperature: attempt ? 0.4 : 0.1 }, 60000);
    if (!strayScript(out, target)) return out;
  }
  throw new summarizer.SummaryError('The model answered in the wrong script; line skipped.');
}

/** True if the answer has CJK characters although the target language is not Chinese, Japanese or Korean. */
function strayScript(s, target) {
  if (['zh', 'ja', 'ko'].includes(target)) return false;
  return /[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af\uf900-\ufaff]/.test(s);
}

class Translator {
  constructor({ translate = ollamaTranslate, onChange = () => {}, onError = () => {}, delay = 900 } = {}) {
    this.translate = translate; this.onChange = onChange; this.onError = onError; this.delay = delay;
    this.enabled = false; this.target = 'ru';
    this.cache = new Map();
    this.lines = [];
    this.running = false;
    this.failedAt = new Map();           // key -> time of the last failure (retry after a while)
    this.stale = new Map();              // target+line header ("[01:02] Them:") -> last translation of that growing line
  }

  header(line, body) { const i = line.lastIndexOf(body); return i > 0 ? line.slice(0, i) : line; }
  staleKey(line, body) { return `${this.target}\u0001${this.header(line, body)}`; }

  key(body) { return `${this.target}\u0001${body}`; }

  configure({ enabled, target }) {
    if (target) this.target = target;
    if (enabled !== undefined) this.enabled = !!enabled;
  }

  sync(lines) {
    this.lines = lines;
    this.kick();
  }

  /** {body: translation} for the lines on screen, in the current target language. */
  view(lines = this.lines) {
    const out = {};
    // A line that is still growing has no exact translation yet: show the one for its earlier text meanwhile.
    for (const l of lines) {
      const b = lineBody(l);
      const t = this.cache.get(this.key(b)) || this.stale.get(this.staleKey(l, b));
      if (t) out[b] = t;
    }
    return out;
  }

  pending() {
    const out = [];
    this.lines.forEach((l, i) => {
      const body = lineBody(l);
      if (body.length < 2 || this.cache.has(this.key(body))) return;
      const failed = this.failedAt.get(this.key(body));
      if (failed && Date.now() - failed < 15000) return;
      out.push({ body, header: this.header(l, body), context: i > 0 ? lineBody(this.lines[i - 1]) : '' });
    });
    return out;
  }

  kick() {
    if (!this.enabled || this.running) return;
    if (!this.pending().length) return;
    this.running = true;
    this.loop().finally(() => { this.running = false; });
  }

  async loop() {
    await new Promise((r) => setTimeout(r, this.delay));        // let a growing line settle
    for (;;) {
      if (!this.enabled) return;
      const list = this.pending(); const next = list[list.length - 1];   // newest first: the live end stays current
      if (!next) return;
      const target = this.target;
      const key = this.key(next.body);
      try {
        const out = await this.translate(next.body, { target, context: next.context });
        if (out) {
          this.cache.set(`${target}\u0001${next.body}`, out.trim());
          this.stale.set(`${target}\u0001${next.header}`, out.trim());
        }
        else this.failedAt.set(key, Date.now());
      } catch (e) {
        this.failedAt.set(key, Date.now());
        this.onError(e);
      }
      if (this.cache.size > 5000) this.cache.delete(this.cache.keys().next().value);
      this.onChange(this.view());
    }
  }
}

module.exports = { strayScript, Translator, languages, lineBody, buildPrompt, nameOf };
