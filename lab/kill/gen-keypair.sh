#!/usr/bin/env bash
# Generate a fresh Ed25519 signing keypair for the M3 kill-switch lab.
# Private key → lab/kill/kill-signing.key  (git-ignored — NEVER commit)
# Public key  → lab/kill/kill-signing.pub  (committed — shipped in the app)
#
# Run once per dev box. If you regenerate the key, you MUST re-sign all kill commands
# AND update the hardcoded publicKeyPem in src/main/config.js.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PRIV="$SCRIPT_DIR/kill-signing.key"
PUB="$SCRIPT_DIR/kill-signing.pub"

if [[ -f "$PRIV" ]]; then
  echo "kill-signing.key already exists. Delete it first if you want to regenerate." >&2
  exit 1
fi

openssl genpkey -algorithm ed25519 -out "$PRIV"
chmod 600 "$PRIV"
openssl pkey -in "$PRIV" -pubout -out "$PUB"

echo "Keypair generated:"
echo "  private: $PRIV  (git-ignored)"
echo "  public : $PUB   (committed; hardcode into src/main/config.js KILL.publicKeyPem)"
