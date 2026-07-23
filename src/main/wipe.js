import { session } from 'electron'
import { spawn } from 'child_process'
import { join } from 'path'
import os from 'os'
import { CERT_SUBJECT_CN } from './config.js'
import { clearTokens } from './auth/token-store.js'

function runCertutil(args) {
  return new Promise((resolve, reject) => {
    const proc = spawn('certutil', args, { stdio: 'pipe' })
    let stderr = ''
    proc.stderr.on('data', (d) => { stderr += d.toString() })
    proc.on('error', reject)
    proc.on('close', (code) => {
      if (code === 0) resolve()
      else reject(new Error(`certutil exited ${code}: ${stderr.trim()}`))
    })
  })
}

// macOS equivalent of runCertutil - same shape (spawn, capture stderr, reject on non-zero exit).
function runSecurityDeleteIdentity(cn) {
  return new Promise((resolve, reject) => {
    const proc = spawn('security', ['delete-identity', '-c', cn, '-t'], { stdio: 'pipe' })
    let stderr = ''
    proc.stderr.on('data', (d) => { stderr += d.toString() })
    proc.on('error', reject)
    proc.on('close', (code) => {
      if (code === 0) resolve()
      else reject(new Error(`security delete-identity exited ${code}: ${stderr.trim()}`))
    })
  })
}

/**
 * Full device wipe - three clauses, executed in order:
 *
 *   (a) Electron session data (storage, cache, auth cache) on defaultSession.
 *       NOTE: portal runs on defaultSession (no partition).
 *       IF a session.fromPartition() is ever added, wipe() MUST also clear that
 *       partition here - otherwise cookies/storage in that partition survive the wipe.
 *
 *   (b) Client cert + private key, platform-specific store:
 *       - Linux: NSS via certutil -F (removes key AND cert atomically). NEVER use -D - it
 *         removes only the cert, orphaning the private key in NSS.
 *       - macOS: Keychain via security delete-identity -t (removes cert AND key atomically,
 *         same reasoning). NEVER use security delete-certificate - same orphaning trap as -D.
 *
 *   (c) Encrypted token file (userData/tokens.enc) via token-store.clearTokens().
 *       Covers OIDC access/refresh tokens stored by safeStorage.
 *
 * Returns { sessionCleared, certDeleted, tokensCleared }.
 * UI-agnostic - callable from the --wipe dev flag and the signed kill command.
 */
export async function wipe() {
  console.log('[wipe] Starting wipe...')

  // (a) Electron session data
  await session.defaultSession.clearStorageData()
  console.log('[wipe] Cleared storage data.')
  await session.defaultSession.clearCache()
  console.log('[wipe] Cleared cache.')
  await session.defaultSession.clearAuthCache()
  console.log('[wipe] Cleared auth cache.')

  // (b) Client cert + private key - platform-specific store, must delete atomically on both.
  // Isolated in its own try/catch on both branches: cert deletion is the most environment-fragile
  // step (external process, OS-cert-store-specific) and its failure must not prevent (c) from
  // running - otherwise a failed cert delete leaves the OIDC tokens behind, which defeats the
  // point of the kill switch.
  let certDeleted = false
  if (process.platform === 'darwin') {
    try {
      await runSecurityDeleteIdentity(CERT_SUBJECT_CN)
      console.log(`[wipe] Deleted identity "${CERT_SUBJECT_CN}" from Keychain.`)
      certDeleted = true
    } catch (err) {
      console.error(`[wipe] FAILED to delete identity "${CERT_SUBJECT_CN}" from Keychain:`, err.message)
    }
  } else {
    const nssdb = `sql:${join(os.homedir(), '.pki', 'nssdb')}`
    try {
      await runCertutil(['-F', '-n', CERT_SUBJECT_CN, '-d', nssdb])
      console.log(`[wipe] Deleted cert+key "${CERT_SUBJECT_CN}" from NSS (${nssdb}).`)
      certDeleted = true
    } catch (err) {
      console.error(`[wipe] FAILED to delete cert+key from NSS (${nssdb}):`, err.message)
    }
  }

  // (c) OIDC tokens - delete userData/tokens.enc
  clearTokens()
  console.log('[wipe] Cleared OIDC token store.')

  const result = { sessionCleared: true, certDeleted, tokensCleared: true }
  console.log('[wipe] Done.', result)
  return result
}
