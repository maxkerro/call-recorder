// Captures what you hear (WASAPI loopback, via Electron) and your microphone as two separate tracks.
let ctx = null;
let streams = [];

async function startCapture() {
  ctx = new AudioContext({ sampleRate: 48000 });
  await ctx.audioWorklet.addModule('worklet.js');
  const mute = ctx.createGain();
  mute.gain.value = 0;                      // keeps the graph running without playing anything
  mute.connect(ctx.destination);
  const problems = [];

  const attach = (stream, track) => {
    const src = ctx.createMediaStreamSource(new MediaStream(stream.getAudioTracks()));
    const node = new AudioWorkletNode(ctx, 'tap', { processorOptions: { track }, numberOfOutputs: 1 });
    node.port.onmessage = (e) => window.api.audio(e.data.track, e.data.buffer);
    src.connect(node);
    node.connect(mute);
  };

  try {
    // The main process answers with the screen + loopback audio; the video is not used.
    const disp = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true });
    streams.push(disp);
    if (!disp.getAudioTracks().length) throw new Error('Windows gave no system audio');
    attach(disp, 'system');
  } catch (e) {
    problems.push(`system audio: ${e.message}`);
  }
  try {
    const mic = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false },
    });
    streams.push(mic);
    attach(mic, 'mic');
  } catch (e) {
    problems.push(`microphone: ${e.message} (Windows Settings → Privacy → Microphone)`);
  }
  if (problems.length === 2) {
    await stopCapture();
    throw new Error(problems.join('; '));
  }
  return { sampleRate: ctx.sampleRate, warning: problems.join('; ') };
}

async function stopCapture() {
  await new Promise((r) => setTimeout(r, 250));      // let the last blocks arrive
  for (const s of streams) s.getTracks().forEach((t) => t.stop());
  streams = [];
  if (ctx) { try { await ctx.close(); } catch { /* closed */ } ctx = null; }
}

window.api.onCapture(async (what, id) => {
  try {
    if (what === 'start') window.api.reply(id, { ok: true, ...(await startCapture()) });
    else { await stopCapture(); window.api.reply(id, { ok: true }); }
  } catch (e) {
    window.api.reply(id, { ok: false, error: e.message || String(e) });
  }
});
