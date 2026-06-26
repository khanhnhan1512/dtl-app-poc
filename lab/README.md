# DTL mTLS Test Lab

Local HTTPS test endpoints for M0 spike + M1 Step 2 navigation verification. All scripts are idempotent.

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

# Nav-test page (M1 Step 2) — with cert → :8443/nav (expect HTML with test links)
curl -s --cacert ca.pem --cert client.crt --key client.key https://localhost:8443/nav | grep -o '<title>.*</title>'
```

## Navigation test page (M1 Step 2)

`https://localhost:8443/nav` serves a page with four links to exercise the default-deny allow-list:

| Link | Expected behaviour |
|---|---|
| Same-host `/nav` | Loads in the same window (allow-listed) |
| `https://localhost:8444/` | Page stays put; `[nav] BLOCKED` logged (not in NAV_ALLOWLIST) |
| `https://example.com/` | Page stays put; `[nav] BLOCKED` logged (blocked before any network call) |
| Same-host `_blank` | Loads in the same view — no new window (setWindowOpenHandler deny) |

**nginx restart required** when `mtls.conf` changes (conf is read at startup, not hot-reloaded):
```bash
podman stop dtl-mtls-nginx && podman rm dtl-mtls-nginx
podman run -d --name dtl-mtls-nginx \
  -p 8443:8443 -p 8444:8444 \
  -v ~/Downloads/dtl-app/lab/nginx/mtls.conf:/etc/nginx/conf.d/default.conf:ro,Z \
  -v ~/Downloads/dtl-app/lab/certs:/etc/nginx/certs:ro,Z \
  nginx:alpine
```
