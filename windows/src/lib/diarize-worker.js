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
  parentPort.postMessage({ segments: segs.map((s) => ({ speaker: String(s.speaker), start: s.start, end: s.end })) });
} catch (e) {
  parentPort.postMessage({ error: String((e && e.message) || e) });
}
