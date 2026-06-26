import { app, BrowserWindow } from 'electron'
import { join } from 'path'
import { handleCertSelect } from './cert-select.js'
import { TARGET_URL } from './config.js'
import { wipe } from './wipe.js'

app.on('select-client-certificate', handleCertSelect)

function createWindow() {
  const win = new BrowserWindow({
    width: 1280,
    height: 800,
    show: false,
    webPreferences: {
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      webviewTag: false,
      preload: join(__dirname, '../preload/index.js')
    }
  })

  win.once('ready-to-show', () => win.show())

  win.loadURL(TARGET_URL)

  win.webContents.on('did-finish-load', () => {
    win.show()
    if (process.argv.includes('--quit-after-load')) app.quit()
  })

  win.webContents.on('did-fail-load', (_e, errorCode, errorDescription, validatedURL) => {
    console.error(`[load] FAILED ${errorCode} ${errorDescription} url=${validatedURL}`)
    win.show()
  })
}

app.whenReady().then(async () => {
  if (process.argv.includes('--wipe')) {
    try {
      const result = await wipe()
      console.log('[wipe] SUCCESS', result)
    } catch (err) {
      console.error('[wipe] FAILED', err.message)
      process.exitCode = 1
    }
    app.quit()
    return
  }
  createWindow()
})
app.on('window-all-closed', () => app.quit())
