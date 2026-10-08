const $ = (id) => document.getElementById(id);
let current = null;

function setText(el, value) { if (el.textContent !== value) el.textContent = value; }
function show(el, on) { el.classList.toggle('hidden', !on); }

function render(s) {
  current = s;
  const live = s.liveMode;
  show($('rec'), s.isRecording);
  setText($('elapsed'), s.elapsed);

  $('btnRec').classList.toggle('on', s.isRecording && !live);
  setText($('lblRec'), s.isRecording && !live ? 'Stop recording' : 'Record to MP3');
  $('btnRec').disabled = s.busy || (s.isRecording && live);
  $('btnLive').classList.toggle('on', s.isRecording && live);
  setText($('lblLive'), s.isRecording && live ? 'Stop' : 'Record + live transcript');
  $('btnLive').disabled = s.busy || (s.isRecording && !live);

  $('btnShot').disabled = !s.isRecording;
  setText($('btnShot').firstElementChild, s.shotCount ? `Screenshot into summary (${s.shotCount})` : 'Screenshot into summary');
  if (document.activeElement !== $('topic') && $('topic').value !== s.topic) $('topic').value = s.topic;
  $('topic').disabled = false;
  setText($('folderPath'), s.settings.outputRoot || s.rootDir);
  $('btnChoose').disabled = s.isRecording; $('btnReset').disabled = s.isRecording || !s.settings.outputRoot;

  const lang = $('language');
  if (!lang.options.length) {
    for (const l of s.languages) lang.add(new Option(l.name, l.id));
  }
  if (lang.value !== s.settings.language) lang.value = s.settings.language;
  lang.disabled = s.isRecording;
  for (const k of ['verifyAfterLive', 'identifySpeakers', 'summarizeCalls', 'glossaryCorrect', 'offlineMode']) {
    $(k).checked = !!s.settings[k];
    $(k).disabled = s.isRecording;
  }

  show($('hint'), !!s.whisperHint);
  setText($('hint'), s.whisperHint || '');
  show($('syncWarning'), !!s.syncWarning);
  setText($('syncWarning'), s.syncWarning || '');
  show($('levels'), s.isRecording);
  setText($('levels'), `Captured so far — call audio: ${s.sysSeconds} s, microphone: ${s.micSeconds} s` +
    (s.isRecording && s.elapsed !== '00:00' && s.sysSeconds === 0 ? '  (no call audio yet: is anything playing?)' : ''));

  // Transcript: final lines, then tentative text per speaker in grey.
  const has = s.finalLines.length || Object.keys(s.partials).length;
  show($('transcriptBox'), !!has);
  const box = $('transcript');
  const key = JSON.stringify([s.finalLines, s.partials]);
  if (box.dataset.key !== key) {
    box.dataset.key = key;
    const atEnd = box.scrollTop + box.clientHeight >= box.scrollHeight - 30;
    box.textContent = '';
    for (const l of s.finalLines) { const p = document.createElement('p'); p.textContent = l; box.appendChild(p); }
    for (const [k, v] of Object.entries(s.partials).sort()) {
      const p = document.createElement('p'); p.className = 'partial'; p.textContent = `${k}: ${v}`; box.appendChild(p);
    }
    if (atEnd) box.scrollTop = box.scrollHeight;
  }

  // Rename speakers
  const names = s.speakerLabels;
  show($('renameBox'), names.length > 0 && !s.isRecording);
  const who = $('renameWho');
  if (who.dataset.names !== names.join('|')) {
    who.dataset.names = names.join('|');
    who.textContent = '';
    for (const n of names) who.add(new Option(n, n));
  }

  show($('summaryBox'), !!(s.summaryText || s.summaryNote));
  setText($('summaryText'), s.summaryText);
  setText($('summaryNote'), s.summaryNote);
  show($('btnCopySummary'), !!s.summaryText);

  $('btnFile').disabled = s.busy || s.isRecording;
  setText($('status'), s.status);
  setText($('checkNote'), s.checkNote);
}

$('btnRec').onclick = () => window.api.toggle(false);
$('btnLive').onclick = () => window.api.toggle(true);
$('language').onchange = (e) => window.api.setSetting('language', e.target.value);
for (const k of ['verifyAfterLive', 'identifySpeakers', 'summarizeCalls', 'glossaryCorrect', 'offlineMode']) {
  $(k).onchange = (e) => window.api.setSetting(k, e.target.checked);
}
$('btnRename').onclick = () => {
  const to = $('renameTo').value.trim();
  if (to) { window.api.rename($('renameWho').value, to); $('renameTo').value = ''; }
};
$('btnShot').onclick = () => window.api.screenshot();
$('topic').oninput = (e) => window.api.setTopic(e.target.value);
$('btnChoose').onclick = () => window.api.chooseFolder();
$('btnReset').onclick = () => window.api.resetFolder();
$('btnFile').onclick = () => window.api.transcribeFile();
$('btnFolder').onclick = () => window.api.openFolder();
$('btnVocab').onclick = () => window.api.openVocabulary();
$('btnCopySummary').onclick = () => window.api.copy('summary');
$('btnCopyClaude').onclick = () => window.api.copy('claude');
$('btnAbout').onclick = () => window.api.about();
$('btnQuit').onclick = () => window.api.quit();

window.api.onState(render);
window.api.state().then(render);
