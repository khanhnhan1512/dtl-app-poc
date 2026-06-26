#!/usr/bin/env bash
# Re-injects the DTL client cert+key into NSS after a wipe.
# Idempotent — safe to re-run. The CA (DTL-Test-Root-CA) is NOT touched (it survives a wipe).
# Prerequisite: run lab/certs/gen-certs.sh first to generate client.p12.
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")/certs" && pwd)"
NSS_DB="sql:$HOME/.pki/nssdb"
P12_PASS="dtltest"

command -v certutil >/dev/null 2>&1 || { echo "ERROR: certutil not found. Install: sudo apt install libnss3-tools"; exit 1; }
command -v pk12util  >/dev/null 2>&1 || { echo "ERROR: pk12util not found.  Install: sudo apt install libnss3-tools"; exit 1; }

# Remove any leftover (idempotent) then re-import the .p12 bundle
certutil -F -n "DTL-Ubuntu-Test-Device" -d "$NSS_DB" 2>/dev/null || true
pk12util -i "$CERT_DIR/client.p12" -d "$NSS_DB" -W "$P12_PASS"
echo "Client cert+key re-imported (nickname: DTL-Ubuntu-Test-Device)."

echo ""
echo "=== NSS certs ==="
certutil -L -d "$NSS_DB"
echo ""
echo "=== NSS keys ==="
certutil -K -d "$NSS_DB" 2>&1 || true
