// Kill-switch poller — M3 Step 3 (verdict log only; wipe wired in Step 4).
// Fetches the control-plane endpoint, verifies the signed command, and logs the verdict.
// D-M3-8: FAIL-OPEN — unreachable control plane is logged and ignored.
// D-M3-9: endpoint is https://localhost:8444/kill (non-mTLS, lab CA trusted explicitly).
import { request as httpsRequest } from 'https'
import { readFileSync } from 'fs'
import { resolve } from 'path'
import { KILL } from '../config.js'
import { verifyKillCommand, Verdict } from './verify.js'
import * as ledger from './ledger.js'

/** Fetch the kill-command URL using the lab CA for TLS trust. Returns the raw body string. */
function fetchKillCommand() {
  return new Promise((resolve_, reject) => {
    let caPem
    try {
      // caPath is relative to the repo root (process.cwd()), or absolute.
      const caAbsPath = resolve(process.cwd(), KILL.caPath)
      caPem = readFileSync(caAbsPath, 'utf8')
    } catch (err) {
      reject(new Error(`Cannot read lab CA at ${KILL.caPath}: ${err.message}`))
      return
    }

    const url = new URL(KILL.url)
    const options = {
      hostname: url.hostname,
      port: url.port || 443,
      path: url.pathname,
      method: 'GET',
      ca: caPem,       // trust ONLY this CA — NOT rejectUnauthorized:false
      timeout: 5000,
    }

    const req = httpsRequest(options, (res) => {
      let body = ''
      res.on('data', (chunk) => { body += chunk })
      res.on('end', () => resolve_(body))
    })
    req.on('error', reject)
    req.on('timeout', () => { req.destroy(); reject(new Error('request timed out')) })
    req.end()
  })
}

/**
 * Fetch, parse, verify, and LOG the verdict once.
 * Step 3: logs only — does NOT call wipe(). Step 4 wires the real wipe.
 */
export async function checkKillOnce() {
  console.log('[kill] checkKillOnce — fetching', KILL.url)
  let body
  try {
    body = await fetchKillCommand()
  } catch (err) {
    // D-M3-8: fail-open; unreachable control plane is never destructive.
    console.log('[kill] control plane unreachable — ignoring (fail-open):', err.message)
    return
  }

  let doc
  try { doc = JSON.parse(body) }
  catch {
    console.warn('[kill] response is not valid JSON — ignoring')
    return
  }

  const verdict = verifyKillCommand(doc, KILL, ledger)
  console.log('[kill] command_id:', doc?.command_id, '| action:', doc?.action, '| verdict:', verdict)

  switch (verdict) {
    case Verdict.VALID_WIPE:
      // Step 3: log only. Step 4 wires the real wipe behind this verdict.
      console.log('[kill] WOULD WIPE (Step 4 wires the real wipe)')
      break
    case Verdict.VALID_NONE:
      console.log('[kill] no command (action:none) — app continues normally')
      break
    case Verdict.BAD_SIGNATURE:
      console.warn('[kill] REJECTED — bad signature (tampered or wrong key)')
      break
    case Verdict.NOT_THIS_DEVICE:
      console.warn('[kill] REJECTED — not this device (device_id mismatch)')
      break
    case Verdict.STALE:
      console.warn('[kill] REJECTED — stale (issued_at outside window)')
      break
    case Verdict.ALREADY_EXECUTED:
      console.warn('[kill] REJECTED — already executed (command_id in ledger)')
      break
    case Verdict.UNKNOWN_ACTION:
      console.warn('[kill] REJECTED — unknown action:', doc?.action)
      break
    case Verdict.MALFORMED:
      console.warn('[kill] REJECTED — malformed document')
      break
    default:
      console.warn('[kill] REJECTED — unhandled verdict:', verdict)
  }
}
