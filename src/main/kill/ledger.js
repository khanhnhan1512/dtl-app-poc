// Executed command_id ledger.
// Persists executed command_ids to a plain JSON array in userData/kill-ledger.json.
// NOT secret - purely an idempotency record. Survives restarts so a re-served
// command_id is never re-executed on the same device after recovery.
import { app } from 'electron'
import { readFileSync, writeFileSync, existsSync } from 'fs'
import { join } from 'path'

function ledgerPath() {
  return join(app.getPath('userData'), 'kill-ledger.json')
}

function load() {
  const p = ledgerPath()
  if (!existsSync(p)) return []
  try { return JSON.parse(readFileSync(p, 'utf8')) }
  catch { return [] }
}

function save(ids) {
  writeFileSync(ledgerPath(), JSON.stringify(ids), 'utf8')
}

export function has(commandId) {
  return load().includes(commandId)
}

export function record(commandId) {
  const ids = load()
  if (!ids.includes(commandId)) {
    ids.push(commandId)
    save(ids)
    console.log('[kill-ledger] recorded command_id:', commandId)
  }
}
