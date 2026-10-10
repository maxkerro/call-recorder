'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const tools = require('./tools');
const text = require('./text');

// ---- parsing whisper-cli output ---------------------------------------------------------------------------------------

/** Lines look like: [00:00:03.000 --> 00:00:07.500]   Hello there */
function parse(output) {
  const re = /^\[(\d+):(\d+):(\d+)[.,](\d+)\s*-->\s*(\d+):(\d+):(\d+)[.,](\d+)\s*\]\s*(.*)$/;
  const seq = text.vocabularySequence();
  const blocked = text.userBlocklist();
  const segs = [];
  for (const line of output.split(/\r?\n/)) {
    const m = re.exec(line);
    if (!m) continue;
    const start = +m[1] * 3600 + +m[2] * 60 + +m[3] + +('0.' + m[4]);
    const end = +m[5] * 3600 + +m[6] * 60 + +m[7] + +('0.' + m[8]);
    const t = text.stripPromptEcho(text.scrub(m[9].trim(), blocked), seq);
    if (text.isNoise(t)) continue;
    segs.push({ start, end: Math.max(start, end), text: t });
  }
  return segs;
}

/** whisper-cli with --print-progress writes "progress =  37%" to stderr; returns the last percentage in a chunk, or null. */
function parseProgress(chunk) {
  let last = null;
  for (const m of String(chunk).matchAll(/progress\s*=\s*(\d+)\s*%/g)) last = Math.min(100, +m[1]);
  return last;
}

async function execute(cli, args, onProgress) {
  const r = await tools.run(cli, args, onProgress ? { onStderr: (s) => { const p = parseProgress(s); if (p !== null) onProgress(p / 100); } } : {});
  if (r.code !== 0) throw new tools.ToolError(`whisper-cli failed (${r.code}): ${r.stderr.slice(-300)}`);
  return parse(r.stdout.toString('utf8'));
}

async function runCli(wav, language, quality = false, onProgress = null) {
  const cli = tools.cliPath();
  if (!cli) throw new tools.ToolError('whisper-cli not found. Run setup-whisper.ps1.');
  const model = tools.modelPath();
  if (!model) throw new tools.ToolError('No Whisper model found. Run setup-whisper.ps1 to download one.');
  const threads = String(Math.max(2, os.cpus().length - 2));
  const base = ['-m', model, '-f', wav, '-l', language, '-np', '-t', threads];
  const extra = [];
  if (quality) {
    extra.push('-bs', '5', '-bo', '5', '-sns');                // beam search, suppress music/noise tokens
    const prompt = text.vocabularyPrompt();
    if (prompt) extra.push('--prompt', prompt, '--carry-initial-prompt');
    const vad = tools.vadModelPath();
    if (vad) extra.push('--vad', '-vm', vad);
  }
  if (onProgress) extra.push('-pp');                          // print progress
  try {
    return await execute(cli, [...base, ...extra], onProgress);
  } catch (e) {
    if (!extra.length) throw e;
    return execute(cli, base);                                // an older whisper-cli may not know some option
  }
}

// ---- whole files ------------------------------------------------------------------------------------------------------

/** Any audio file -> 16 kHz mono WAV (volume levelled), then Whisper. */
async function segmentsOf(input, language, onProgress = null) {
  const ffmpeg = tools.ffmpegPath();
  if (!ffmpeg) throw new tools.ToolError('ffmpeg not found. Run setup-whisper.ps1 (it installs ffmpeg) or: winget install Gyan.FFmpeg');
  const wav = path.join(os.tmpdir(), `whisper-in-${crypto.randomUUID()}.wav`);
  try {
    const r = await tools.run(ffmpeg, ['-y', '-loglevel', 'error', '-i', input,
      '-af', 'loudnorm=I=-16:TP=-1.5:LRA=11', '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', wav]);
    if (r.code !== 0) throw new tools.ToolError(`ffmpeg could not read ${path.basename(input)}`);
    return await runCli(wav, language, true, onProgress);
  } finally {
    fs.rm(wav, { force: true }, () => {});
  }
}

/** True when the track is (nearly) digital silence. Whisper invents text for silence, so such tracks are skipped. */
async function isSilent(file) {
  const ffmpeg = tools.ffmpegPath();
  if (!ffmpeg) return false;
  try {
    const r = await tools.run(ffmpeg, ['-hide_banner', '-nostats', '-i', file, '-af', 'volumedetect', '-f', 'null', '-']);
    const m = /max_volume:\s*(-?[\d.]+)\s*dB/.exec(r.stderr);
    return m ? parseFloat(m[1]) < -50 : false;
  } catch { return false; }
}

// ---- speakers ---------------------------------------------------------------------------------------------------------

