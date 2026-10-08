'use strict';
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('sel', {
  onInit: (cb) => ipcRenderer.once('sel:init', (_e, dataUrl) => cb(dataUrl)),
  done: (rect) => ipcRenderer.send('sel:done', rect),
});
