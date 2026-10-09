'use strict';
const { parentPort, workerData } = require('worker_threads');
try {
  const sherpa = require('sherpa-onnx-node');
  const sd = new sherpa.OfflineSpeakerDiarization({
    segmentation: { pyannote: { model: workerData.seg, windowShiftRatio: 0.1 } },
    embedding: { model: workerData.emb },
    clustering: { numClusters: -1, threshold: 0.5 },   // unknown number of speakers; larger = fewer speakers
    minDurationOn: 0.3,
    minDurationOff: 0.5,
  });
  const segs = sd.process(workerData.samples);
  const segments = segs.map((s) => ({ speaker: String(s.speaker), start: s.start, end: s.end }));
  // A voice fingerprint per speaker: the speaker-embedding model over up to 60 s of that speaker's speech.
  const voices = {};
  try {
    const rate = 16000;
    const extractor = new sherpa.SpeakerEmbeddingExtractor({ model: workerData.emb, numThreads: 2 });
    for (const id of new Set(segments.map((s) => s.speaker))) {
      const parts = []; let n = 0;
      for (const s of segments.filter((x) => x.speaker === id)) {
        const a = Math.max(0, Math.floor(s.start * rate)); const b = Math.min(workerData.samples.length, Math.floor(s.end * rate));
        if (b > a && n < 60 * rate) { const part = workerData.samples.subarray(a, b); parts.push(part); n += part.length; }
      }
      if (n < 3 * rate) continue;
      const all = new Float32Array(n); let o = 0;
      for (const p of parts) { all.set(p, o); o += p.length; }
      const stream = extractor.createStream();
      stream.acceptWaveform({ sampleRate: rate, samples: all });
      voices[id] = Array.from(extractor.compute(stream));
    }
  } catch { /* fingerprints are optional: without them speakers are still told apart, just not named */ }
  parentPort.postMessage({ segments, voices });
} catch (e) {
  parentPort.postMessage({ error: String((e && e.message) || e) });
}
