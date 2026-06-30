import { app, Menu, shell } from 'electron'
import { handleCertSelect } from './cert-select.js'
import { wipe } from './wipe.js'
import { createShell } from './window.js'
import { PRODUCT_NAME, OIDC } from './config.js'
import { startOidcFlow, exchangeCode, checkEmailDomain } from './auth/oidc.js'
import { startLoopbackServer } from './auth/loopback.js'

app.setName(PRODUCT_NAME)

if (process.env.NODE_ENV !== 'development') {
  Menu.setApplicationMenu(null)
}

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

  // Dev-only: run the OIDC round-trip and log results. No window, no token persistence.
  if (process.argv.includes('--login')) {
    try {
      const { client, authUrl, codeVerifier, state, nonce } = await startOidcFlow()

      // Start loopback listener BEFORE opening the browser.
      const callbackPromise = startLoopbackServer(state)

      // RFC 8252 §7.3 — login MUST happen in the system browser, never an embedded view.
      console.log('[login] Opening system browser for login (RFC 8252 — NOT an embedded view)')
      await shell.openExternal(authUrl)

      console.log('[login] Waiting for loopback callback on', OIDC.redirectUri, '...')
      const { code } = await callbackPromise
      console.log('[login] Callback received — exchanging code')

      const { claims, userinfoClaims } = await exchangeCode(client, code, state, codeVerifier, nonce)

      console.log('[login] id_token claims:', JSON.stringify(claims, null, 2))
      console.log('[login] userinfo claims:', JSON.stringify(userinfoClaims, null, 2))

      const { email, emailVerified, allowed } = checkEmailDomain(claims, userinfoClaims)
      console.log(`[login] email          : ${email}`)
      console.log(`[login] email_verified : ${emailVerified}`)
      console.log(`[login] allowed domain : @${OIDC.allowedEmailDomain}`)

      if (allowed) {
        console.log('[login] PASS — email domain check passed')
      } else {
        console.log('[login] REJECTED — email not verified or domain mismatch')
        process.exitCode = 1
      }
    } catch (err) {
      console.error('[login] FAILED', err.message)
      process.exitCode = 1
    }
    app.quit()
    return
  }

  createShell()
})
app.on('window-all-closed', () => app.quit())
