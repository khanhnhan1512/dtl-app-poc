import { NAV_ALLOWLIST } from './config.js'
import { isAllowed } from './allowlist.js'

export function applyNavigationLockdown(webContents) {
  webContents.on('will-navigate', (e, url) => {
    if (!isAllowed(url, NAV_ALLOWLIST)) {
      e.preventDefault()
      console.log(`[nav] BLOCKED will-navigate → ${url}`)
    }
  })

  webContents.on('will-redirect', (e, url) => {
    if (!isAllowed(url, NAV_ALLOWLIST)) {
      e.preventDefault()
      console.log(`[nav] BLOCKED will-redirect → ${url}`)
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
