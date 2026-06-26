# DTL mTLS Test Lab

Local HTTPS test endpoints for M0 spike verification. All scripts are idempotent.

## Run order

```
# 1. Generate certs (once per machine)
bash lab/certs/gen-certs.sh

# 2. Start nginx container (two server blocks: :8443 mTLS on, :8444 mTLS optional)
podman run -d --name dtl-mtls-nginx \
  -p 8443:8443 -p 8444:8444 \
  -v ~/Downloads/dtl-app/lab/nginx/mtls.conf:/etc/nginx/conf.d/default.conf:ro,Z \
  -v ~/Downloads/dtl-app/lab/certs:/etc/nginx/certs:ro,Z \
  nginx:alpine

# 3. Import CA + client cert into NSS (~/.pki/nssdb)
bash lab/provision-nss.sh

# 4. (After a wipe) Re-inject client cert only (CA survives the wipe)
bash lab/reprovision-cert.sh
```

## Verify (curl)

```bash
cd lab/certs
# WITH cert → :8443 (expect verify=SUCCESS)
curl -s --cacert ca.pem --cert client.crt --key client.key https://localhost:8443/

# NO cert → :8443 (expect HTTP 400)
curl -s -o /dev/null -w "HTTP %{http_code}\n" --cacert ca.pem https://localhost:8443/

# NO cert → :8444 (expect verify=NONE)
curl -s --cacert ca.pem https://localhost:8444/
```
