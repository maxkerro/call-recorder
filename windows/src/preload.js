'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  state: () => ipcRenderer.invoke('state'),
  onState: (cb) => ipcRenderer.on('state', (_e, s) => cb(s)),
  toggle: (live) => ipcRenderer.invoke('toggle', live),
  setSetting: (k, v) => ipcRenderer.invoke('setSetting', k, v),
  setTopic: (t) => ipcRenderer.invoke('setTopic', t),
  screenshot: () => ipcRenderer.invoke('screenshot'),
  chooseFolder: () => ipcRenderer.invoke('chooseFolder'),
  resetFolder: () => ipcRenderer.invoke('resetFolder'),
  rename: (a, b) => ipcRenderer.invoke('rename', a, b),
  openFolder: () => ipcRenderer.invoke('openFolder'),
  openVocabulary: () => ipcRenderer.invoke('openVocabulary'),
  copy: (what) => ipcRenderer.invoke('copy', what),
  transcribeFile: () => ipcRenderer.invoke('transcribeFile'),
  about: () => ipcRenderer.invoke('about'),
  audio: (track, buffer) => ipcRenderer.send('audio', track, buffer),
  onCapture: (cb) => {
    ipcRenderer.on('capture:start', (_e, id) => cb('start', id));
    ipcRenderer.on('capture:stop', (_e, id) => cb('stop', id));
  },
  reply: (id, r) => ipcRenderer.send('capture:reply', id, r),
});
