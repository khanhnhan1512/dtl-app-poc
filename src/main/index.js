import { app, BrowserWindow } from 'electron'
import { join } from 'path'
import { handleCertSelect } from './cert-select.js'
import { TARGET_URL } from './config.js'

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

  win.loadURL(TARGET_URL)

  win.webContents.on('did-finish-load', () => {
    win.show()
    if (process.argv.includes('--quit-after-load')) app.quit()
  })
}

app.whenReady().then(createWindow)
app.on('window-all-closed', () => app.quit())
