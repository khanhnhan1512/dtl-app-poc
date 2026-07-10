// Kill-switch poller (launch + periodic interval).
// Fetches the control-plane endpoint, verifies the signed command, dispatches.
// FAIL-OPEN: unreachable control plane is logged and ignored.
// Endpoint is https://localhost:8444/kill (non-mTLS, lab CA trusted explicitly).
// Post-kill the app quits; locked-out state surfaces on next relaunch.
import { app } from 'electron'
import { request as httpsRequest } from 'https'
import { readFileSync } from 'fs'
import { resolve } from 'path'
import { KILL } from '../config.js'
import { verifyKillCommand, Verdict } from './verify.js'
import * as ledger from './ledger.js'
import { wipe } from '../wipe.js'

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
      ca: caPem,       // trust ONLY this CA - NOT rejectUnauthorized:false
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
 * Fetch, parse, verify, and dispatch the verdict once.
 * VALID_WIPE -> record command_id -> wipe() -> quit.
 * All reject paths and VALID_NONE: log only, no side effects.
 */
export async function checkKillOnce() {
  console.log('[kill] checkKillOnce — fetching', KILL.url)
  let body
  try {
    body = await fetchKillCommand()
  } catch (err) {
    // Fail-open; unreachable control plane is never destructive.
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
    case Verdict.VALID_WIPE: {
      // Idempotency: record BEFORE the destructive call so a crash/race after wipe()
      // but before quit() cannot re-execute the same command_id after recovery.
      ledger.record(doc.command_id)
      console.log('[kill] VALID_WIPE — executing wipe (session + cert + tokens)')
      try {
        const result = await wipe()
        console.log('[kill] wipe() result:', result)
      } catch (err) {
        console.error('[kill] wipe() threw:', err.message)
      }
      // Quit after wipe; locked-out state surfaces on next relaunch via the auth gate
      // (no token -> forced re-login) and mTLS (no cert -> nginx 400).
      console.log('[kill] kill complete — quitting app')
      app.quit()
      return
    }
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

/**
 * Start the kill-switch poller: one immediate check at launch, then a periodic interval.
 * Overlap guard: if a tick is still in flight when the next interval fires, that tick is
 * skipped - preventing stacked async calls on a slow/hung control plane.
 * After VALID_WIPE fires app.quit() the interval is moot; no explicit clearInterval needed.
 */
export function startKillPoller() {
  let running = false

  async function tick() {
    if (running) {
      console.log('[kill] poller tick skipped — previous check still in flight')
      return
    }
    running = true
    try { await checkKillOnce() }
    finally { running = false }
  }

  // Immediate launch check (no await - returns to caller; interval fires later).
  tick()
  setInterval(tick, KILL.pollIntervalMs)
  console.log('[kill] poller started — interval', KILL.pollIntervalMs, 'ms')
}
