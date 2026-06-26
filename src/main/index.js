import { app } from 'electron'
import { handleCertSelect } from './cert-select.js'
import { wipe } from './wipe.js'
import { createShell } from './window.js'

app.on('select-client-certificate', handleCertSelect)

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
  createShell()
})
app.on('window-all-closed', () => app.quit())
