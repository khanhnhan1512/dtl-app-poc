import { NAV_ALLOWLIST } from './config.js'
import { isAllowed } from './allowlist.js'

// onBlocked(url): optional, fired after preventDefault() on a blocked will-navigate/will-redirect
// (M1b — drives the local address-not-permitted page). Not wired to setWindowOpenHandler; the
// nav-block demo is a same-window link, never a window.open.
export function applyNavigationLockdown(webContents, { onBlocked } = {}) {
  webContents.on('will-navigate', (e, url) => {
    if (!isAllowed(url, NAV_ALLOWLIST)) {
      e.preventDefault()
      console.log(`[nav] BLOCKED will-navigate → ${url}`)
      onBlocked?.(url)
    }
  })

  webContents.on('will-redirect', (e, url) => {
    if (!isAllowed(url, NAV_ALLOWLIST)) {
      e.preventDefault()
      console.log(`[nav] BLOCKED will-redirect → ${url}`)
      onBlocked?.(url)
    }
  })

  webContents.setWindowOpenHandler(({ url }) => {
    if (isAllowed(url, NAV_ALLOWLIST)) {
      webContents.loadURL(url)
    } else {
      console.log(`[nav] BLOCKED window.open → ${url}`)
    }
    return { action: 'deny' }
  })
}
