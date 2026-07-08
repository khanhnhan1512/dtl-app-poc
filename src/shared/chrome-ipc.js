// Shared IPC channel names for the chrome bar preload ↔ Main process contract (M1b).
// Zero Electron/Node dependency — safe to import from both the preload build and Main.
export const CHROME_STATE_CHANNEL = 'chrome:state'
export const CHROME_GO_HOME_CHANNEL = 'chrome:go-home'
// Sent by the chrome bar's renderer script once it has registered its onState listener, so Main
// can re-push the current state if the bar mounted after the first push (initial-state race).
export const CHROME_READY_CHANNEL = 'chrome:ready'
