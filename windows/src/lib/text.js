'use strict';
const fs = require('fs');
const { vocabularyFile, supportDir } = require('./config');

/** Lower-case letters and digits only ("SAFe," -> "safe"). */
function norm(s) {
  return String(s).toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');
}

// ---- vocabulary file ------------------------------------------------------------------------------------------------

function vocabularyLines() {
  let raw = '';
  try { raw = fs.readFileSync(vocabularyFile, 'utf8'); } catch { return []; }
  return raw.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));
}
const vocabularyTerms = () => vocabularyLines().filter((l) => !l.startsWith('!'));
const vocabularyPrompt = () => vocabularyTerms().join(', ').slice(0, 600);
const userBlocklist = () => vocabularyLines().filter((l) => l.startsWith('!')).map((l) => l.slice(1).trim()).filter(Boolean);
const vocabularySequence = () =>
  vocabularyTerms().flatMap((t) => t.split(/\s+/)).map(norm).filter(Boolean);

function ensureVocabularyFile() {
  if (!fs.existsSync(vocabularyFile)) {
    fs.mkdirSync(supportDir, { recursive: true });
    fs.writeFileSync(vocabularyFile, [
      '# Words Whisper should spell correctly: names, products, jargon, abbreviations. One per line.',
      '# Lines starting with # are ignored. Keep it short (a few dozen terms) for best results.',
      '# A line starting with ! is a phrase that must never appear in a transcript, for example:',
      '# ! Subtitles by the Amara.org community',
      'Mercedes-Benz', 'Luxoft', 'infotainment', 'HMI', 'SAFe', 'Scrum', '',
    ].join('\r\n'));
  }
  return vocabularyFile;
}

// ---- hallucination filters ------------------------------------------------------------------------------------------

/** Phrases Whisper makes up on silence, breath or noise: subtitle credits and sign-offs from its training data. */
const hallucinationPatterns = [
  String.raw`субтитры\s+(?:создавал|создал|сделал|делал|подогнал|предоставил)\p{L}*(?:\s+[\p{L}\d._\-]+)?`,
  String.raw`редактор\s+субтитров(?:\s+\p{L}\.[\p{L}\-]+)?`,
  String.raw`корректор\s+\p{L}\.[\p{L}\-]+`,
  String.raw`dimatorzok`,
  String.raw`untertitel\w*\s+(?:der|des|von|im\s+auftrag)\s+[\w.\-]+(?:\s+[\w.\-]+){0,2}`,
  String.raw`amara\.org\S*`,
  String.raw`(?:thanks?|thank\s+you)\s+for\s+watching\W*`,
  String.raw`subtitles?\s+(?:by|made\s+by|created\s+by)\s+[\w.\-]+(?:\s+[\w.\-]+)?`,
  String.raw`продолжение\s+следует\W*`,
  String.raw`vielen\s+dank\s+f(?:ü|u)rs\s+zuschauen\W*`,
  String.raw`подписывайтесь\s+на\s+(?:наш\s+)?канал\W*`,
  String.raw`спасибо\s+за\s+просмотр\W*`,
].map((p) => new RegExp(p, 'giu'));

const escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** Removes made-up phrases (built-in list plus the user's "!" lines). Returns the text unchanged if nothing matched. */
function scrub(text, blocklist = []) {
  const extra = blocklist.map((b) => new RegExp(escapeRegExp(b), 'giu'));
  let t = text;
  for (const re of [...hallucinationPatterns, ...extra]) {
    re.lastIndex = 0;
    t = t.replace(re, '');
  }
  if (t === text) return text;
  return t.replace(/\s{2,}/g, ' ').replace(/^[\s,;:\-–—]+|[\s,;:\-–—]+$/g, '');
}

/** Indices of words that merely echo the vocabulary hint: a run of 3+ words that follows the vocabulary order,
 *  or a run of 2+ at the very end of the text (the typical "…, HMI, SAFe, Scrum" tail after a breath). */
function echoIndices(norms, seq) {
  const drop = new Set();
  if (seq.length < 2 || norms.length < 2) return drop;
  let i = 0;
  while (i < norms.length) {
    let best = 0;
    if (norms[i]) {
      for (let start = 0; start < seq.length; start++) {
        if (seq[start] !== norms[i]) continue;
        let k = 0;
        while (i + k < norms.length && start + k < seq.length && norms[i + k] === seq[start + k]) k++;
        best = Math.max(best, k);
      }
    }
    if (best >= 3 || (best >= 2 && i + best === norms.length)) {
      for (let j = i; j < i + best; j++) drop.add(j);
    }
    i += Math.max(best, 1);
  }
  return drop;
}

function stripPromptEcho(text, seq) {
  const words = text.split(/\s+/).filter(Boolean);
  const drop = echoIndices(words.map(norm), seq);
  if (!drop.size) return text;
  return words.filter((_, i) => !drop.has(i)).join(' ');
}

/** Drops markers such as [BLANK_AUDIO], (music), [Music] that Whisper emits for non-speech. */
function isNoise(t) {
  if (!t) return true;
  const s = t.replace(/^[ .]+|[ .]+$/g, '');
  return (s.startsWith('[') && s.endsWith(']')) || (s.startsWith('(') && s.endsWith(')')) ||
         (s.startsWith('♪') && s.endsWith('♪'));
}

/** Whisper sometimes loops ("a little bit of a little bit of …"). Such text is never real speech. */
function isRepetitive(text) {
  const w = text.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  if (w.length < 8) return false;
  return new Set(w).size / w.length < 0.35;
}

/** Keeps one copy of any 1–4 word phrase that repeats three or more times in a row (words have .norm). */
function collapseRepeats(words) {
  const out = words.slice();
  for (let n = 1; n <= 4; n++) {
    let i = 0;
    while (i + 3 * n <= out.length) {
      const group = out.slice(i, i + n).map((w) => w.norm).join('\u0001');
      let reps = 1;
      while (i + (reps + 1) * n <= out.length &&
             out.slice(i + reps * n, i + (reps + 1) * n).map((w) => w.norm).join('\u0001') === group) reps++;
      if (reps >= 3) out.splice(i + n, (reps - 1) * n);
      i++;
    }
  }
  return out;
}

/** Short sign-offs Whisper invents on faint noise such as typing ("Thank you"). Only dropped when the audio is quiet. */
const FILLERS = new Set(['thankyou', 'thanks', 'thankyouverymuch', 'thankyousomuch', 'thankyouforwatching', 'bye', 'byebye',
  'goodbye', 'you', 'danke', 'dankeschön', 'dankeschoen', 'vielendank', 'спасибо', 'пока', 'благодарюзавнимание']);
const isGenericFiller = (t) => FILLERS.has(norm(t));

module.exports = {
  isGenericFiller,
  norm, vocabularyLines, vocabularyTerms, vocabularyPrompt, userBlocklist, vocabularySequence, ensureVocabularyFile,
  scrub, echoIndices, stripPromptEcho, isNoise, isRepetitive, collapseRepeats,
};
