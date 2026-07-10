import { shell } from 'electron'
import { startOidcFlow, exchangeCode, checkEmailDomain } from './oidc.js'
import { startLoopbackServer } from './loopback.js'
import { OIDC } from '../config.js'

/**
 * Run the full authorization-code + PKCE flow in the system browser.
 *
 * Opens the system browser (RFC 8252 §7.3 - never an embedded view), waits for the
 * loopback callback, exchanges the code for tokens, and checks the email-domain claim.
 *
 * Returns { client, tokenSet, claims, userinfoClaims, email, emailVerified, allowed }.
 * Throws on loopback timeout or token-exchange failure.
 */
export async function runLoginFlow() {
  const { client, authUrl, codeVerifier, state, nonce } = await startOidcFlow()

  const callbackPromise = startLoopbackServer(state)

  console.log('[auth] Opening system browser for login (RFC 8252 - NOT an embedded view)')
  await shell.openExternal(authUrl)
  console.log('[auth] Waiting for loopback callback on', OIDC.redirectUri, '...')

  const { code } = await callbackPromise
  console.log('[auth] Callback received - exchanging code')

  const { tokenSet, claims, userinfoClaims } = await exchangeCode(client, code, state, codeVerifier, nonce)
  const { email, emailVerified, allowed } = checkEmailDomain(claims, userinfoClaims)

  return { client, tokenSet, claims, userinfoClaims, email, emailVerified, allowed }
}
