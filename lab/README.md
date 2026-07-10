# DTL mTLS Test Lab

Local HTTPS test endpoints for mTLS and navigation verification. All scripts are idempotent.

## One-command bring-up (preferred)

```bash
bash lab/setup.sh      # certs -> NSS -> nginx(:8443/:8444/:8445) -> Postgres -> Zitadel -> auto-seed app+user
bash lab/run-app.sh    # launch the app (NoMachine DESKTOP terminal) - one command, no keyring prompt
bash lab/teardown.sh   # remove all app/test traces (keeps prerequisites: node/podman/libnss3-tools/...)
```

`setup.sh` stands up the whole lab AND auto-seeds Zitadel (Project + Native PKCE App +
`testuser@dtl.local`) with **zero web-console clicks**, writing the fresh `client_id` into
`lab/.runtime-env` (git-ignored). `run-app.sh` then sources that env and unlocks the OS keyring
**silently** (empty password - no "Unlock Keyring" dialog; it keeps real `gnome_libsecret`
encryption, it does NOT downgrade to `--password-store=basic`). **First `setup.sh` run is a
one-way door** - it destroys any existing Zitadel instance (and clears the OS login
keyring) and re-seeds from scratch.

The manual step-by-step below is kept as reference / fallback for machines where `setup.sh` can't run.

## Run order (manual - fallback)

```bash
# 1. Generate certs (once per machine)
bash lab/certs/gen-certs.sh

# 2. Initialize the active kill-command to no-op (once per machine; re-run after a wipe demo)
bash ~/Downloads/dtl-app/lab/kill/sign-command.sh DTL-Ubuntu-Test-Device cmd-init none 2>/dev/null > ~/Downloads/dtl-app/lab/kill/kill-command.json

# 3. Start nginx container (four server blocks: :8443 mTLS on (tool-1), :8445 mTLS on + CN gate
#    (tool-2, always 403 for this device), :8444 mTLS optional + /kill endpoint)
podman run -d --name dtl-mtls-nginx \
  -p 8443:8443 -p 8444:8444 -p 8445:8445 \
  -v ~/Downloads/dtl-app/lab/nginx/mtls.conf:/etc/nginx/conf.d/default.conf:ro,Z \
  -v ~/Downloads/dtl-app/lab/certs:/etc/nginx/certs:ro,Z \
  -v ~/Downloads/dtl-app/lab/kill:/etc/nginx/kill:ro,Z \
  nginx:alpine

# 4. Import CA + client cert into NSS (~/.pki/nssdb)
bash lab/provision-nss.sh

# 5. (After a wipe) Re-inject client cert only (CA survives the wipe)
bash lab/reprovision-cert.sh
```

## Verify (curl)

```bash
cd ~/Downloads/dtl-app/lab/certs

# WITH cert -> :8443 (expect the tool-1 HTML page; grep the embedded comment for verify=SUCCESS -
# the body is HTML, but the verify=/subject= line is kept as an HTML
# comment specifically so this check still works)
curl -s --cacert ca.pem --cert client.crt --key client.key https://localhost:8443/ | grep 'verify='

# NO cert -> :8443 (expect HTTP 400)
curl -s -o /dev/null -w "HTTP %{http_code}\n" --cacert ca.pem https://localhost:8443/

# WITH cert -> :8445 (expect HTTP 403 - tool-2, this device's CN is not on the approved list)
curl -s -o /dev/null -w "HTTP %{http_code}\n" --cacert ca.pem --cert client.crt --key client.key https://localhost:8445/

# NO cert -> :8444 (expect verify=NONE)
curl -s --cacert ca.pem https://localhost:8444/

# Nav-test page - with cert -> :8443/nav (expect HTML with test links)
curl -s --cacert ca.pem --cert client.crt --key client.key https://localhost:8443/nav | grep -o '<title>.*</title>'

# Kill endpoint - :8444/kill, no client cert needed
curl -s --cacert ca.pem https://localhost:8444/kill
```

## Navigation test page

`https://localhost:8443/nav` serves a page with four links to exercise the default-deny allow-list:

| Link | Expected behaviour |
|---|---|
| Same-host `/nav` | Loads in the same window (allow-listed) |
| `https://localhost:8444/` | Page stays put; `[nav] BLOCKED` logged (not in NAV_ALLOWLIST) |
| `https://example.com/` | Page stays put; `[nav] BLOCKED` logged (blocked before any network call) |
| Same-host `_blank` | Loads in the same view - no new window (setWindowOpenHandler deny) |

**nginx restart required** when `mtls.conf` changes (conf is read at startup, not hot-reloaded).
Static files (`kill-command.json`) are served fresh on each request - no restart needed to swap them.

```bash
podman stop dtl-mtls-nginx && podman rm dtl-mtls-nginx
podman run -d --name dtl-mtls-nginx \
  -p 8443:8443 -p 8444:8444 -p 8445:8445 \
  -v ~/Downloads/dtl-app/lab/nginx/mtls.conf:/etc/nginx/conf.d/default.conf:ro,Z \
  -v ~/Downloads/dtl-app/lab/certs:/etc/nginx/certs:ro,Z \
  -v ~/Downloads/dtl-app/lab/kill:/etc/nginx/kill:ro,Z \
  nginx:alpine
```

## Kill-command swap (wipe demo)

`kill-command.json` is generated fresh by `lab/setup.sh` (a signed no-op) and is not committed -
sign a new command directly to change what the app's next poll sees.

```bash
# No-op (app polls, nothing happens):
bash ~/Downloads/dtl-app/lab/kill/sign-command.sh DTL-Ubuntu-Test-Device cmd-demo-none none 2>/dev/null > ~/Downloads/dtl-app/lab/kill/kill-command.json

# Activate wipe (next app poll triggers wipe):
bash ~/Downloads/dtl-app/lab/kill/sign-command.sh DTL-Ubuntu-Test-Device cmd-demo-wipe wipe 2>/dev/null > ~/Downloads/dtl-app/lab/kill/kill-command.json

# Confirm what's currently served:
curl -s --cacert ~/Downloads/dtl-app/lab/certs/ca.pem https://localhost:8444/kill | python3 -m json.tool
```
