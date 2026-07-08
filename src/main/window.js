import { BaseWindow, WebContentsView, ipcMain } from 'electron'
import { join } from 'path'
import { PRODUCT_NAME, CERT_SUBJECT_CN } from './config.js'
import { applyNavigationLockdown } from './navigation.js'
import { logSessionIdentity } from './session-identity.js'
import {
  toolLabelForUrl,
  buildState,
  sendChromeState,
  CHROME_GO_HOME_CHANNEL,
  CHROME_READY_CHANNEL
} from './chrome-state.js'

const isDev = process.env.NODE_ENV === 'development'
const CHROME_H = 48

// M1b — local pages served into portalView. In dev, Vite's dev server serves `public/pages/*`
// at the same root as the renderer; in prod they're copied verbatim into `out/renderer/pages/`
// (Vite's publicDir mechanism — no build step for these static files).
function loadPage(view, name, query) {
  if (isDev) {
    const qs = query ? `?${new URLSearchParams(query).toString()}` : ''
    view.webContents.loadURL(`${process.env.ELECTRON_RENDERER_URL}/pages/${name}.html${qs}`)
  } else {
    view.webContents.loadFile(join(__dirname, `../renderer/pages/${name}.html`), query ? { query } : undefined)
  }
}

function isHomePage(url) {
  return url.includes('/pages/home.html')
}

export function createShell({ userEmail }) {
  const win = new BaseWindow({ width: 1280, height: 800, title: PRODUCT_NAME })

  const baseWebPrefs = {
    contextIsolation: true,
    sandbox: true,
    nodeIntegration: false,
    webviewTag: false,
    devTools: isDev
  }
  // Two distinct preloads: chromeView gets the narrow dtlChrome IPC API; portalView keeps the
  // existing empty preload — it renders both trusted local pages and (allow-listed) remote mTLS
  // content, and must never get a privileged API.
  const chromeWebPrefs = { ...baseWebPrefs, preload: join(__dirname, '../preload/chrome.js') }
  const portalWebPrefs = { ...baseWebPrefs, preload: join(__dirname, '../preload/index.js') }

  const chromeView = new WebContentsView({ webPreferences: chromeWebPrefs })
  const portalView = new WebContentsView({ webPreferences: portalWebPrefs })

  win.contentView.addChildView(chromeView)
  win.contentView.addChildView(portalView)

  // Tracks the last state pushed to chromeView so it can be re-sent if the bar's renderer script
  // finishes registering its onState listener AFTER the first push (initial-state race) — see the
  // 'chrome:ready' handler below.
  let currentChromeState = null
  function pushChromeState(state) {
    if (!state) return
    currentChromeState = state
    sendChromeState(chromeView, state)
  }

  applyNavigationLockdown(portalView.webContents, {
    onBlocked: (url) => loadPage(portalView, 'address-not-permitted', { url })
  })

  // M1b — extends the M4 did-navigate hook (moved here from index.js, generalized from a single
  // HOME_URL to any TOOLS host): 2xx on a tool host → log identity + green chrome state; non-2xx
  // → local access-denied page + red chrome state; the home page itself → neutral chrome state.
  // Anything else (the address-not-permitted page, the access-denied page's own load) matches no
  // branch below and pushes no state — the last pushed state stands (plan Decision 4).
  portalView.webContents.on('did-navigate', (_nav, url, httpResponseCode) => {
    const label = toolLabelForUrl(url)
    if (label) {
      if (httpResponseCode >= 200 && httpResponseCode < 300) {
        logSessionIdentity({ deviceCN: CERT_SUBJECT_CN, userEmail: userEmail ?? 'unknown' })
        pushChromeState(buildState('tool-ok', { label, userEmail }))
      } else {
        console.log(`[session] transport blocked — no valid mTLS (HTTP ${httpResponseCode})`)
        loadPage(portalView, 'access-denied', { code: httpResponseCode })
        pushChromeState(buildState('tool-blocked', { label, userEmail }))
      }
      return
    }
    if (isHomePage(url)) {
      pushChromeState(buildState('home', { userEmail }))
    }
  })

  ipcMain.on(CHROME_GO_HOME_CHANNEL, () => loadPage(portalView, 'home'))
  ipcMain.on(CHROME_READY_CHANNEL, () => {
    if (currentChromeState) sendChromeState(chromeView, currentChromeState)
  })

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

  loadPage(portalView, 'home')
  win.show()

  return win
}
