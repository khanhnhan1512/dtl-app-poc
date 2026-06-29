import { BaseWindow, WebContentsView } from 'electron'
import { join } from 'path'
import { HOME_URL } from './config.js'
import { applyNavigationLockdown } from './navigation.js'

const isDev = process.env.NODE_ENV === 'development'

export function createShell() {
  const win = new BaseWindow({ width: 1280, height: 800, title: 'DTL App' })

  const portalView = new WebContentsView({
    webPreferences: {
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      webviewTag: false,
      devTools: isDev,
      preload: join(__dirname, '../preload/index.js')
    }
  })

  win.contentView.addChildView(portalView)
  applyNavigationLockdown(portalView.webContents)

  if (!isDev) {
    portalView.webContents.on('before-input-event', (e, input) => {
      if (input.type !== 'keyDown') return
      const ctrl = input.control || input.meta
      if (
        (ctrl && input.key === 'r') ||
        input.key === 'F5' ||
        (ctrl && input.shift && input.key === 'i') ||
        input.key === 'F12' ||
        (input.alt && input.key === 'ArrowLeft') ||
        (input.alt && input.key === 'ArrowRight')
      ) {
        e.preventDefault()
      }
    })
  }

  function layout() {
    const { width, height } = win.getContentBounds()
    portalView.setBounds({ x: 0, y: 0, width, height })
  }

  layout()
  win.on('resize', layout)

  portalView.webContents.on('did-finish-load', () => {
    win.show()
  })
  portalView.webContents.on('did-fail-load', (_e, errorCode, errorDescription, validatedURL) => {
    console.error(`[load] FAILED ${errorCode} ${errorDescription} url=${validatedURL}`)
    win.show()
  })

  portalView.webContents.loadURL(HOME_URL)
  win.show()

  return win
}
