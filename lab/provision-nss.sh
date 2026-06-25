#!/usr/bin/env bash
# Imports the DTL test CA and client cert+key into the NSS shared DB (~/.pki/nssdb).
# Idempotent — safe to re-run; removes existing entries before re-importing.
# Prerequisite: run lab/certs/gen-certs.sh first.
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")/certs" && pwd)"
NSS_DB="sql:$HOME/.pki/nssdb"
P12_PASS="dtltest"

command -v certutil >/dev/null 2>&1 || { echo "ERROR: certutil not found. Install: sudo apt install libnss3-tools"; exit 1; }
command -v pk12util  >/dev/null 2>&1 || { echo "ERROR: pk12util not found.  Install: sudo apt install libnss3-tools"; exit 1; }

# Create NSS DB if it doesn't already exist
if [ ! -d "$HOME/.pki/nssdb" ]; then
  mkdir -p "$HOME/.pki/nssdb"
  certutil -N -d "$NSS_DB" --empty-password
  echo "NSS DB created at ~/.pki/nssdb"
fi

# --- Root CA ---
# Remove existing entry first (idempotent); certutil -D removes cert only (no key for CAs)
certutil -D -n "DTL-Test-Root-CA" -d "$NSS_DB" 2>/dev/null || true
certutil -A -n "DTL-Test-Root-CA" -t "CT,C,C" -a -i "$CERT_DIR/ca.pem" -d "$NSS_DB"
# Trust flags: CT,C,C = SSL:trusted-CA-for-server+client / email:CA / objsign:CA
echo "CA imported (trust CT,C,C)."

# --- Client cert + private key ---
# Use certutil -F (not -D) to remove BOTH the cert AND the private key atomically.
# certutil -D alone would orphan the key in the NSS DB.
certutil -F -n "DTL-Ubuntu-Test-Device" -d "$NSS_DB" 2>/dev/null || true
pk12util -i "$CERT_DIR/client.p12" -d "$NSS_DB" -W "$P12_PASS"
echo "Client cert+key imported (nickname: DTL-Ubuntu-Test-Device)."

echo ""
echo "=== NSS certs ==="
certutil -L -d "$NSS_DB"
echo ""
echo "=== NSS keys ==="
certutil -K -d "$NSS_DB" 2>&1 || true
