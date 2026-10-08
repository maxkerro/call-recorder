'use strict';
const text = require('./text');
const log = require('./livelog');

const SR = 16000;
const SILENCE_RMS = 0.003;
const ALLOWED = ['en', 'de', 'ru'];       // what "Auto-detect" chooses between

function rms(x) {
  if (!x.length) return 0;
  let s = 0;
  for (let i = 0; i < x.length; i++) s += x[i] * x[i];
  return Math.sqrt(s / x.length);
}

function hasSpeech(x, win, thr) {
  for (let i = 0; i < x.length; i += win) if (rms(x.subarray(i, Math.min(i + win, x.length))) >= thr) return true;
  return false;
}

/** Low average confidence marks garbage in longer segments; one- or two-word segments are exempt, otherwise the
 *  end of a phrase gets dropped. */
const plausible = (s) => s.text.split(/\s+/).filter(Boolean).length < 3 || s.avgLogprob > -1.3;

/**
 * Every second the not-yet-confirmed audio is transcribed again. A word is only confirmed once two consecutive passes
 * agree on it, and the last word of a pass is never confirmed early. A word that is cut in half by the end of the
 * audio is therefore re-read with its second half. A pause (1.2 s of silence) ends an utterance.
 *
 * `transcribe(samples, language)` -> {segs, probs, language} (the whisper-server client, or a fake in tests).
 * Events: {label, commit, tail, time, newLine, error}.
 */
class StreamingTranscriber {
  constructor({ label, language, transcribe, vocabSeq, tickMs = 1000 }) {
    this.label = label;
    this.language = language;
    this.transcribe = transcribe;
    this.vocabSeq = vocabSeq || text.vocabularySequence();
    this.tickMs = tickMs;
    this.onEvent = null;

    this.samples = new Float32Array(0);
    this.bufferStart = 0;                  // absolute index (16 kHz) of samples[0]
    this.stopped = false;
    this.running = false;

    this.committedEnd = 0;
    this.committedMid = 0;
    this.lastCommitEnd = -100;
    this.recentNorms = [];
    this.prevTail = [];
    this.lastSentCount = -1;
    this.reportedError = false;
    this.lockedLanguage = null;
    this.lastLanguage = null;
  }

  start() {
    this.running = true;
    this.loop = (async () => {
      while (this.running) {
        await new Promise((r) => { this.wake = r; this.timer = setTimeout(r, this.tickMs); });
        if (!this.running) break;
        await this.tick(false);
      }
    })();
  }

  /** samples: Float32Array of 16 kHz mono audio */
  append(chunk) {
    if (this.stopped || !chunk || !chunk.length) return;
    const merged = new Float32Array(this.samples.length + chunk.length);
    merged.set(this.samples, 0);
    merged.set(chunk, this.samples.length);
    this.samples = merged;
  }

  async finish() {
    this.halt();
    if (this.loop) await this.loop;
    await this.tick(true);
    this.stopped = true;
  }

  /** Stops the tick loop immediately (also wakes it if it is waiting for the next tick). */
  halt() {
    this.running = false;
    clearTimeout(this.timer);
    if (this.wake) this.wake();
  }

  trimTo(abs) {
    const drop = Math.min(Math.max(abs - this.bufferStart, 0), this.samples.length);
    this.samples = this.samples.slice(drop);
    this.bufferStart += drop;
  }