/** The speaker whose turns overlap the segment the most (null when nobody was detected there). */
function speakerFor(seg, turns) {
  const end = Math.max(seg.end, seg.start + 0.5);
  const overlap = new Map();
  for (const t of turns) {
    const o = Math.min(end, t.end) - Math.max(seg.start, t.start);
    if (o > 0) overlap.set(t.speaker, (overlap.get(t.speaker) || 0) + o);
  }
  let best = null, bv = 0;
  for (const [k, v] of overlap) if (v > bv) { best = k; bv = v; }
  return best;
}

/** Speaker at a moment; in a gap between turns, the nearest turn within 1.5 s. */
function speakerAt(time, turns) {
  const hit = turns.find((t) => t.start <= time && time <= t.end);
  if (hit) return hit.speaker;
  let near = null, nd = Infinity;
  for (const t of turns) {
    const d = time < t.start ? t.start - time : time > t.end ? time - t.end : 0;
    if (d < nd) { nd = d; near = t; }
  }
  return near && nd <= 1.5 ? near.speaker : null;
}

/** Word-level speaker assignment: each word gets an estimated time (spread over the segment in proportion to its
 *  length) and the speaker talking at that moment. Consecutive words of one speaker are joined again. */
function splitBySpeaker(seg, turns, fallback) {
  const words = seg.text.split(/\s+/).filter(Boolean);
  if (words.length <= 1 || !(seg.end > seg.start)) {
    return [{ t: seg.start, label: speakerFor(seg, turns) || fallback, text: seg.text }];
  }
  const weights = words.map((w) => Math.max([...w].length, 2));
  const total = weights.reduce((a, b) => a + b, 0);
  let t = seg.start;
  const out = [];
  words.forEach((w, i) => {
    const dur = (seg.end - seg.start) * weights[i] / total;
    const who = speakerAt(t + dur / 2, turns) || (out.length ? out[out.length - 1].label : fallback);
    if (out.length && out[out.length - 1].label === who) out[out.length - 1].text += ' ' + w;
    else out.push({ t, label: who, text: w });
    t += dur;
  });
  return out;
}

/** Joins consecutive entries of the same speaker (gap < 6 s, < 300 chars) into "[mm:ss] Label: text" lines. */
function toLines(entries) {
  const all = entries.slice().sort((a, b) => a.t - b.t);
  const lines = [];
  for (const e of all) {
    const last = lines[lines.length - 1];
    if (last && last.label === e.label && e.t - last.last < 6 && last.text.length < 300) {
      last.text += ' ' + e.text;
      last.last = e.t;
    } else {
      lines.push({ t: e.t, label: e.label, text: e.text, last: e.t });
    }
  }
  return lines.map((l) => {
    const s = Math.floor(Math.max(l.t, 0));
    return `[${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}] ${l.label}: ${l.text}`;
  });
}

/** The accurate "check" pass: call-audio track ("Them" or Speaker N) and microphone track ("Me"), separately. */
async function transcribeTracks({ system, mic, language, turns = [], onProgress = null }) {
  const all = [];
  const tracks = [];
  for (const [file, label] of [[system, 'Them'], [mic, 'Me']]) if (file && !(await isSilent(file))) tracks.push([file, label]);
  for (const [i, [file, label]] of tracks.entries()) {
    const part = onProgress ? (f) => onProgress((i + f) / tracks.length) : null;          // progress over all tracks
    for (const seg of await segmentsOf(file, language, part)) {
      if (label === 'Them' && turns.length) all.push(...splitBySpeaker(seg, turns, label));
      else all.push({ t: seg.start, label, text: seg.text });
    }
  }
  return toLines(all);
}

/** Whole file with speaker labels (every voice, including yours, gets a Speaker label). */
async function transcribeFileWithSpeakers(input, language, turns, onProgress = null) {
  const all = [];
  for (const seg of await segmentsOf(input, language, onProgress)) all.push(...splitBySpeaker(seg, turns, 'Speaker ?'));
  return toLines(all);
}

/** New paragraph with a [mm:ss] marker roughly every 30 seconds. */
function format(segs) {
  let out = '';
  let lastMark = -100;
  for (const seg of segs) {
    if (seg.start - lastMark >= 30) {
      const s = Math.floor(seg.start);
      out += (out ? '\n\n' : '') + `[${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}] `;
      lastMark = seg.start;
    } else out += ' ';
    out += seg.text;
  }
  return out;
}

async function transcribeFile(input, language, onProgress = null) {
  return format(await segmentsOf(input, language, onProgress));
}

module.exports = {
  parse, parseProgress, runCli, segmentsOf, isSilent, speakerFor, speakerAt, splitBySpeaker, toLines,
  transcribeTracks, transcribeFileWithSpeakers, format, transcribeFile,
};
