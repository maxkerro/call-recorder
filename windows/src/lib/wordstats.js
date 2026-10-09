'use strict';
// Word statistics of a transcript: the most frequent words and the words the app does not know yet
// (names, abbreviations and terms that are not in the Vocabulary list). Local text processing only.
const { lineBody } = require('./translator');

const STOP = new Set((
  // English
  'the and for are but not you your all any can had her was one our out has have him his how its let may new now old see two way who did get got ' +
  'she him too use that this with from they will would there their what when which about been were then them than these those just like also into over only some such ' +
  'more most much very here where while after before because could should still really going yeah yes okay well know think want need make made said say says ' +
  'dont doesnt didnt isnt wasnt thats its ive weve youre theyre hes shes lets cant wont ' +
  // German
  'der die das den dem des ein eine einen einem einer und oder aber nicht ist sind war waren wird werden wurde bin hat haben hatte auch noch schon nur mit von für auf aus bei nach zum zur über ' +
  'wir ihr sie ich du er es mir mich dir dich uns euch wie was wer wo wann warum dass wenn dann also ja nein ganz mal sehr kann können muss müssen soll gibt ' +
  // Russian
  'это что как так вот или для при его она они мне вас нас уже если есть был была были будет надо тоже ещё еще очень только можно нужно просто да нет ну вот там тут когда потом ' +
  'который которая которые этот эта эти этого себя меня тебя свой своё'
).split(/\s+/).filter(Boolean));

const WORD = /[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu;
const norm = (s) => String(s).toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');

/** Every word of the spoken text, with whether it starts a sentence. */
function tokens(transcript) {
  const out = [];
  for (const line of String(transcript).split(/\r?\n/)) {
    const body = lineBody(line);
    if (!body) continue;
    let prevEnd = true;
    let last = 0;
    for (const m of body.matchAll(WORD)) {
      const between = body.slice(last, m.index);
      if (/[.!?…]\s*$/.test(between) || last === 0 && m.index === 0) prevEnd = true;
      out.push({ word: m[0].replace(/^[-'’]+|[-'’]+$/g, ''), sentenceStart: prevEnd });
      prevEnd = false;
      last = m.index + m[0].length;
    }
  }
  return out.filter((t) => t.word);
}

function tally(list) {
  const counts = new Map();
  for (const w of list) {
    const k = norm(w);
    if (!k) continue;
    const e = counts.get(k) || { count: 0, forms: new Map() };
    e.count++; e.forms.set(w, (e.forms.get(w) || 0) + 1);
    counts.set(k, e);
  }
  return [...counts.entries()].map(([k, e]) => ({
    key: k, count: e.count, word: [...e.forms.entries()].sort((a, b) => b[1] - a[1])[0][0],
  })).sort((a, b) => b.count - a.count || a.word.localeCompare(b.word));
}

/** The n most frequent words (not counting filler words like "the", "und", "это"). */
function topWords(transcript, n = 10) {
  const list = tokens(transcript).map((t) => t.word).filter((w) => norm(w).length >= 3 && !STOP.has(norm(w)) && !/^\d+$/.test(w));
  return tally(list).slice(0, n).map(({ word, count }) => ({ word, count }));
}

/** Looks like a name, abbreviation or technical term (rather than an ordinary word). */
function looksSpecial(t) {
  const w = t.word;
  if (/^\d+$/.test(w) || w.length < 2) return false;
  if (/\p{L}/u.test(w) && /\d/.test(w)) return true;                       // ID3, MB.EA, 5G
  if (w.length >= 2 && w === w.toUpperCase() && w !== w.toLowerCase()) return true;      // HMI, SAFe-like caps
  if (/\p{Ll}\p{Lu}/u.test(w)) return true;                                // camelCase, SAFe
  if (!t.sentenceStart && /^\p{Lu}/u.test(w)) return true;                // Capitalized in mid-sentence: names, products
  return false;
}

/** The n words that are not in the vocabulary and look like names/abbreviations/terms (most frequent first). */
function unknownWords(transcript, vocabulary = [], n = 10) {
  const known = new Set(vocabulary.flatMap((v) => String(v).split(/\s+/)).map(norm).filter(Boolean));
  const all = tokens(transcript);
  // A word counts as special if it looks like a name/abbreviation/term anywhere; then every occurrence is counted
  // (at the start of a sentence a name looks like any other word).
  const special = new Set(all.filter((t) => looksSpecial(t) && !STOP.has(norm(t.word)) && !known.has(norm(t.word))).map((t) => norm(t.word)));
  const list = all.filter((t) => special.has(norm(t.word))).map((t) => t.word);
  return tally(list).slice(0, n).map(({ word, count }) => ({ word, count }));
}

module.exports = { topWords, unknownWords, tokens, STOP };
