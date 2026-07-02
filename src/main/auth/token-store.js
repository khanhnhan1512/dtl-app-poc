import { safeStorage, app } from 'electron'
import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'fs'
import { join } from 'path'
import { refresh as oidcRefresh } from './oidc.js'

const TOKENS_FILENAME = 'tokens.enc'
const SKEW_MS = 30_000 // treat token as expired 30 s early to avoid clock-edge races

function tokensPath() {
  return join(app.getPath('userData'), TOKENS_FILENAME)
}

// Diagnostic: log backend state. Does NOT gate anything — purely informational.
export function logBackend() {
  const available = safeStorage.isEncryptionAvailable()
  const backend   = safeStorage.getSelectedStorageBackend()
  console.log('[token-store] logBackend() — storage backend      :', backend)
  console.log('[token-store] logBackend() — encryption available :', available)
}

/**
 * Persist tokens encrypted by safeStorage to userData/tokens.enc.
 *
 * DIAGNOSTIC version: does NOT pre-check isEncryptionAvailable() before calling
 * encryptString(). Logs both values independently to determine whether they
 * are consistent. This disambiguates the "is it a timing issue?" question.
 *
 * If encryptString() throws → re-throw so the caller can report FAILED with full detail.
 *
 * @param {object} tokenSet - The token set from openid-client.
 * @param {string} [email]  - User email from userinfo. Optional: if omitted (e.g. on
 *   token refresh, which returns no userinfo), the previously stored email is preserved.
 */
export function save(tokenSet, email) {
  // Sample both values at save() time — which is well inside app.whenReady(), after OIDC
  // completes. This is the LATEST possible point we could call these.
  const available = safeStorage.isEncryptionAvailable()
  const backend   = safeStorage.getSelectedStorageBackend()
  console.log('[token-store] save() — backend            :', backend)
  console.log('[token-store] save() — isEncryptionAvailable :', available)

  const expiresAt = tokenSet.expires_at
    ? tokenSet.expires_at * 1000                            // openid-client: seconds → ms
    : Date.now() + (tokenSet.expires_in ?? 3600) * 1000

  // Preserve existing email on refresh (email is not returned by the refresh grant).
  // If the caller supplies email, use it; otherwise carry forward whatever is stored.
  const resolvedEmail = email ?? load()?.email ?? null

  const payload = JSON.stringify({
    access:    tokenSet.access_token,
    refresh:   tokenSet.refresh_token ?? null,
    id:        tokenSet.id_token ?? null,
    expiresAt,
    email:     resolvedEmail,
  })

  // DIAGNOSTIC: call encryptString() unconditionally and observe the result.
  // If it throws even when isEncryptionAvailable()=false → they are consistent (no timing gap).
  // If it succeeds despite isEncryptionAvailable()=false → the gate was wrong; keep this path.
  let encrypted
  try {
    encrypted = safeStorage.encryptString(payload)
    console.log('[token-store] save() — encryptString() SUCCEEDED,', encrypted.length, 'bytes')
  } catch (err) {
    console.error('[token-store] save() — encryptString() THREW:', err.message)
    console.error('[token-store] DIAGNOSTIC RESULT: backend=' + backend +
                  ' | isEncryptionAvailable=' + available +
                  ' | encryptString threw — consistent, not a timing issue.')
    throw err
  }

  const path = tokensPath()
  writeFileSync(path, encrypted)
  console.log('[token-store] tokens.enc written to', path)
  console.log('[token-store] expiresAt            :', new Date(expiresAt).toISOString())
}

/** Return the decrypted token object, or null if missing/unreadable. */
export function load() {
  const path = tokensPath()
  if (!existsSync(path)) return null
  if (!safeStorage.isEncryptionAvailable()) {
    console.warn('[token-store] load() — safeStorage unavailable; clearing tokens.enc')
    clearTokens()
    return null
  }
  try {
    const buf  = readFileSync(path)
    const json = safeStorage.decryptString(buf)
    return JSON.parse(json)
  } catch (err) {
    console.warn('[token-store] load() — failed:', err.message)
    clearTokens()
    return null
  }
}

/** Delete tokens.enc — called by wipe() and on refresh failure. */
export function clearTokens() {
  try {
    unlinkSync(tokensPath())
    console.log('[token-store] tokens.enc deleted')
  } catch (err) {
    if (err.code !== 'ENOENT') console.warn('[token-store] clearTokens error:', err.message)
  }
}

/**
 * Return a valid access token, refreshing transparently if needed.
 * Returns null when there are no stored tokens or refresh fails (→ triggers re-auth in Step 4).
 */
export async function getValidAccessToken(client) {
  const tokens = load()
  if (!tokens) {
    console.log('[token-store] getValidAccessToken: no stored tokens')
    return null
  }

  if (Date.now() < tokens.expiresAt - SKEW_MS) {
    console.log('[token-store] getValidAccessToken: token valid until', new Date(tokens.expiresAt).toISOString())
    return tokens.access
  }

  if (tokens.refresh) {
    console.log('[token-store] getValidAccessToken: access token expired — refreshing')
    try {
      const newTokenSet = await oidcRefresh(client, tokens.refresh)
      save(newTokenSet) // rotated refresh token — MUST overwrite
      console.log('[token-store] getValidAccessToken: refresh succeeded')
      return newTokenSet.access_token
    } catch (err) {
      console.warn('[token-store] getValidAccessToken: refresh failed —', err.message)
      clearTokens()
      return null
    }
  }

  console.log('[token-store] getValidAccessToken: token expired, no refresh token — clearing')
  clearTokens()
  return null
}
