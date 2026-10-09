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
    `Answer with the translation only.\n` +
    (context ? `\nPrevious line, for context only (do not translate it): ${context}\n` : '') +
    `\nLine to translate:\n${text}`;
}

/** Default translate function: the best installed Ollama text model. */
let modelCache = { at: 0, name: null };
async function ollamaTranslate(text, { target, context }) {
  if (!modelCache.name || Date.now() - modelCache.at > 60000) {
    modelCache = { at: Date.now(), name: summarizer.pickModel(await summarizer.installedModels()) };
  }
  if (!modelCache.name) throw new summarizer.SummaryError('No Ollama model installed. Run: ollama pull qwen2.5:7b');
  return summarizer.generate(summarizer.BASE, modelCache.name, buildPrompt(text, nameOf(target), context),
    { num_ctx: 4096, temperature: 0.1 });
}

class Translator {
  constructor({ translate = ollamaTranslate, onChange = () => {}, onError = () => {}, delay = 900 } = {}) {
    this.translate = translate; this.onChange = onChange; this.onError = onError; this.delay = delay;
    this.enabled = false; this.target = 'ru';
    this.cache = new Map();
    this.lines = [];
    this.running = false;
    this.failedAt = new Map();           // key -> time of the last failure (retry after a while)
  }

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
    for (const l of lines) { const b = lineBody(l); const t = this.cache.get(this.key(b)); if (t) out[b] = t; }
    return out;
  }

  pending() {
    const out = [];
    this.lines.forEach((l, i) => {
      const body = lineBody(l);
      if (body.length < 2 || this.cache.has(this.key(body))) return;
      const failed = this.failedAt.get(this.key(body));
      if (failed && Date.now() - failed < 15000) return;
      out.push({ body, context: i > 0 ? lineBody(this.lines[i - 1]) : '' });
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
      const next = this.pending()[0];
      if (!next) return;
      const target = this.target;
      const key = this.key(next.body);
      try {
        const out = await this.translate(next.body, { target, context: next.context });
        if (out) this.cache.set(`${target}\u0001${next.body}`, out.trim());
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

module.exports = { Translator, languages, lineBody, buildPrompt, nameOf };
