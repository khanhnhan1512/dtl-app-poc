// Preload for the chrome bar view ONLY (M1b). Narrow contextBridge API — three functions, no
// generic ipcRenderer passthrough, no filesystem/Node access. The portal preload (index.js)
// stays empty; only the chrome bar gets this API.
import { contextBridge, ipcRenderer } from 'electron'
import {
  CHROME_STATE_CHANNEL,
  CHROME_GO_HOME_CHANNEL,
  CHROME_READY_CHANNEL
} from '../shared/chrome-ipc.js'

contextBridge.exposeInMainWorld('dtlChrome', {
  onState: (cb) => ipcRenderer.on(CHROME_STATE_CHANNEL, (_e, state) => cb(state)),
  goHome: () => ipcRenderer.send(CHROME_GO_HOME_CHANNEL),
  // Call once, after onState's listener is registered — lets Main re-push the current state if
  // the bar mounts after the first push (initial-state race).
  ready: () => ipcRenderer.send(CHROME_READY_CHANNEL),
})
