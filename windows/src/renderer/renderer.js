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
  setText($('lblRec'), s.isRecording && !live ? 'Stop' : 'Record');
  $('btnRec').disabled = s.busy || (s.isRecording && live);
  $('btnLive').classList.toggle('on', s.isRecording && live);
  setText($('lblLive'), s.isRecording && live ? 'Stop' : 'Record + transcript');
  $('btnLive').disabled = s.busy || (s.isRecording && !live);

  $('btnShot').disabled = !s.isRecording;
  setText($('btnShot').firstElementChild, s.shotCount ? `Screenshot (${s.shotCount})` : 'Screenshot');
  if (document.activeElement !== $('topic') && $('topic').value !== s.topic) $('topic').value = s.topic;
  $('topic').disabled = false;
  setText($('folderPath'), s.settings.outputRoot || s.rootDir);
  $('btnChoose').disabled = s.isRecording; $('btnReset').disabled = s.isRecording || !s.settings.outputRoot;

  const op = Math.round((s.settings.windowOpacity || 1) * 100);
  if (document.activeElement !== $('opacity')) $('opacity').value = op;
  setText($('opacityValue'), `${$('opacity').value}%`);

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

  // Transcript: final lines, then tentative text per speaker in grey. With the translation pane open every line
  // gets a second column with its translation.
  const open = !!s.translateOpen;
  setText($('btnTranslate'), open ? 'Translation ▸' : 'Translation ◂');
  show($('trLang'), open);
  show($('trCtl'), open);
  const ts = s.translateState || 'running';
  $('trPause').disabled = ts !== 'running';
  $('trContinue').disabled = ts === 'running';
  $('trStop').disabled = ts === 'stopped';
  const tl = $('trLang');
  if (!tl.options.length) for (const l of s.translationLanguages) tl.add(new Option(l.name, l.code));
  if (document.activeElement !== tl && tl.value !== s.settings.translateTo) tl.value = s.settings.translateTo;
  show($('translateNote'), !!s.translateNote);
  setText($('translateNote'), s.translateNote || '');

  const has = s.finalLines.length || Object.keys(s.partials).length;
  show($('transcriptBox'), !!has);
  const box = $('transcript');
  box.classList.toggle('two', open);
  const key = JSON.stringify([s.finalLines, s.partials, open, open ? s.translations : 0]);
  if (box.dataset.key !== key) {
    box.dataset.key = key;
    const atEnd = box.scrollTop + box.clientHeight >= box.scrollHeight - 30;
    box.textContent = '';
    const cell = (cls, text) => { const p = document.createElement('p'); if (cls) p.className = cls; p.textContent = text; return p; };
    for (const l of s.finalLines) {
      box.appendChild(cell('', l));
      if (open) {
        const m = /^\[\d+:\d+\]\s+[^:\[\]]{1,40}?:\s+([\s\S]*)$/.exec(l);
        const body = (m ? m[1] : l.replace(/^\[\d+:\d+\]\s*/, '')).trim();
        box.appendChild(cell(s.translations[body] ? 'tr' : 'tr wait', s.translations[body] || '…'));
      }
    }
    for (const [k, v] of Object.entries(s.partials).sort()) {
      box.appendChild(cell('partial', `${k}: ${v}`));
      if (open) box.appendChild(cell('', ''));
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

  const voiceKey = (s.knownVoices || []).join('|');
  const vl = $('voiceList');
  if (vl.dataset.v !== voiceKey) {
    vl.dataset.v = voiceKey;
    vl.textContent = '';
    if (!s.knownVoices.length) { const p = document.createElement('p'); p.className = 'hint'; p.textContent = 'None yet'; vl.appendChild(p); }
    for (const n of s.knownVoices) {
      const row = document.createElement('div'); row.className = 'voice';
      const label = document.createElement('span'); label.textContent = n;
      const b = document.createElement('button'); b.textContent = 'Forget'; b.onclick = () => window.api.forgetVoice(n);
      row.append(label, b); vl.appendChild(row);
    }
    if (s.knownVoices.length > 1) {
      const all = document.createElement('button'); all.textContent = 'Forget all voices'; all.onclick = () => window.api.forgetAllVoices(); vl.appendChild(all);
    }
  }

  const conf = s.confirmable || [];
  show($('confirmBox'), conf.length > 0 && !s.isRecording);
  const cw = $('confirmWho');
  if (cw.dataset.names !== conf.join('|')) { cw.dataset.names = conf.join('|'); cw.textContent = ''; for (const n of conf) cw.add(new Option(n, n)); }

  show($('wordsBox'), !!s.wordStats);
  if (s.wordStats) {
    setText($('wordsSource'), `(${s.wordStats.source})`);
    const fill = (id, rows, button) => {
      const ol = $(id); ol.textContent = '';
      for (const r of rows) {
        const li = document.createElement('li');
        li.textContent = `${r.word} × ${r.count} `;
        if (button) { const b = document.createElement('button'); b.className = 'mini'; b.textContent = '+ Vocabulary'; b.onclick = () => window.api.addVocabulary([r.word]); li.appendChild(b); }
        ol.appendChild(li);
      }
      if (!rows.length) { const li = document.createElement('li'); li.textContent = '—'; ol.appendChild(li); }
    };
    fill('wordsTop', s.wordStats.frequent, false);
    fill('wordsUnknown', s.wordStats.unknown, true);
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
for (const [id, action] of [['trPause', 'pause'], ['trContinue', 'continue'], ['trStop', 'stop'], ['trRestart', 'restart']]) {
  $(id).onclick = () => window.api.translateControl(action);
}
$('btnConfirm').onclick = () => { const n = $('confirmWho').value; if (n) window.api.confirmVoice(n); };
$('btnWords').onclick = () => window.api.analyzeWords();
$('btnAddAll').onclick = () => window.api.addVocabulary(current.wordStats.unknown.map((u) => u.word));
$('btnShot').onclick = () => window.api.screenshot();
$('topic').oninput = (e) => window.api.setTopic(e.target.value);
$('btnChoose').onclick = () => window.api.chooseFolder();
$('btnReset').onclick = () => window.api.resetFolder();
$('opacity').oninput = (e) => { setText($('opacityValue'), `${e.target.value}%`); window.api.setSetting('windowOpacity', e.target.value / 100); };
$('btnTranslate').onclick = () => window.api.setTranslation(!current.translateOpen, $('trLang').value || current.settings.translateTo);
$('trLang').onchange = (e) => window.api.setTranslation(true, e.target.value);
$('btnFile').onclick = () => window.api.transcribeFile();
$('btnFolder').onclick = () => window.api.openFolder();
$('btnVocab').onclick = () => window.api.openVocabulary();
$('btnCopySummary').onclick = () => window.api.copy('summary');
$('btnCopyClaude').onclick = () => window.api.copy('claude');

// ---- tabs ----
function showTab(name) {
  for (const t of ['recorder', 'settings', 'about']) {
    show($('page-' + t), t === name);
    $('tab' + t[0].toUpperCase() + t.slice(1)).classList.toggle('on', t === name);
  }
}
for (const b of document.querySelectorAll('.tab')) b.onclick = () => showTab(b.dataset.tab);
window.api.about().then((i) => {
  $('aboutTitle').textContent = `${i.name} ${i.version}`;
  $('aboutSummary').textContent = i.summary;
  $('aboutVersion').textContent = `${i.version} (build ${i.build})`;
  $('aboutReleased').textContent = i.releaseDate;
  $('aboutAuthor').textContent = i.author;
});

window.api.onState(render);
window.api.state().then(render);
