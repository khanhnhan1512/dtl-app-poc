// Kill-command verifier — M3 Step 3.
// Pure logic; no Electron deps. Implements contracts/kill-command.md §5 verbatim.
// Verdict order: SIGNATURE CHECK FIRST (so forged/tampered fields are never acted on).
import { verify as cryptoVerify } from 'crypto'

export const Verdict = Object.freeze({
  VALID_WIPE:       'VALID_WIPE',
  VALID_NONE:       'VALID_NONE',
  BAD_SIGNATURE:    'BAD_SIGNATURE',
  NOT_THIS_DEVICE:  'NOT_THIS_DEVICE',
  STALE:            'STALE',
  ALREADY_EXECUTED: 'ALREADY_EXECUTED',
  UNKNOWN_ACTION:   'UNKNOWN_ACTION',
  MALFORMED:        'MALFORMED',
})

/**
 * Verify a fetched kill-command document against config and the ledger.
 *
 * @param {object} doc        - Parsed JSON from the control plane.
 * @param {object} config     - KILL config block (publicKeyPem, deviceId, issuedAtWindowMs).
 * @param {object} ledger     - { has(id): boolean } — checked for ALREADY_EXECUTED.
 * @returns {string}          - A Verdict constant.
 */
export function verifyKillCommand(doc, config, ledger) {
  // Step 1 — required fields present and correct types.
  const { action, command_id, device_id, issued_at, signature } = doc ?? {}
  if (
    typeof action     !== 'string' ||
    typeof command_id !== 'string' ||
    typeof device_id  !== 'string' ||
    !Number.isInteger(issued_at)   ||
    typeof signature  !== 'string'
  ) return Verdict.MALFORMED

  // Step 3 — reconstruct canonical bytes (§2: alphabetical keys, compact, UTF-8).
  // Key order: action < command_id < device_id < issued_at  (already alphabetical).
  const canonical = JSON.stringify({ action, command_id, device_id, issued_at })
  const canonicalBytes = Buffer.from(canonical, 'utf8')

  // Step 4 — decode signature.
  let sigBytes
  try { sigBytes = Buffer.from(signature, 'base64') }
  catch { return Verdict.MALFORMED }
  if (sigBytes.length !== 64) return Verdict.MALFORMED

  // Step 5 — Ed25519 verify (algorithm=null: no pre-hash, pure EdDSA per RFC 8032).
  // MUST run before semantic checks — forged fields must not be acted on.
  let sigValid = false
  try { sigValid = cryptoVerify(null, canonicalBytes, config.publicKeyPem, sigBytes) }
  catch { return Verdict.BAD_SIGNATURE }
  if (!sigValid) return Verdict.BAD_SIGNATURE

  // Step 6 — device targeting.
  if (device_id !== config.deviceId) return Verdict.NOT_THIS_DEVICE

  // Step 7 — freshness window.
  const ageMs = Date.now() - issued_at
  if (ageMs > config.issuedAtWindowMs) return Verdict.STALE

  // Step 8 — single-execution ledger.
  if (ledger.has(command_id)) return Verdict.ALREADY_EXECUTED

  // Step 9 — dispatch by action.
  if (action === 'wipe') return Verdict.VALID_WIPE
  if (action === 'none') return Verdict.VALID_NONE
  return Verdict.UNKNOWN_ACTION
}
