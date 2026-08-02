const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('gw', {
  getDefaults: () => ipcRenderer.invoke('gw:defaults'),
  preview: (opts) => ipcRenderer.invoke('gw:preview', opts),
  install: (opts) => ipcRenderer.invoke('gw:install', opts),
  uninstall: (opts) => ipcRenderer.invoke('gw:uninstall', opts),
  demo: (desc) => ipcRenderer.invoke('gw:demo', desc),
  projectSetup: (opts) => ipcRenderer.invoke('gw:projectSetup', opts),
  pickProfile: () => ipcRenderer.invoke('gw:pickProfile'),
  pickDir: (title) => ipcRenderer.invoke('gw:pickDir', { title }),
});
