# DTL Kill-Switch Lab - Ed25519 signing infra (M3 Step 1)

Per-machine lab infra. **Not committed (private key).** Same discipline as `lab/certs/` and
`lab/zitadel/`. The private key plays the role of DTL's control-plane signing key.

---

## Files

| File                  | Committed? | Purpose                                              |
|-----------------------|-----------|------------------------------------------------------|
| `gen-keypair.sh`      | Yes        | Generate a fresh Ed25519 keypair on this machine     |
| `sign-command.sh`     | Yes        | Sign a kill command                                  |
| `verify-check.js`     | Yes        | Standalone Node verifier - M3 Step 1 gate check      |
| `kill-signing.key`    | **NO**     | Ed25519 private signing key (git-ignored)            |
| `kill-signing.pub`    | Yes        | Ed25519 public key (hardcoded in the app later)      |
| `kill-wipe.json`      | Yes        | Signed sample: `action:"wipe"`                       |
| `kill-none.json`      | Yes        | Signed sample: `action:"none"` (no-op)               |

---

## Device identity

`device_id` = **`DTL-Ubuntu-Test-Device`** - matches the mTLS client-cert Subject CN from M0.
Consistent across the PoC: the same identity string appears in the TLS handshake and the kill target.

---

## BRING UP (if keypair is missing - e.g. fresh clone)

```bash
cd lab/kill
bash gen-keypair.sh
# Then re-sign the sample commands:
bash sign-command.sh DTL-Ubuntu-Test-Device cmd-001 wipe  2>/dev/null > kill-wipe.json
bash sign-command.sh DTL-Ubuntu-Test-Device cmd-002 none  2>/dev/null > kill-none.json
```

After regenerating the keypair, update `KILL.publicKeyPem` in `src/main/config.js` (Step 3).

---

## VERIFY - M3 Step 1 hand-verification gate (no Electron needed)

```bash
cd ~/Downloads/dtl-app

# Both should print VALID:
node lab/kill/verify-check.js lab/kill/kill-wipe.json
node lab/kill/verify-check.js lab/kill/kill-none.json

# Tamper test - should print INVALID:
node -e "
  const d = JSON.parse(require('fs').readFileSync('lab/kill/kill-wipe.json','utf8'))
  d.action = 'none'   // flip the action
  require('fs').writeFileSync('/tmp/tampered.json', JSON.stringify(d,null,2))
"
node lab/kill/verify-check.js /tmp/tampered.json   # -> INVALID - bad signature
```

All three pass -> Step 1 is verified. Proceed to Step 2 (serve via nginx `:8444`).

---

## Step 2 - Serve via nginx (M3 Step 2 gate)

The kill endpoint is `https://localhost:8444/kill` (TLS, no client cert required - D-M3-9).
`kill-command.json` is the **active** file nginx serves; swap it to toggle none ↔ wipe.

> **Permission gotcha:** nginx runs as a different uid inside the container; JSON files must be
> world-readable (`chmod 644`). `sign-command.sh` sets this automatically. If you write a file
> manually (e.g. `cp kill-none.json kill-command.json`), run `chmod 644 kill-command.json` after.

### First-time setup (or after container was removed)

```bash
cd ~/Downloads/dtl-app

# Initialize active command to no-op:
cp lab/kill/kill-none.json lab/kill/kill-command.json

# Start (or restart) nginx with the kill volume mount:
podman stop dtl-mtls-nginx; podman rm dtl-mtls-nginx 2>/dev/null || true
podman run -d --name dtl-mtls-nginx \
  -p 8443:8443 -p 8444:8444 \
  -v ~/Downloads/dtl-app/lab/nginx/mtls.conf:/etc/nginx/conf.d/default.conf:ro,Z \
  -v ~/Downloads/dtl-app/lab/certs:/etc/nginx/certs:ro,Z \
  -v ~/Downloads/dtl-app/lab/kill:/etc/nginx/kill:ro,Z \
  nginx:alpine
```

### Verify Step 2 (M3 Step 2 gate)

```bash
cd ~/Downloads/dtl-app

# 1. Returns signed JSON (action:"none"):
curl -s --cacert lab/certs/ca.pem https://localhost:8444/kill

# 2. Byte-identical to source (no reformatting - signature must not break):
curl -s --cacert lab/certs/ca.pem https://localhost:8444/kill | diff - lab/kill/kill-command.json
# -> no output (identical)

# 3. Swap to wipe and confirm:
cp lab/kill/kill-wipe.json lab/kill/kill-command.json
curl -s --cacert lab/certs/ca.pem https://localhost:8444/kill | python3 -m json.tool
# -> action: "wipe"

# 4. Reset to none after demo:
cp lab/kill/kill-none.json lab/kill/kill-command.json
```

All pass -> Step 2 verified. Proceed to Step 3 (in-app verifier, no wipe yet).

## SIGN A NEW COMMAND

```bash
# Wipe command:
bash lab/kill/sign-command.sh DTL-Ubuntu-Test-Device cmd-<N> wipe 2>/dev/null > lab/kill/kill-wipe.json

# No-op (poll placeholder):
bash lab/kill/sign-command.sh DTL-Ubuntu-Test-Device cmd-<N> none 2>/dev/null > lab/kill/kill-none.json
```

`issued_at` defaults to now (epoch ms). Pass a 4th argument to override.
