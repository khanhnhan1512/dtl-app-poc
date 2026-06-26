import { session } from 'electron'
import { spawn } from 'child_process'
import { join } from 'path'
import os from 'os'
import { CERT_SUBJECT_CN } from './config.js'

function runCertutil(args) {
  return new Promise((resolve, reject) => {
    const proc = spawn('certutil', args, { stdio: 'pipe' })
    let stderr = ''
    proc.stderr.on('data', (d) => { stderr += d.toString() })
    proc.on('close', (code) => {
      if (code === 0) resolve()
      else reject(new Error(`certutil exited ${code}: ${stderr.trim()}`))
    })
  })
}

export async function wipe() {
  console.log('[wipe] Starting wipe...')

  // (a) Electron session data
  await session.defaultSession.clearStorageData()
  console.log('[wipe] Cleared storage data.')
  await session.defaultSession.clearCache()
  console.log('[wipe] Cleared cache.')
  await session.defaultSession.clearAuthCache()
  console.log('[wipe] Cleared auth cache.')

  // (b) NSS client cert + private key — must use -F (removes key AND cert atomically)
  const nssdb = `sql:${join(os.homedir(), '.pki', 'nssdb')}`
  await runCertutil(['-F', '-n', CERT_SUBJECT_CN, '-d', nssdb])
  console.log(`[wipe] Deleted cert+key "${CERT_SUBJECT_CN}" from NSS (${nssdb}).`)

  const result = { sessionCleared: true, certDeleted: true, nickname: CERT_SUBJECT_CN }
  console.log('[wipe] Done.', result)
  return result
}