  async tick(final) {
    const buf = this.samples;
    const start = this.bufferStart;
    if (buf.length < (final ? 4000 : Math.floor(0.8 * SR))) return;
    const startSec = start / SR;
    const endAbs = start + buf.length;
    const endSec = endAbs / SR;

    // Nothing but silence: drop it (keep half a second so the next word's onset isn't clipped).
    if (!hasSpeech(buf, Math.floor(0.25 * SR), SILENCE_RMS)) {
      const hadTail = this.prevTail.length > 0;
      log.write(`${this.label} no speech in buffer (${Math.floor(buf.length / SR)} s), tail=${this.prevTail.length}`);
      if (final && hadTail) this.emit(this.prevTail, []);
      else if (hadTail) this.fire({ label: this.label, commit: '', tail: '' });
      this.prevTail = [];
      this.lockedLanguage = null;
      this.trimTo(Math.max(start, endAbs - Math.floor(0.5 * SR)));
      return;
    }

    const trailingSilent = rms(buf.subarray(Math.max(0, buf.length - Math.floor(1.2 * SR)))) < SILENCE_RMS;
    const forceFlush = !final && !trailingSilent && buf.length / SR > 20;
    const flush = final || trailingSilent || forceFlush;
    if (!flush && buf.length === this.lastSentCount) return;       // no new audio since the last pass
    this.lastSentCount = buf.length;

    let r;
    const t0 = Date.now();
    try {
      // "Auto": decide the language once per utterance among English/German/Russian instead of letting Whisper
      // re-guess every second (that is how a short phrase turned into Icelandic).
      r = await this.transcribe(buf, this.language === 'auto' ? (this.lockedLanguage || 'auto') : this.language);
      if (this.language === 'auto' && !this.lockedLanguage) {
        const chosen = this.pickLanguage(r);
        this.lockedLanguage = chosen;
        if (chosen !== r.language) r = await this.transcribe(buf, chosen);
      }
      log.write(`${this.label} pass buf=${(buf.length / SR).toFixed(1)}s start=${startSec.toFixed(1)} lang=${this.lockedLanguage || this.language} req=${Date.now() - t0}ms segs=${r.segs.length} flush=${flush} trailSilent=${trailingSilent} committedMid=${this.committedMid.toFixed(1)}`);
    } catch (e) {
      log.write(`${this.label} ERROR ${e && e.message}`);
      if (!this.reportedError) {
        this.reportedError = true;
        this.fire({ label: this.label, commit: '', tail: '', error: String((e && e.message) || e) });
      }
      return;
    }

    // Hypothesis for this window, with absolute times.
    let hyp = [];
    const segEnds = [];
    for (const s of r.segs) {
      if (!(s.noSpeech < 0.6) || !plausible(s) || text.isNoise(s.text) || text.isRepetitive(s.text)) continue;
      for (const w of s.words) {
        hyp.push({ text: w.text, start: startSec + w.start, end: startSec + w.end, norm: text.norm(w.text) });
      }
      segEnds.push(startSec + s.end);
    }

    // Drop words that only echo the vocabulary hint (Whisper reads it back after a breath).
    const echo = text.echoIndices(hyp.map((w) => w.norm), this.vocabSeq);
    if (echo.size) hyp = hyp.filter((_, i) => !echo.has(i));
    hyp = text.collapseRepeats(hyp);

    // Only words after what is already confirmed (a word counts as new when its midpoint is later).
    let fresh = hyp.filter((w) => (w.start + w.end) / 2 > this.committedMid);

    // Drop an n-gram that repeats the end of the confirmed text (the window overlaps it).
    if (fresh.length && fresh[0].start - this.committedEnd < 1.0) {
      for (let n = Math.min(5, this.recentNorms.length, fresh.length); n >= 1; n--) {
        const a = this.recentNorms.slice(-n).join('\u0001');
        const b = fresh.slice(0, n).map((w) => w.norm).join('\u0001');
        if (a === b) { fresh = fresh.slice(n); break; }
      }
    }

    let commitWords, tail;
    if (flush) {
      commitWords = fresh; tail = [];
    } else {
      let n = 0;
      while (n < fresh.length && n < this.prevTail.length && fresh[n].norm && fresh[n].norm === this.prevTail[n].norm) n++;
      n = Math.min(n, Math.max(fresh.length - 1, 0));          // the last word may be cut off: never confirm it yet
      commitWords = fresh.slice(0, n);
      tail = fresh.slice(n);
    }
    this.emit(commitWords, tail);
    this.prevTail = tail;
    log.write(`${this.label}   hyp=${hyp.length} fresh=${fresh.length} commit=${commitWords.length} tail=${tail.length} | ${commitWords.map((w) => w.text).join(' ')} ‖ ${tail.map((w) => w.text).join(' ')}`);

    if (flush) {
      this.committedEnd = Math.max(this.committedEnd, endSec);
      this.committedMid = Math.max(this.committedMid, endSec);
      this.trimTo(endAbs);
      this.prevTail = [];
      this.lastSentCount = -1;
      if (this.lockedLanguage) this.lastLanguage = this.lockedLanguage;
      this.lockedLanguage = null;
    } else if (buf.length / SR > 10) {
      // Window is getting long: cut at the end of a fully confirmed segment.
      let e = null;
      for (let i = segEnds.length - 1; i >= 0; i--) {
        if (segEnds[i] > startSec + 1 && segEnds[i] <= this.committedEnd + 0.05) { e = segEnds[i]; break; }
      }
      if (e !== null) this.trimTo(Math.floor(e * SR));
    }
  }

  emit(commit, tail) {
    const ev = { label: this.label, commit: '', tail: tail.map((w) => w.text).join(' ') };
    if (commit.length) {
      const first = commit[0], last = commit[commit.length - 1];
      ev.commit = commit.map((w) => w.text).join(' ');
      ev.time = first.start;
      ev.newLine = first.start - this.lastCommitEnd > 1.5;
      this.committedEnd = Math.max(this.committedEnd, last.end);
      this.committedMid = Math.max(this.committedMid, (last.start + last.end) / 2);
      this.lastCommitEnd = last.end;
      this.recentNorms = this.recentNorms.concat(commit.map((w) => w.norm)).slice(-8);
    }
    this.fire(ev);
  }

  fire(ev) { if (this.onEvent) this.onEvent(ev); }

  pickLanguage(r) {
    const scores = ALLOWED.map((l) => [l, r.probs[l] || 0]);
    const total = scores.reduce((a, s) => a + s[1], 0);
    if (total > 0) {
      const best = scores.reduce((a, b) => (b[1] > a[1] ? b : a));
      if (best[1] / total >= 0.6 || !this.lastLanguage) return best[0];
      return this.lastLanguage;               // unsure: stay with the previous utterance's language
    }
    if (ALLOWED.includes(r.language)) return r.language;
    return this.lastLanguage || 'en';
  }
}

/** Box-filter downsampler from the capture rate (e.g. 48 kHz) to 16 kHz mono Float32. */
class Downsampler {
  constructor(inRate) { this.ratio = inRate / SR; this.pos = 0; this.acc = 0; this.n = 0; }
  process(input) {
    const out = [];
    for (let i = 0; i < input.length; i++) {
      this.acc += input[i]; this.n++; this.pos += 1;
      if (this.pos >= this.ratio) {
        out.push(this.acc / this.n);
        this.acc = 0; this.n = 0; this.pos -= this.ratio;
      }
    }
    return Float32Array.from(out);
  }
}

module.exports = { StreamingTranscriber, Downsampler, rms, hasSpeech, plausible, SR };
