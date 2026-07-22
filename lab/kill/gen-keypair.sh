#!/usr/bin/env bash
# Generate a fresh Ed25519 signing keypair for the kill-switch lab.
# Private key -> lab/kill/kill-signing.key  (git-ignored - NEVER commit)
# Public key  -> lab/kill/kill-signing.pub  (git-ignored - per-machine, NOT committed)
#
# Run once per dev box. If you regenerate the key, you MUST re-sign all kill commands.
# lab/setup.sh normally does both automatically and injects the fresh public key into the app
# via DTL_KILL_PUBLIC_KEY_PEM (see lab/.runtime-env); src/main/config.js's hardcoded PEM is only
# a fallback for launches without that variable set.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PRIV="$SCRIPT_DIR/kill-signing.key"
PUB="$SCRIPT_DIR/kill-signing.pub"

if [[ -f "$PRIV" ]]; then
  echo "kill-signing.key already exists. Delete it first if you want to regenerate." >&2
  exit 1
fi

if [[ "$(uname)" == "Darwin" ]]; then
  # macOS ships an ancient LibreSSL as /usr/bin/openssl with no `genpkey -algorithm ed25519`
  # support at all (confirmed - fails with "Algorithm ed25519 not found"). Postgres.app bundles
  # modern libssl/libcrypto (3.x) but no openssl CLI binary to invoke - just headers/libs meant
  # for linking Postgres itself, not scripted use - so there's no simpler "use a newer openssl"
  # option here. sign-command.sh and verify.js already do all actual signing/verification via
  # Node's crypto module, so this uses the same tool for key generation too, on macOS only.
  # Node's generateKeyPairSync produces the same standard PKCS8/SPKI PEM shapes openssl would
  # have, so nothing downstream needed to change. The Linux path below is untouched.
  node - "$PRIV" "$PUB" <<'NODESCRIPT'
const { generateKeyPairSync } = require('crypto')
const { writeFileSync } = require('fs')

const [, , privPath, pubPath] = process.argv

const { publicKey, privateKey } = generateKeyPairSync('ed25519', {
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
})

writeFileSync(privPath, privateKey, { mode: 0o600 })
writeFileSync(pubPath, publicKey)
NODESCRIPT
else
  openssl genpkey -algorithm ed25519 -out "$PRIV"
  chmod 600 "$PRIV"
  openssl pkey -in "$PRIV" -pubout -out "$PUB"
fi

echo "Keypair generated:"
echo "  private: $PRIV  (git-ignored)"
echo "  public : $PUB   (git-ignored; injected into the app via DTL_KILL_PUBLIC_KEY_PEM)"
