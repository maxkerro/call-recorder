'use strict';
// Facts shown in the About box. Keep `version` in step with package.json and the Mac app (Info.plist, AppInfo.swift).
module.exports = {
  name: 'CallRecorder',
  version: require('../../package.json').version,
  releaseDate: '8 October 2026',
  author: 'Maksim Masliukov',
  summary: 'Records any call you hear (Teams, Telemost, Skype, a browser…) plus your microphone, transcribes it locally with Whisper, ' +
    'labels the speakers, and writes a summary with a local Ollama model. Nothing leaves your computer.',
};
