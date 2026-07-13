#!/usr/bin/env bash
# Sign a kill command: canonical bytes are the compact, alphabetically-keyed JSON of
# {action, command_id, device_id, issued_at}, signed with Ed25519 (64-byte sig, base64-encoded).
#
# Usage:
#   ./sign-command.sh <device_id> <command_id> <action> [issued_at_ms]
#
#   action      : "none" or "wipe"
#   issued_at_ms: epoch milliseconds (default: now)
#
# Output: signed kill-command JSON printed to stdout.
# Example:
#   ./sign-command.sh DTL-Ubuntu-Test-Device cmd-001 wipe 2>/dev/null > kill-wipe.json
#   ./sign-command.sh DTL-Ubuntu-Test-Device cmd-002 none 2>/dev/null > kill-none.json
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEVICE_ID="${1:?Usage: sign-command.sh <device_id> <command_id> <action> [issued_at_ms]}"
COMMAND_ID="${2:?}"
ACTION="${3:?}"
ISSUED_AT="${4:-}"

if [[ "$ACTION" != "none" && "$ACTION" != "wipe" ]]; then
  echo "action must be 'none' or 'wipe'" >&2; exit 1
fi

PRIV="$SCRIPT_DIR/kill-signing.key"
if [[ ! -f "$PRIV" ]]; then
  echo "kill-signing.key not found. Run gen-keypair.sh first." >&2; exit 1
fi

# Produce the signed JSON document via Node.
node - "$DEVICE_ID" "$COMMAND_ID" "$ACTION" "$ISSUED_AT" "$PRIV" <<'NODESCRIPT'
const { sign } = require('crypto')
const { readFileSync } = require('fs')

const [,, device_id, command_id, action, issued_at_arg, keyPath] = process.argv

const issued_at = issued_at_arg ? parseInt(issued_at_arg, 10) : Date.now()

// Canonical bytes: compact JSON, keys in ascending alphabetical order.
// Key order: action < command_id < device_id < issued_at  (already alphabetical).
const canonical = JSON.stringify({ action, command_id, device_id, issued_at })
const canonicalBytes = Buffer.from(canonical, 'utf8')

const privateKeyPem = readFileSync(keyPath, 'utf8')

// Ed25519: algorithm=null (no pre-hash - EdDSA uses its own internal digest).
const sigBytes = sign(null, canonicalBytes, privateKeyPem)
const signature = sigBytes.toString('base64')

const doc = { action, command_id, device_id, issued_at, signature }
process.stdout.write(JSON.stringify(doc, null, 2) + '\n')

// Sanity check: log canonical bytes to stderr so the user can confirm.
process.stderr.write('[sign] canonical bytes: ' + canonical + '\n')
process.stderr.write('[sign] signature (' + sigBytes.length + ' bytes): ' + signature.substring(0, 20) + '...\n')
NODESCRIPT

# JSON files that nginx serves must be world-readable (nginx runs as uid 101 inside the
# container, not root) - AND the containing directory itself must be traversable by "other",
# or nginx's open() fails with 403/Permission-denied even though the file is 644 (confirmed on
# a rootless-podman VM: the bind mount preserves this directory's permission bits, and if it
# has no traversal bit for "other", the uid-101 worker can't reach the file at all). Only the
# traversal (x) bit is added here, never read/list - do NOT "simplify" this to o+rx, that would
# expose the directory listing (kill-signing.key's own 600 mode stays protected either way, but
# there's no reason to make its filename visible).
chmod o+x "$SCRIPT_DIR" 2>/dev/null || true
for f in "$SCRIPT_DIR/kill-none.json" "$SCRIPT_DIR/kill-wipe.json" "$SCRIPT_DIR/kill-command.json"; do
  [[ -f "$f" ]] && chmod 644 "$f" 2>/dev/null || true
done
