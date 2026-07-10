#!/usr/bin/env bash
# Generates the DTL mTLS test certificate chain.
# Output: ca.key, ca.pem, server.key, server.crt, client.key, client.crt, client.p12
# All files are git-ignored (lab/certs/*.key *.crt *.pem *.p12 *.srl *.csr).
# Re-run at any time to regenerate - existing files are overwritten.
set -euo pipefail
cd "$(dirname "$0")"

P12_PASS="dtltest"

echo "=== [1/5] Root CA ==="
openssl genrsa -out ca.key 4096
openssl req -x509 -new -key ca.key -sha256 -days 3650 \
  -subj "/CN=DTL-Test-Root-CA" -out ca.pem

echo "=== [2/5] Server cert (SAN required by modern Chromium — CN alone is ignored) ==="
openssl genrsa -out server.key 2048
openssl req -new -key server.key -subj "/CN=localhost" -out server.csr
# x509 -req does NOT copy CSR extensions; re-state via -extfile
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -days 825 -sha256 -out server.crt -extfile server.ext

echo "=== [3/5] Client cert (CN=DTL-Ubuntu-Test-Device, extendedKeyUsage=clientAuth) ==="
openssl genrsa -out client.key 2048
openssl req -new -key client.key -subj "/CN=DTL-Ubuntu-Test-Device" -out client.csr
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -days 825 -sha256 -out client.crt -extfile client.ext

echo "=== [4/5] PKCS#12 bundle (friendlyName becomes NSS nickname) ==="
# -name sets the friendlyName; NSS adopts this as the cert nickname (used in certutil -F -n)
openssl pkcs12 -export \
  -inkey client.key -in client.crt -certfile ca.pem \
  -name "DTL-Ubuntu-Test-Device" \
  -passout "pass:${P12_PASS}" \
  -out client.p12

echo "=== [5/5] Verification ==="
echo "--- Server SAN ---"
openssl x509 -in server.crt -noout -text | grep -A2 "Subject Alternative"
echo "--- Client EKU ---"
openssl x509 -in client.crt -noout -text | grep -A2 "Extended Key Usage"
echo "--- p12 integrity ---"
openssl pkcs12 -in client.p12 -noout -passin "pass:${P12_PASS}"

echo ""
echo "Done. Certs in: $(pwd)"
