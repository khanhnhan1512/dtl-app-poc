import { app, Menu } from 'electron'
import { handleCertSelect } from './cert-select.js'
import { wipe } from './wipe.js'
import { createShell } from './window.js'
import { PRODUCT_NAME, OIDC } from './config.js'
import { getOidcClient } from './auth/oidc.js'
import { runLoginFlow } from './auth/login-flow.js'
import { logBackend, save, getValidAccessToken, load as loadTokens } from './auth/token-store.js'
import { startKillPoller } from './kill/poller.js'

app.setName(PRODUCT_NAME)

if (process.env.NODE_ENV !== 'development') {
  Menu.setApplicationMenu(null)
}

app.on('select-client-certificate', handleCertSelect)

/**
 * Ensure a valid access token exists before the shell is created.
 * - Valid stored token  -> returns { ok: true, email } immediately (warm start, no browser).
 * - No/expired token   -> runs the full OIDC flow in the system browser, persists the
 *                        new token set, and returns { ok: true, email }.
 * - Domain rejected / flow failure / save failure -> returns { ok: false, email: null }.
 *
 * createShell() is only called when ok is true.
 * email is used for session-identity surfacing (observability only, not a security boundary).
 */
async function ensureAuthenticated() {
  logBackend()
  console.log('[auth] userData path:', app.getPath('userData'))

  // Discover once - the client is reused for both refresh and (if needed) the new flow.
  const client = await getOidcClient()

  const accessToken = await getValidAccessToken(client)
  if (accessToken) {
    console.log('[auth] Valid stored token - no login required (warm start)')
    // Read email from the persisted token payload (stored at cold login by save(tokenSet, email)).
    const email = loadTokens()?.email ?? null
    return { ok: true, email }
  }

  console.log('[auth] No valid token - starting OIDC flow')
  try {
    const { tokenSet, email, allowed } = await runLoginFlow()
    if (!allowed) {
      console.error('[auth] REJECTED - email domain mismatch:', email)
      return { ok: false, email: null }
    }
    console.log('[auth] PASS -', email)
    save(tokenSet, email)   // persist email alongside tokens for warm-start reads
    return { ok: true, email }
  } catch (err) {
    console.error('[auth] Login flow failed:', err.message)
    return { ok: false, email: null }
  }
}

app.whenReady().then(async () => {
  // Dev: wipe.
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

  // Dev: OIDC round-trip + token persistence + reload verification. No app window.
  if (process.argv.includes('--login')) {
    try {
      logBackend()
      console.log('[login] userData path:', app.getPath('userData'))

      const { client, tokenSet, claims, userinfoClaims, email, emailVerified, allowed } =
        await runLoginFlow()

      // Verbose diagnostics - kept for dev/debug purposes.
      console.log('[login] id_token claims:', JSON.stringify(claims, null, 2))
      console.log('[login] userinfo claims:', JSON.stringify(userinfoClaims, null, 2))
      console.log(`[login] email          : ${email}`)
      console.log(`[login] email_verified : ${emailVerified}`)
      console.log(`[login] allowed domain : @${OIDC.allowedEmailDomain}`)

      if (allowed) {
        console.log('[login] PASS - email domain check passed')
        save(tokenSet)
        const storedToken = await getValidAccessToken(client)
        if (storedToken) {
          console.log('[login] getValidAccessToken: returned valid token from store')
        } else {
          console.log('[login] getValidAccessToken: returned null (unexpected)')
          process.exitCode = 1
        }
      } else {
        console.log('[login] REJECTED - email not verified or domain mismatch')
        process.exitCode = 1
      }
    } catch (err) {
      console.error('[login] FAILED', err.message)
      process.exitCode = 1
    }
    app.quit()
    return
  }

  // Normal launch: gate portal on authentication.
  const { ok: authenticated, email: sessionEmail } = await ensureAuthenticated()
  if (!authenticated) {
    console.error('[auth] Authentication failed - portal will not load')
    app.quit()
    return
  }

  // The did-navigate identity hook lives in window.js - it covers any TOOLS host (not just a
  // single fixed home URL) and also drives the chrome bar state.
  createShell({ userEmail: sessionEmail })

  // Start the periodic kill-command poller (immediate check + interval).
  startKillPoller()
})

app.on('window-all-closed', () => app.quit())
