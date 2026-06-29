import { BaseWindow, WebContentsView } from 'electron'
import { join } from 'path'
import { HOME_URL, PRODUCT_NAME } from './config.js'
import { applyNavigationLockdown } from './navigation.js'

const isDev = process.env.NODE_ENV === 'development'
const CHROME_H = 48

export function createShell() {
  const win = new BaseWindow({ width: 1280, height: 800, title: PRODUCT_NAME })

  const sharedWebPrefs = {
    contextIsolation: true,
    sandbox: true,
    nodeIntegration: false,
    webviewTag: false,
    devTools: isDev,
    preload: join(__dirname, '../preload/index.js')
  }

  const chromeView = new WebContentsView({ webPreferences: sharedWebPrefs })
  const portalView = new WebContentsView({ webPreferences: sharedWebPrefs })

  win.contentView.addChildView(chromeView)
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
  } else {
    // BaseWindow has no own webContents so the default menu Reload accelerator is a no-op.
    // Wire Ctrl+R / F5 directly to the portal view in dev for convenience.
    portalView.webContents.on('before-input-event', (_e, input) => {
      if (input.type !== 'keyDown') return
      const ctrl = input.control || input.meta
      if ((ctrl && input.key === 'r') || input.key === 'F5') {
        portalView.webContents.reload()
      }
    })
  }

  function layout() {
    const { width, height } = win.getContentBounds()
    chromeView.setBounds({ x: 0, y: 0, width, height: CHROME_H })
    portalView.setBounds({ x: 0, y: CHROME_H, width, height: height - CHROME_H })
  }

  layout()
  win.on('resize', layout)

  portalView.webContents.on('did-finish-load', () => {
    win.show()
    portalView.webContents.focus()
  })
  portalView.webContents.on('did-fail-load', (_e, errorCode, errorDescription, validatedURL) => {
    console.error(`[load] FAILED ${errorCode} ${errorDescription} url=${validatedURL}`)
    win.show()
  })

  if (isDev) {
    chromeView.webContents.loadURL(process.env.ELECTRON_RENDERER_URL)
  } else {
    chromeView.webContents.loadFile(join(__dirname, '../renderer/index.html'))
  }

  portalView.webContents.loadURL(HOME_URL)
  win.show()

  return win
}
