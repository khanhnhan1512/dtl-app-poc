# M4 Step 2 — Two-layer compose test (D-M4-3)

Demonstrates the "device AND user" model as three distinct, repeatable cases.
Serve `kill-none.json` throughout so the kill-switch poller does not interfere.

**Before any case:** nginx `:8443` must be running with the lab CA/server cert in place.

```bash
cd ~/Downloads/dtl-app
cp lab/kill/kill-none.json lab/kill/kill-command.json && chmod 644 lab/kill/kill-command.json
podman ps | grep dtl-mtls-nginx   # confirm up
```

App launch wrapper (required for safeStorage on the VM):
```bash
dbus-run-session -- bash -c '
  eval $(gnome-keyring-daemon --start --components=secrets)
  GNOME_DESKTOP_SESSION_ID=this-is-deprecated ELECTRON_DISABLE_SANDBOX=1 \
    ./node_modules/.bin/electron .
'
```

---

## Case (a) — NO CERT → transport-layer block

**Setup:**
```bash
# Remove the device cert + private key from NSS (mirrors wipe.js clause b):
certutil -F -n "DTL-Ubuntu-Test-Device" -d sql:$HOME/.pki/nssdb

# Confirm gone:
certutil -L -d sql:$HOME/.pki/nssdb     # DTL-Ubuntu-Test-Device absent
certutil -K -d sql:$HOME/.pki/nssdb     # no private key
```

**Launch:** (tokens.enc must be present — warm start)

**Observable:** portal region renders nginx `400 No required SSL certificate`.
`verify=SUCCESS` never appears. The OIDC gate passes (token present) but the
transport layer blocks at the TLS handshake — no cert to present.

**Restore cert before case (c):**
```bash
bash lab/reprovision-cert.sh
certutil -L -d sql:$HOME/.pki/nssdb     # DTL-Ubuntu-Test-Device restored
```

**Expected log on the 400 page:**
```
[session] transport blocked — no valid mTLS (HTTP 400)
```
The `[session]` line is gated on a 2xx main-frame navigation (`did-navigate`
`httpResponseCode`). A 400 response triggers the "transport blocked" path instead,
so a bogus `device=…` identity line is never emitted on the error page.

---

## Case (b) — CERT PRESENT, NO TOKEN → portal-layer (auth-gate) block

**Setup:** (cert must be in NSS — run reprovision-cert.sh if needed)
```bash
rm -f ~/.config/"DTL App"/tokens.enc

# Confirm gone:
ls ~/.config/"DTL App"/tokens.enc   # → No such file or directory
```

**Launch.**

**Observable:** system browser opens immediately for OIDC login. Portal window is NOT
shown pre-login. The M2 auth gate detects no valid token and starts the OIDC flow before
`createShell()` is called — so the portal never loads until the user authenticates.

---

## Case (c) — CERT + TOKEN → full access

**Setup:** both present (run reprovision-cert.sh + re-login if coming from case (a)/(b)).
```bash
certutil -L -d sql:$HOME/.pki/nssdb         # DTL-Ubuntu-Test-Device present
ls ~/.config/"DTL App"/tokens.enc           # file exists
```

**Launch.**

**Observables:**
1. Portal renders `verify=SUCCESS … CN=DTL-Ubuntu-Test-Device` — mTLS accepted.
2. Log contains:
   ```
   [session] device=DTL-Ubuntu-Test-Device user=testuser@dtl.local
   ```
   Both identity layers visible together in one log line.

---

## Run order reminder

```
(a) no cert  →  certutil -F removes cert  →  observe 400 page
               ↓
               bash lab/reprovision-cert.sh   ← MUST RESTORE before (c)
               ↓
(b) no token →  rm tokens.enc             →  observe OIDC browser opens
               ↓
               re-login via OIDC to restore token
               ↓
(c) both     →  verify=SUCCESS + [session] device+user
```
